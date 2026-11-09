//
//  GLES2Builtins.swift
//  PyShader
//
//  PyShader's builtins in GLSL ES 1.00. Most are GLSL's own; the float
//  functions it lacks (`sinh`, `round`, `trunc`…) are written as small
//  helpers; integer `abs`/`min`/`max`/`clamp` go through floats, as GLSL ES
//  1.00 has them for floats only. What has no equivalent at all (bit
//  operations, packing, `inverse`…) is an error naming the function.
//

extension GLES2Writer {

    func callBuiltin(_ name: String, _ args: [GLValue], line: Int) throws -> GLValue? {
        switch name {
        // MARK: Trigonometry, exponential
        case "sin", "cos", "tan", "asin", "acos", "radians", "degrees",
             "exp", "exp2", "log", "log2", "sqrt", "floor", "ceil", "fract":
            return try floatUnary(name, name, args, line)
        case "inversesqrt", "rsqrt":
            return try floatUnary("inversesqrt", name, args, line)
        case "atan":
            if args.count == 2 { return try floatBinary("atan", name, args, line) }
            return try floatUnary("atan", name, args, line)
        case "atan2":
            return try floatBinary("atan", name, args, line)
        case "pow":
            return try floatBinary("pow", name, args, line)
        case "sinh", "cosh", "tanh", "asinh", "acosh", "atanh", "trunc", "round":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            let fn = try compiler.helper(name, type: x.type, line: line, uses: &uses) { t in
                Self.helperBody(name, type: t, isScalar: x.type.isScalar)
            }
            return GLValue(code: "\(fn)(\(x.code))", type: x.type)

        // MARK: Common
        case "abs", "sign":
            try arity(name, args, 1, line)
            let x = args[0]
            guard x.type.isNumeric else { throw PyShaderError("\(name)() needs a number, got `\(x.type)`", line: line) }
            return try viaFloat(x.type, line: line) { "\(name)(\(try self.asFloat(x, name, line).code))" }
        case "mod":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            return GLValue(code: "mod(\(a.code), \(b.code))", type: a.type)
        case "min", "max":
            guard args.count >= 2 else { throw PyShaderError("\(name)() needs at least 2 arguments", line: line) }
            var acc = args[0]
            for next in args.dropFirst() {
                let (a, b) = try promote(acc, next, line: line)
                acc = try viaFloat(a.type, line: line) {
                    "\(name)(\(try self.asFloat(a, name, line).code), \(try self.asFloat(b, name, line).code))"
                }
            }
            return acc
        case "clamp":
            try arity(name, args, 3, line)
            let (x, lo, hi) = try promoteThree(args, line: line)
            return try viaFloat(x.type, line: line) {
                "clamp(\(try self.asFloat(x, name, line).code), \(try self.asFloat(lo, name, line).code), \(try self.asFloat(hi, name, line).code))"
            }
        case "saturate":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return GLValue(code: "clamp(\(x.code), 0.0, 1.0)", type: x.type)
        case "mix", "lerp":
            try arity(name, args, 3, line)
            let (a, b, t) = try promoteThree(args, line: line, forceFloat: true)
            return GLValue(code: "mix(\(a.code), \(b.code), \(t.code))", type: a.type)
        case "step":
            try arity(name, args, 2, line)
            let (edge, x) = try promote(args[0], args[1], line: line, forceFloat: true)
            return GLValue(code: "step(\(edge.code), \(x.code))", type: x.type)
        case "smoothstep":
            try arity(name, args, 3, line)
            let (e0, e1, x) = try promoteThree(args, line: line, forceFloat: true)
            return GLValue(code: "smoothstep(\(e0.code), \(e1.code), \(x.code))", type: x.type)
        case "fma":
            try arity(name, args, 3, line)
            let (a, b, c) = try promoteThree(args, line: line, forceFloat: true)
            return GLValue(code: "(\(a.code) * \(b.code) + \(c.code))", type: a.type)

        // MARK: Geometric
        case "length":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return GLValue(code: "length(\(x.code))", type: x.type.elementType!)
        case "distance":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            return GLValue(code: "distance(\(a.code), \(b.code))", type: a.type.elementType!)
        case "dot":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            guard a.type.isVector else { throw PyShaderError("dot() needs vectors", line: line) }
            return GLValue(code: "dot(\(a.code), \(b.code))", type: a.type.elementType!)
        case "cross":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            guard a.type.componentCount == 3 else { throw PyShaderError("cross() needs 3-component vectors", line: line) }
            return GLValue(code: "cross(\(a.code), \(b.code))", type: a.type)
        case "normalize":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return GLValue(code: "normalize(\(x.code))", type: x.type)
        case "faceforward":
            try arity(name, args, 3, line)
            let (n, i, nref) = try promoteThree(args, line: line, forceFloat: true)
            return GLValue(code: "faceforward(\(n.code), \(i.code), \(nref.code))", type: n.type)
        case "reflect":
            try arity(name, args, 2, line)
            let (i, n) = try promote(args[0], args[1], line: line, forceFloat: true)
            return GLValue(code: "reflect(\(i.code), \(n.code))", type: i.type)
        case "refract":
            try arity(name, args, 3, line)
            let (i, n) = try promote(args[0], args[1], line: line, forceFloat: true)
            let eta = try coerce(args[2], to: i.type.elementType!, line: line)
            return GLValue(code: "refract(\(i.code), \(n.code), \(eta.code))", type: i.type)

        // MARK: Matrices
        case "outerProduct":
            try arity(name, args, 2, line)
            let c = try materialize(try asFloat(args[0], name, line), line: line)
            let r = try materialize(try asFloat(args[1], name, line), line: line)
            guard c.type.isVector, r.type.isVector else {
                throw PyShaderError("outerProduct() needs two vectors, got `\(c.type)` and `\(r.type)`", line: line)
            }
            let n = c.type.componentCount
            guard r.type.componentCount == n else {
                throw PyShaderError("outerProduct() of a `\(c.type)` and a `\(r.type)` is not square, and OpenGL ES 2 has only square matrices", line: line)
            }
            let columns = (0..<n).map { "\(c.code) * \(r.code).\(Self.swizzleLetters([$0]))" }
            return GLValue(code: "mat\(n)(\(columns.joined(separator: ", ")))", type: .matrix(.float(bits: 32), columns: n, rows: n))
        case "transpose", "determinant", "inverse":
            throw unavailable(name, "it has no matrix functions besides `matrixCompMult`", line)

        // MARK: Vector relational
        case "any", "all":
            try arity(name, args, 1, line)
            guard args[0].type.isVector, args[0].type.isBool else {
                throw PyShaderError("\(name)() needs a bool vector (e.g. `any(v > 0.5)`), got `\(args[0].type)`", line: line)
            }
            return GLValue(code: "\(name)(\(args[0].code))", type: .bool)

        // MARK: Derivatives
        case "dfdx", "dFdx", "dfdy", "dFdy", "fwidth":
            try requireFragment(name, line)
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            uses.insert(GLES2Compiler.derivativesKey)
            let gl = name == "fwidth" ? "fwidth" : name.lowercased() == "dfdx" ? "dFdx" : "dFdy"
            return GLValue(code: "\(gl)(\(x.code))", type: x.type)
        case "dFdxFine", "dfdx_fine", "dFdyFine", "dfdy_fine", "fwidthFine", "fwidth_fine",
             "dFdxCoarse", "dfdx_coarse", "dFdyCoarse", "dfdy_coarse", "fwidthCoarse", "fwidth_coarse":
            throw unavailable(name, "it has only `dFdx`, `dFdy` and `fwidth`, through GL_OES_standard_derivatives", line)

        // MARK: Without an equivalent
        case "isnan", "isinf":
            throw unavailable(name, "GLSL ES 1.00 cannot test for NaN or infinity", line)
        case "modf", "frexp", "ldexp":
            throw unavailable(name, "GLSL ES 1.00 has no float decomposition", line)
        case "packHalf2x16", "packUnorm2x16", "pack_float_to_unorm2x16", "packSnorm2x16", "pack_float_to_snorm2x16",
             "packUnorm4x8", "pack_float_to_unorm4x8", "packSnorm4x8", "pack_float_to_snorm4x8",
             "unpackHalf2x16", "unpackUnorm2x16", "unpack_unorm2x16_to_float", "unpackSnorm2x16", "unpack_snorm2x16_to_float",
             "unpackUnorm4x8", "unpack_unorm4x8_to_float", "unpackSnorm4x8", "unpack_snorm4x8_to_float":
            throw unavailable(name, "it has no unsigned integers to pack into", line)
        case "bitCount", "popcount", "bitfieldReverse", "reverse_bits", "bitfieldExtract", "extract_bits",
             "bitfieldInsert", "insert_bits", "floatBitsToInt", "floatBitsToUint", "intBitsToFloat", "uintBitsToFloat",
             "findLSB", "findMSB":
            throw unavailable(name, "it has no bit operations", line)

        // MARK: Fragment control
        case "discard":
            try requireFragment(name, line)
            try arity(name, args, 0, line)
            emitDiscard()
            return .void

        // MARK: Host resources
        case "layer":
            try arity(name, args, 1, line)
            let p = try coerce(args[0], to: .float(2), line: line)
            return try compiler.sampleContent(at: p, from: self, line: line)
        case "len":
            try arity(name, args, 1, line)
            switch args[0].type {
            case .array, .tuple, .matrix, .vector:
                return Self.literal(.int(args[0].type.count), type: .int)
            default:
                throw PyShaderError("len() needs a list, tuple, vector or matrix, got `\(args[0].type)`", line: line)
            }

        default:
            return nil
        }
    }

