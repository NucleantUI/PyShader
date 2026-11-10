//
//  StageWriter.swift
//  Spirv2GLSL
//
//  One stage of a module as GLSL ES 1.00: the functions its entry point
//  reaches, the module variables they use as declarations (attributes,
//  varyings, uniforms, samplers, globals), the structs their types name,
//  and the file put together in the order GLSL needs: extensions,
//  precision, structs, interface, globals, prototypes, functions, `main`.
//

import SpirvCore

/// What a module variable is in GLSL.
enum GlobalRef {
    /// A name read and written as is: an attribute, varying, uniform, global
    /// or `gl_` variable. `writable` is false for inputs and uniforms, which
    /// nothing in the stage stores to.
    case variable(name: String, type: SpirvType, writable: Bool)
    /// A struct whose members are declared one by one: a uniform block's or
    /// push constants' members as uniforms, or `gl_PerVertex`'s built-ins.
    /// nil for a member with no GLSL ES 1.00 form, an error if used.
    case members(names: [String?], types: [SpirvType], writable: Bool, what: String)
    /// A sampler or an image the stage samples through `OpSampledImage`.
    case sampler(name: String)
    /// A separate sampler, which GLSL ES 1.00 folds into the image's sampler2D.
    case separateSampler
}

final class StageWriter {
    let module: SpirvModule
    let entry: SpirvEntryPoint
    let stage: GLSLESStage
    let options: GLSLESOptions
    let varyingNamesIn: [Int: String]

    let globalScope = NameScope()
    private(set) var globalRefs: [SpirvId: GlobalRef] = [:]
    private(set) var functionNames: [SpirvId: String] = [:]
    /// Reachable functions, each after the ones it calls; the entry point last.
    private(set) var functionOrder: [SpirvId] = []

    private var structNames: [SpirvId: String] = [:]
    private var structMemberNames: [SpirvId: [String]] = [:]
    private var structDeclarations: [String] = []
    private var interfaceDeclarations: [String] = []
    private var globalDeclarations: [String] = []
    /// Statements `main` runs first: the module variables' initializers GLSL
    /// cannot write at their declaration.
    private(set) var mainPrologue: [String] = []
    private(set) var extensions: [String] = []
    private var uniformNames: [String] = []
    private var attributes: [(location: Int, name: String)] = []
    private var varyingNamesOut: [Int: String] = [:]
    private var sizeUniforms: [String: String] = [:]
    /// The members of each uniform block the stage reads, so it declares only those.
    private var usedMembers: [SpirvId: Set<Int>] = [:]

    init(module: SpirvModule, entry: SpirvEntryPoint, stage: GLSLESStage, options: GLSLESOptions, varyingNames: [Int: String]) {
        self.module = module
        self.entry = entry
        self.stage = stage
        self.options = options
        self.varyingNamesIn = varyingNames
    }

    func error(_ message: String, at located: Located? = nil) -> Spirv2GLSLError {
        Spirv2GLSLError(message, file: located?.file.flatMap { module.strings[$0] }, line: located?.line)
    }

    func requireExtension(_ name: String) {
        let line = "#extension \(name) : enable"
        if !extensions.contains(line) { extensions.append(line) }
    }

    // MARK: Writing

