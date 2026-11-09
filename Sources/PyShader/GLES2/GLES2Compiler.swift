//
//  GLES2Compiler.swift
//  PyShader
//
//  Drives GLSL ES 1.00 generation for one module: every user function, the
//  monomorphized lambdas and list-taking functions, and a `main()` per
//  stage that hands the Python entry point what the target promises, from
//  what the OpenGL ES 2 program provides, under the names `GLES2Options` gives:
//
//      varying  uv, color                the generated vertex stage's outputs
//      uniform  the content sampler      the texture `layer()` samples
//      uniform  time, resolution, …      the inputs the target names, set by the app
//      uniform  <argument>               each shader argument, by its name
//
//  Each stage holds only the declarations its `main()` reaches.
//

import PySwiftAST

/// A GLSL expression with its PyShader type.
struct GLValue {
    var code: String
    var type: ShaderType
    /// The value when it is a literal, for folding constant arithmetic (a
    /// `range()` bound must be a constant in OpenGL ES 2).
    var literal: GLLiteral? = nil
    /// Built from literals and `for` counters only: what GLSL ES 1.00 lets
    /// index an array or a vector (its Appendix A).
    var isConstantIndex = false

    static let void = GLValue(code: "", type: .void)
}

enum GLLiteral: Equatable {
    case int(Int)
    case float(Double)
    case bool(Bool)
}

/// One top-level declaration of a stage and the ones it needs above it.
struct GLDeclaration {
    enum Kind: Int, Comparable {
        case structure, attribute, uniform, varying, variable, function
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    let kind: Kind
    /// The declaration itself; a function's whole definition.
    let text: String
    /// A function's prototype, declared before every definition.
    var prototype: String?
    let uses: Swift.Set<String>
    let order: Int
}

final class GLES2Compiler {
    let program: ShaderProgram
    let sourceFile: String?
    let options: GLES2Options

    private var declarations: [String: GLDeclaration] = [:]
    private var declarationCount = 0
    /// Declaration keys that are not declarations: `ext:derivatives`.
    static let derivativesKey = "ext:derivatives"

    private var structNames: [ShaderType: String] = [:]
    private var fieldNames: [String: String] = [:]
    private var tupleCount = 0
    /// Every GLSL identifier at the top level of a stage, the interface's
    /// included, so nothing generated shadows or redeclares one.
    private var taken: Swift.Set<String>
    /// The Python functions' GLSL names.
    private var functionNames: [String: String] = [:]
    private var callGraph: [String: Swift.Set<String>] = [:]
    private var inlining: [String] = []
    private var lambdaInstances: [String: (name: String, returnType: ShaderType)] = [:]
    private var lambdaCounter = 0
    private var genericInstances: [GenericKey: String] = [:]
    private var genericCounts: [String: Int] = [:]
    /// The module variables, by Python name: GLSL globals set by `py_globals()`.
    private(set) var variables: [String: (name: String, type: ShaderType)] = [:]
    private var globalsInit: String?

    init(program: ShaderProgram, sourceFile: String?, options: GLES2Options) {
        self.program = program
        self.sourceFile = sourceFile
        self.options = options
        var names = Swift.Set(options.names.map(\.name))
        names.insert("py_globals")
        names.formUnion(Self.inputUniforms.keys)
        for argument in program.target.arguments { names.insert(argument.name) }
        for texture in program.target.textures { names.insert(texture.name); names.insert(texture.name + "_size") }
        if case .structure(_, let members) = program.varyingsStruct {
            for (name, _) in members.dropFirst() { names.insert("v_" + name) }
        }
        taken = names
    }

    /// The inputs a compute or graphics target reads from uniforms of the
    /// same name, set by the app.
    static let inputUniforms: [String: ShaderType] = [
        "time": .float, "time_delta": .float, "frame": .int,
        "resolution": .float(2), "mouse": .float(2), "mouse_click": .float(2),
    ]

    func compile() throws -> GLES2Shader {
        try options.validate()
        try checkEntries()
        for name in program.functionOrder where !program.functions[name]!.isGeneric {
            functionNames[name] = program.isEntry(name) ? globalName("py_" + name) : globalName(name)
        }
        try emitGlobalsInit()
        for name in program.functionOrder where !program.functions[name]!.isGeneric {
            let fn = program.functions[name]!
            let forwards = program.entry(named: name)?.forwardsColor ?? false
            let writer = GLES2Writer(
                compiler: self, name: name, returnType: fn.returnType,
                implicitReturn: forwards ? { try Self.forwardColor($0, entry: name, line: fn.def.lineno) } : nil
            )
            try PyShaderError.attributing(to: program.origin(of: name)) {
                try writer.emitFunction(glName: functionNames[name]!, params: fn.params, body: fn.def.body, line: fn.def.lineno)
            }
        }
        try checkRecursion()
        switch program.target {
        case .fragment(let interface):
            let (fragment, uses) = try fragmentStage(interface)
            return GLES2Shader(vertex: quadVertexStage(for: uses), fragment: fragment)
        case .computeImage(let interface):
            let (fragment, uses) = try computeStage(interface)
            return GLES2Shader(vertex: quadVertexStage(for: uses), fragment: fragment)
        case .graphics(let interface):
            return try graphicsStages(interface)
        }
    }

