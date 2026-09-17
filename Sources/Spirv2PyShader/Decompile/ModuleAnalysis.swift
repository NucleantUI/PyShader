//
//  ModuleAnalysis.swift
//  Spirv2PyShader
//
//  Module-wide decisions taken before any function is written: which
//  functions the entry point reaches and what they are called, which
//  pointer parameters carry results back to the caller (GLSL `out`) and so
//  become tuple returns, and which interface values each helper reads (its
//  own or through callees) and so takes as extra parameters.
//

import PyShader
import SpirvCore

final class ModuleAnalysis {
    let module: ModuleIndex
    let interface: InterfaceMap
    let entry: FunctionDef
    let entryName: String
    private(set) var scans: [SpirvId: FunctionScan] = [:]
    /// Reachable functions, callees before callers, entry point last.
    private(set) var order: [SpirvId] = []
    private(set) var functionNames: [SpirvId: String] = [:]
    /// Parameter indices lowered to extra return values, per function.
    private(set) var outParams: [SpirvId: [Int]] = [:]
    /// Interface values a function reads, itself or through callees; extra trailing parameters.
    private(set) var threaded: [SpirvId: [InterfaceValue]] = [:]
    /// Struct types that need a `class`, in first-use order, with their Python names.
    private(set) var structs: [ShaderType] = []
    private(set) var structNames: [ShaderType: String] = [:]

    init(module: ModuleIndex, interface: InterfaceMap, options: DecompileOptions) throws {
        self.module = module
        self.interface = interface

        let candidates = module.entryPoints.filter { $0.model == SpirvExecutionModel.fragment.rawValue }
        let chosen: EntryPoint?
        if let wanted = options.entryPoint {
            chosen = module.entryPoints.first { $0.name == wanted }
            guard chosen != nil else { throw Spirv2PyShaderError("no entry point named `\(wanted)`") }
            guard chosen!.model == SpirvExecutionModel.fragment.rawValue else {
                throw Spirv2PyShaderError("entry point `\(wanted)` is not a fragment stage; only fragment shaders decompile to PyShader")
            }
        } else {
            chosen = candidates.first
        }
        guard let ep = chosen else {
            let models = module.entryPoints.map { modelName($0.model) }
            throw Spirv2PyShaderError(models.isEmpty
                ? "module has no entry point"
                : "no fragment entry point; only fragment shaders decompile to PyShader (module has: \(models.joined(separator: ", ")))")
        }
        guard let fn = module.function(ep.function) else { throw Spirv2PyShaderError("entry point function %\(ep.function) is missing") }
        entry = fn
        entryName = PyNames.sanitize(ep.name, fallback: "main")

        for f in module.functions { scans[f.id] = FunctionScan(function: f, module: module) }
        collectOrder()
        nameFunctions()
        findOutParams()
        threadInterfaceValues()
        collectStructs()
    }

    func scan(_ id: SpirvId) -> FunctionScan { scans[id]! }

    func name(of function: SpirvId) -> String { functionNames[function] ?? "f\(function)" }

    /// The Python name of a struct type (`Ray`), or of the type in general.
    func typeName(_ t: ShaderType) -> String {
        switch t {
        case .structure: return structNames[t] ?? PyNames.sanitize(t.description, fallback: "Struct")
        case .array(let e, _): return "list[\(typeName(e))]"
        case .tuple(let ts): return "tuple[\(ts.map(typeName).joined(separator: ", "))]"
        case .void: return "None"
        default: return t.description
        }
    }

    /// What a function returns in Python: its value, then every out parameter.
    func returnTypes(_ function: SpirvId) -> [ShaderType] {
        guard let f = module.function(function) else { return [] }
        var out: [ShaderType] = f.returnType == .void ? [] : [f.returnType]
        for i in outParams[function] ?? [] {
            out.append(f.params[i].type.pointee ?? f.params[i].type)
        }
        return out
    }

    // MARK: - Reachability & names

    private func collectOrder() {
        var visited = Set<SpirvId>()
        func visit(_ id: SpirvId) {
            guard !visited.contains(id), let scan = scans[id] else { return }
            visited.insert(id)
            for call in scan.calls { visit(call.operands[2]) }
            order.append(id)
        }
        visit(entry.id)
    }