    // MARK: Helpers

    private func unavailable(_ name: String, _ why: String, _ line: Int) -> PyShaderError {
        PyShaderError("`\(name)()` is not available in OpenGL ES 2: \(why)", line: line)
    }

    private func requireFragment(_ name: String, _ line: Int) throws {
        if case .fragment = program.target { return }
        throw PyShaderError("\(name)() is only available in the fragment target (a compute shader has no derivatives); return the value without it", line: line)
    }

    private func arity(_ name: String, _ args: [GLValue], _ n: Int, _ line: Int) throws {
        guard args.count == n else {
            throw PyShaderError("\(name)() takes \(n) argument(s), got \(args.count)", line: line)
        }
    }

    func asFloat(_ v: GLValue, _ name: String, _ line: Int) throws -> GLValue {
        guard v.type.isNumeric else {
            throw PyShaderError("\(name)() needs a number, got `\(v.type)`", line: line)
        }
        if v.type.isFloat { return v }
        return try coerce(v, to: v.type.withKind(.float(bits: 32)), line: line)
    }

    /// A float function applied to `type`: as is for floats, through a
    /// conversion and back for ints, which GLSL ES 1.00 has no overload for.
    private func viaFloat(_ type: ShaderType, line: Int, _ call: () throws -> String) throws -> GLValue {
        let code = try call()
        if type.isFloat { return GLValue(code: code, type: type) }
        return GLValue(code: "\(try typeName(type, line: line))(\(code))", type: type)
    }