    // MARK: - What OpenGL ES 2 cannot take

    /// The entry points' inputs that have no OpenGL ES 2 counterpart, reported
    /// at the `def` before anything else is compiled.
    private func checkEntries() throws {
        for name in program.functionOrder where program.isEntry(name) {
            let fn = program.functions[name]!
            let line = fn.def.lineno
            try PyShaderError.attributing(to: program.origin(of: name)) {
                for param in fn.params {
                    switch param.type {
                    case .floatArray:
                        throw PyShaderError("array argument `\(param.name)` has no OpenGL ES 2 equivalent: its uniforms have a size fixed in the shader, an array argument a length the app picks", line: line)
                    case .inputList:
                        throw PyShaderError("the list input `\(param.name)` is read from a storage buffer, which OpenGL ES 2 does not have", line: line)
                    default:
                        if let input = program.inputType, param.type == input, param.type != program.varyingsStruct {
                            throw PyShaderError("the class input `\(param.name)` is read from a storage buffer, which OpenGL ES 2 does not have; pass its fields as shader arguments", line: line)
                        }
                    }
                    if case .graphics(let i) = program.target, name == i.vertexEntryPoint {
                        switch i.inputs[param.name] {
                        case .vertexIndex:
                            throw PyShaderError("`\(param.name)`: OpenGL ES 2 has no vertex index (no `gl_VertexID`)", line: line)
                        case .instanceIndex:
                            throw PyShaderError("`\(param.name)`: OpenGL ES 2 has no instancing (no `gl_InstanceID`)", line: line)
                        default:
                            break
                        }
                    }
                }
                if case .graphics(let i) = program.target, name == i.vertexEntryPoint, case .structure(let cls, let members) = fn.returnType {
                    for (field, type) in members.dropFirst() where !type.isFloat {
                        throw PyShaderError("varying `\(field)` of `\(cls)` is a `\(type)`: OpenGL ES 2 interpolates only floats, vectors and matrices of them", line: line)
                    }
                }
            }
        }
    }

    // MARK: - Names

    /// A free top-level GLSL name for `name`: itself when GLSL allows it and
    /// nothing else has it, otherwise prefixed (and numbered).
    func globalName(_ python: String) -> String {
        // What an imported module defines is linked in under its qualified name (`palette.ramp`).
        let name = python.replacingOccurrences(of: ".", with: "_")
        var candidate = GLES2Names.usable(name) && !taken.contains(name) ? name : GLES2Names.prefixed(name)
        var n = 2
        let base = candidate
        while taken.contains(candidate) {
            candidate = "\(base)_\(n)"
            n += 1
        }
        taken.insert(candidate)
        return candidate
    }

    /// Whether a local may be called `name`: not a GLSL word, and not a
    /// top-level name it would hide (a function, a struct, a uniform).
    func isFreeLocalName(_ name: String) -> Bool {
        GLES2Names.usable(name) && (!taken.contains(name) || mainOnly.contains(name))
            && program.functions[name] == nil && program.structs[name] == nil
    }

    /// Interface names only `main()` reads, which a function's local may
    /// share: `main()` has no locals to hide them.
    private lazy var mainOnly: Swift.Set<String> = {
        // The content sampler is the one interface name a function samples.
        var names = Swift.Set(options.names.map(\.name).filter { $0 != options.contentSampler })
        names.formUnion(Self.inputUniforms.keys)
        for argument in program.target.arguments { names.insert(argument.name) }
        if case .structure(_, let members) = program.varyingsStruct {
            for (name, _) in members.dropFirst() { names.insert("v_" + name) }
        }
        return names
    }()

    /// A struct field's GLSL name.
    func fieldName(_ name: String) -> String {
        if let known = fieldNames[name] { return known }
        let gl = GLES2Names.usable(name) ? name : GLES2Names.prefixed(name)
        fieldNames[name] = gl
        return gl
    }

    func functionName(_ python: String) -> String? { functionNames[python] }

    // MARK: - Types