    func write() throws -> GLSLESShader {
        try collectFunctions()
        let usedGlobals = scanGlobals()
        try declareInterface(usedGlobals)
        // Function names after the interface's, which are the host's and exact.
        for id in functionOrder {
            functionNames[id] = id == entry.function ? "main" : globalScope.unique(module.names[id] ?? "f\(id)")
        }

        var prototypes: [String] = []
        var bodies: [String] = []
        for id in functionOrder {
            let writer = try FunctionWriter(stage: self, function: module.functions[id]!, isEntry: id == entry.function)
            let text = try writer.write()
            bodies.append(text.body)
            if id != entry.function { prototypes.append(text.prototype + ";") }
        }

        var out: [String] = []
        if let header = options.header {
            out += header.split(separator: "\n", omittingEmptySubsequences: false).map { "// " + $0 }
            out.append("")
        }
        if let version = options.version { out.append("#version \(version)") }
        out += extensions
        if options.version != nil || !extensions.isEmpty { out.append("") }
        out += ["#ifdef GL_ES", "precision \(options.floatPrecision) float;", "#endif", ""]
        for section in [structDeclarations, interfaceDeclarations + sizeUniforms.sorted(by: { $0.key < $1.key }).map { "uniform ivec2 \($0.value);" }, globalDeclarations, prototypes] where !section.isEmpty {
            out += section
            out.append("")
        }
        out.append(bodies.joined(separator: "\n\n"))
        return GLSLESShader(
            source: out.joined(separator: "\n") + "\n",
            varyingNames: varyingNamesOut,
            uniforms: uniformNames + sizeUniforms.sorted(by: { $0.key < $1.key }).map(\.value),
            attributes: attributes.sorted { $0.location < $1.location }
        )
    }

    // MARK: Functions

    private func collectFunctions() throws {
        var state: [SpirvId: Bool] = [:]   // false: visiting, true: done
        func visit(_ id: SpirvId) throws {
            if state[id] == true { return }
            if state[id] == false { throw error("function `\(module.names[id] ?? "%\(id)")` calls itself, which GLSL forbids") }
            guard let f = module.functions[id] else { throw error("call of %\(id), which is not a function of the module") }
            state[id] = false
            for block in f.blocks {
                for i in block.body where i.op == .opFunctionCall {
                    try visit(i.operands[2])
                }
            }
            state[id] = true
            functionOrder.append(id)
        }
        try visit(entry.function)
    }

    /// The module variables the reached functions use, in module order, and
    /// the members of the uniform blocks they read.
    private func scanGlobals() -> [SpirvId] {
        var used = Set(entry.interface)
        for id in functionOrder {
            for block in module.functions[id]!.blocks {
                for i in block.body {
                    for w in i.operands where module.globals[w] != nil { used.insert(w) }
                    if i.op == .opAccessChain || i.op == .opInBoundsAccessChain, i.operands.count > 3,
                       module.globals[i.operands[2]] != nil, let k = module.intConstant(i.operands[3]) {
                        usedMembers[i.operands[2], default: []].insert(k)
                    }
                }
            }
        }
        // Only what the stage's own functions touch: an entry point's
        // interface list names variables of both stages in SPIR-V 1.4+.
        var touched = Set<SpirvId>()
        for id in functionOrder {
            for block in module.functions[id]!.blocks {
                for i in block.body { for w in i.operands where used.contains(w) { touched.insert(w) } }
            }
        }
        return module.globalOrder.filter { touched.contains($0) }
    }

    // MARK: Interface

    private func pointee(of global: SpirvGlobal) throws -> SpirvType {
        guard case .pointer(_, let t) = try module.type(global.type) else { throw error("variable %\(global.id) is not a pointer") }
        return t
    }

    /// An interface name as the host knows it: exact, so it must be one GLSL lets a shader declare and the only one.
    private func claimInterfaceName(_ name: String, what: String) throws -> String {
        guard globalScope.isDeclarable(name) else {
            throw error("the \(what) `\(name)` is not a name GLSL ES 1.00 lets a shader declare")
        }
        guard globalScope.claim(name) else {
            throw error("two of the stage's attributes, varyings or uniforms are called `\(name)`")
        }
        return name
    }

