//
//  SpirvOpcodes.swift
//  PyShader
//
//  The subset of the SPIR-V 1.0 instruction set and enums PyShader emits.
//  Values are taken straight from the Khronos spirv.core.grammar.
//

typealias SpirvId = UInt32

enum SpirvOp: UInt16 {
    case opNop = 0
    case opUndef = 1
    case opSource = 3
    case opName = 5
    case opMemberName = 6
    case opExtInstImport = 11
    case opExtInst = 12
    case opMemoryModel = 14
    case opEntryPoint = 15
    case opExecutionMode = 16
    case opCapability = 17

    case opTypeVoid = 19
    case opTypeBool = 20
    case opTypeInt = 21
    case opTypeFloat = 22
    case opTypeVector = 23
    case opTypeMatrix = 24
    case opTypeImage = 25
    case opTypeArray = 28
    case opTypeSampledImage = 27
    case opTypeRuntimeArray = 29
    case opTypeStruct = 30
    case opTypePointer = 32
    case opTypeFunction = 33

    case opConstantTrue = 41
    case opConstantFalse = 42
    case opConstant = 43
    case opConstantComposite = 44

    case opFunction = 54
    case opFunctionParameter = 55
    case opFunctionEnd = 56
    case opFunctionCall = 57

    case opVariable = 59
    case opLoad = 61
    case opStore = 62
    case opAccessChain = 65

    case opDecorate = 71
    case opMemberDecorate = 72

    case opVectorExtractDynamic = 77
    case opVectorInsertDynamic = 78
    case opVectorShuffle = 79
    case opCompositeConstruct = 80
    case opCompositeExtract = 81
    case opCompositeInsert = 82
    case opTranspose = 84

    case opImageSampleExplicitLod = 88
    case opImageWrite = 99
    case opImageQuerySize = 104

    case opConvertFToU = 109
    case opConvertFToS = 110
    case opConvertSToF = 111
    case opConvertUToF = 112
    case opUConvert = 113
    case opSConvert = 114
    case opFConvert = 115
    case opBitcast = 124

    case opSNegate = 126
    case opFNegate = 127
    case opIAdd = 128
    case opFAdd = 129
    case opISub = 130
    case opFSub = 131
    case opIMul = 132
    case opFMul = 133
    case opUDiv = 134
    case opSDiv = 135
    case opFDiv = 136
    case opUMod = 137
    case opSRem = 138
    case opSMod = 139
    case opFRem = 140
    case opFMod = 141
    case opVectorTimesScalar = 142
    case opMatrixTimesScalar = 143
    case opVectorTimesMatrix = 144
    case opMatrixTimesVector = 145
    case opMatrixTimesMatrix = 146
    case opOuterProduct = 147
    case opDot = 148

    case opAny = 154
    case opAll = 155
    case opIsNan = 156
    case opIsInf = 157

    case opLogicalEqual = 164
    case opLogicalNotEqual = 165
    case opLogicalOr = 166
    case opLogicalAnd = 167
    case opLogicalNot = 168
    case opSelect = 169
    case opIEqual = 170
    case opINotEqual = 171
    case opUGreaterThan = 172
    case opSGreaterThan = 173
    case opUGreaterThanEqual = 174
    case opSGreaterThanEqual = 175
    case opULessThan = 176
    case opSLessThan = 177
    case opULessThanEqual = 178
    case opSLessThanEqual = 179
    case opFOrdEqual = 180
    case opFUnordNotEqual = 183
    case opFOrdLessThan = 184
    case opFOrdGreaterThan = 186
    case opFOrdLessThanEqual = 188
    case opFOrdGreaterThanEqual = 190

    case opShiftRightLogical = 194
    case opShiftRightArithmetic = 195
    case opShiftLeftLogical = 196
    case opBitwiseOr = 197
    case opBitwiseXor = 198
    case opBitwiseAnd = 199
    case opNot = 200

    case opDPdx = 207
    case opDPdy = 208
    case opFwidth = 209

    case opLoopMerge = 246
    case opSelectionMerge = 247
    case opLabel = 248
    case opBranch = 249
    case opBranchConditional = 250
    case opKill = 252
    case opReturn = 253
    case opReturnValue = 254
    case opUnreachable = 255
}

/// GLSL.std.450 extended instruction numbers.
enum GLSLstd450: UInt32 {
    case round = 1
    case roundEven = 2
    case trunc = 3
    case fAbs = 4
    case sAbs = 5
    case fSign = 6
    case sSign = 7
    case floor = 8
    case ceil = 9
    case fract = 10
    case radians = 11
    case degrees = 12
    case sin = 13
    case cos = 14
    case tan = 15
    case asin = 16
    case acos = 17
    case atan = 18
    case sinh = 19
    case cosh = 20
    case tanh = 21
    case asinh = 22
    case acosh = 23
    case atanh = 24
    case atan2 = 25
    case pow = 26
    case exp = 27
    case log = 28
    case exp2 = 29
    case log2 = 30
    case sqrt = 31
    case inverseSqrt = 32
    case determinant = 33
    case matrixInverse = 34
    case fMin = 37
    case uMin = 38
    case sMin = 39
    case fMax = 40
    case uMax = 41
    case sMax = 42
    case fClamp = 43
    case uClamp = 44
    case sClamp = 45
    case fMix = 46
    case step = 48
    case smoothStep = 49
    case fma = 50
    case length = 66
    case distance = 67
    case cross = 68
    case normalize = 69
    case faceForward = 70
    case reflect = 71
    case refract = 72
    case nMin = 79
    case nMax = 80
    case nClamp = 81
}

enum SpirvCapability: UInt32 {
    case shader = 1
    case float16 = 9
    case int16 = 22
    case imageQuery = 50
    case derivativeControl = 51
}

enum SpirvAddressingModel: UInt32 {
    case logical = 0
}

enum SpirvMemoryModel: UInt32 {
    case glsl450 = 1
}

enum SpirvExecutionModel: UInt32 {
    case vertex = 0
    case fragment = 4
    case glCompute = 5
}

enum SpirvExecutionMode: UInt32 {
    case originUpperLeft = 7
    case localSize = 17
}

public enum SpirvStorageClass: UInt32, Sendable {
    case uniformConstant = 0
    case input = 1
    case uniform = 2
    case output = 3
    case function = 7
    case pushConstant = 9
}

enum SpirvDecoration: UInt32 {
    case block = 2
    case bufferBlock = 3
    case arrayStride = 6
    case builtIn = 11
    case flat = 14
    case nonWritable = 24
    case nonReadable = 25
    case location = 30
    case binding = 33
    case descriptorSet = 34
    case offset = 35
}

enum SpirvBuiltIn: UInt32 {
    case position = 0
    case fragCoord = 15
    case pointCoord = 16
    case frontFacing = 17
    case sampleId = 18
    case sampleMask = 20
    case globalInvocationId = 28
    case vertexIndex = 42
    case instanceIndex = 43
}

enum SpirvDim: UInt32 {
    case dim2D = 1
}

enum SpirvImageFormat: UInt32 {
    case unknown = 0
    case rgba8 = 4
}

enum SpirvImageOperands: UInt32 {
    case lod = 0x2
}

enum SpirvFunctionControl: UInt32 {
    case none = 0
    case inline = 1
}

enum SpirvSelectionControl: UInt32 {
    case none = 0
}

enum SpirvLoopControl: UInt32 {
    case none = 0
}

enum SpirvSourceLanguage: UInt32 {
    case unknown = 0
}