    /// `type` as GLSL spells it; a struct or tuple is declared on first use.
    func typeName(_ type: ShaderType, line: Int, uses: inout Swift.Set<String>) throws -> String {
        switch type {
        case .void:
            return "void"
        case .scalar(let k):
            return try scalarName(k, line: line)
        case .vector(let k, let n):
            switch k {
            case .bool: return "bvec\(n)"
            case .float: return "vec\(n)"
            default:
                _ = try scalarName(k, line: line)
                return "ivec\(n)"
            }
        case .matrix(_, let columns, let rows):
            guard columns == rows else {
                throw PyShaderError("`\(type)`: OpenGL ES 2 has only square matrices (`float2x2`, `float3x3`, `float4x4`)", line: line)
            }
            return "mat\(columns)"
        case .structure, .tuple:
            let name = try structName(type, line: line)
            uses.insert("struct:" + name)
            return name
        case .array:
            throw PyShaderError("OpenGL ES 2 has no lists of lists", line: line)
        case .sampledImage(.sampled2D):
            return "sampler2D"
        default:
            throw PyShaderError("`\(type)` has no OpenGL ES 2 equivalent", line: line)
        }
    }

    private func scalarName(_ kind: ScalarKind, line: Int) throws -> String {
        switch kind {
        case .bool: return "bool"
        // `half` is a float here: GLSL ES says how precise in a qualifier,
        // which desktop GLSL would not take.
        case .float: return "float"
        case .int(32, true): return "int"
        case .int(32, false):
            throw PyShaderError("OpenGL ES 2 has no unsigned integers (`uint`)", line: line)
        case .int:
            throw PyShaderError("OpenGL ES 2 has no 16-bit integers (`\(kind.name)`)", line: line)
        }
    }

    /// `type name` — or `element name[n]` for a list — as a declaration.
    func declaration(_ name: String, _ type: ShaderType, line: Int, uses: inout Swift.Set<String>) throws -> String {
        if case .array(let element, let count) = type {
            return try typeName(element, line: line, uses: &uses) + " \(name)[\(count)]"
        }
        return try typeName(type, line: line, uses: &uses) + " " + name
    }

    /// A class's or tuple's struct, declared once. A struct holding a list
    /// cannot be assigned or returned in GLSL ES 1.00, so it is refused.
    private func structName(_ type: ShaderType, line: Int) throws -> String {
        if let known = structNames[type] { return known }
        let name: String
        let fields: [(String, ShaderType)]
        switch type {
        case .structure(let python, let members):
            for (field, member) in members {
                if case .array = member {
                    throw PyShaderError("class `\(python)`: field `\(field)` is a list, and OpenGL ES 2 cannot assign or return a struct holding one", line: line)
                }
            }
            name = globalName(python)
            fields = members.map { (fieldName($0.0), $0.1) }
        case .tuple(let members):
            for member in members {
                if case .array = member {
                    throw PyShaderError("a tuple holding a list has no OpenGL ES 2 equivalent: a struct holding an array cannot be assigned or returned", line: line)
                }
            }
            name = globalName("py_tuple\(tupleCount)")
            tupleCount += 1
            fields = members.enumerated().map { ("m\($0.offset)", $0.element) }
        default:
            preconditionFailure()
        }
        var uses: Swift.Set<String> = []
        var text = "struct \(name) {\n"
        for (field, member) in fields {
            text += "    " + (try typeName(member, line: line, uses: &uses)) + " \(field);\n"
        }
        text += "};\n"
        structNames[type] = name
        declare("struct:" + name, kind: .structure, text: text, uses: uses)
        return name
    }

    /// The GLSL field of member `index` of a class or tuple.
    func member(_ type: ShaderType, _ index: Int) -> String {
        switch type {
        case .structure(_, let members): return fieldName(members[index].0)
        default: return "m\(index)"
        }
    }

    // MARK: - Declarations

    func declare(_ key: String, kind: GLDeclaration.Kind, text: String, prototype: String? = nil, uses: Swift.Set<String> = []) {
        guard declarations[key] == nil else { return }
        declarations[key] = GLDeclaration(kind: kind, text: text, prototype: prototype, uses: uses, order: declarationCount)
        declarationCount += 1
    }

    /// `uniform <type> <name>;`, keyed so each stage declares it once.
    func uniform(_ name: String, _ type: ShaderType, line: Int, uses: inout Swift.Set<String>) throws -> GLValue {
        var own: Swift.Set<String> = []
        let text = "uniform " + (try declaration(name, type, line: line, uses: &own)) + ";"
        declare("uniform:" + name, kind: .uniform, text: text, uses: own)
        uses.insert("uniform:" + name)
        return GLValue(code: name, type: type)
    }

