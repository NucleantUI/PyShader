//
//  FunctionWriter+Operations.swift
//  Spirv2GLSL
//
//  The instructions that compute a value, as GLSL ES 1.00 expressions. What
//  1.00 lacks but can be written another way (round, trunc, the integer
//  forms of min / max / abs / sign, %, the hyperbolic functions, a
//  component-wise select) is written that way; the rest is an error.
//

import SpirvCore

extension FunctionWriter {
    private func binary(_ op: String, _ prec: Int, _ a: Expr, _ b: Expr, _ t: SpirvType) -> Expr {
        Expr(code: "\(a.at(prec)) \(op) \(b.at(prec - 1))", type: t, prec: prec, reads: a.reads.union(b.reads),
             isConstantIndex: a.isConstantIndex && b.isConstantIndex && t.isScalar && !t.isBool)
    }

    /// A built-in function or constructor; of constant-index arguments, a constant index too.
    private func call(_ name: String, _ args: [Expr], _ t: SpirvType) -> Expr {
        Expr(code: "\(name)(\(args.map(\.code).joined(separator: ", ")))", type: t, reads: args.reduce(into: Set()) { $0.formUnion($1.reads) },
             isConstantIndex: t.isScalar && !t.isBool && args.allSatisfy(\.isConstantIndex))
    }

    private func unsupported(_ what: String) -> Spirv2GLSLError {
        error("\(what) has no OpenGL ES 2 form")
    }

    /// `type(x)`, converting a scalar or vector to `t`'s scalar kind.
    private func convert(_ x: Expr, to t: SpirvType) throws -> Expr {
        // float(3) is 3.0.
        if t.isScalar, t.isFloat, x.type.isInt, x.isTrivial, let k = Int(x.code) {
            return Expr(code: "\(k).0", type: t, prec: k < 0 ? 1 : 0, isTrivial: true, isConstantIndex: true)
        }
        return call(try stage.typeName(t), [x], t)
    }

    /// The float type with `t`'s shape.
    private func floatShape(of t: SpirvType) -> SpirvType {
        t.componentCount == 1 ? .float(width: 32) : .vector(.float(width: 32), t.componentCount)
    }

    /// An integer GLSL function done in floats: `int(f(float(a), …))`.
    private func viaFloat(_ name: String, _ args: [Expr], _ t: SpirvType) throws -> Expr {
        let f = floatShape(of: t)
        let floats = try args.map { $0.type.isFloat ? $0 : try convert($0, to: f.componentCount == $0.type.componentCount ? f : .float(width: 32)) }
        return try convert(call(name, floats, f), to: t)
    }

