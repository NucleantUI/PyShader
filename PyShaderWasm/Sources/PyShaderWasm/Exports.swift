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
//    content-top-down=1                 (as content=1, the image stored top-down)
//    textures-top-down=1                (the `Texture` parameters' images stored top-down; y-up by default)
//    format=spirv|gles2                 (default spirv; gles2: OpenGL ES 2)
//    single-file=1                      (gles2: both stages in one file)
//    position-attribute=, texcoord-attribute=, color-attribute=, color-uniform=,
//    opacity-uniform=, position-matrix= (repeatable), uv-varying=, color-varying=,
//    content-sampler=                   (gles2: the names the stages declare; see GLES2Options)
//    file=name.py                       (the source file's name, for line information and headers)
//    arg=name:float|float2|float3|float4|floatArray|float2Array|float3Array|float4Array
//                                       (repeatable, in buffer order)
//
//  The modules the source may import are registered beforehand, one call to
//  pyshader_add_module per module (dotted name and source), and stay until
//  pyshader_clear_modules.
//
//  On success the result is the SPIR-V module as bytes. For format=gles2 it is
//  the fragment stage's UTF-8 text, the vertex stage's readable through
//  pyshader_vertex_stage; with single-file=1 it is the one file holding both.
//  The entry point names are readable through pyshader_entry_point /
//  pyshader_vertex_entry_point.
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
private nonisolated(unsafe) var vertexStageBytes: [UInt8] = []
private nonisolated(unsafe) var decompileWarningBytes: [UInt8] = []
/// The modules `pyshader_compile` can import, by dotted name.
private nonisolated(unsafe) var moduleSources: [String: String] = [:]

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

private func target(from options: String) throws -> (target: ShaderTarget, format: String, file: String?, gles2: GLES2Options, singleFile: Bool) {
    var name = "compute"
    var format = "spirv"
    var file: String?
    var gles2 = GLES2Options()
    var singleFile = false
    var gles2Keys: [String] = []
    var samplesContent = false
    var contentIsTopDown = false
    var texturesAreTopDown = false
    var arguments: [(name: String, kind: ShaderArgumentKind)] = []
    for pair in options.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw PyShaderError("bad option `\(pair)`") }
        switch parts[0] {
        case "target":
            name = parts[1]
        case "content":
            samplesContent = samplesContent || parts[1] == "1" || parts[1] == "true"
        case "content-top-down":
            contentIsTopDown = parts[1] == "1" || parts[1] == "true"
            samplesContent = samplesContent || contentIsTopDown
        case "textures-top-down":
            texturesAreTopDown = parts[1] == "1" || parts[1] == "true"
        case "file":
            file = parts[1]
        case "single-file":
            singleFile = parts[1] == "1" || parts[1] == "true"
            gles2Keys.append(parts[0])
        case "position-attribute": gles2.positionAttribute = parts[1]; gles2Keys.append(parts[0])
        case "texcoord-attribute": gles2.texcoordAttribute = parts[1]; gles2Keys.append(parts[0])
        case "color-attribute": gles2.colorAttribute = parts[1]; gles2Keys.append(parts[0])
        case "color-uniform": gles2.colorUniform = parts[1]; gles2Keys.append(parts[0])
        case "opacity-uniform": gles2.opacityUniform = parts[1]; gles2Keys.append(parts[0])
        case "position-matrix": gles2.positionMatrices.append(parts[1]); gles2Keys.append(parts[0])
        case "uv-varying": gles2.uvVarying = parts[1]; gles2Keys.append(parts[0])
        case "color-varying": gles2.colorVarying = parts[1]; gles2Keys.append(parts[0])
        case "content-sampler": gles2.contentSampler = parts[1]; gles2Keys.append(parts[0])
        case "format":
            guard parts[1] == "spirv" || parts[1] == "gles2" else { throw PyShaderError("unknown format `\(parts[1])`") }
            format = parts[1]
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
    if format != "gles2", let key = gles2Keys.first {
        throw PyShaderError("option `\(key)` applies to format=gles2")
    }
    switch name {
    case "compute": return (.computeImage(.nucleantUI(samplesContent: samplesContent, contentIsTopDown: contentIsTopDown, arguments: arguments, texturesAreTopDown: texturesAreTopDown)), format, file, gles2, singleFile)
    case "fragment": return (.nucleant, format, file, gles2, singleFile)
    case "graphics": return (.graphics(.nucleantUI(samplesContent: samplesContent, contentIsTopDown: contentIsTopDown, arguments: arguments, texturesAreTopDown: texturesAreTopDown)), format, file, gles2, singleFile)
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

/// Registers a module the next compiles can import: `name` dotted (`noise`,
/// `pyshader.stdlib.fragment.sdf`), `source` its Python source (a package's
/// `__init__.py`).
@_expose(wasm, "pyshader_add_module")
@_cdecl("pyshader_add_module")
public func pyshader_add_module(
    _ namePointer: UnsafeRawPointer?,
    _ nameLength: Int32,
    _ sourcePointer: UnsafeRawPointer?,
    _ sourceLength: Int32
) {
    moduleSources[string(from: namePointer, length: nameLength)] = string(from: sourcePointer, length: sourceLength)
}

/// Forgets every registered module.
@_expose(wasm, "pyshader_clear_modules")
@_cdecl("pyshader_clear_modules")
public func pyshader_clear_modules() {
    moduleSources = [:]
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
        let source = string(from: sourcePointer, length: sourceLength)
        let (shaderTarget, format, file, gles2, singleFile) = try target(from: string(from: optionsPointer, length: optionsLength))
        vertexStageBytes = []
        if format == "gles2" {
            let shader = try PyShader.compileGLES2(source, target: shaderTarget, sourceFile: file, modules: moduleSources, options: gles2)
            entryPointBytes = Array("main".utf8)
            vertexEntryPointBytes = Array("main".utf8)
            if singleFile {
                storeResult(Array(shader.singleFile.utf8))
            } else {
                vertexStageBytes = Array(shader.vertex.utf8)
                storeResult(Array(shader.fragment.utf8))
            }
            return 0
        }
        let shader = try PyShader.compile(source, target: shaderTarget, sourceFile: file, modules: moduleSources)
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

/// The vertex stage of the last successful `format=gles2` compile without
/// `single-file`, copied into `pointer` (at most `capacity` bytes); returns its
/// whole length, so a call with capacity 0 asks how much room it needs.
@_expose(wasm, "pyshader_vertex_stage")
@_cdecl("pyshader_vertex_stage")
public func pyshader_vertex_stage(_ pointer: UnsafeMutableRawPointer?, _ capacity: Int32) -> Int32 {
    copyOut(vertexStageBytes, to: pointer, capacity: capacity)
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
