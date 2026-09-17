//
//  FunctionDecompiler+Expressions.swift
//  Spirv2PyShader
//
//  The expression each value-producing instruction stands for, in the
//  spelling PyShader compiles back to the same instruction.
//

import PyShader
import SpirvCore

extension FunctionDecompiler {

    func expression(_ inst: Instruction, _ op: SpirvOp, type t: ShaderType) throws -> PyExpr {
        let ops = inst.operands
        func a(_ i: Int) throws -> PyExpr { try use(ops[i]) }

        switch op {
        // MARK: Arithmetic
        case .opFAdd, .opIAdd: return try binary("+", ops[2], ops[3])
        case .opFSub, .opISub: return try binary("-", ops[2], ops[3])
        case .opFMul, .opIMul, .opVectorTimesScalar, .opMatrixTimesScalar, .opVectorTimesMatrix, .opMatrixTimesVector, .opMatrixTimesMatrix:
            return try binary("*", ops[2], ops[3])
        case .opFDiv: return try binary("/", ops[2], ops[3])
        case .opUDiv: return try binary("//", ops[2], ops[3])
        case .opSDiv:
            // OpSDiv truncates, Python's // floors: the same for non-negative operands.
            return try binary("//", ops[2], ops[3])
        case .opSMod, .opUMod: return try binary("%", ops[2], ops[3])
        case .opSRem:
            warn("OpSRem (sign of the dividend) written as `%` (sign of the divisor)")
            return try binary("%", ops[2], ops[3])
        case .opFMod: return .call("mod", [try a(2), try a(3)])
        case .opFRem:
            warn("OpFRem (sign of the dividend) written as `mod()` (sign of the divisor)")
            return .call("mod", [try a(2), try a(3)])
        case .opFNegate, .opSNegate: return .unary("-", try a(2))
        case .opDot: return .call("dot", [try a(2), try a(3)])
        case .opOuterProduct:
            warn("OpOuterProduct has no PyShader builtin")
            return .call("outer_product", [try a(2), try a(3)])
        case .opTranspose: return .call("transpose", [try a(2)])

        // MARK: Bits
        case .opBitwiseAnd: return try binary("&", ops[2], ops[3])
        case .opBitwiseOr: return try binary("|", ops[2], ops[3])
        case .opBitwiseXor: return try binary("^", ops[2], ops[3])
        case .opShiftLeftLogical: return try binary("<<", ops[2], ops[3])
        case .opShiftRightLogical, .opShiftRightArithmetic: return try binary(">>", ops[2], ops[3])
        case .opNot: return .unary("~", try a(2))

        // MARK: Logic & comparison
        case .opLogicalAnd: return .boolOp("and", try a(2), try a(3))
        case .opLogicalOr: return .boolOp("or", try a(2), try a(3))
        case .opLogicalNot: return .not(try a(2))
        case .opLogicalEqual, .opIEqual, .opFOrdEqual, .opFUnordEqual: return try compare("==", ops[2], ops[3])
        case .opLogicalNotEqual, .opINotEqual, .opFOrdNotEqual, .opFUnordNotEqual: return try compare("!=", ops[2], ops[3])
        case .opSLessThan, .opULessThan, .opFOrdLessThan, .opFUnordLessThan: return try compare("<", ops[2], ops[3])
        case .opSLessThanEqual, .opULessThanEqual, .opFOrdLessThanEqual, .opFUnordLessThanEqual: return try compare("<=", ops[2], ops[3])
        case .opSGreaterThan, .opUGreaterThan, .opFOrdGreaterThan, .opFUnordGreaterThan: return try compare(">", ops[2], ops[3])
        case .opSGreaterThanEqual, .opUGreaterThanEqual, .opFOrdGreaterThanEqual, .opFUnordGreaterThanEqual: return try compare(">=", ops[2], ops[3])
        case .opAny: return .call("any", [try a(2)])
        case .opAll: return .call("all", [try a(2)])
        case .opIsNan: return .call("isnan", [try a(2)])
        case .opIsInf: return .call("isinf", [try a(2)])
        case .opSelect:
            var cond = try a(2)
            if (try type(of: ops[2])).isVector {
                // PyShader splats a scalar condition to the vector's arity; take it back.
                if case .call(let f, let args) = cond, args.count == 1, ShaderType.named(f)?.isVector == true {
                    cond = args[0]
                } else {
                    warn("OpSelect with a vector condition; PyShader's `x if c else y` takes a scalar")
                }
            }
            return .ternary(cond: cond, then: try a(3), else: try a(4))

        // MARK: Conversions
        case .opConvertFToS, .opConvertFToU, .opConvertSToF, .opConvertUToF, .opFConvert, .opSConvert, .opUConvert, .opQuantizeToF16:
            return .call(t.description, [try a(2)])
        case .opBitcast:
            let from = try type(of: ops[2])
            if from.isInt, t.isInt {
                return .call(t.description, [try a(2)])
            }
            warn("OpBitcast between `\(from)` and `\(t)` has no PyShader spelling")
            return .call("bitcast_\(t.description)", [try a(2)])

        // MARK: Derivatives
        case .opDPdx, .opDPdxFine, .opDPdxCoarse: return .call("dfdx", [try a(2)])
        case .opDPdy, .opDPdyFine, .opDPdyCoarse: return .call("dfdy", [try a(2)])
        case .opFwidth, .opFwidthFine, .opFwidthCoarse: return .call("fwidth", [try a(2)])

        // MARK: Composites
        case .opCompositeConstruct:
            return try construct(t, Array(ops.dropFirst(2)))
        case .opCompositeExtract:
            return try extract(ops[2], indices: ops.dropFirst(3).map { Int($0) })
        case .opCompositeInsert:
            // A copy with one element replaced.
            let name = try copyToTemp(ops[3])
            let path = try extractPath(.name(name), type: try type(of: ops[3]), indices: ops.dropFirst(4).map { Int($0) })
            emitStatement(.assign(path, try a(2)))
            return .name(name)
        case .opVectorExtractDynamic:
            return .index(try a(2), try a(3))
        case .opVectorInsertDynamic:
            let name = try copyToTemp(ops[2])
            emitStatement(.assign(.index(.name(name), try a(4)), try a(3)))
            return .name(name)
        case .opVectorShuffle:
            return try shuffle(inst, type: t)

        // MARK: Extended instructions
        case .opExtInst:
            guard module.extInstImports[ops[2]] == "GLSL.std.450" else {
                throw error("extended instruction set `\(module.extInstImports[ops[2]] ?? "%\(ops[2])")` is not supported")
            }
            var args = try ops.dropFirst(4).map { try use($0) }
            let splats = zip(ops.dropFirst(4), args).map { splatScalar($0, $1) }
            if splats.contains(where: { $0 == nil }) {
                for (i, s) in splats.enumerated() { if let s { args[i] = s } }
            }
            return try glsl(ops[3], args)

        // MARK: Images
        case .opImageSampleImplicitLod, .opImageSampleExplicitLod, .opImageFetch, .opImageRead, .opImageGather,
             .opImageSampleDrefImplicitLod, .opImageSampleDrefExplicitLod:
            warn("texture sampling has no PyShader spelling in the fragment target; written as `texture()`")
            return .call("texture", [try a(2), try a(3)])
        case .opSampledImage:
            return try a(2)
        case .opImage:
            return try a(2)
        case .opImageQuerySize, .opImageQuerySizeLod:
            warn("image size queries have no PyShader spelling")
            return .call("texture_size", [try a(2)])
        case .opArrayLength:
            return .call("len", [try a(2)])

        default:
            throw error("\(op) is not supported")
        }
    }