    /// `attribute <type> <name>;` — a vertex stage's per-vertex input.
    func attribute(_ name: String, _ type: ShaderType, line: Int, uses: inout Swift.Set<String>) throws -> GLValue {
        var own: Swift.Set<String> = []
        let text = "attribute " + (try declaration(name, type, line: line, uses: &own)) + ";"
        declare("attribute:" + name, kind: .attribute, text: text, uses: own)
        uses.insert("attribute:" + name)
        return GLValue(code: name, type: type)
    }

    func varying(_ name: String, _ type: ShaderType, line: Int, uses: inout Swift.Set<String>) throws -> GLValue {
        var own: Swift.Set<String> = []
        let text = "varying " + (try declaration(name, type, line: line, uses: &own)) + ";"
        declare("varying:" + name, kind: .varying, text: text, uses: own)
        uses.insert("varying:" + name)
        return GLValue(code: name, type: type)
    }

    /// A helper function GLSL ES 1.00 lacks (`sinh`, `round`…), written once
    /// per type it is called with. `body` gets the GLSL type's name.
    func helper(_ name: String, type: ShaderType, line: Int, uses: inout Swift.Set<String>, body: (String) -> String) throws -> String {
        var own: Swift.Set<String> = []
        let t = try typeName(type, line: line, uses: &own)
        let gl = "pyx_\(name)_\(t)"
        let key = "fn:" + gl
        if declarations[key] == nil {
            taken.insert(gl)
            let prototype = "\(t) \(gl)(\(t) x)"
            declare(key, kind: .function, text: prototype + " {\n" + body(t) + "}\n", prototype: prototype, uses: own)
        }
        uses.insert(key)
        return gl
    }

    // MARK: - Module variables

    func variable(_ name: String) -> (name: String, type: ShaderType)? { variables[name] }

    /// `py_globals()`: sets each module variable from its initializer, in
    /// order. GLSL ES 1.00 globals take only constant initializers, so every
    /// `main()` calls it first, as the SPIR-V entry points do.
    private func emitGlobalsInit() throws {
        guard !program.variableOrder.isEmpty else { return }
        let writer = GLES2Writer(compiler: self, name: "py_globals", returnType: .void)
        let name = "py_globals"
        let prototype = "void \(name)()"
        let text = try writer.emitBody(prototype: prototype) { w in
            for python in self.program.variableOrder {
                let g = self.program.variables[python]!
                let value = try PyShaderError.attributing(to: self.program.origin(of: python)) {
                    var value = try w.emitExpression(g.expr)
                    if let annotation = g.annotation {
                        let type = try self.program.resolveType(annotation, line: g.line)
                        value = try w.coerce(value, to: type, line: g.line)
                    }
                    guard value.type.isStorable else {
                        throw PyShaderError("cannot store a `\(value.type)` in the module variable `\(python)`", line: g.line)
                    }
                    return value
                }
                let gl = self.globalName(python)
                var own: Swift.Set<String> = []
                let text = (try self.declaration(gl, value.type, line: g.line, uses: &own)) + ";"
                self.declare("var:" + gl, kind: .variable, text: text, uses: own)
                w.uses.insert("var:" + gl)
                try w.store(code: gl, type: value.type, value, line: g.line)
                self.variables[python] = (gl, value.type)
            }
        }
        declare("fn:" + name, kind: .function, text: text, prototype: prototype, uses: writer.uses)
        globalsInit = name
    }

    // MARK: - Functions

    func record(_ writer: GLES2Writer, prototype: String, text: String, glName: String) {
        declare("fn:" + glName, kind: .function, text: text, prototype: prototype, uses: writer.uses)
    }

    func recordCall(from: String, to: String) {
        callGraph[from, default: []].insert(to)
    }

    /// `fn` for one call's list lengths, once per distinct set, named as the SPIR-V instances are.
    func instantiate(_ fn: ShaderFunctionSignature, params: [(name: String, type: ShaderType)]) throws -> String {
        let key = GenericKey(name: fn.name, types: params.map(\.type))
        if let name = genericInstances[key] { return name }
        let count = (genericCounts[fn.name] ?? 0) + 1
        genericCounts[fn.name] = count
        let name = globalName(count == 1 ? fn.name : "\(fn.name)_\(count)")
        genericInstances[key] = name
        let writer = GLES2Writer(compiler: self, name: fn.name, returnType: fn.returnType)
        try PyShaderError.attributing(to: program.origin(of: fn.name)) {
            try writer.emitFunction(glName: name, params: params, body: fn.def.body, line: fn.def.lineno)
        }
        return name
    }