    func operation(_ i: Located, type t: SpirvType) throws -> Expr {
        let o = i.operands
        guard let op = i.op else { throw unsupported("opcode \(i.inst.opcode)") }
        switch op {
        // Arithmetic
        case .opFAdd, .opIAdd: return binary("+", 3, try use(o[2]), try use(o[3]), t)
        case .opFSub, .opISub: return binary("-", 3, try use(o[2]), try use(o[3]), t)
        case .opFMul, .opIMul, .opVectorTimesScalar, .opMatrixTimesScalar, .opVectorTimesMatrix,
             .opMatrixTimesVector, .opMatrixTimesMatrix:
            return binary("*", 2, try use(o[2]), try use(o[3]), t)
        case .opFDiv, .opSDiv: return binary("/", 2, try use(o[2]), try use(o[3]), t)
        case .opFNegate, .opSNegate:
            let a = try use(o[2])
            return Expr(code: "-" + a.at(0), type: t, prec: 1, reads: a.reads, isConstantIndex: a.isConstantIndex)
        case .opFMod:
            return call("mod", [try use(o[2]), try use(o[3])], t)
        case .opFRem:
            // Truncated: a - b * trunc(a / b).
            let a = try stable(o[2]), b = try stable(o[3])
            let q = "\(a.at(2)) / \(b.at(1))"
            return Expr(code: "\(a.at(3)) - \(b.at(2)) * (sign(\(q)) * floor(abs(\(q))))", type: t, prec: 3, reads: a.reads.union(b.reads))
        case .opSMod:
            // Floored, the sign of the divisor, as mod() does.
            return try viaFloat("mod", [try use(o[2]), try use(o[3])], t)
        case .opSRem:
            let a = try stable(o[2]), b = try stable(o[3])
            return Expr(code: "\(a.at(3)) - \(b.at(2)) * (\(a.at(2)) / \(b.at(1)))", type: t, prec: 3, reads: a.reads.union(b.reads))
        case .opDot:
            return call("dot", [try use(o[2]), try use(o[3])], t)
        case .opUDiv, .opUMod:
            throw unsupported("unsigned arithmetic")
        case .opShiftLeftLogical, .opShiftRightLogical, .opShiftRightArithmetic, .opBitwiseAnd, .opBitwiseOr,
             .opBitwiseXor, .opNot, .opBitFieldInsert, .opBitFieldSExtract, .opBitFieldUExtract, .opBitReverse, .opBitCount:
            throw unsupported("a bitwise operation")
        case .opTranspose:
            throw unsupported("transpose")
        case .opOuterProduct:
            throw unsupported("an outer product")

        // Comparisons
        case .opFOrdEqual, .opFUnordEqual, .opIEqual, .opLogicalEqual:
            return try compare("==", "equal", o, t)
        case .opFOrdNotEqual, .opFUnordNotEqual, .opINotEqual, .opLogicalNotEqual:
            return try compare("!=", "notEqual", o, t)
        case .opFOrdLessThan, .opFUnordLessThan, .opSLessThan, .opULessThan:
            return try compare("<", "lessThan", o, t)
        case .opFOrdLessThanEqual, .opFUnordLessThanEqual, .opSLessThanEqual, .opULessThanEqual:
            return try compare("<=", "lessThanEqual", o, t)
        case .opFOrdGreaterThan, .opFUnordGreaterThan, .opSGreaterThan, .opUGreaterThan:
            return try compare(">", "greaterThan", o, t)
        case .opFOrdGreaterThanEqual, .opFUnordGreaterThanEqual, .opSGreaterThanEqual, .opUGreaterThanEqual:
            return try compare(">=", "greaterThanEqual", o, t)
        case .opLogicalAnd, .opLogicalOr:
            let symbol = op == .opLogicalAnd ? "&&" : "||"
            let prec = op == .opLogicalAnd ? 6 : 8
            if t.isScalar { return binary(symbol, prec, try use(o[2]), try use(o[3]), t) }
            let a = try stable(o[2]), b = try stable(o[3])
            let parts = (0..<t.componentCount).map { "\(a.at(0)).\(Self.component($0)) \(symbol) \(b.at(0)).\(Self.component($0))" }
            return Expr(code: "\(try stage.typeName(t))(\(parts.joined(separator: ", ")))", type: t, reads: a.reads.union(b.reads))
        case .opLogicalNot:
            let a = try use(o[2])
            if t.isScalar { return Expr(code: "!" + a.at(0), type: t, prec: 1, reads: a.reads) }
            return call("not", [a], t)
        case .opAny: return call("any", [try use(o[2])], t)
        case .opAll: return call("all", [try use(o[2])], t)
        case .opIsNan, .opIsInf:
            throw unsupported(op == .opIsNan ? "isnan" : "isinf")
        case .opSelect:
            let condType = try type(of: o[2])
            if !condType.isScalar, let scalar = splats[o[2]] {
                _ = try use(o[2])
                let a = try use(o[3]), b = try use(o[4])
                return Expr(code: "\(scalar.at(8)) ? \(a.at(8)) : \(b.at(8))", type: t, prec: 9, reads: scalar.reads.union(a.reads).union(b.reads))
            }
            if condType.isScalar {
                let c = try use(o[2]), a = try use(o[3]), b = try use(o[4])
                if stage.containsArray(t) { throw unsupported("choosing between two arrays") }
                return Expr(code: "\(c.at(8)) ? \(a.at(8)) : \(b.at(8))", type: t, prec: 9, reads: c.reads.union(a.reads).union(b.reads))
            }
            let c = try stable(o[2]), a = try stable(o[3]), b = try stable(o[4])
            let parts = (0..<t.componentCount).map { k -> String in
                let x = Self.component(k)
                return "\(c.at(0)).\(x) ? \(a.at(0)).\(x) : \(b.at(0)).\(x)"
            }
            return Expr(code: "\(try stage.typeName(t))(\(parts.joined(separator: ", ")))", type: t)

        // Conversions
        case .opConvertFToS, .opConvertSToF:
            return try convert(try use(o[2]), to: t)
        case .opConvertFToU, .opConvertUToF, .opUConvert, .opSatConvertSToU, .opSatConvertUToS:
            throw unsupported("an unsigned integer conversion")
        case .opFConvert, .opSConvert:
            // Only widths change, and GLSL ES 1.00 has one of each.
            let a = try use(o[2])
            return Expr(code: a.code, type: t, prec: a.prec, reads: a.reads, isTrivial: a.isTrivial)
        case .opBitcast:
            let a = try use(o[2])
            guard a.type == t else {
                // An unsigned type on either side says so first.
                _ = try stage.typeName(a.type)
                _ = try stage.typeName(t)
                throw unsupported("a bit cast")
            }
            return a
        case .opQuantizeToF16:
            throw unsupported("quantizing to 16 bits")

        // Composites
        case .opCompositeConstruct:
            let parts = Array(o.dropFirst(2))
            let e = try construct(parts, t)
            if case .vector = t, parts.count == t.componentCount, Set(parts).count == 1, let scalar = e.splatParts.first {
                splats[o[1]] = scalar
            }
            return e
        case .opCompositeExtract:
            let base = try use(o[2])
            let path = o.dropFirst(3).map(Int.init)
            if path.count == 1, case .vector = base.type, let (name, letters) = Self.swizzle(base.code), path[0] < letters.count {
                let letter = letters[letters.index(letters.startIndex, offsetBy: path[0])]
                var e = Expr(code: "\(name).\(letter)", type: t, reads: base.reads, isTrivial: base.isTrivial)
                e.swizzledSize = base.swizzledSize
                return e
            }
            if path.count == 1, case .vector(_, let n) = base.type, base.isTrivial, Self.isName(base.code) {
                var e = Expr(code: "\(base.code).\(Self.component(path[0]))", type: t, reads: base.reads, isTrivial: true)
                e.swizzledSize = n
                return e
            }
            var code = base.at(0)
            var at = base.type
            for k in o.dropFirst(3).map(Int.init) {
                (code, at) = try member(code, at, k)
            }
            return Expr(code: code, type: t, reads: base.reads, isTrivial: base.isTrivial)
        case .opCompositeInsert:
            let object = try use(o[2])
            let base = try use(o[3])
            let n = try temporary(t)
            for s in try stage.assignCopy(from: base.code, to: n, type: t) { emitLine(s) }
            var code = n
            var at = t
            for k in o.dropFirst(4).map(Int.init) { (code, at) = try member(code, at, k) }
            for s in try stage.assignCopy(from: object.code, to: code, type: at) { emitLine(s) }
            return Expr(code: n, type: t, isTrivial: true)
        case .opVectorShuffle:
            return try shuffle(o, t)
        case .opVectorExtractDynamic:
            let v = try use(o[2])
            let k = try indexCode(o[3])
            return Expr(code: "\(v.at(0))[\(k)]", type: t, reads: v.reads)
        case .opVectorInsertDynamic:
            let v = try use(o[2]), x = try use(o[3])
            let k = try indexCode(o[4])
            let n = try temporary(t)
            emitLine("\(n) = \(v.code);")
            emitLine("\(n)[\(k)] = \(x.code);")
            return Expr(code: n, type: t, isTrivial: true)

        // Derivatives
        case .opDPdx, .opDPdxFine, .opDPdxCoarse: return try derivative("dFdx", o)
        case .opDPdy, .opDPdyFine, .opDPdyCoarse: return try derivative("dFdy", o)
        case .opFwidth, .opFwidthFine, .opFwidthCoarse: return try derivative("fwidth", o)

        // Images
        case .opSampledImage:
            let image = try use(o[2])
            return Expr(code: image.code, type: t, isTrivial: true)
        case .opImage:
            let sampled = try use(o[2])
            return Expr(code: sampled.code, type: t, isTrivial: true)
        case .opImageSampleImplicitLod, .opImageSampleExplicitLod, .opImageSampleProjImplicitLod, .opImageSampleProjExplicitLod:
            return try sample(i, t)
        case .opImageQuerySizeLod, .opImageQuerySize:
            let image = try use(o[2])
            guard t == .vector(.int(width: 32, signed: true), 2) else { throw unsupported("an image size other than a 2D one as ivec2") }
            return Expr(code: try stage.sizeUniform(for: image.code), type: t, isTrivial: true)
        case .opImageFetch, .opImageRead, .opImageGather, .opImageDrefGather, .opImageSampleDrefImplicitLod,
             .opImageSampleDrefExplicitLod, .opImageQueryLod, .opImageQueryLevels, .opImageQuerySamples:
            throw unsupported("\(op)")

        case .opExtInst:
            return try extInst(i, t)

        default:
            throw unsupported("\(op)")
        }
    }