    // MARK: - Helpers

    private func binary(_ op: String, _ l: SpirvId, _ r: SpirvId) throws -> PyExpr {
        let (le, re) = try operands(l, r)
        return .binary(op, le, re)
    }

    private func compare(_ op: String, _ l: SpirvId, _ r: SpirvId) throws -> PyExpr {
        let (le, re) = try operands(l, r)
        return .compare(op, le, re)
    }

    /// Both operands, with a splatted scalar written as the scalar (PyShader
    /// broadcasts) and a typed int literal next to a value written plainly.
    private func operands(_ l: SpirvId, _ r: SpirvId) throws -> (PyExpr, PyExpr) {
        var le = try use(l), re = try use(r)
        let lt = try type(of: l), rt = try type(of: r)
        // A splat against a vector of the same arity is its scalar; the vector keeps the arity.
        if lt.isVector, lt == rt {
            let ls = splatScalar(l, le, constants: true), rs = splatScalar(r, re, constants: true)
            if let ls, rs == nil { le = ls }
            if let rs, ls == nil { re = rs }
        }
        return try plainLiterals(le, re)
    }

    /// `uint(3)` next to a non-literal uint is just `3`: PyShader gives an int literal the other side's kind.
    private func plainLiterals(_ l: PyExpr, _ r: PyExpr) throws -> (PyExpr, PyExpr) {
        func unwrap(_ e: PyExpr) -> PyExpr? {
            if case .call(let f, let args) = e, args.count == 1, ["uint", "int", "short", "ushort"].contains(f), args[0].isIntLiteral { return args[0] }
            return nil
        }
        let lu = unwrap(l), ru = unwrap(r)
        if let lu, ru == nil, !r.isIntLiteral { return (lu, r) }
        if let ru, lu == nil, !l.isIntLiteral { return (l, ru) }
        return (l, r)
    }

