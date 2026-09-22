//
//  Exports.swift
//  PyShaderWasm
//
//  Wasm can only pass numbers, so strings travel as (pointer, length) into
//  linear memory. The host allocates with pyshader_alloc, writes the source
//  and an options string, calls pyshader_compile, then reads the result
//  through pyshader_result_ptr/pyshader_result_len and releases it.
//
//  Options are whitespace-separated `key=value` pairs:
//    target=compute|fragment|graphics   (default compute)
//    content=1                          (compute/graphics: the shader may call layer())
//    arg=name:float|float2|float3|float4|floatArray|float2Array|float3Array|float4Array
//                                       (repeatable, in buffer order)
//
//  On success the result is the SPIR-V module as bytes, and the entry point
//  names are readable through pyshader_entry_point / pyshader_vertex_entry_point.
//  On failure it is the error text.
//
//  pyshader_decompile goes the other way: SPIR-V bytes in, PyShader source
//  out (see the docs' GLSL converter). Its options:
//    interface=nucleant|shadertoy       (the layout the module was compiled against; default nucleant)
//    rename=spirvName:pyName            (repeatable)
//    entry=name                         (the entry point, when the module has several)
//    header=0                           (no "# Decompiled from …" line)
//  The warnings of the last decompile are readable through pyshader_decompile_warnings,
//  and pyshader_shadertoy_prelude gives the GLSL that `interface=shadertoy` expects
//  in front of a ShaderToy `mainImage` (its epilogue is `pyshader_shadertoy_epilogue`).
//

import PyShader
import Spirv2PyShader

private nonisolated(unsafe) var resultBuffer: UnsafeMutableRawPointer?
private nonisolated(unsafe) var resultCount: Int32 = 0
private nonisolated(unsafe) var entryPointBytes: [UInt8] = []
private nonisolated(unsafe) var vertexEntryPointBytes: [UInt8] = []
private nonisolated(unsafe) var decompileWarningBytes: [UInt8] = []

private func storeResult(_ bytes: [UInt8]) {
    freeResult()
    guard !bytes.isEmpty else { return }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 4)
    bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
    resultBuffer = buffer
    resultCount = Int32(bytes.count)
}

private func freeResult() {
    resultBuffer?.deallocate()
    resultBuffer = nil
    resultCount = 0
}

private func string(from pointer: UnsafeRawPointer?, length: Int32) -> String {
    guard let pointer, length > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
}

private func target(from options: String) throws -> ShaderTarget {
    var name = "compute"
    var samplesContent = false
    var arguments: [(name: String, kind: ShaderArgumentKind)] = []
    for pair in options.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw PyShaderError("bad option `\(pair)`") }
        switch parts[0] {
        case "target":
            name = parts[1]
        case "content":
            samplesContent = parts[1] == "1" || parts[1] == "true"
        case "arg":
            let spec = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard spec.count == 2 else { throw PyShaderError("bad arg `\(parts[1])`, want name:kind") }
            let kind: ShaderArgumentKind
            switch spec[1] {
            case "float": kind = .float
            case "float2": kind = .float2
            case "float3": kind = .float3
            case "float4": kind = .float4
            case "floatArray": kind = .floatArray
            case "float2Array": kind = .float2Array
            case "float3Array": kind = .float3Array
            case "float4Array": kind = .float4Array
            default: throw PyShaderError("unknown argument kind `\(spec[1])`")
            }
            arguments.append((spec[0], kind))
        default:
            throw PyShaderError("unknown option `\(parts[0])`")
        }
    }
    switch name {
    case "compute": return .computeImage(.nucleantSwiftUI(samplesContent: samplesContent, arguments: arguments))
    case "fragment": return .nucleant
    case "graphics": return .graphics(.nucleantSwiftUI(arguments: arguments))
    default: throw PyShaderError("unknown target `\(name)`")
    }
}

@_expose(wasm, "pyshader_alloc")
@_cdecl("pyshader_alloc")
public func pyshader_alloc(_ size: Int32) -> UnsafeMutableRawPointer? {
    guard size > 0 else { return nil }
    return UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 4)
}

@_expose(wasm, "pyshader_dealloc")
@_cdecl("pyshader_dealloc")
public func pyshader_dealloc(_ pointer: UnsafeMutableRawPointer?, _ size: Int32) {
    pointer?.deallocate()
}

/// Returns 0 on success (result = SPIR-V bytes), 1 on failure (result = error text).
@_expose(wasm, "pyshader_compile")
@_cdecl("pyshader_compile")
public func pyshader_compile(
    _ sourcePointer: UnsafeRawPointer?,
    _ sourceLength: Int32,
    _ optionsPointer: UnsafeRawPointer?,
    _ optionsLength: Int32
) -> Int32 {
    do {
        let shader = try PyShader.compile(
            string(from: sourcePointer, length: sourceLength),
            target: try target(from: string(from: optionsPointer, length: optionsLength))
        )
        entryPointBytes = Array(shader.entryPoint.utf8)
        vertexEntryPointBytes = Array((shader.vertexEntryPoint ?? "").utf8)
        storeResult(shader.spirv.withUnsafeBytes { Array($0) })
        return 0
    } catch {
        entryPointBytes = []
        vertexEntryPointBytes = []
        storeResult(Array("\(error)".utf8))
        return 1
    }
}

