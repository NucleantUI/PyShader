//
//  SpirvOpcodes.swift
//  SpirvCore
//
//  The subset of the SPIR-V 1.0 instruction set and enums PyShader emits and
//  Spirv2PyShader reads. Values are taken straight from the Khronos
//  spirv.core.grammar.
//

public typealias SpirvId = UInt32

public enum SpirvOp: UInt16, Sendable {
    case opNop = 0
    case opUndef = 1
    case opSourceContinued = 2
    case opSource = 3
    case opSourceExtension = 4
    case opName = 5
    case opMemberName = 6
    case opString = 7
    case opLine = 8
    case opExtension = 10
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
    case opTypeSampler = 26
    case opTypeSampledImage = 27
    case opTypeArray = 28
    case opTypeRuntimeArray = 29
    case opTypeStruct = 30
    case opTypeOpaque = 31
    case opTypePointer = 32
    case opTypeFunction = 33
    case opTypeForwardPointer = 39

    case opConstantTrue = 41
    case opConstantFalse = 42
    case opConstant = 43
    case opConstantComposite = 44
    case opConstantNull = 46
    case opSpecConstantTrue = 48
    case opSpecConstantFalse = 49
    case opSpecConstant = 50
    case opSpecConstantComposite = 51
    case opSpecConstantOp = 52

    case opFunction = 54
    case opFunctionParameter = 55
    case opFunctionEnd = 56
    case opFunctionCall = 57

    case opVariable = 59
    case opImageTexelPointer = 60
    case opLoad = 61
    case opStore = 62
    case opCopyMemory = 63
    case opAccessChain = 65
    case opInBoundsAccessChain = 66
    case opArrayLength = 68

    case opDecorate = 71
    case opMemberDecorate = 72
    case opDecorationGroup = 73
    case opGroupDecorate = 74
    case opGroupMemberDecorate = 75

    case opVectorExtractDynamic = 77
    case opVectorInsertDynamic = 78
    case opVectorShuffle = 79
    case opCompositeConstruct = 80
    case opCompositeExtract = 81
    case opCompositeInsert = 82
    case opCopyObject = 83
    case opTranspose = 84

    case opSampledImage = 86
    case opImageSampleImplicitLod = 87
    case opImageSampleExplicitLod = 88
    case opImageSampleDrefImplicitLod = 89
    case opImageSampleDrefExplicitLod = 90
    case opImageFetch = 95
    case opImageGather = 96
    case opImageRead = 98
    case opImageWrite = 99
    case opImage = 100
    case opImageQuerySizeLod = 103
    case opImageQuerySize = 104
    case opImageQueryLod = 105
    case opImageQueryLevels = 106

    case opConvertFToU = 109
    case opConvertFToS = 110
    case opConvertSToF = 111
    case opConvertUToF = 112
    case opUConvert = 113
    case opSConvert = 114
    case opFConvert = 115
    case opQuantizeToF16 = 116
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
    case opIsFinite = 158
    case opIsNormal = 159

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
    case opFUnordEqual = 181
    case opFOrdNotEqual = 182
    case opFUnordNotEqual = 183
    case opFOrdLessThan = 184
    case opFUnordLessThan = 185
    case opFOrdGreaterThan = 186
    case opFUnordGreaterThan = 187
    case opFOrdLessThanEqual = 188
    case opFUnordLessThanEqual = 189
    case opFOrdGreaterThanEqual = 190
    case opFUnordGreaterThanEqual = 191

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
    case opDPdxFine = 210
    case opDPdyFine = 211
    case opFwidthFine = 212
    case opDPdxCoarse = 213
    case opDPdyCoarse = 214
    case opFwidthCoarse = 215

    case opPhi = 245
    case opLoopMerge = 246
    case opSelectionMerge = 247
    case opLabel = 248
    case opBranch = 249
    case opBranchConditional = 250
    case opSwitch = 251
    case opKill = 252
    case opReturn = 253
    case opReturnValue = 254
    case opUnreachable = 255

