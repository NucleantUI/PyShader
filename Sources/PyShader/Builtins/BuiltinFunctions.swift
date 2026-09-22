//
//  BuiltinFunctions.swift
//  PyShader
//
//  The shader standard library: GLSL.std.450 extended instructions, the
//  core geometric/derivative ops and the Python builtins that map onto them.
//  Naming follows GLSL 450 with the Metal spellings accepted as aliases.
//

import SpirvCore

extension FunctionEmitter {

    /// Returns nil when `name` is not a builtin so the caller can report an unknown function.
    func callBuiltin(_ name: String, _ args: [Value], line: Int) throws -> Value? {
        switch name {
        // MARK: Trigonometry
        case "sin": return try floatUnary(.sin, name, args, line)
        case "cos": return try floatUnary(.cos, name, args, line)
        case "tan": return try floatUnary(.tan, name, args, line)
        case "asin": return try floatUnary(.asin, name, args, line)
        case "acos": return try floatUnary(.acos, name, args, line)
        case "atan":
            if args.count == 2 { return try floatBinary(.atan2, name, args, line) }
            return try floatUnary(.atan, name, args, line)
        case "atan2": return try floatBinary(.atan2, name, args, line)
        case "sinh": return try floatUnary(.sinh, name, args, line)
        case "cosh": return try floatUnary(.cosh, name, args, line)
        case "tanh": return try floatUnary(.tanh, name, args, line)
        case "asinh": return try floatUnary(.asinh, name, args, line)
        case "acosh": return try floatUnary(.acosh, name, args, line)
        case "atanh": return try floatUnary(.atanh, name, args, line)
        case "radians": return try floatUnary(.radians, name, args, line)
        case "degrees": return try floatUnary(.degrees, name, args, line)

        // MARK: Exponential
        case "pow": return try floatBinary(.pow, name, args, line)
        case "exp": return try floatUnary(.exp, name, args, line)
        case "exp2": return try floatUnary(.exp2, name, args, line)
        case "log": return try floatUnary(.log, name, args, line)
        case "log2": return try floatUnary(.log2, name, args, line)
        case "sqrt": return try floatUnary(.sqrt, name, args, line)
        case "inversesqrt", "rsqrt": return try floatUnary(.inverseSqrt, name, args, line)

        // MARK: Common
        case "abs": return try numericUnary(float: .fAbs, int: .sAbs, name, args, line)
        case "sign": return try numericUnary(float: .fSign, int: .sSign, name, args, line)
        case "floor": return try floatUnary(.floor, name, args, line)
        case "ceil": return try floatUnary(.ceil, name, args, line)
        case "round": return try floatUnary(.roundEven, name, args, line)
        case "trunc": return try floatUnary(.trunc, name, args, line)
        case "fract": return try floatUnary(.fract, name, args, line)
        case "mod":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            return emit(.opFMod, type: a.type, [a.id, b.id])
        case "min": return try numericFold(float: .fMin, sint: .sMin, uint: .uMin, name, args, line)
        case "max": return try numericFold(float: .fMax, sint: .sMax, uint: .uMax, name, args, line)
        case "clamp":
            try arity(name, args, 3, line)
            let (x, lo, hi) = try promoteThree(args, line: line)
            let inst: GLSLstd450 = x.type.isFloat ? .fClamp : (x.type.scalarKind!.isSigned ? .sClamp : .uClamp)
            return emitExt(inst, type: x.type, [x.id, lo.id, hi.id])
        case "saturate":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emitExt(.fClamp, type: x.type, [x.id, splatConstant(x.type, float: 0), splatConstant(x.type, float: 1)])
        case "mix", "lerp":
            try arity(name, args, 3, line)
            let (a, b, t) = try promoteThree(args, line: line, forceFloat: true)
            return emitExt(.fMix, type: a.type, [a.id, b.id, t.id])
        case "step":
            try arity(name, args, 2, line)
            let (edge, x) = try promote(args[0], args[1], line: line, forceFloat: true)
            return emitExt(.step, type: x.type, [edge.id, x.id])
        case "smoothstep":
            try arity(name, args, 3, line)
            let (e0, e1, x) = try promoteThree(args, line: line, forceFloat: true)
            return emitExt(.smoothStep, type: x.type, [e0.id, e1.id, x.id])
        case "fma":
            try arity(name, args, 3, line)
            let (a, b, c) = try promoteThree(args, line: line, forceFloat: true)
            return emitExt(.fma, type: a.type, [a.id, b.id, c.id])
        case "isnan":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emit(.opIsNan, type: .bool(x.type.componentCount), [x.id])
        case "isinf":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emit(.opIsInf, type: .bool(x.type.componentCount), [x.id])

        // MARK: Geometric
        case "length":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emitExt(.length, type: x.type.elementType!, [x.id])
        case "distance":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            return emitExt(.distance, type: a.type.elementType!, [a.id, b.id])
        case "dot":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            guard a.type.isVector else { throw PyShaderError("dot() needs vectors", line: line) }
            return emit(.opDot, type: a.type.elementType!, [a.id, b.id])
        case "cross":
            try arity(name, args, 2, line)
            let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
            guard a.type.componentCount == 3 else { throw PyShaderError("cross() needs 3-component vectors", line: line) }
            return emitExt(.cross, type: a.type, [a.id, b.id])
        case "normalize":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emitExt(.normalize, type: x.type, [x.id])
        case "faceforward":
            try arity(name, args, 3, line)
            let (n, i, nref) = try promoteThree(args, line: line, forceFloat: true)
            return emitExt(.faceForward, type: n.type, [n.id, i.id, nref.id])
        case "reflect":
            try arity(name, args, 2, line)
            let (i, n) = try promote(args[0], args[1], line: line, forceFloat: true)
            return emitExt(.reflect, type: i.type, [i.id, n.id])
        case "refract":
            try arity(name, args, 3, line)
            let (i, n) = try promote(args[0], args[1], line: line, forceFloat: true)
            let eta = try coerce(args[2], to: i.type.elementType!, line: line)
            return emitExt(.refract, type: i.type, [i.id, n.id, eta.id])

        // MARK: Matrices
        case "transpose":
            try arity(name, args, 1, line)
            guard case .matrix(let k, let c, let r) = args[0].type else {
                throw PyShaderError("transpose() needs a matrix, got `\(args[0].type)`", line: line)
            }
            return emit(.opTranspose, type: .matrix(k, columns: r, rows: c), [args[0].id])
        case "determinant":
            try arity(name, args, 1, line)
            guard case .matrix(let k, let c, let r) = args[0].type, c == r else {
                throw PyShaderError("determinant() needs a square matrix, got `\(args[0].type)`", line: line)
            }
            return emitExt(.determinant, type: .scalar(k), [args[0].id])
        case "inverse":
            try arity(name, args, 1, line)
            guard case .matrix(_, let c, let r) = args[0].type, c == r else {
                throw PyShaderError("inverse() needs a square matrix, got `\(args[0].type)`", line: line)
            }
            return emitExt(.matrixInverse, type: args[0].type, [args[0].id])

        // MARK: Vector relational
        case "any":
            try arity(name, args, 1, line)
            let v = try asBoolVector(args[0], name, line)
            return emit(.opAny, type: .bool, [v.id])
        case "all":
            try arity(name, args, 1, line)
            let v = try asBoolVector(args[0], name, line)
            return emit(.opAll, type: .bool, [v.id])

        // MARK: Derivatives
        case "dfdx", "dFdx":
            try requireFragment(name, line)
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emit(.opDPdx, type: x.type, [x.id])
        case "dfdy", "dFdy":
            try requireFragment(name, line)
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emit(.opDPdy, type: x.type, [x.id])
        case "fwidth":
            try requireFragment(name, line)
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            return emit(.opFwidth, type: x.type, [x.id])

        // MARK: Fragment control
        case "discard":
            try requireFragment(name, line)
            try arity(name, args, 0, line)
            return try emitDiscard(line: line)

        // MARK: Host resources
        case "layer":
            try arity(name, args, 1, line)
            let p = try coerce(args[0], to: .float(2), line: line)
            return try compiler.sampleContent(at: p, from: self, line: line)
        case "len":
            try arity(name, args, 1, line)
            switch args[0].type {
            case .floatArray(let argument, _):
                return try compiler.argumentArrayCount(argument, from: self, line: line)
            case .array, .tuple, .matrix, .vector:
                return Value(id: builder.constant(int: args[0].type.count), type: .int)
            default:
                throw PyShaderError("len() needs a list, tuple, vector or matrix, got `\(args[0].type)`", line: line)
            }

        default:
            return nil
        }
    }