    /// A lambda as a function for the argument types it is called with.
    func callLambda(_ template: LambdaTemplate, args: [GLValue], from caller: GLES2Writer, line: Int) throws -> GLValue {
        let params = template.lambda.args.posonlyArgs + template.lambda.args.args
        guard params.count == args.count else {
            throw PyShaderError("`\(template.name)` takes \(params.count) argument(s), got \(args.count)", line: line)
        }
        let key = template.name + "(" + args.map { "\($0.type)" }.joined(separator: ",") + ")@\(template.line)"
        let instance: (name: String, returnType: ShaderType)
        if let existing = lambdaInstances[key] {
            instance = existing
        } else {
            lambdaCounter += 1
            let name = globalName("\(template.name == "<lambda>" ? "lambda" : template.name)_\(lambdaCounter)")
            let writer = GLES2Writer(compiler: self, name: name, returnType: .void)
            let paramList = zip(params, args).map { (name: $0.arg, type: $1.type) }
            let returnType = try PyShaderError.attributing(to: program.origin(of: template.name)) {
                try writer.emitLambda(glName: name, params: paramList, body: template.lambda.body, line: template.line)
            }
            instance = (name, returnType)
            lambdaInstances[key] = instance
        }
        caller.uses.insert("fn:" + instance.name)
        let code = "\(instance.name)(" + args.map(\.code).joined(separator: ", ") + ")"
        return GLValue(code: code, type: instance.returnType)
    }

    private struct GenericKey: Hashable {
        let name: String
        let types: [ShaderType]
    }

    func withGlobalInlining<T>(_ name: String, line: Int, _ body: () throws -> T) throws -> T {
        if inlining.contains(name) {
            throw PyShaderError("module constant `\(name)` refers to itself", line: line)
        }
        inlining.append(name)
        defer { inlining.removeLast() }
        return try body()
    }

    private func checkRecursion() throws {
        var visiting: Swift.Set<String> = []
        var done: Swift.Set<String> = []
        func visit(_ n: String, path: [String]) throws {
            if done.contains(n) { return }
            if visiting.contains(n) {
                let cycle = (path.drop(while: { $0 != n }) + [n]).joined(separator: " -> ")
                throw PyShaderError("recursion is not allowed in shader code: \(cycle)", line: program.functions[n]?.def.lineno, file: program.origin(of: n))
            }
            visiting.insert(n)
            for m in callGraph[n] ?? [] { try visit(m, path: path + [n]) }
            visiting.remove(n)
            done.insert(n)
        }
        for n in program.functionOrder { try visit(n, path: []) }
    }

    /// `return` without a value in an entry point forwards `color`, as in SPIR-V.
    private static func forwardColor(_ writer: GLES2Writer, entry: String, line: Int) throws -> GLValue {
        if let color = writer.lookupLocal("color"), color.type == .float(4) {
            return GLValue(code: color.name, type: color.type)
        }
        throw PyShaderError("`\(entry)` must return a `float4`, or take `color` as a parameter to forward it", line: line)
    }

    // MARK: - Host resources

    /// `layer(p)`: the `contentSampler` uniform, when the target samples content.
    func sampleContent(at coordinate: GLValue, from w: GLES2Writer, line: Int) throws -> GLValue {
        guard program.target.contentBinding != nil else {
            throw PyShaderError("layer() needs a content image; this target does not provide one", line: line)
        }
        let texture = try uniform(options.contentSampler, .sampledImage(.sampled2D), line: line, uses: &w.uses)
        return try sample(texture.code, at: coordinate, topDown: program.target.contentIsTopDown, from: w, line: line)
    }

    func texture(named name: String) -> ShaderTexture? {
        program.target.textures.first { $0.name == name }
    }

    func sampleTexture(_ texture: ShaderTexture, at coordinate: GLValue, from w: GLES2Writer, line: Int) throws -> GLValue {
        let sampler = try uniform(texture.name, .sampledImage(.sampled2D), line: line, uses: &w.uses)
        return try sample(sampler.code, at: coordinate, topDown: texture.isTopDown, from: w, line: line)
    }

    /// `a_size`: GLSL ES 1.00 cannot ask a texture its size, so the app sets
    /// it as an `ivec2` uniform of that name.
    func textureSize(named name: String, from w: GLES2Writer, line: Int) throws -> GLValue? {
        guard name.hasSuffix("_size"), texture(named: String(name.dropLast(5))) != nil else { return nil }
        return try uniform(name, .int(2), line: line, uses: &w.uses)
    }

    private func sample(_ sampler: String, at coordinate: GLValue, topDown: Bool, from w: GLES2Writer, line: Int) throws -> GLValue {
        var p = coordinate
        if topDown {
            p = try w.materialize(p, line: line)
            p = GLValue(code: "vec2(\(p.code).x, 1.0 - \(p.code).y)", type: .float(2))
        }
        return GLValue(code: "texture2D(\(sampler), \(p.code))", type: .float(4))
    }

    // MARK: - Stages

