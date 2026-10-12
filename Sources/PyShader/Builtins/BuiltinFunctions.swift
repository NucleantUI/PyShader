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
        case "modf":
            try arity(name, args, 1, line)
            return try modf(try asFloat(args[0], name, line))
        case "frexp":
            try arity(name, args, 1, line)
            return try frexp(try asFloat(args[0], name, line), line: line)
        case "ldexp":
            try arity(name, args, 2, line)
            var x = try asFloat(args[0], name, line)
            var e = try asInt32(args[1], name, line)
            let n = max(x.type.componentCount, e.type.componentCount)
            guard x.type.componentCount == n || x.type.isScalar, e.type.componentCount == n || e.type.isScalar else {
                throw PyShaderError("ldexp() needs an exponent with as many components as `\(x.type)`, got `\(e.type)`", line: line)
            }
            x = try coerce(x, to: x.type.with(components: n)!, line: line)
            e = try coerce(e, to: e.type.with(components: n)!, line: line)
            return emitExt(.ldexp, type: x.type, [x.id, e.id])

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
        case "outerProduct":
            // Column vector `c` times row vector `r`: len(r) columns of len(c) rows, column j
            // being c * r[j]. Built from those products rather than OpOuterProduct, which naga
            // (the web build) types transposed and WGSL has no spelling for.
            try arity(name, args, 2, line)
            var c = try asFloat(args[0], name, line), r = try asFloat(args[1], name, line)
            guard c.type.isVector, r.type.isVector else {
                throw PyShaderError("outerProduct() needs two vectors, got `\(c.type)` and `\(r.type)`", line: line)
            }
            let kind = ScalarKind.float(bits: max(c.type.scalarKind!.bits, r.type.scalarKind!.bits))
            c = try coerce(c, to: c.type.withKind(kind), line: line)
            r = try coerce(r, to: r.type.withKind(kind), line: line)
            let columns = (0..<r.type.componentCount).map { j in
                emit(.opVectorTimesScalar, type: c.type, [c.id, swizzle(r, [j]).id]).id
            }
            return emit(.opCompositeConstruct, type: .matrix(kind, columns: columns.count, rows: c.type.componentCount), columns)

        // MARK: Packing
        case "packHalf2x16": return try pack(.packHalf2x16, 2, name, args, line)
        case "packUnorm2x16", "pack_float_to_unorm2x16": return try pack(.packUnorm2x16, 2, name, args, line)
        case "packSnorm2x16", "pack_float_to_snorm2x16": return try pack(.packSnorm2x16, 2, name, args, line)
        case "packUnorm4x8", "pack_float_to_unorm4x8": return try pack(.packUnorm4x8, 4, name, args, line)
        case "packSnorm4x8", "pack_float_to_snorm4x8": return try pack(.packSnorm4x8, 4, name, args, line)
        case "unpackHalf2x16": return try unpack(.unpackHalf2x16, 2, name, args, line)
        case "unpackUnorm2x16", "unpack_unorm2x16_to_float": return try unpack(.unpackUnorm2x16, 2, name, args, line)
        case "unpackSnorm2x16", "unpack_snorm2x16_to_float": return try unpack(.unpackSnorm2x16, 2, name, args, line)
        case "unpackUnorm4x8", "unpack_unorm4x8_to_float": return try unpack(.unpackUnorm4x8, 4, name, args, line)
        case "unpackSnorm4x8", "unpack_snorm4x8_to_float": return try unpack(.unpackSnorm4x8, 4, name, args, line)

        // MARK: Bits
        case "bitCount":
            try arity(name, args, 1, line)
            let x = try asInt32(args[0], name, line)
            return intResult(emit(.opBitCount, type: x.type, [x.id]))
        case "popcount":
            // Metal's popcount keeps the argument's type; GLSL's bitCount returns int.
            try arity(name, args, 1, line)
            let x = try asInt32(args[0], name, line)
            return emit(.opBitCount, type: x.type, [x.id])
        case "bitfieldReverse", "reverse_bits":
            try arity(name, args, 1, line)
            let x = try asInt32(args[0], name, line)
            return emit(.opBitReverse, type: x.type, [x.id])
        case "bitfieldExtract", "extract_bits":
            try arity(name, args, 3, line)
            let x = try asInt32(args[0], name, line)
            let offset = try scalarInt(args[1], name, line), bits = try scalarInt(args[2], name, line)
            let op: SpirvOp = x.type.scalarKind!.isSigned ? .opBitFieldSExtract : .opBitFieldUExtract
            return emit(op, type: x.type, [x.id, offset.id, bits.id])
        case "bitfieldInsert", "insert_bits":
            try arity(name, args, 4, line)
            let (b, i) = try promote(try asInt32(args[0], name, line), try asInt32(args[1], name, line), line: line)
            let offset = try scalarInt(args[2], name, line), bits = try scalarInt(args[3], name, line)
            return emit(.opBitFieldInsert, type: b.type, [b.id, i.id, offset.id, bits.id])
        case "floatBitsToInt", "floatBitsToUint":
            try arity(name, args, 1, line)
            let x = try asFloat(args[0], name, line)
            guard x.type.scalarKind == .float(bits: 32) else {
                throw PyShaderError("\(name)() needs a 32-bit float, got `\(x.type)`", line: line)
            }
            let n = x.type.componentCount
            return emit(.opBitcast, type: name == "floatBitsToInt" ? .int(n) : .uint(n), [x.id])
        case "intBitsToFloat", "uintBitsToFloat":
            try arity(name, args, 1, line)
            let signed = name == "intBitsToFloat"
            let x: Value
            if let literal = builder.literalInt(args[0].id), args[0].type.isScalar, args[0].type.isInt {
                // `uintBitsToFloat(0x3F800000)`: the literal takes the parameter's kind.
                let t = ShaderType.scalar(.int(bits: 32, signed: signed))
                x = Value(id: builder.constant(int: literal, type: t), type: t)
            } else {
                guard args[0].type.scalarKind == .int(bits: 32, signed: signed) else {
                    throw PyShaderError("\(name)() needs \(signed ? "an `int`" : "a `uint`") scalar or vector, got `\(args[0].type)`", line: line)
                }
                x = args[0]
            }
            return emit(.opBitcast, type: .float(x.type.componentCount), [x.id])
        case "findLSB":
            try arity(name, args, 1, line)
            let x = try asInt32(args[0], name, line)
            return intResult(emitExt(.findILsb, type: x.type, [x.id]))
        case "findMSB":
            try arity(name, args, 1, line)
            let x = try asInt32(args[0], name, line)
            return intResult(emitExt(x.type.scalarKind!.isSigned ? .findSMsb : .findUMsb, type: x.type, [x.id]))

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
        case "dfdx", "dFdx": return try derivative(.opDPdx, name, args, line)
        case "dfdy", "dFdy": return try derivative(.opDPdy, name, args, line)
        case "fwidth": return try derivative(.opFwidth, name, args, line)
        case "dFdxFine", "dfdx_fine": return try derivative(.opDPdxFine, name, args, line)
        case "dFdyFine", "dfdy_fine": return try derivative(.opDPdyFine, name, args, line)
        case "fwidthFine", "fwidth_fine": return try derivative(.opFwidthFine, name, args, line)
        case "dFdxCoarse", "dfdx_coarse": return try derivative(.opDPdxCoarse, name, args, line)
        case "dFdyCoarse", "dfdy_coarse": return try derivative(.opDPdyCoarse, name, args, line)
        case "fwidthCoarse", "fwidth_coarse": return try derivative(.opFwidthCoarse, name, args, line)

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

    /// An integer scalar or vector widened to 32 bits, keeping its signedness:
    /// Vulkan takes the bit instructions on 32-bit integers only.
    private func asInt32(_ v: Value, _ name: String, _ line: Int) throws -> Value {
        guard case .int(_, let signed) = v.type.scalarKind else {
            throw PyShaderError("\(name)() needs an integer, got `\(v.type)`", line: line)
        }
        return try coerce(v, to: v.type.withKind(.int(bits: 32, signed: signed)), line: line)
    }

    /// A bit offset or count: one integer of either signedness.
    private func scalarInt(_ v: Value, _ name: String, _ line: Int) throws -> Value {
        guard v.type.isScalar else {
            throw PyShaderError("\(name)() takes a scalar bit offset and count, got `\(v.type)`", line: line)
        }
        return try asInt32(v, name, line)
    }

    /// Like GLSL, `bitCount`, `findLSB` and `findMSB` give an int (a bit index is -1 when
    /// no bit is set) for int and uint alike. The instruction is emitted in the argument's
    /// type and a uint result bitcast after it: naga (the web build) types the result as
    /// the argument.
    private func intResult(_ v: Value) -> Value {
        if v.type.scalarKind!.isSigned { return v }
        return emit(.opBitcast, type: .int(v.type.componentCount), [v.id])
    }

    /// `(fraction, whole)` as Python's math.modf: whole is trunc(x), both signed like x,
    /// and an integral x (infinity included) has fraction 0. Spelled with trunc rather
    /// than GLSL.std.450 ModfStruct, whose result type naga (the web build) cannot resolve.
    private func modf(_ x: Value) throws -> Value {
        let whole = emitExt(.trunc, type: x.type, [x.id])
        let integral = emit(.opFOrdEqual, type: .bool(x.type.componentCount), [x.id, whole.id])
        let difference = emit(.opFSub, type: x.type, [x.id, whole.id])
        let fraction = emit(.opSelect, type: x.type, [integral.id, builder.zero(of: x.type), difference.id])
        return emit(.opCompositeConstruct, type: .tuple([x.type, x.type]), [fraction.id, whole.id])
    }

    /// `(mantissa, exponent)` as Python's math.frexp: x == mantissa * 2 ** exponent with
    /// |mantissa| in [0.5, 1); zero, infinity and NaN come back as they are with exponent 0.
    /// Read from the float's bits (exact, subnormals included) rather than GLSL.std.450
    /// FrexpStruct, whose result type naga (the web build) cannot resolve.
    private func frexp(_ x0: Value, line: Int) throws -> Value {
        let n = x0.type.componentCount
        let x = try coerce(x0, to: .float(n), line: line)   // a half widens exactly
        let u = ShaderType.uint(n), i = ShaderType.int(n), b = ShaderType.bool(n)
        func exponentField(_ bits: Value) -> Value {
            let shifted = emit(.opShiftRightLogical, type: u, [bits.id, splatConstant(u, int: 23)])
            return emit(.opBitwiseAnd, type: u, [shifted.id, splatConstant(u, int: 0xFF)])
        }
        // A subnormal has a zero exponent field: scale it by 2^24 into the normal range first.
        let subnormal = emit(.opIEqual, type: b, [exponentField(emit(.opBitcast, type: u, [x.id])).id, builder.zero(of: u)])
        let scaled = emit(.opFMul, type: x.type, [x.id, splatConstant(x.type, float: 16_777_216)])
        let normal = emit(.opSelect, type: x.type, [subnormal.id, scaled.id, x.id])
        let bits = emit(.opBitcast, type: u, [normal.id])
        let field = exponentField(bits)
        let bias = emit(.opSelect, type: i, [subnormal.id, splatConstant(i, int: 126 + 24), splatConstant(i, int: 126)])
        let exponent = emit(.opISub, type: i, [emit(.opBitcast, type: i, [field.id]).id, bias.id])
        // Keep sign and fraction bits, set the exponent field to 126: a magnitude in [0.5, 1).
        // The mask is spelled as its Int32 bit pattern: Int is 32 bits on wasm32.
        let signAndFraction = emit(.opBitwiseAnd, type: u, [bits.id, splatConstant(u, int: Int(Int32(bitPattern: 0x807F_FFFF)))])
        let mantissaBits = emit(.opBitwiseOr, type: u, [signAndFraction.id, splatConstant(u, int: 0x3F00_0000)])
        let mantissa = emit(.opBitcast, type: x.type, [mantissaBits.id])
        // Two selects rather than one on `zero or infOrNaN`: naga takes `or` on scalars only.
        let zero = emit(.opFOrdEqual, type: b, [x.id, builder.zero(of: x.type)])
        let infOrNaN = emit(.opIEqual, type: b, [field.id, splatConstant(u, int: 0xFF)])
        var m = emit(.opSelect, type: x.type, [zero.id, x.id, mantissa.id])
        m = emit(.opSelect, type: x.type, [infOrNaN.id, x.id, m.id])
        var e = emit(.opSelect, type: i, [zero.id, builder.zero(of: i), exponent.id])
        e = emit(.opSelect, type: i, [infOrNaN.id, builder.zero(of: i), e.id])
        let result = try convert(m, to: x0.type, line: line)
        return emit(.opCompositeConstruct, type: .tuple([x0.type, i]), [result.id, e.id])
    }

    /// `floatN` -> `uint`: the vector's components packed into one word.
    private func pack(_ inst: GLSLstd450, _ n: Int, _ name: String, _ args: [Value], _ line: Int) throws -> Value {
        try arity(name, args, 1, line)
        guard args[0].type.isNumeric, args[0].type.componentCount == n || args[0].type.isScalar else {
            throw PyShaderError("\(name)() needs a `float\(n)`, got `\(args[0].type)`", line: line)
        }
        let v = try coerce(args[0], to: .float(n), line: line)
        return emitExt(inst, type: .uint, [v.id])
    }

    /// `uint` -> `floatN`, the inverse of `pack`.
    private func unpack(_ inst: GLSLstd450, _ n: Int, _ name: String, _ args: [Value], _ line: Int) throws -> Value {
        try arity(name, args, 1, line)
        let word: Value
        if let literal = builder.literalInt(args[0].id), args[0].type.isScalar, args[0].type.isInt {
            word = Value(id: builder.constant(int: literal, type: .uint), type: .uint)
        } else {
            guard args[0].type == .uint || args[0].type == .ushort else {
                throw PyShaderError("\(name)() needs a `uint`, got `\(args[0].type)`", line: line)
            }
            word = try coerce(args[0], to: .uint, line: line)
        }
        return emitExt(inst, type: .float(n), [word.id])
    }

    /// Screen-space derivatives; the fine and coarse ones need `DerivativeControl`.
    private func derivative(_ op: SpirvOp, _ name: String, _ args: [Value], _ line: Int) throws -> Value {
        try requireFragment(name, line)
        try arity(name, args, 1, line)
        let x = try asFloat(args[0], name, line)
        if ![.opDPdx, .opDPdy, .opFwidth].contains(op) { builder.require(.derivativeControl) }
        return emit(op, type: x.type, [x.id])
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
