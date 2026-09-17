//
//  InterfaceMap.swift
//  Spirv2PyShader
//
//  Names the module's interface variables the way PyShader's `main` takes
//  them: an `Input` at location 0 is `uv`, the push-constant member at
//  offset 0 is `time`, and so on, following the `FragmentInterface`.
//  Variables the interface does not describe keep their SPIR-V names (or
//  the caller's renames) and are reported.
//

import PyShader
import SpirvCore

/// One value the host hands the stage: a `main` parameter in PyShader.
struct InterfaceValue: Hashable {
    let name: String
    let type: ShaderType
    /// Position in `main`'s parameter list.
    let order: Int

    static func == (l: InterfaceValue, r: InterfaceValue) -> Bool { l.name == r.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

final class InterfaceMap {
    /// Whole `Input` variables.
    private(set) var variables: [SpirvId: InterfaceValue] = [:]
    /// Members of push-constant / uniform blocks, by block variable and member index.
    private(set) var members: [SpirvId: [Int: InterfaceValue]] = [:]
    /// The colour output the stage writes.
    private(set) var output: SpirvId?
    private(set) var outputName = "fragColor"
    /// Every parameter name, reserved in every function so helpers can take them.
    private(set) var reservedNames: Set<String> = []
    /// Opaque resources (samplers, images) by variable, for the warning at their use.
    private(set) var opaque: [SpirvId: String] = [:]
    /// `Private` globals: PyShader has no module-level variables.
    private(set) var privateGlobals: [SpirvId: String] = [:]

    private var warnings: [String] = []
    private var unmappedOrder = 0

    init(module: ModuleIndex, interface: FragmentInterface, options: DecompileOptions) {
        for id in module.globalOrder {
            let g = module.globals[id]!
            switch g.storage {
            case .input:
                map(input: g, module: module, interface: interface, options: options)
            case .output:
                if output == nil, interface.output.location == Int(module.decoration(id, .location)?.first ?? 0) {
                    output = id
                    outputName = PyNames.sanitize(g.name ?? interface.output.name, fallback: "out")
                } else if output == nil {
                    output = id
                    outputName = PyNames.sanitize(g.name ?? interface.output.name, fallback: "out")
                    warnings.append("output `\(outputName)` is not at location \(interface.output.location); taken as the colour output anyway")
                } else {
                    warnings.append("second output `\(g.name ?? "%\(id)")` ignored; PyShader's main returns one colour")
                }
            case .pushConstant:
                map(block: g, module: module, byOffset: interface.pushConstants, options: options)
            case .uniform, .storageBuffer:
                map(block: g, module: module, byOffset: [], options: options)
            case .uniformConstant:
                opaque[id] = g.name ?? "%\(id)"
            case .private, .workgroup:
                privateGlobals[id] = g.name ?? "%\(id)"
            default:
                break
            }
        }
        if output == nil {
            warnings.append("no colour output; main returns nothing")
        }
        reservedNames.insert(outputName)
    }

    func takeWarnings() -> [String] {
        defer { warnings = [] }
        return warnings
    }

    /// The parameter a load through `root` (and, for blocks, the first access-chain index) reads.
    func value(root: SpirvId, member: Int?) -> InterfaceValue? {
        if let v = variables[root] { return v }
        if let member, let v = members[root]?[member] { return v }
        return nil
    }

    // MARK: - Mapping

    private func map(input g: GlobalVariable, module: ModuleIndex, interface: FragmentInterface, options: DecompileOptions) {
        let location = module.decoration(g.id, .location)?.first
        let builtIn = module.decoration(g.id, .builtIn)?.first
        for (i, input) in interface.inputs.enumerated() {
            let matches: Bool
            switch input.binding {
            case .location(let l): matches = location == UInt32(l)
            case .builtIn(let b): matches = builtIn == b.spirv.rawValue
            }
            if matches {
                if input.type != g.type {
                    warnings.append("`\(input.name)` is a `\(g.type)` in the module, the interface expects `\(input.type)`")
                }
                add(g.id, member: nil, name: input.name, type: g.type, order: i)
                return
            }
        }
        // Not bound like the interface says: by name, then as-is.
        if let name = g.name, let i = interface.inputs.firstIndex(where: { $0.name == name }) {
            add(g.id, member: nil, name: name, type: g.type, order: i)
            return
        }
        let raw = g.name ?? (location.map { "input_\($0)" } ?? "input_\(g.id)")
        addUnmapped(g.id, member: nil, raw: raw, type: g.type, options: options, what: "input")
    }

    private func map(block g: GlobalVariable, module: ModuleIndex, byOffset table: [FragmentInterface.PushConstantMember], options: DecompileOptions) {
        guard case .structure(let blockName, let blockMembers) = g.type else {
            let raw = g.name ?? "%\(g.id)"
            addUnmapped(g.id, member: nil, raw: raw, type: g.type, options: options, what: "uniform")
            return
        }
        // The struct type id, for member decorations.
        let typeId = module.types.first { $0.value == g.type }?.key
        members[g.id] = [:]
        for (i, (memberName, memberType)) in blockMembers.enumerated() {
            let offset = typeId.flatMap { module.memberDecoration($0, member: i, .offset)?.first }
            if let offset, let k = table.firstIndex(where: { $0.offset == Int(offset) }) {
                if table[k].type != memberType {
                    warnings.append("`\(table[k].name)` is a `\(memberType)` in the module, the interface expects `\(table[k].type)`")
                }
                add(g.id, member: i, name: table[k].name, type: memberType, order: 100 + k)
            } else if let k = table.firstIndex(where: { $0.name == memberName }) {
                add(g.id, member: i, name: table[k].name, type: memberType, order: 100 + k)
            } else {
                addUnmapped(g.id, member: i, raw: memberName, type: memberType, options: options, what: "member of `\(blockName)`")
            }
        }
    }

    private func add(_ id: SpirvId, member: Int?, name: String, type: ShaderType, order: Int) {
        let v = InterfaceValue(name: name, type: type, order: order)
        if let member { members[id, default: [:]][member] = v } else { variables[id] = v }
        reservedNames.insert(name)
    }

    private func addUnmapped(_ id: SpirvId, member: Int?, raw: String, type: ShaderType, options: DecompileOptions, what: String) {
        var name = options.renames[raw] ?? PyNames.sanitize(raw, fallback: "input")
        if options.renames[raw] == nil {
            while reservedNames.contains(name) || PyNames.isReserved(name) { name += "_" }
            warnings.append("\(what) `\(raw)` is not in the interface; main takes it as `\(name)`")
        }
        unmappedOrder += 1
        add(id, member: member, name: name, type: type, order: (member == nil ? 1000 : 2000) + unmappedOrder)
    }
}