    // MARK: Helpers

    /// Screen-space derivatives and `discard` exist only in a fragment stage.
    private func requireFragment(_ name: String, _ line: Int) throws {
        if case .fragment = program.target { return }
        throw PyShaderError("\(name)() is only available in the fragment target (a compute shader has no derivatives); return the value without it", line: line)
    }

    private func arity(_ name: String, _ args: [Value], _ n: Int, _ line: Int) throws {
        guard args.count == n else {
            throw PyShaderError("\(name)() takes \(n) argument(s), got \(args.count)", line: line)
        }
    }

    /// Ints are promoted so `sin(1)` works like Python.
    private func asFloat(_ v: Value, _ name: String, _ line: Int) throws -> Value {
        guard v.type.isNumeric else {
            throw PyShaderError("\(name)() needs a number, got `\(v.type)`", line: line)
        }
        if v.type.isFloat { return v }
        return try coerce(v, to: v.type.withKind(.float(bits: 32)), line: line)
    }

    private func asBoolVector(_ v: Value, _ name: String, _ line: Int) throws -> Value {
        guard v.type.isVector, v.type.isBool else {
            throw PyShaderError("\(name)() needs a bool vector (e.g. `any(v > 0.5)`), got `\(v.type)`", line: line)
        }
        return v
    }