    private func header(_ stage: String) -> String {
        let target: String
        switch program.target {
        case .fragment: target = "fragment"
        case .computeImage: target = "compute"
        case .graphics: target = "graphics"
        }
        let file = sourceFile.map { " from \($0)" } ?? ""
        return "// PyShader\(file) (\(target) target): \(stage) stage, OpenGL ES 2 / GLSL ES 1.00"
    }

    /// The stage's source: what `main` uses, and everything that needs, in
    /// declaration order — structs, then the interface, then globals and
    /// functions (prototypes first, so the order of definitions is free).
    private func assemble(stage: String, main: String, uses: Swift.Set<String>) -> String {
        var needed: Swift.Set<String> = []
        var work = Array(uses)
        if let globalsInit { work.append("fn:" + globalsInit) }
        while let key = work.popLast() {
            guard needed.insert(key).inserted else { continue }
            if let d = declarations[key] { work += d.uses }
        }
        let decls = needed.compactMap { declarations[$0] }.sorted { ($0.kind, $0.order) < ($1.kind, $1.order) }
        var out = header(stage) + "\n\n#ifdef GL_ES\n"
        if needed.contains(Self.derivativesKey) {
            out += "#extension GL_OES_standard_derivatives : enable\n"
        }
        out += "precision highp float;\n#endif\n"
        var lastKind: GLDeclaration.Kind?
        for d in decls where d.kind != .function {
            if lastKind != d.kind { out += "\n" }
            out += d.text + (d.text.hasSuffix("\n") ? "" : "\n")
            lastKind = d.kind
        }
        let functions = decls.filter { $0.kind == .function }
        if !functions.isEmpty {
            out += "\n"
            for f in functions { out += f.prototype! + ";\n" }
            for f in functions { out += "\n" + f.text }
        }
        out += "\n" + main
        return out
    }

    /// `void main(void)`, calling `py_globals()` first when there are module variables.
    private func mainFunction(_ body: (GLES2Writer) throws -> Void) throws -> (text: String, uses: Swift.Set<String>) {
        let writer = GLES2Writer(compiler: self, name: "main", returnType: .void)
        let text = try writer.emitBody(prototype: "void main(void)") { w in
            if let globalsInit = self.globalsInit { w.line("\(globalsInit)();") }
            try body(w)
        }
        return (text, writer.uses)
    }

    /// A fragment target behind the generated vertex stage: `uv` and `color`
    /// are its `uvVarying` and `colorVarying`, the built-ins GL's own, the
    /// push constants uniforms of the same name. Returns what the stage uses
    /// too, for the vertex stage to write only the varyings it reads.
    private func fragmentStage(_ interface: FragmentInterface) throws -> (String, Swift.Set<String>) {
        let main = program.functions[interface.entryPoint]!
        let line = main.def.lineno
        guard interface.output.type == .float(4) else {
            throw PyShaderError("OpenGL ES 2 writes a `float4` color (`gl_FragColor`), not a `\(interface.output.type)`", line: line)
        }
        let (text, uses) = try mainFunction { w in
            var args: [String] = []
            for param in main.params {
                if let input = interface.inputs.first(where: { $0.name == param.name }) {
                    switch input.binding {
                    case .builtIn(.fragCoord): args.append(try w.coerce(GLValue(code: "gl_FragCoord", type: .float(4)), to: param.type, line: line).code)
                    case .builtIn(.pointCoord): args.append(try w.coerce(GLValue(code: "gl_PointCoord", type: .float(2)), to: param.type, line: line).code)
                    case .builtIn(.frontFacing): args.append("gl_FrontFacing")
                    case .location:
                        let name = param.name == "uv" ? self.options.uvVarying : param.name == "color" ? self.options.colorVarying : param.name
                        args.append(try self.varying(name, input.type, line: line, uses: &w.uses).code)
                    }
                } else if let constant = interface.pushConstants.first(where: { $0.name == param.name }) {
                    args.append(try self.uniform(constant.name, constant.type, line: line, uses: &w.uses).code)
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: line)
                }
            }
            w.uses.insert("fn:" + self.functionNames[interface.entryPoint]!)
            w.line("gl_FragColor = \(self.functionNames[interface.entryPoint]!)(\(args.joined(separator: ", ")));")
        }
        return (assemble(stage: "fragment", main: text, uses: uses), uses)
    }

