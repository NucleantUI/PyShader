//
//  PyShaderError.swift
//  PyShader
//

/// A compile error with the 1-based Python source line it refers to.
public struct PyShaderError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int?

    public init(_ message: String, line: Int? = nil) {
        self.message = message
        self.line = line
    }

    public var description: String {
        if let line { return "line \(line): \(message)" }
        return message
    }
}