    private func floatUnary(_ inst: GLSLstd450, _ name: String, _ args: [Value], _ line: Int) throws -> Value {
        try arity(name, args, 1, line)
        let x = try asFloat(args[0], name, line)
        return emitExt(inst, type: x.type, [x.id])
    }

    private func floatBinary(_ inst: GLSLstd450, _ name: String, _ args: [Value], _ line: Int) throws -> Value {
        try arity(name, args, 2, line)
        let (a, b) = try promote(args[0], args[1], line: line, forceFloat: true)
        return emitExt(inst, type: a.type, [a.id, b.id])
    }

    private func numericUnary(float: GLSLstd450, int: GLSLstd450, _ name: String, _ args: [Value], _ line: Int) throws -> Value {
        try arity(name, args, 1, line)
        let x = args[0]
        guard x.type.isNumeric else {
            throw PyShaderError("\(name)() needs a number, got `\(x.type)`", line: line)
        }
        if x.type.isFloat { return emitExt(float, type: x.type, [x.id]) }
        if !x.type.scalarKind!.isSigned { return x }   // abs/sign of unsigned
        return emitExt(int, type: x.type, [x.id])
    }

    /// `min(a, b, c, ...)` folds pairwise like the Python builtin.
    private func numericFold(float: GLSLstd450, sint: GLSLstd450, uint: GLSLstd450, _ name: String, _ args: [Value], _ line: Int) throws -> Value {
        guard args.count >= 2 else {
            throw PyShaderError("\(name)() needs at least 2 arguments", line: line)
        }
        var acc = args[0]
        for next in args.dropFirst() {
            let (a, b) = try promote(acc, next, line: line)
            let inst: GLSLstd450 = a.type.isFloat ? float : (a.type.scalarKind!.isSigned ? sint : uint)
            acc = emitExt(inst, type: a.type, [a.id, b.id])
        }
        return acc
    }

    private func promoteThree(_ args: [Value], line: Int, forceFloat: Bool = false) throws -> (Value, Value, Value) {
        let (a, b) = try promote(args[0], args[1], line: line, forceFloat: forceFloat)
        let (a2, c) = try promote(a, args[2], line: line, forceFloat: forceFloat)
        let b2 = try coerce(b, to: a2.type, line: line)
        return (a2, b2, c)
    }
}