    private func declareInterface(_ used: [SpirvId]) throws {
        for id in used {
            let g = module.globals[id]!
            let t = try pointee(of: g)
            let name = module.names[id]
            let location = module.decoration(id, .location)?.first.map(Int.init)
            switch SpirvStorageClass(rawValue: g.storage) {
            case .input:
                if let builtIn = module.decoration(id, .builtIn)?.first {
                    globalRefs[id] = .variable(name: try builtInName(builtIn, input: true), type: t, writable: false)
                } else if case .structure = t {
                    throw error("the \(stage == .vertex ? "vertex attribute" : "varying") `\(name ?? "%\(id)")` is a struct, which OpenGL ES 2 \(stage == .vertex ? "attributes" : "varyings") cannot be")
                } else if stage == .vertex {
                    try checkAttributeType(t, name: name ?? "%\(id)")
                    let n = try claimInterfaceName(name ?? "a_location\(location ?? 0)", what: "attribute")
                    interfaceDeclarations.append("attribute \(try declaration(n, t));")
                    attributes.append((location ?? -1, n))
                    globalRefs[id] = .variable(name: n, type: t, writable: false)
                } else {
                    try checkVaryingType(t, name: name ?? "%\(id)")
                    let n = try claimInterfaceName(location.flatMap { varyingNamesIn[$0] } ?? name ?? "v_location\(location ?? 0)", what: "varying")
                    interfaceDeclarations.append("varying \(try declaration(n, t));")
                    if let location { varyingNamesOut[location] = n }
                    globalRefs[id] = .variable(name: n, type: t, writable: false)
                }
            case .output:
                if let builtIn = module.decoration(id, .builtIn)?.first {
                    globalRefs[id] = .variable(name: try builtInName(builtIn, input: false), type: t, writable: true)
                } else if case .structure(let sid) = t, module.decoration(sid, .block) != nil {
                    // gl_PerVertex: its members are the built-ins.
                    let types = try module.members(of: sid)
                    let names = try types.indices.map { k -> String? in
                        guard let b = module.memberDecoration(sid, k, .builtIn)?.first else { return nil }
                        return try? builtInName(b, input: false)
                    }
                    globalRefs[id] = .members(names: names, types: types, writable: true, what: "built-in")
                } else if stage == .vertex {
                    try checkVaryingType(t, name: name ?? "%\(id)")
                    let n = try claimInterfaceName(location.flatMap { varyingNamesIn[$0] } ?? name ?? "v_location\(location ?? 0)", what: "varying")
                    interfaceDeclarations.append("varying \(try declaration(n, t));")
                    if let location { varyingNamesOut[location] = n }
                    globalRefs[id] = .variable(name: n, type: t, writable: true)
                } else {
                    guard location ?? 0 == 0 else {
                        throw error("the fragment output `\(name ?? "%\(id)")` is at location \(location!); OpenGL ES 2 writes one color, gl_FragColor")
                    }
                    guard t == .vector(.float(width: 32), 4) || t == .vector(.float(width: 16), 4) else {
                        throw error("the fragment output `\(name ?? "%\(id)")` is a `\(try typeName(t))`; gl_FragColor is a vec4")
                    }
                    globalRefs[id] = .variable(name: "gl_FragColor", type: t, writable: true)
                }
            case .uniform, .pushConstant:
                guard case .structure(let sid) = t else {
                    throw error("the uniform `\(name ?? "%\(id)")` is not a block")
                }
                if module.decoration(sid, .bufferBlock) != nil {
                    throw error("`\(name ?? "%\(id)")` is a storage buffer, which OpenGL ES 2 does not have")
                }
                let types = try module.members(of: sid)
                var names: [String?] = Array(repeating: nil, count: types.count)
                for k in types.indices where usedMembers[id]?.contains(k) == true {
                    let member = module.memberNames[sid]?[k] ?? "\(name ?? "u")_\(k)"
                    let n = try claimInterfaceName(member, what: "uniform")
                    interfaceDeclarations.append("uniform \(try declaration(n, types[k]));")
                    uniformNames.append(n)
                    names[k] = n
                }
                globalRefs[id] = .members(names: names, types: types, writable: false, what: "uniform")
            case .uniformConstant:
                switch t {
                case .sampledImage(let dim), .image(let dim, _, _, _, _):
                    let n = try claimInterfaceName(name ?? "sampler\(id)", what: "sampler")
                    interfaceDeclarations.append("uniform \(try samplerType(dim)) \(n);")
                    uniformNames.append(n)
                    globalRefs[id] = .sampler(name: n)
                case .sampler:
                    globalRefs[id] = .separateSampler
                default:
                    let n = try claimInterfaceName(name ?? "uniform\(id)", what: "uniform")
                    interfaceDeclarations.append("uniform \(try declaration(n, t));")
                    uniformNames.append(n)
                    globalRefs[id] = .variable(name: n, type: t, writable: false)
                }
            case .private:
                let n = globalScope.unique(name ?? "g\(id)")
                if let initializer = g.initializer, !containsArray(t), let literal = try constantLiteral(initializer) {
                    globalDeclarations.append("\(try declaration(n, t)) = \(literal);")
                } else {
                    globalDeclarations.append("\(try declaration(n, t));")
                    if let initializer = g.initializer {
                        mainPrologue += try assignConstant(initializer, to: n, type: t)
                    }
                }
                globalRefs[id] = .variable(name: n, type: t, writable: true)
            case .workgroup:
                throw error("`\(name ?? "%\(id)")` is workgroup memory, which only compute shaders have")
            default:
                throw error("`\(name ?? "%\(id)")` is in storage class \(g.storage), which OpenGL ES 2 does not have")
            }
        }
    }