    private func copyToTemp(_ id: SpirvId) throws -> String {
        let name = temporary()
        emitStatement(.assign(.name(name), try use(id)))
        return name
    }

    private func construct(_ t: ShaderType, _ ids: [SpirvId]) throws -> PyExpr {
        switch t {
        case .structure:
            return .call(analysis.typeName(t), try ids.map { try use($0) })
        case .tuple:
            return .tuple(try ids.map { try use($0) })
        case .array(_, let n):
            let elts = try ids.map { try use($0) }
            if n > 1, elts.allSatisfy({ $0 == elts[0] }) { return .binary("*", .list([elts[0]]), .number("\(n)")) }
            return .list(elts)
        case .matrix:
            return .call(t.description, try ids.map { try use($0) })
        case .vector(_, let n):
            // Extracts of a whole vector become the vector itself: float4(v.x, v.y, v.z, 1.0) -> float4(v, 1.0).
            var args: [PyExpr] = []
            var i = 0
            while i < ids.count {
                if let group = extractGroup(ids, from: i, constructed: n) {
                    args.append(try use(group.source))
                    i += group.count
                } else {
                    args.append(try use(ids[i]))
                    i += 1
                }
            }
            if args.count > 1, args.allSatisfy({ $0 == args[0] }), (try type(of: ids[0])).isScalar {
                return .call(t.description, [args[0]])
            }
            return .call(t.description, args)
        default:
            throw error("cannot construct a `\(t)`")
        }
    }

    /// A run of `OpCompositeExtract`s taking components 0..k-1 of one vector, absorbed at prepare time.
    private func extractGroup(_ ids: [SpirvId], from start: Int, constructed: Int) -> (source: SpirvId, count: Int)? {
        guard let source = absorbedSource(ids[start]) else { return nil }
        var count = 0
        while start + count < ids.count, absorbedSource(ids[start + count]) == source { count += 1 }
        return (source, count)
    }

    private func extract(_ id: SpirvId, indices: [Int]) throws -> PyExpr {
        if indices.count == 1, let name = unpackedName(id, indices[0]) { return .name(name) }
        return try extractPath(try use(id), type: try type(of: id), indices: indices)
    }

    /// `[a, b][1]` is `b`; `(a, b)[0]` is `a`.
    private func literalElement(_ e: PyExpr, _ i: Int) -> PyExpr? {
        switch e {
        case .list(let elts) where elts.indices.contains(i): return elts[i]
        case .tuple(let elts) where elts.indices.contains(i): return elts[i]
        case .binary("*", .list(let elts), let n) where elts.count == 1 && (n.intValue ?? 0) > i: return elts[0]
        default: return nil
        }
    }