    case opNoLine = 317
    case opModuleProcessed = 330
    case opExecutionModeId = 331
    case opDecorateId = 332
}

/// GLSL.std.450 extended instruction numbers.
public enum GLSLstd450: UInt32, Sendable {
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
    case modf = 35
    case modfStruct = 36
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
    case iMix = 47
    case step = 48
    case smoothStep = 49
    case fma = 50
    case frexp = 51
    case frexpStruct = 52
    case ldexp = 53
    case packSnorm4x8 = 54
    case packUnorm4x8 = 55
    case packSnorm2x16 = 56
    case packUnorm2x16 = 57
    case packHalf2x16 = 58
    case packDouble2x32 = 59
    case unpackSnorm2x16 = 60
    case unpackUnorm2x16 = 61
    case unpackHalf2x16 = 62
    case unpackSnorm4x8 = 63
    case unpackUnorm4x8 = 64
    case unpackDouble2x32 = 65
    case length = 66
    case distance = 67
    case cross = 68
    case normalize = 69
    case faceForward = 70
    case reflect = 71
    case refract = 72
    case findILsb = 73
    case findSMsb = 74
    case findUMsb = 75
    case interpolateAtCentroid = 76
    case interpolateAtSample = 77
    case interpolateAtOffset = 78
    case nMin = 79
    case nMax = 80
    case nClamp = 81
}

public enum SpirvCapability: UInt32, Sendable {
    case shader = 1
    case float16 = 9
    case int16 = 22
    case imageQuery = 50
    case derivativeControl = 51
}

public enum SpirvAddressingModel: UInt32, Sendable {
    case logical = 0
}

public enum SpirvMemoryModel: UInt32, Sendable {
    case glsl450 = 1
}

public enum SpirvExecutionModel: UInt32, Sendable {
    case vertex = 0
    case fragment = 4
    case glCompute = 5
}

public enum SpirvExecutionMode: UInt32, Sendable {
    case originUpperLeft = 7
    case localSize = 17
}

public enum SpirvStorageClass: UInt32, Sendable {
    case uniformConstant = 0
    case input = 1
    case uniform = 2
    case output = 3
    case workgroup = 4
    case crossWorkgroup = 5
    case `private` = 6
    case function = 7
    case generic = 8
    case pushConstant = 9
    case atomicCounter = 10
    case image = 11
    case storageBuffer = 12
}

public enum SpirvDecoration: UInt32, Sendable {
    case relaxedPrecision = 0
    case block = 2
    case bufferBlock = 3
    case rowMajor = 4
    case colMajor = 5
    case arrayStride = 6
    case matrixStride = 7
    case builtIn = 11
    case noPerspective = 13
    case flat = 14
    case centroid = 16
    case nonWritable = 24
    case nonReadable = 25
    case location = 30
    case component = 31
    case index = 32
    case binding = 33
    case descriptorSet = 34
    case offset = 35
}

public enum SpirvBuiltIn: UInt32, Sendable {
    case position = 0
    case pointSize = 1
    case fragCoord = 15
    case pointCoord = 16
    case frontFacing = 17
    case sampleId = 18
    case sampleMask = 20
    case fragDepth = 22
    case globalInvocationId = 28
    case vertexIndex = 42
    case instanceIndex = 43
}

public enum SpirvDim: UInt32, Sendable {
    case dim1D = 0
    case dim2D = 1
    case dim3D = 2
    case cube = 3
}

public enum SpirvImageFormat: UInt32, Sendable {
    case unknown = 0
    case rgba8 = 4
}

public enum SpirvImageOperands: UInt32, Sendable {
    case lod = 0x2
}

public enum SpirvFunctionControl: UInt32, Sendable {
    case none = 0
    case inline = 1
}

public enum SpirvSelectionControl: UInt32, Sendable {
    case none = 0
}

public enum SpirvLoopControl: UInt32, Sendable {
    case none = 0
}

public enum SpirvSourceLanguage: UInt32, Sendable {
    case unknown = 0
    case essl = 1
    case glsl = 2
}