    private func builtInName(_ b: UInt32, input: Bool) throws -> String {
        switch (SpirvBuiltIn(rawValue: b), stage, input) {
        case (.position, .vertex, false): return "gl_Position"
        case (.pointSize, .vertex, false): return "gl_PointSize"
        case (.fragCoord, .fragment, true): return "gl_FragCoord"
        case (.frontFacing, .fragment, true): return "gl_FrontFacing"
        case (.pointCoord, .fragment, true): return "gl_PointCoord"
        case (.vertexIndex, _, _), (.vertexId, _, _):
            throw error("OpenGL ES 2 has no vertex index (gl_VertexID): pass one as an attribute")
        case (.instanceIndex, _, _), (.instanceId, _, _):
            throw error("OpenGL ES 2 has no instancing (gl_InstanceID)")
        case (.fragDepth, _, _):
            throw error("writing the fragment depth needs GL_EXT_frag_depth, which this translation does not use")
        default:
            throw error("the built-in \(b) has no OpenGL ES 2 \(stage.description) stage form")
        }
    }

    private func checkAttributeType(_ t: SpirvType, name: String) throws {
        switch t {
        case .float, .vector(.float, _), .matrix: return
        default: throw error("the vertex attribute `\(name)` is a `\(try typeName(t))`; OpenGL ES 2 attributes are float, vec2-4 or mat2-4")
        }
    }

    private func checkVaryingType(_ t: SpirvType, name: String) throws {
        switch t {
        case .float, .vector(.float, _), .matrix: return
        case .array(let e, _): try checkVaryingType(e, name: name)
        default: throw error("the varying `\(name)` is a `\(try typeName(t))`; OpenGL ES 2 varyings are float, vec2-4, mat2-4 or arrays of them")
        }
    }

    /// The `ivec2` uniform holding `sampler`'s size, declared on first use.
    func sizeUniform(for sampler: String) throws -> String {
        if let n = sizeUniforms[sampler] { return n }
        let n = try claimInterfaceName(sampler + options.textureSizeSuffix, what: "texture size uniform")
        sizeUniforms[sampler] = n
        return n
    }

    // MARK: Types

    func samplerType(_ dim: UInt32) throws -> String {
        switch SpirvDim(rawValue: dim) {
        case .dim2D: return "sampler2D"
        case .cube: return "samplerCube"
        default: throw error("OpenGL ES 2 samples only 2D and cube images, not dimension \(dim)")
        }
    }