    func emitLine(_ s: String) { appendLine(s) }

    static func isName(_ code: String) -> Bool {
        guard let first = code.first, first == "_" || first.isLetter else { return false }
        return code.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Runs of components of one variable in a constructor as one swizzle,
    /// or the variable itself: vec4(v.x, v.y, v.z, 1.0) is vec4(v, 1.0).
    private func mergeComponents(_ es: [Expr]) -> [Expr] {
        var out: [Expr] = []
        var k = 0
        while k < es.count {
            guard let (name, letters) = Self.swizzle(es[k].code), letters.count == 1, es[k].swizzledSize > 0 else {
                out.append(es[k]); k += 1; continue
            }
            var run = String(letters)
            var reads = es[k].reads
            var j = k + 1
            while j < es.count, let (n2, l2) = Self.swizzle(es[j].code), n2 == name, l2.count == 1, es[j].swizzledSize == es[k].swizzledSize, run.count < 4 {
                run += l2
                reads.formUnion(es[j].reads)
                j += 1
            }
            if run.count == 1 { out.append(es[k]); k += 1; continue }
            let size = es[k].swizzledSize
            let whole = run == String("xyzw".prefix(size))
            let scalar = es[k].type
            let type: SpirvType = .vector(scalar, run.count)
            out.append(Expr(code: whole ? name : "\(name).\(run)", type: type, reads: reads, isTrivial: true))
            k = j
        }
        return out
    }

    /// `name.xyz` as its name and letters, when the code is just that.
    static func swizzle(_ code: String) -> (String, Substring)? {
        guard let dot = code.lastIndex(of: ".") else { return nil }
        let name = code[..<dot], letters = code[code.index(after: dot)...]
        guard !letters.isEmpty, letters.allSatisfy({ "xyzw".contains($0) }),
              !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return (String(name), letters)
    }

    func type(of id: SpirvId) throws -> SpirvType {
        if let c = module.constants[id] { return try module.type(c.type) }
        return try use(peek: id).type
    }

    private func compare(_ symbol: String, _ function: String, _ o: [UInt32], _ t: SpirvType) throws -> Expr {
        let a = try use(o[2]), b = try use(o[3])
        if t.isScalar {
            let prec = symbol == "==" || symbol == "!=" ? 5 : 4
            return binary(symbol, prec, a, b, t)
        }
        return call(function, [a, b], t)
    }

    /// A component, column, element or member of `code`.
    private func member(_ code: String, _ t: SpirvType, _ k: Int) throws -> (String, SpirvType) {
        switch t {
        case .vector(let c, _): return ("\(code).\(Self.component(k))", c)
        case .matrix(let column, _): return ("\(code)[\(k)]", column)
        case .array(let e, _): return ("\(code)[\(k)]", e)
        case .structure(let sid): return ("\(code).\(try stage.memberName(sid, k))", try module.members(of: sid)[k])
        default: throw error("a member of a \(t)")
        }
    }

    private func construct(_ parts: [SpirvId], _ t: SpirvType) throws -> Expr {
        if stage.containsArray(t) {
            // GLSL ES 1.00 has no array constructors: a temporary, filled in.
            let n = try temporary(t)
            let es = try parts.map { try use($0) }
            for (k, e) in es.enumerated() {
                let (target, mt) = try member(n, t, k)
                for s in try stage.assignCopy(from: e.code, to: target, type: mt) { emitLine(s) }
            }
            return Expr(code: n, type: t, isTrivial: true)
        }
        var es = try parts.map { try use($0) }
        let name = try stage.typeName(t)
        if case .vector = t { es = mergeComponents(es) }
        // vec3(x, x, x) as vec3(x).
        if case .vector = t, es.count == t.componentCount, Set(es.map(\.code)).count == 1, es[0].type.isScalar, es[0].isTrivial || Set(parts).count == 1 {
            var e = call(name, [es[0]], t)
            e.splatParts = [es[0]]
            return e
        }
        return call(name, es, t)
    }

    private func shuffle(_ o: [UInt32], _ t: SpirvType) throws -> Expr {
        let v1Type = try type(of: o[2])
        let n1 = v1Type.componentCount
        var picks = o.dropFirst(4).map { $0 == 0xFFFF_FFFF ? 0 : Int($0) }
        if o[2] == o[3] { picks = picks.map { $0 % n1 } }
        let usesFirst = picks.contains { $0 < n1 }
        let usesSecond = picks.contains { $0 >= n1 }
        if o[2] == o[3] {
            let a = try use(o[2])
            if picks == Array(0..<n1) && t.componentCount == n1 { return a }
            return try swizzled(a, picks, t)
        }
        if !usesSecond {
            _ = try? use(o[3])
            let a = try use(o[2])
            if picks == Array(0..<n1) && t.componentCount == n1 { return a }
            return try swizzled(a, picks, t)
        }
        if !usesFirst {
            _ = try? use(o[2])
            let b = try use(o[3])
            return try swizzled(b, picks.map { $0 - n1 }, t)
        }
        let a = try stable(o[2]), b = try stable(o[3])
        // Runs from one source, each one swizzle: vec4(a.xy, b.zw).
        var runs: [(from: Expr, picks: [Int])] = []
        for p in picks {
            let (src, k) = p < n1 ? (a, p) : (b, p - n1)
            if let last = runs.last, last.from.code == src.code {
                runs[runs.count - 1].picks.append(k)
            } else {
                runs.append((src, [k]))
            }
        }
        let parts = runs.map { "\($0.from.at(0)).\($0.picks.map(Self.component).joined())" }
        return Expr(code: "\(try stage.typeName(t))(\(parts.joined(separator: ", ")))", type: t, reads: a.reads.union(b.reads))
    }

    /// `v.xzy`; a swizzle of a swizzle of a name reads the name's own components.
    private func swizzled(_ v: Expr, _ picks: [Int], _ t: SpirvType) throws -> Expr {
        if let (name, letters) = Self.swizzle(v.code), picks.allSatisfy({ $0 < letters.count }) {
            let chars = Array(letters)
            return Expr(code: "\(name).\(String(picks.map { chars[$0] }))", type: t, reads: v.reads, isTrivial: v.isTrivial)
        }
        return Expr(code: "\(v.at(0)).\(picks.map(Self.component).joined())", type: t, reads: v.reads, isTrivial: v.isTrivial)
    }

    private func derivative(_ name: String, _ o: [UInt32]) throws -> Expr {
        guard stage.stage == .fragment else { throw unsupported("a derivative in a vertex stage") }
        stage.requireExtension("GL_OES_standard_derivatives")
        let t = try module.type(o[0])
        return call(name, [try use(o[2])], t)
    }

    private func sample(_ i: Located, _ t: SpirvType) throws -> Expr {
        let o = i.operands
        let op = i.op!
        let sampler = try use(o[2])
        let coordinate = try use(o[3])
        let mask = o.count > 4 ? SpirvImageOperands(rawValue: o[4]) : []
        var extra = Array(o.dropFirst(5))
        let projective = op == .opImageSampleProjImplicitLod || op == .opImageSampleProjExplicitLod
        guard case .sampledImage(let dim) = sampler.type else { throw error("sampling something that is not a sampled image") }
        let cube = SpirvDim(rawValue: dim) == .cube
        let base = cube ? "textureCube" : (projective ? "texture2DProj" : "texture2D")
        if mask.contains(.constOffset) || mask.contains(.offset) || mask.contains(.constOffsets) {
            throw unsupported("sampling at an offset")
        }
        if mask.contains(.grad) { throw unsupported("sampling with explicit gradients") }
        var bias: Expr?
        var lod: Expr?
        if mask.contains(.bias) { bias = try use(extra.removeFirst()) }
        if mask.contains(.lod) { lod = try use(extra.removeFirst()) }
        if let lod {
            switch stage.stage {
            case .vertex:
                return call(base + "Lod", [sampler, coordinate, lod], t)
            case .fragment:
                switch stage.options.fragmentExplicitLod {
                case .implicit:
                    return call(base, [sampler, coordinate], t)
                case .shaderTextureLodExtension:
                    stage.requireExtension("GL_EXT_shader_texture_lod")
                    return call(base + "LodEXT", [sampler, coordinate, lod], t)
                }
            }
        }
        if let bias {
            guard stage.stage == .fragment else { throw unsupported("a sampling bias in a vertex stage") }
            return call(base, [sampler, coordinate, bias], t)
        }
        if stage.stage == .vertex {
            // A vertex stage has no derivatives to pick a level from: the image itself.
            return call(base + "Lod", [sampler, coordinate, Expr(code: "0.0", type: .float(width: 32), isTrivial: true)], t)
        }
        return call(base, [sampler, coordinate], t)
    }

    private func extInst(_ i: Located, _ t: SpirvType) throws -> Expr {
        let o = i.operands
        guard o[2] == module.glslStd450 else {
            throw unsupported("the extended instruction set `\(module.otherImports[o[2]] ?? "%\(o[2])")`")
        }
        guard let inst = GLSLstd450(rawValue: o[3]) else { throw unsupported("GLSL.std.450 instruction \(o[3])") }
        let args = Array(o.dropFirst(4))
        func a(_ k: Int) throws -> Expr { try use(args[k]) }
        func s(_ k: Int) throws -> Expr { try stable(args[k]) }
        func f(_ name: String) throws -> Expr { call(name, try args.indices.map(a), t) }
        switch inst {
        case .fAbs: return try f("abs")
        case .fSign: return try f("sign")
        case .floor: return try f("floor")
        case .ceil: return try f("ceil")
        case .fract: return try f("fract")
        case .radians: return try f("radians")
        case .degrees: return try f("degrees")
        case .sin: return try f("sin")
        case .cos: return try f("cos")
        case .tan: return try f("tan")
        case .asin: return try f("asin")
        case .acos: return try f("acos")
        case .atan: return try f("atan")
        case .atan2: return try f("atan")
        case .pow: return try f("pow")
        case .exp: return try f("exp")
        case .log: return try f("log")
        case .exp2: return try f("exp2")
        case .log2: return try f("log2")
        case .sqrt: return try f("sqrt")
        case .inverseSqrt: return try f("inversesqrt")
        case .fMin, .nMin: return try f("min")
        case .fMax, .nMax: return try f("max")
        case .fClamp, .nClamp: return try f("clamp")
        case .fMix: return try f("mix")
        case .step: return try f("step")
        case .smoothStep: return try f("smoothstep")
        case .length: return try f("length")
        case .distance: return try f("distance")
        case .cross: return try f("cross")
        case .normalize: return try f("normalize")
        case .faceForward: return try f("faceforward")
        case .reflect: return try f("reflect")
        case .refract: return try f("refract")
        case .round:
            // Halves either way, as GLSL.std.450 allows: up.
            let x = try a(0)
            return call("floor", [Expr(code: "\(x.at(3)) + 0.5", type: t, prec: 3, reads: x.reads)], t)
        case .roundEven:
            // Halves to even: floor(x + 0.5), one less on an exact half that lands odd.
            let x = try s(0)
            let f = try temporary(t)
            emitLine("\(f) = floor(\(x.at(3)) + 0.5);")
            return Expr(code: "\(f) - (1.0 - abs(sign(fract(\(x.code)) - 0.5))) * mod(\(f), 2.0)", type: t, prec: 3, reads: x.reads)
        case .trunc:
            let x = try s(0)
            return Expr(code: "sign(\(x.code)) * floor(abs(\(x.code)))", type: t, prec: 2, reads: x.reads)
        case .fma:
            let x = try a(0), y = try a(1), z = try a(2)
            return Expr(code: "\(x.at(2)) * \(y.at(1)) + \(z.at(2))", type: t, prec: 3, reads: x.reads.union(y.reads).union(z.reads))
        case .ldexp:
            let x = try a(0), e = try a(1)
            return binary("*", 2, x, call("exp2", [try convert(e, to: floatShape(of: e.type))], floatShape(of: e.type)), t)
        case .sAbs: return try viaFloat("abs", [try a(0)], t)
        case .sSign: return try viaFloat("sign", [try a(0)], t)
        case .sMin: return try viaFloat("min", [try a(0), try a(1)], t)
        case .sMax: return try viaFloat("max", [try a(0), try a(1)], t)
        case .sClamp: return try viaFloat("clamp", [try a(0), try a(1), try a(2)], t)
        case .sinh, .cosh:
            let x = try s(0)
            let op = inst == .sinh ? "-" : "+"
            return Expr(code: "(exp(\(x.code)) \(op) exp(-\(x.at(0)))) * 0.5", type: t, prec: 2, reads: x.reads)
        case .tanh:
            let x = try s(0)
            let e = "exp(2.0 * \(x.at(1)))"
            return Expr(code: "(\(e) - 1.0) / (\(e) + 1.0)", type: t, prec: 2, reads: x.reads)
        case .asinh:
            let x = try s(0)
            return Expr(code: "log(\(x.code) + sqrt(\(x.at(2)) * \(x.at(1)) + 1.0))", type: t, reads: x.reads)
        case .acosh:
            let x = try s(0)
            return Expr(code: "log(\(x.code) + sqrt(\(x.at(2)) * \(x.at(1)) - 1.0))", type: t, reads: x.reads)
        case .atanh:
            let x = try s(0)
            return Expr(code: "0.5 * log((1.0 + \(x.at(2))) / (1.0 - \(x.at(2))))", type: t, prec: 2, reads: x.reads)
        case .uMin, .uMax, .uClamp: throw unsupported("unsigned min / max / clamp")
        case .iMix: throw unsupported("an integer mix")
        case .determinant: throw unsupported("determinant")
        case .matrixInverse: throw unsupported("a matrix inverse")
        case .modf, .modfStruct: throw unsupported("modf")
        case .frexp, .frexpStruct: throw unsupported("frexp")
        case .findILsb, .findSMsb, .findUMsb: throw unsupported("finding a bit")
        case .interpolateAtCentroid, .interpolateAtSample, .interpolateAtOffset: throw unsupported("interpolating at a point")
        default: throw unsupported("\(inst) (packing and unpacking)")
        }
    }
}
