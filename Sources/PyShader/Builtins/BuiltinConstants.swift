//
//  BuiltinConstants.swift
//  PyShader
//
//  Named values every shader can use without writing them out. A module that
//  defines a name of its own still wins: `emitName` only asks for these once
//  nothing else answers to the name.
//

enum BuiltinConstants {

    /// The constant `name` stands for, at the precision a `float` holds.
    static func value(named name: String) -> Double? {
        switch name {
        case "PI": return .pi
        default: return nil
        }
    }
}
