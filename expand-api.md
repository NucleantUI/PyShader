# What PyShader can add

Working notes. Not a plan of record — a list to pick from.

SpirvCore now generates its tables from the Khronos grammar (SpirvCore
`81afbf9`). Every opcode, capability, builtin, decoration, execution mode,
scope and mask PyShader could want has a Swift name there, so nothing below
waits on SpirvCore. What each item still needs is Python surface in PyShader,
sometimes a target or interface change, and sometimes something from the host
(NucleantVulkan, or Naga on the web).

## Where PyShader is today

- **Targets:** `.fragment`, `.computeImage` (one invocation per pixel, writing
  an `rgba8` storage image) and `.graphics` (vertex + fragment in one module,
  no vertex buffers).
- **Module:** a SPIR-V 1.0 header and the `Logical` / `GLSL450` memory model.
  Capabilities are `Shader`, plus `Float16`, `Int16` and `ImageQuery` when used.
  GLSL.std.450 is the only extended set.
- **What gets emitted:**
  - Execution modes: `OriginUpperLeft`, `LocalSize`.
  - Decorations: `Location`, `BuiltIn`, `Binding`, `DescriptorSet`, `Block`,
    `BufferBlock`, `ArrayStride`, `Flat`, `NonReadable`, plus `Offset` and
    `NonWritable` on block members.
  - Built-ins: `FragCoord`, `FrontFacing`, `PointCoord`, `Position`,
    `VertexIndex`, `InstanceIndex`, `GlobalInvocationId`.
- **Images:** 2D sampled images read at explicit LOD 0 (`layer(p)`, `a(uv)`,
  `a_size`), and the `rgba8` output.
- **Library:** 53 of GLSL.std.450's 81 instructions are reachable from Python.

## Constraints on everything below

- macOS runs Vulkan through MoltenVK. NucleantVulkan asks for Vulkan 1.2, so
  modules up to SPIR-V 1.5 are accepted.
- The web build turns SPIR-V into WGSL with Naga 30 (`NagaWasm`,
  `NucleantVulkan/NagaWebGPU`).
- A feature lands only if it works on both. Otherwise, the target that can't
  run it refuses it with a clear error. Run each new feature's example through
  NagaWasm as well as `spirv-val`.

## Small: library functions

No new types, no host change and no version bump. The names follow PyShader's
rule: GLSL 450 spelling, with the Metal one as an alias where the semantics
match.

| Python (suggested) | SPIR-V | Notes |
|---|---|---|
| `modf(x) -> tuple[float, float]` | `GLSLstd450.modfStruct` | The struct result maps onto PyShader's existing tuple returns. |
| `frexp(x) -> tuple[float, int]`, `ldexp(x, e)` | `.frexpStruct`, `.ldexp` | |
| `packHalf2x16` / `unpackHalf2x16`, plus the `Unorm4x8`, `Snorm4x8`, `Unorm2x16`, `Snorm2x16` pairs | `.packHalf2x16` … `.unpackUnorm4x8` | Packs colours or normals into `uint`s, e.g. for argument buffers and hashes. |
| `findLSB(x)`, `findMSB(x)` | `.findILsb`, `.findSMsb` / `.findUMsb` | Signed and unsigned are split the way `abs` is. |
| `bitCount` / `popcount`, `bitfieldReverse` / `reverse_bits` | `SpirvOp.opBitCount`, `.opBitReverse` | Core ops, on int and uint scalars and vectors. |
| `bitfieldExtract` / `extract_bits`, `bitfieldInsert` / `insert_bits` | `.opBitFieldSExtract` / `.opBitFieldUExtract`, `.opBitFieldInsert` | |
| `outerProduct(a, b)` | `.opOuterProduct` | Spirv2PyShader already reads it. |
| `dFdxFine` / `dfdx_fine`, `…Coarse`, and the same for `dfdy` and `fwidth` | `.opDPdxFine` … `.opFwidthCoarse` | Needs `SpirvCapability.derivativeControl`. Spirv2PyShader already reads these, but folds them into plain `dfdx`. |