    /// A compute target as one fragment per pixel of the quad drawn: `uv`
    /// is `uvVarying`, the rest of the inputs uniforms the app sets
    /// (`resolution` the quad's size in pixels, `mouse` y-up in it).
    private func computeStage(_ interface: ComputeImageInterface) throws -> (String, Swift.Set<String>) {
        let main = program.functions[interface.entryPoint]!
        let line = main.def.lineno
        let (text, uses) = try mainFunction { w in
            var fragCoord: String?
            func coord() throws -> String {
                if let fragCoord { return fragCoord }
                let uv = try self.varying(self.options.uvVarying, .float(2), line: line, uses: &w.uses)
                let resolution = try self.uniform("resolution", .float(2), line: line, uses: &w.uses)
                let name = try w.temp(.float(2), line: line)
                w.line("\(name) = \(uv.code) * \(resolution.code);")
                fragCoord = name
                return name
            }
            var args: [String] = []
            for param in main.params {
                if let input = interface.inputs[param.name] {
                    switch input {
                    case .uv:
                        args.append(try self.varying(self.options.uvVarying, .float(2), line: line, uses: &w.uses).code)
                    case .fragCoord:
                        args.append(try coord())
                    case .pixel:
                        // y-down, as the compute target's store location is.
                        let c = try coord()
                        args.append("ivec2(int(floor(\(c).x)), int(floor(resolution.y - \(c).y)))")
                    default:
                        args.append(try self.uniform(param.name, input.type, line: line, uses: &w.uses).code)
                    }
                } else if let argument = interface.arguments.first(where: { $0.name == param.name }) {
                    args.append(try self.uniform(argument.name, argument.kind.type, line: line, uses: &w.uses).code)
                } else if interface.textures.contains(where: { $0.name == param.name }) {
                    continue   // a handle: the sampler is a uniform the body names
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: line)
                }
            }
            let fn = self.functionNames[interface.entryPoint]!
            w.uses.insert("fn:" + fn)
            w.line("gl_FragColor = \(fn)(\(args.joined(separator: ", ")));")
        }
        return (assemble(stage: "fragment", main: text, uses: uses), uses)
    }

    /// Both stages of a graphics target. The vertex stage writes its first
    /// field to `gl_Position` (already GL's y-up clip space) and the others
    /// to `v_<field>` varyings, which the fragment stage takes by name.
    private func graphicsStages(_ interface: GraphicsInterface) throws -> GLES2Shader {
        let vertex = program.functions[interface.vertexEntryPoint]!
        let fragment = program.functions[interface.fragmentEntryPoint]!
        guard case .structure(_, let members) = vertex.returnType else { preconditionFailure() }
        let varyings = Array(members.dropFirst())
        let vertexLine = vertex.def.lineno
        let fragmentLine = fragment.def.lineno

        func input(_ name: String, _ input: GraphicsInterface.Input, _ w: GLES2Writer, line: Int) throws -> String {
            switch input {
            case .uv:
                let resolution = try self.uniform("resolution", .float(2), line: line, uses: &w.uses)
                return "(gl_FragCoord.xy / \(resolution.code))"
            case .fragCoord:
                return "gl_FragCoord.xy"
            case .pixel:
                let resolution = try self.uniform("resolution", .float(2), line: line, uses: &w.uses)
                return "ivec2(int(floor(gl_FragCoord.x)), int(floor(\(resolution.code).y - gl_FragCoord.y)))"
            case .frontFacing:
                return "gl_FrontFacing"
            case .positionAttribute:
                return try self.attribute(self.options.positionAttribute, .float(2), line: line, uses: &w.uses).code
            case .texcoordAttribute:
                return try self.attribute(self.options.texcoordAttribute, .float(2), line: line, uses: &w.uses).code
            case .colorAttribute:
                return try self.attribute(self.options.colorAttribute, .float(4), line: line, uses: &w.uses).code
            default:
                return try self.uniform(name, input.type, line: line, uses: &w.uses).code
            }
        }

        let (vertexText, vertexUses) = try mainFunction { w in
            var args: [String] = []
            for param in vertex.params {
                if let i = interface.inputs[param.name] {
                    switch i {
                    case .uv, .fragCoord, .pixel, .frontFacing:
                        throw PyShaderError("`\(param.name)` is a fragment input, not available in `\(interface.vertexEntryPoint)`", line: vertexLine)
                    default:
                        args.append(try input(param.name, i, w, line: vertexLine))
                    }
                } else if let argument = interface.arguments.first(where: { $0.name == param.name }) {
                    args.append(try self.uniform(argument.name, argument.kind.type, line: vertexLine, uses: &w.uses).code)
                } else if interface.textures.contains(where: { $0.name == param.name }) {
                    continue
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: vertexLine)
                }
            }
            let fn = self.functionNames[interface.vertexEntryPoint]!
            w.uses.insert("fn:" + fn)
            let result = try w.temp(vertex.returnType, line: vertexLine)
            w.line("\(result) = \(fn)(\(args.joined(separator: ", ")));")
            let position = "\(result).\(self.member(vertex.returnType, 0))"
            for matrix in self.options.positionMatrices { _ = try self.uniform(matrix, .matrix(.float(bits: 32), columns: 4, rows: 4), line: vertexLine, uses: &w.uses) }
            w.line("gl_Position = " + (self.options.positionMatrices + [position]).joined(separator: " * ") + ";")
            for (index, (name, type)) in varyings.enumerated() {
                let v = try self.varying("v_" + name, type, line: vertexLine, uses: &w.uses)
                w.line("\(v.code) = \(result).\(self.member(vertex.returnType, index + 1));")
            }
        }

        let (fragmentText, fragmentUses) = try mainFunction { w in
            var args: [String] = []
            for param in fragment.params {
                if param.type == vertex.returnType {
                    var fields = ["gl_FragCoord"]
                    for (name, type) in varyings {
                        fields.append(try self.varying("v_" + name, type, line: fragmentLine, uses: &w.uses).code)
                    }
                    let type = try self.typeName(vertex.returnType, line: fragmentLine, uses: &w.uses)
                    args.append("\(type)(\(fields.joined(separator: ", ")))")
                } else if let varying = varyings.first(where: { $0.0 == param.name }) {
                    args.append(try self.varying("v_" + varying.0, varying.1, line: fragmentLine, uses: &w.uses).code)
                } else if let i = interface.inputs[param.name] {
                    switch i {
                    case .vertexIndex, .instanceIndex, .positionAttribute, .texcoordAttribute, .colorAttribute:
                        throw PyShaderError("`\(param.name)` is a vertex input, not available in `\(interface.fragmentEntryPoint)`", line: fragmentLine)
                    default:
                        args.append(try input(param.name, i, w, line: fragmentLine))
                    }
                } else if let argument = interface.arguments.first(where: { $0.name == param.name }) {
                    args.append(try self.uniform(argument.name, argument.kind.type, line: fragmentLine, uses: &w.uses).code)
                } else if interface.textures.contains(where: { $0.name == param.name }) {
                    continue
                } else {
                    throw PyShaderError("`\(param.name)` is not a shader input", line: fragmentLine)
                }
            }
            let fn = self.functionNames[interface.fragmentEntryPoint]!
            w.uses.insert("fn:" + fn)
            w.line("gl_FragColor = \(fn)(\(args.joined(separator: ", ")));")
        }
        return GLES2Shader(
            vertex: assemble(stage: "vertex", main: vertexText, uses: vertexUses),
            fragment: assemble(stage: "fragment", main: fragmentText, uses: fragmentUses)
        )
    }

    /// The vertex stage of a fragment or compute target: a quad from
    /// `positionAttribute`, through `positionMatrices`, passing on the
    /// varyings the fragment stage reads (`fragmentUses`) and no others.
    private func quadVertexStage(for fragmentUses: Swift.Set<String>) -> String {
        let o = options
        let uv = fragmentUses.contains("varying:" + o.uvVarying)
        let color = fragmentUses.contains("varying:" + o.colorVarying)
        var declarations = ["attribute vec2 \(o.positionAttribute);"]
        if uv { declarations.append("attribute vec2 \(o.texcoordAttribute);") }
        if color, o.colorUniform == nil { declarations.append("attribute vec4 \(o.colorAttribute);") }
        for matrix in o.positionMatrices { declarations.append("uniform mat4 \(matrix);") }
        if color, let uniform = o.colorUniform { declarations.append("uniform vec4 \(uniform);") }
        if color, let opacity = o.opacityUniform { declarations.append("uniform float \(opacity);") }
        if color { declarations.append("varying vec4 \(o.colorVarying);") }
        if uv { declarations.append("varying vec2 \(o.uvVarying);") }
        var body: [String] = []
        if color {
            let source = o.colorUniform ?? o.colorAttribute
            body.append("\(o.colorVarying) = \(source)" + (o.opacityUniform.map { " * vec4(1.0, 1.0, 1.0, \($0))" } ?? "") + ";")
        }
        if uv {
            let t = o.texcoordAttribute
            body.append("\(o.uvVarying) = " + (o.uvIsTopDown ? "vec2(\(t).x, 1.0 - \(t).y)" : t) + ";")
        }
        let position = (o.positionMatrices + ["vec4(\(o.positionAttribute).xy, 0.0, 1.0)"]).joined(separator: " * ")
        body.append("gl_Position = \(position);")
        var out: String = header("vertex")
        out += "\n\n#ifdef GL_ES\nprecision highp float;\n#endif\n\n"
        out += declarations.joined(separator: "\n")
        out += "\n\nvoid main(void) {\n"
        for statement in body { out += "    \(statement)\n" }
        out += "}\n"
        return out
    }
}