    private func nameFunctions() {
        var names = NameAllocator(reserved: interface.reservedNames)
        names.reserve(entryName)
        functionNames[entry.id] = entryName
        for id in order where id != entry.id {
            var raw = module.names[id] ?? "f\(id)"
            // PyShader names its entry `py_main`; the wrapper it belongs to is `main`.
            if raw.hasPrefix("py_") { raw = String(raw.dropFirst(3)) }
            functionNames[id] = names.unique(raw, fallback: "f")
        }
    }

    // MARK: - Out parameters

    /// A pointer parameter is an out parameter when some caller reads the
    /// variable it passed after the call (or passes its own out parameter on).
    private func findOutParams() {
        var flags: [SpirvId: Set<Int>] = [:]
        var changed = true
        while changed {
            changed = false
            for callerId in order {
                let caller = scan(callerId)
                for call in caller.calls {
                    let calleeId = call.operands[2]
                    guard let callee = module.function(calleeId) else { continue }
                    for (k, arg) in call.operands.dropFirst(3).enumerated() where k < callee.params.count && callee.params[k].type.isPointer {
                        guard let root = caller.root(arg) else { continue }
                        var readsBack = caller.loadedRoots.contains(root)
                        if caller.pointerParams.contains(root) {
                            // Passing our own parameter on: it is an out parameter of ours or is read here.
                            let ourIndex = caller.function.params.firstIndex { $0.id == root }!
                            readsBack = readsBack || flags[callerId]?.contains(ourIndex) == true
                        }
                        // Passed to a second call that may read it, too.
                        readsBack = readsBack || caller.calls.contains { other in
                            other.offset != call.offset && other.operands.dropFirst(3).contains { caller.root($0) == root }
                        }
                        if readsBack, !(flags[calleeId]?.contains(k) ?? false) {
                            flags[calleeId, default: []].insert(k)
                            changed = true
                        }
                    }
                }
            }
        }
        for (id, set) in flags { outParams[id] = set.sorted() }
    }

    // MARK: - Interface threading

    private func threadInterfaceValues() {
        var memo: [SpirvId: [InterfaceValue]] = [:]
        func values(of id: SpirvId) -> [InterfaceValue] {
            if let v = memo[id] { return v }
            let scan = scan(id)
            var set = Set<InterfaceValue>()
            for (pointer, root) in scan.roots where module.globals[root] != nil {
                let read = scan.users[pointer]?.contains {
                    ($0.op == .opLoad && $0.operands[2] == pointer) || $0.op == .opFunctionCall
                } ?? false
                guard read, let v = interface.value(root: root, member: scan.firstMember[pointer]) else { continue }
                set.insert(v)
            }
            for call in scan.calls {
                for v in values(of: call.operands[2]) { set.insert(v) }
            }
            let sorted = set.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
            memo[id] = sorted
            return sorted
        }
        for id in order { threaded[id] = values(of: id) }
    }

    // MARK: - Structs

    private func collectStructs() {
        var names = NameAllocator(reserved: interface.reservedNames.union(functionNames.values))
        func visit(_ t: ShaderType) {
            switch t {
            case .structure(let name, let members):
                if structNames[t] != nil { return }
                if isBlock(t) { return }
                structNames[t] = names.unique(name, fallback: "Struct")
                structs.append(t)
                for m in members { visit(m.1) }
            case .array(let e, _), .runtimeArray(let e), .pointer(_, let e):
                visit(e)
            case .tuple(let ts):
                for m in ts { visit(m) }
            case .function(let r, let ps):
                visit(r)
                for p in ps { visit(p) }
            default:
                break
            }
        }
        for id in order {
            let scan = scan(id)
            visit(scan.function.functionType)
            for inst in scan.function.allInstructions {
                guard let op = inst.op, hasResult(op), let t = module.types[inst.operands[0]] else { continue }
                visit(t)
            }
        }
    }

    private func isBlock(_ t: ShaderType) -> Bool {
        guard let id = module.types.first(where: { $0.value == t })?.key else { return false }
        return module.has(id, .block) || module.has(id, .bufferBlock)
    }
}

func modelName(_ model: UInt32) -> String {
    switch SpirvExecutionModel(rawValue: model) {
    case .vertex: return "vertex"
    case .fragment: return "fragment"
    case .glCompute: return "compute"
    case nil: return "execution model \(model)"
    }
}