    /// The GLSL name of a type that is not an array.
    func typeName(_ t: SpirvType) throws -> String {
        switch t {
        case .void: return "void"
        case .bool: return "bool"
        case .int(let width, let signed):
            guard signed else { throw error("OpenGL ES 2 has no unsigned integers (uint)") }
            guard width <= 32 else { throw error("OpenGL ES 2 has no 64-bit integers") }
            return "int"
        case .float(let width):
            guard width <= 32 else { throw error("OpenGL ES 2 has no double precision") }
            return "float"
        case .vector(let c, let n):
            switch c {
            case .bool: return "bvec\(n)"
            case .int(_, let signed):
                guard signed else { throw error("OpenGL ES 2 has no unsigned integer vectors (uvec\(n))") }
                return "ivec\(n)"
            case .float(let width):
                guard width <= 32 else { throw error("OpenGL ES 2 has no double precision") }
                return "vec\(n)"
            default: throw error("a vector of \(c)")
            }
        case .matrix(let column, let columns):
            guard case .vector(.float, let rows) = column, rows == columns else {
                throw error("OpenGL ES 2 has only square float matrices (mat2, mat3, mat4)")
            }
            return "mat\(columns)"
        case .structure(let id): return try structName(id)
        case .sampledImage(let dim), .image(let dim, _, _, _, _): return try samplerType(dim)
        case .array: throw error("internal: an array has no type name of its own")
        case .pointer: throw error("OpenGL ES 2 has no pointers")
        case .sampler: throw error("a separate sampler has no OpenGL ES 2 type")
        case .function: throw error("a function type")
        }
    }

    /// `T name` or `T name[N]`.
    func declaration(_ name: String, _ t: SpirvType) throws -> String {
        if case .array(let e, let n) = t {
            if case .array = e { throw error("OpenGL ES 2 has no arrays of arrays") }
            guard let n else { throw error("OpenGL ES 2 has no arrays of a run-time length") }
            return "\(try typeName(e)) \(name)[\(n)]"
        }
        return "\(try typeName(t)) \(name)"
    }

    func containsArray(_ t: SpirvType) -> Bool {
        switch t {
        case .array: return true
        case .structure(let id): return ((try? module.members(of: id)) ?? []).contains(where: containsArray)
        default: return false
        }
    }

    func structName(_ id: SpirvId) throws -> String {
        if let n = structNames[id] { return n }
        let members = try module.members(of: id)
        // Declared after the structs its members name.
        for m in members {
            var e = m
            while case .array(let inner, _) = e { e = inner }
            if case .structure(let sid) = e, sid != id { _ = try structName(sid) }
        }
        let n = globalScope.unique(module.names[id] ?? "S\(id)")
        structNames[id] = n
        let memberScope = NameScope()
        var memberNames: [String] = []
        var lines = ["struct \(n) {"]
        for (k, m) in members.enumerated() {
            let mn = memberScope.unique(module.memberNames[id]?[k] ?? "m\(k)")
            memberNames.append(mn)
            lines.append("    \(try declaration(mn, m));")
        }
        lines.append("};")
        structMemberNames[id] = memberNames
        structDeclarations += lines
        return n
    }

    func memberName(_ structId: SpirvId, _ k: Int) throws -> String {
        _ = try structName(structId)
        return structMemberNames[structId]![k]
    }

    // MARK: Constants

    /// A float literal GLSL reads back as the same value.
    func floatLiteral(_ f: Float) throws -> String {
        guard f.isFinite else { throw error("OpenGL ES 2 has no literal for \(f)") }
        var s = "\(f)"
        if !s.contains(".") && !s.contains("e") { s += ".0" }
        if s.hasPrefix(".") { s = "0" + s }
        return s
    }

    func scalarLiteral(_ words: [UInt32], _ t: SpirvType) throws -> String {
        switch t {
        case .float(let width):
            if width == 16 { return try floatLiteral(floatFromHalfBits(UInt16(truncatingIfNeeded: words[0]))) }
            if width == 64 { throw error("OpenGL ES 2 has no double precision") }
            return try floatLiteral(Float(bitPattern: words[0]))
        case .int(let width, let signed):
            guard signed else { throw error("OpenGL ES 2 has no unsigned integers (uint)") }
            guard width <= 32 else { throw error("OpenGL ES 2 has no 64-bit integers") }
            let v = width == 16 ? Int(Int16(truncatingIfNeeded: words[0])) : Int(Int32(bitPattern: words[0]))
            return v == Int(Int32.min) ? "(-2147483647 - 1)" : "\(v)"
        default:
            throw error("a scalar constant of \(t)")
        }
    }

