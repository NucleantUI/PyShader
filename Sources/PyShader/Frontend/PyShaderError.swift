//
//  PyShaderError.swift
//  PyShader
//

/// A compile error with the 1-based Python source line it refers to.
public struct PyShaderError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int?
    /// The imported module's file the line is in (`noise.py`,
    /// `shaderlib/noise.py`); nil for the shader being compiled.
    public internal(set) var file: String?

    public init(_ message: String, line: Int? = nil, file: String? = nil) {
        self.message = message
        self.line = line
        self.file = file
    }

    public var description: String {
        switch (file, line) {
        case (let file?, let line?): return "\(file), line \(line): \(message)"
        case (let file?, nil): return "\(file): \(message)"
        case (nil, let line?): return "line \(line): \(message)"
        case (nil, nil): return message
        }
    }

    /// Runs `body`; an error it throws that names no file yet is placed in
    /// `file`, the module the code being compiled came from. Nil leaves it
    /// in the shader being compiled.
    static func attributing<T>(to file: String?, _ body: () throws -> T) throws -> T {
        guard let file else { return try body() }
        do {
            return try body()
        } catch var error as PyShaderError where error.file == nil {
            error.file = file
            throw error
        }
    }
}