    private func floatUnary(_ gl: String, _ name: String, _ args: [GLValue], _ line: Int) throws -> GLValue {
        try arity(name, args, 1, line)
        let x = try asFloat(args[0], name, line)
        return GLValue(code: "\(gl)(\(x.code))", type: x.type)
    }

    private func floatBinary(_ gl: String, _ name: String, _ args: [GLValue], _ line: Int) throws -> GLValue {
        try arity(name, args, 2, line)
        let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
        return GLValue(code: "\(gl)(\(a.code), \(b.code))", type: a.type)
    }

    private func promoteThree(_ args: [GLValue], line: Int, forceFloat: Bool = false) throws -> (GLValue, GLValue, GLValue) {
        let (a, b) = try promote(args[0], args[1], line: line, forceFloat: forceFloat)
        let (a2, c) = try promote(a, args[2], line: line, forceFloat: forceFloat)
        let b2 = try coerce(b, to: a2.type, line: line)
        return (a2, b2, c)
    }

    /// The body of a helper for the float function GLSL ES 1.00 lacks, on `x` of type `t`.
    static func helperBody(_ name: String, type t: String, isScalar: Bool) -> String {
        switch name {
        case "sinh": return "    return (exp(x) - exp(-x)) * 0.5;\n"
        case "cosh": return "    return (exp(x) + exp(-x)) * 0.5;\n"
        case "tanh":
            // From exp(-2|x|), which cannot overflow.
            return "    \(t) e = exp(-2.0 * abs(x));\n    return sign(x) * (1.0 - e) / (1.0 + e);\n"
        case "asinh": return "    return sign(x) * log(abs(x) + sqrt(x * x + 1.0));\n"
        case "acosh": return "    return log(x + sqrt(x * x - 1.0));\n"
        case "atanh": return "    return 0.5 * log((1.0 + x) / (1.0 - x));\n"
        case "trunc": return "    return sign(x) * floor(abs(x));\n"
        default:
            // round: half to even, as Python's round() and SPIR-V's RoundEven.
            let tie = isScalar ? "(r - x == 0.5 ? 1.0 : 0.0)" : "\(t)(equal(r - x, \(t)(0.5)))"
            return "    \(t) r = floor(x + 0.5);\n    return r - \(tie) * mod(r, 2.0);\n"
        }
    }
}