    func extractPath(_ base: PyExpr, type: ShaderType, indices: [Int]) throws -> PyExpr {
        var e = base
        var t = type
        for i in indices {
            switch t {
            case .vector(let k, _):
                e = .attr(e, component(i))
                t = .scalar(k)
            case .matrix(let k, _, let rows):
                e = .index(e, .number("\(i)"))
                t = .vector(k, rows)
            case .array(let elem, _):
                e = literalElement(e, i) ?? .index(e, .number("\(i)"))
                t = elem
            case .structure(_, let members):
                e = .attr(e, members[i].0)
                t = members[i].1
            case .tuple(let members):
                e = literalElement(e, i) ?? .index(e, .number("\(i)"))
                t = members[i]
            default:
                throw error("cannot extract from a `\(t)`")
            }
        }
        return e
    }

    private func shuffle(_ inst: Instruction, type t: ShaderType) throws -> PyExpr {
        let ops = inst.operands
        let v1 = ops[2], v2 = ops[3]
        // An undefined component (0xFFFFFFFF) is -1: `Int` is 32 bits on wasm.
        let undefined = -1
        let indices = ops.dropFirst(4).map { $0 == UInt32.max ? undefined : Int($0) }
        guard case .vector(_, let n1) = try type(of: v1) else { throw error("shuffle of a non-vector") }
        let e1 = try use(v1)
        let e2 = v2 == v1 ? e1 : try use(v2)
        rememberShuffle(ops[1], source: v1, sourceExpr: e1, value: e2, indices: indices)

        if indices.allSatisfy({ $0 < n1 || $0 == undefined }) {
            let letters = indices.map { $0 == undefined ? "x" : component($0) }.joined()
            return .attr(e1, letters)
        }
        if indices.allSatisfy({ $0 >= n1 }) {
            let letters = indices.map { component($0 - n1) }.joined()
            return .attr(e2, letters)
        }
        let parts: [PyExpr] = indices.map { i in
            if i == undefined { return .number("0.0") }
            return i < n1 ? .attr(e1, component(i)) : .attr(e2, component(i - n1))
        }
        return .call(t.description, parts)
    }

    private func glsl(_ number: UInt32, _ args: [PyExpr]) throws -> PyExpr {
        guard let inst = GLSLstd450(rawValue: number) else { throw error("GLSL.std.450 instruction \(number) is not supported") }
        let name: String
        switch inst {
        case .round, .roundEven: name = "round"
        case .trunc: name = "trunc"
        case .fAbs, .sAbs: name = "abs"
        case .fSign, .sSign: name = "sign"
        case .floor: name = "floor"
        case .ceil: name = "ceil"
        case .fract: name = "fract"
        case .radians: name = "radians"
        case .degrees: name = "degrees"
        case .sin: name = "sin"
        case .cos: name = "cos"
        case .tan: name = "tan"
        case .asin: name = "asin"
        case .acos: name = "acos"
        case .atan: name = "atan"
        case .sinh: name = "sinh"
        case .cosh: name = "cosh"
        case .tanh: name = "tanh"
        case .asinh: name = "asinh"
        case .acosh: name = "acosh"
        case .atanh: name = "atanh"
        case .atan2: name = "atan2"
        case .pow: name = "pow"
        case .exp: name = "exp"
        case .log: name = "log"
        case .exp2: name = "exp2"
        case .log2: name = "log2"
        case .sqrt: name = "sqrt"
        case .inverseSqrt: name = "rsqrt"
        case .determinant: name = "determinant"
        case .matrixInverse: name = "inverse"
        case .fMin, .uMin, .sMin, .nMin: name = "min"
        case .fMax, .uMax, .sMax, .nMax: name = "max"
        case .fClamp, .uClamp, .sClamp, .nClamp: name = "clamp"
        case .fMix: name = "mix"
        case .step: name = "step"
        case .smoothStep: name = "smoothstep"
        case .fma: name = "fma"
        case .length: name = "length"
        case .distance: name = "distance"
        case .cross: name = "cross"
        case .normalize: name = "normalize"
        case .faceForward: name = "faceforward"
        case .reflect: name = "reflect"
        case .refract: name = "refract"
        default:
            warn("GLSL.std.450 \(inst) has no PyShader builtin; written as `glsl_\(inst)()`")
            name = "glsl_\(inst)"
        }
        let out = args
        if name == "clamp", args.count == 3, args[1] == .number("0.0"), args[2] == .number("1.0") {
            return .call("saturate", [args[0]])
        }
        return .call(name, out)
    }
}