@_expose(wasm, "pyshader_result_ptr")
@_cdecl("pyshader_result_ptr")
public func pyshader_result_ptr() -> UnsafeMutableRawPointer? {
    resultBuffer
}

@_expose(wasm, "pyshader_result_len")
@_cdecl("pyshader_result_len")
public func pyshader_result_len() -> Int32 {
    resultCount
}

@_expose(wasm, "pyshader_result_free")
@_cdecl("pyshader_result_free")
public func pyshader_result_free() {
    freeResult()
}

/// Copies the fragment/compute entry point name of the last successful compile
/// into `pointer` (at most `capacity` bytes) and returns its length.
@_expose(wasm, "pyshader_entry_point")
@_cdecl("pyshader_entry_point")
public func pyshader_entry_point(_ pointer: UnsafeMutableRawPointer?, _ capacity: Int32) -> Int32 {
    copyOut(entryPointBytes, to: pointer, capacity: capacity)
}

/// Same for the vertex entry point of a `graphics` compile; 0 when there is none.
@_expose(wasm, "pyshader_vertex_entry_point")
@_cdecl("pyshader_vertex_entry_point")
public func pyshader_vertex_entry_point(_ pointer: UnsafeMutableRawPointer?, _ capacity: Int32) -> Int32 {
    copyOut(vertexEntryPointBytes, to: pointer, capacity: capacity)
}

private func decompileOptions(from options: String) throws -> (DecompileOptions, FragmentInterface) {
    var result = DecompileOptions()
    var interface = FragmentInterface.nucleant
    for pair in options.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw Spirv2PyShaderError("bad option `\(pair)`") }
        switch parts[0] {
        case "rename":
            let names = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard names.count == 2 else { throw Spirv2PyShaderError("bad rename `\(parts[1])`, want spirvName:pyName") }
            result.renames[names[0]] = names[1]
        case "entry":
            result.entryPoint = parts[1]
        case "header":
            result.header = parts[1] == "1" || parts[1] == "true"
        case "interface":
            switch parts[1] {
            case "nucleant": interface = .nucleant
            case "shadertoy": interface = .shaderToy
            default: throw Spirv2PyShaderError("unknown interface `\(parts[1])`")
            }
        default:
            throw Spirv2PyShaderError("unknown option `\(parts[0])`")
        }
    }
    return (result, interface)
}

/// Returns 0 on success (result = PyShader source), 1 on failure (result = error text).
@_expose(wasm, "pyshader_decompile")
@_cdecl("pyshader_decompile")
public func pyshader_decompile(
    _ spirvPointer: UnsafeRawPointer?,
    _ spirvLength: Int32,
    _ optionsPointer: UnsafeRawPointer?,
    _ optionsLength: Int32
) -> Int32 {
    do {
        guard let spirvPointer, spirvLength > 0, spirvLength % 4 == 0 else {
            throw Spirv2PyShaderError("the SPIR-V module is empty or not a whole number of words")
        }
        let words = [UInt32](unsafeUninitializedCapacity: Int(spirvLength) / 4) { buffer, count in
            UnsafeMutableRawBufferPointer(buffer).copyMemory(from: UnsafeRawBufferPointer(start: spirvPointer, count: Int(spirvLength)))
            count = Int(spirvLength) / 4
        }
        let (options, interface) = try decompileOptions(from: string(from: optionsPointer, length: optionsLength))
        let shader = try Spirv2PyShader.decompile(words, interface: interface, options: options)
        decompileWarningBytes = Array(shader.warnings.joined(separator: "\n").utf8)
        storeResult(Array(shader.source.utf8))
        return 0
    } catch {
        decompileWarningBytes = []
        storeResult(Array("\(error)".utf8))
        return 1
    }
}

/// Copies the warnings of the last successful decompile, one per line, into
/// `pointer` (at most `capacity` bytes) and returns their length.
@_expose(wasm, "pyshader_decompile_warnings")
@_cdecl("pyshader_decompile_warnings")
public func pyshader_decompile_warnings(_ pointer: UnsafeMutableRawPointer?, _ capacity: Int32) -> Int32 {
    copyOut(decompileWarningBytes, to: pointer, capacity: capacity)
}

@_expose(wasm, "pyshader_shadertoy_prelude")
@_cdecl("pyshader_shadertoy_prelude")
public func pyshader_shadertoy_prelude(_ pointer: UnsafeMutableRawPointer?, _ capacity: Int32) -> Int32 {
    copyOut(Array(ShaderToy.prelude.utf8), to: pointer, capacity: capacity)
}

@_expose(wasm, "pyshader_shadertoy_epilogue")
@_cdecl("pyshader_shadertoy_epilogue")
public func pyshader_shadertoy_epilogue(_ pointer: UnsafeMutableRawPointer?, _ capacity: Int32) -> Int32 {
    copyOut(Array(ShaderToy.epilogue.utf8), to: pointer, capacity: capacity)
}

private func copyOut(_ bytes: [UInt8], to pointer: UnsafeMutableRawPointer?, capacity: Int32) -> Int32 {
    if let pointer, capacity > 0 {
        let n = min(bytes.count, Int(capacity))
        bytes.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: n) }
    }
    return Int32(bytes.count)
}
