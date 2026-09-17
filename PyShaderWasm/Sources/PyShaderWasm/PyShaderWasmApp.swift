// Built as a reactor: the host calls `_initialize`, then the exports in
// Exports.swift. SwiftPM wants an entry point for an executable target, so
// this one does nothing.

@main
struct PyShaderWasmApp {
    static func main() {}
}