## Fragment stage

- **`demote()`** → `OpDemoteToHelperInvocation`.
  - Why: unlike `discard()` (`OpKill`), the invocation stays on as a helper.
    So `dfdx`/`fwidth` and implicit-LOD sampling in the neighbouring pixels
    stay defined.
  - Below SPIR-V 1.6 it needs `SpirvCapability.demoteToHelperInvocation` and
    `OpExtension "SPV_EXT_demote_to_helper_invocation"`.
  - Host: `VK_EXT_shader_demote_to_helper_invocation` (core in Vulkan 1.3).
    NucleantVulkan doesn't enable it yet.
  - Spirv2PyShader refuses it today ("opDemoteToHelperInvocation is not
    supported"). Add the reverse mapping in the same change.
- **Depth output** → built-in `FragDepth` plus execution mode
  `DepthReplacing`, with `DepthGreater` / `DepthLess` as hints.
  - `main` would return a class (colour, depth), the way the vertex stage
    returns its varyings.
  - Host: a depth attachment.
- **More inputs:**
  - `sample_id` and `sample_position` (`SampleId`, `SamplePosition`; capability
    `SampleRateShading`).
  - `helper_invocation` (`HelperInvocation`).
- **Varying qualifiers.** Only `Flat` is emitted today, automatically for ints.
  - `NoPerspective`, `Centroid` and `Sample` decorations would go on class
    fields, e.g. `local: NoPerspective[float2]`.
  - `interpolateAtCentroid`, `interpolateAtSample` and `interpolateAtOffset`
    (GLSL.std.450, capability `InterpolationFunction`) belong with them.

## Compute beyond one pixel per invocation

`.computeImage` gives each invocation one pixel and nothing else. A general
compute target is the largest single addition. The host already has the parts:
storage-buffer descriptors and `vkCmdDispatch` are in NucleantVulkan's
`ComputePipeline` and `PixelBufferShaderNode`. It would cover:

- **Writable buffers** (`buf[i] = v`). The argument buffer today is a
  `BufferBlock` whose member is decorated `NonWritable`. A writable buffer is
  the same declaration without that decoration at SPIR-V 1.0, or
  `SpirvStorageClass.storageBuffer` with `Block` from 1.3.
- **Invocation ids:** `local_id`, `group_id`, `group_count`, `local_index` →
  `LocalInvocationId`, `WorkgroupId`, `NumWorkgroups`, `LocalInvocationIndex`.
- **Shared memory:** a module-level list declared shared becomes a
  `SpirvStorageClass.workgroup` variable.
- **`barrier()`** → `OpControlBarrier(Workgroup, Workgroup, AcquireRelease |
  WorkgroupMemory)`. `SpirvScope` and `SpirvMemorySemantics` are typed now,
  so these operands are named rather than magic numbers.
- **Atomics on buffer elements:** `atomic_add(buf, i, v)`, `atomic_max`,
  `atomic_exchange`, `atomic_compare_exchange` → `OpAtomicIAdd`,
  `OpAtomicSMax` / `OpAtomicUMax`, `OpAtomicExchange`,
  `OpAtomicCompareExchange`. They need a pointer to the element, which
  PyShader's access chains already produce.
- **What it unlocks:** particles, histograms (an image editor's levels),
  prefix sums, separable blurs.

Inside `.computeImage` itself:

- **Output formats besides `rgba8`:** `rgba16f`, `rgba32f` or `r32f`
  (`SpirvImageFormat`), for HDR or data images. The host picks the storage
  image's format.
- **`dfdx` / `fwidth` in compute.** They are an error in this target today.
  - Execution mode `DerivativeGroupQuadsKHR` plus capability
    `ComputeDerivativeGroupQuadsKHR` (`SPV_KHR_compute_shader_derivatives`)
    would allow them.
  - Needs the device feature. Check MoltenVK before relying on it.

## Subgroup operations

- **Python:** `subgroup_add(x)`, `subgroup_min` / `subgroup_max`,
  `subgroup_broadcast(x, lane)`, `subgroup_ballot(c)`, `subgroup_any` /
  `subgroup_all`, and the inputs `subgroup_size` and `subgroup_lane`.
- **SPIR-V:**
  - Arithmetic: `OpGroupNonUniformFAdd` / `OpGroupNonUniformIAdd` (and the rest)
    with `SpirvGroupOperation.reduce` / `.inclusiveScan` / `.exclusiveScan`.
  - Others: `OpGroupNonUniformBroadcast`, `OpGroupNonUniformBallot`.
  - Capabilities: `GroupNonUniform`, `GroupNonUniformArithmetic`,
    `GroupNonUniformBallot`, and so on.
- **Needs:** a SPIR-V 1.3 header (see Module below). That is inside what
  Vulkan 1.2 accepts.
- **Use:** mostly with the general compute target, for reductions. Check
  NagaWasm before relying on them on the web.

## Textures

Today: `a(uv)` reads a 2D sampled image at explicit LOD 0, and `a_size` gives
its size.

- **Implicit-LOD sampling in the fragment stage** → `OpImageSampleImplicitLod`,
  so mipmaps work. Compute has no implicit LOD, so this stays fragment-only.
- **`sample_lod(a, uv, lod)`, `sample_grad(a, uv, dx, dy)`** →
  `SpirvImageOperands` `.lod` / `.grad`.
  - The extra operands after the mask word come in increasing bit order.
  - SpirvCore's `OptionSet`s don't encode that rule yet (its `expand-api.md`,
    API shape 1), so the builder has to order them.
- **`fetch(a, pixel)`** → `OpImageFetch`: exact texels with no filtering,
  for data textures.
- **`gather(a, uv, component)`** → `OpImageGather`.
- **`a_levels`** → `OpImageQueryLevels`. Its capability, `ImageQuery`, is
  already requested for `a_size`.
- **Other image shapes:** cube maps (`SpirvDim.cube`) for environments and
  reflections, 3D (`.dim3D`) for colour LUTs, and 2D arrays. `ShaderTexture`
  would carry a kind, and the host would bind that view type.
- **Depth comparison**, `sample_compare(a, uv, ref)` → a depth image plus
  `OpImageSampleDrefExplicitLod`. For shadow maps, once the host has a depth
  pass.

## Language features over existing SPIR-V

- **`match` on ints → `OpSwitch`.** `case 1 | 2:` becomes two literals and
  `case _:` the default. PySwiftAST already parses `match`; `FunctionEmitter`
  currently rejects it with "match is not supported yet; use if/elif".
- **Control hints.** `SpirvLoopControl` (`.unroll`, `.dontUnroll`),
  `SpirvSelectionControl` (`.flatten`, `.dontFlatten`) and
  `SpirvFunctionControl` (`.inline`, `.dontInline`) are `OptionSet`s now.
  PyShader emits `.none` everywhere. A decorator on `def` (`@inline`,
  `@noinline`) and a wrapper on `range` (`for i in unroll(range(4))`) would
  expose them.
- **Specialization constants.** A module constant the host may override when
  it creates the pipeline, e.g. `STEPS: Spec[int] = 64`.
  - SPIR-V: `OpSpecConstant` / `OpSpecConstantTrue` / `OpSpecConstantFalse` /
    `OpSpecConstantComposite`, plus `SpirvDecoration.specId`.
  - Why: quality settings change without recompiling.
  - Host: NucleantVulkan's Swift pipelines don't pass a
    `VkSpecializationInfo` yet. WGSL's equivalent is `override`.
  - Spirv2PyShader already reads spec constants, as plain constants.
- **Precision decorations.** `RelaxedPrecision` lets mobile GPUs run
  `half`-tolerant math faster. `NoContraction` marks a `precise` result. Low
  priority.

## Module, debugging, tooling

- **SPIR-V version option.** The header is fixed at 1.0 in
  `SpirvModuleBuilder.build()`.
  - Subgroups and the `StorageBuffer` class need 1.3; demote is core in 1.6.
  - From 1.4, `OpEntryPoint`'s interface must list every global variable the
    entry point uses, not only `Input` / `Output`. The builder's interface list
    changes with the version.
  - Make the version a target option, raised only when a feature needs it, so
    today's output stays byte-identical. SpirvCore's planned `SpirvVersion`
    (its API shape 5) would replace the magic words.
- **Source lines.**
  - `OpString` with the `.py` file name, then `OpLine` before instructions.
    `spirv-val`, RenderDoc and Naga then point at Python lines.
  - PyShader already tracks `line:` for its own errors, and Spirv2PyShader
    already skips `OpLine`. Small.
- **`print()` via `NonSemantic.DebugPrintf`.**
  - SPIR-V: `OpExtInstImport "NonSemantic.DebugPrintf"`, instruction 1, and
    `OpExtension "SPV_KHR_non_semantic_info"`.
  - Python: `print("x = %f", x)`, since f-strings aren't supported. The output
    shows up through the validation layer's debug printf.
  - SpirvCore has no enum for that set yet (its API shape 7), but it is one
    instruction.

## Spirv2PyShader

- Each item above wants its reverse. When PyShader gains `demote()`,
  `bitCount` or `match`, the decompiler should map glslang's output back to
  them. Today those instructions are refused with an error that names the
  opcode.
- `valueOperands` in `FunctionScan.swift` is a hand-written table of which
  operands are ids. The grammar records that for every opcode, so SpirvCore
  could generate it (its API shape 3). The scan would then be right for every
  instruction, not only the listed ones.

## Bigger stages: host-driven, probably not now

- **Mesh / task** (`MeshEXT`, `TaskEXT`, `VK_EXT_mesh_shader`): not enabled in
  NucleantVulkan, and WebGPU has no equivalent.
- **Ray tracing** (`RayGenerationKHR` and the rest): needs acceleration
  structures on the host.
- **Geometry / tessellation:** Metal and MoltenVK have no geometry shaders, and
  WebGPU has neither stage.

## Leave out

- **`nMin`, `nMax`, `nClamp`:** NaN-propagation variants of `min`, `max` and
  `clamp`.
- **`packDouble2x32` and 64-bit types** (`double`, `long`):
  - SPIR-V: capabilities `Float64` / `Int64` and two-word `OpConstant`s.
  - Apple GPUs have no f64, WGSL has no f64, and NucleantVulkan enables
    neither `shaderFloat64` nor `shaderInt64`.
- **8-bit ints:** storage needs `SPV_KHR_8bit_storage`, for little gain.
- **Kernel / OpenCL instructions:** Vulkan takes `Shader` modules only.

## Gaps found while checking the docs

These are not SPIR-V additions, just things the docs now record as missing:

- **A `list[...]` parameter crashes the compiler** ("Range requires lowerBound
  <= upperBound") instead of reporting an error. List parameters aren't
  supported, so the frontend should refuse them by name.
- **No derivatives or `discard()` in the graphics target's fragment stage.**
  `requireFragment` only accepts `.fragment`, so `fwidth` there gets the
  compute target's "a compute shader has no derivatives" message. The stage
  is a real fragment stage, so these could simply be allowed there.
- **The editor stub has no `Texture`.** `scripts/generate_stub.py` doesn't
  know the type, so an editor flags `a: Texture`.

## Suggested order

1. The library functions and source lines. Small, with no host change and no
   version bump.
2. Texture variants: `fetch`, `sample_lod`, `a_levels`, and implicit LOD in
   the fragment stage.
3. `match` → `OpSwitch`, and the control hints.
4. The general compute target: buffers, shared memory, barriers, atomics. The
   biggest item, but the host parts exist.
5. The version option, then subgroups and `demote()`.
6. Specialization constants, which wait on the host.