    /// A constant as a GLSL expression; nil for one holding an array, which
    /// GLSL ES 1.00 cannot write as one (`assignConstant` fills it instead).
    func constantLiteral(_ id: SpirvId) throws -> String? {
        guard let c = module.constants[id] else { return nil }
        let t = try module.type(c.type)
        if containsArray(t) { return nil }
        switch c.value {
        case .bool(let b): return b ? "true" : "false"
        case .scalar(let words): return try scalarLiteral(words, t)
        case .null, .undef: return try zeroLiteral(t)
        case .composite(let parts):
            let literals = try parts.map { try constantLiteral($0) ?? "" }
            if case .vector = t, Set(literals).count == 1 { return "\(try typeName(t))(\(literals[0]))" }
            return "\(try typeName(t))(\(literals.joined(separator: ", ")))"
        }
    }

    func zeroLiteral(_ t: SpirvType) throws -> String {
        switch t {
        case .bool: return "false"
        case .int: return "0"
        case .float: return "0.0"
        case .vector(let c, _): return "\(try typeName(t))(\(try zeroLiteral(c)))"
        case .matrix: return "\(try typeName(t))(0.0)"
        case .structure(let id):
            return "\(try structName(id))(\(try module.members(of: id).map { try zeroLiteral($0) }.joined(separator: ", ")))"
        default: throw error("no zero value for \(t)")
        }
    }

    /// Statements filling `target` (a place of type `t`) with a constant,
    /// element by element where it holds arrays.
    func assignConstant(_ id: SpirvId, to target: String, type t: SpirvType) throws -> [String] {
        if !containsArray(t), let literal = try constantLiteral(id) {
            return ["\(target) = \(literal);"]
        }
        guard let c = module.constants[id] else { throw error("%\(id) is not a constant") }
        switch (t, c.value) {
        case (.array(let e, let n?), .composite(let parts)):
            _ = n
            return try parts.enumerated().flatMap { try assignConstant($1, to: "\(target)[\($0)]", type: e) }
        case (.array(let e, let n?), .null), (.array(let e, let n?), .undef):
            return try (0..<n).flatMap { try assignZero(to: "\(target)[\($0)]", type: e) }
        case (.structure(let sid), .composite(let parts)):
            let members = try module.members(of: sid)
            return try parts.enumerated().flatMap { try assignConstant($1, to: "\(target).\(try memberName(sid, $0))", type: members[$0]) }
        case (.structure, .null), (.structure, .undef):
            return try assignZero(to: target, type: t)
        default:
            throw error("cannot write constant %\(id) of \(t)")
        }
    }

    func assignZero(to target: String, type t: SpirvType) throws -> [String] {
        switch t {
        case .array(let e, let n?):
            return try (0..<n).flatMap { try assignZero(to: "\(target)[\($0)]", type: e) }
        case .structure(let sid) where containsArray(t):
            let members = try module.members(of: sid)
            return try members.enumerated().flatMap { try assignZero(to: "\(target).\(try memberName(sid, $0))", type: $1) }
        default:
            return ["\(target) = \(try zeroLiteral(t));"]
        }
    }

    /// Statements copying `source` to `target`, both places of type `t`:
    /// one assignment, or one per element where GLSL ES 1.00 cannot assign
    /// the whole (arrays, and structs holding them).
    func assignCopy(from source: String, to target: String, type t: SpirvType) throws -> [String] {
        switch t {
        case .array(let e, let n?):
            return try (0..<n).flatMap { try assignCopy(from: "\(source)[\($0)]", to: "\(target)[\($0)]", type: e) }
        case .structure(let sid) where containsArray(t):
            let members = try module.members(of: sid)
            return try members.enumerated().flatMap {
                let m = try memberName(sid, $0)
                return try assignCopy(from: "\(source).\(m)", to: "\(target).\(m)", type: $1)
            }
        default:
            return ["\(target) = \(source);"]
        }
    }
}
