

# PyShader lang 


parse python AST to generate:
https://github.com/Py-Swift/PySwiftAST


* SPIR-V OpCodes: Translating a Python + operation into OpFAdd (for floats) or OpIAdd (for integers).
* ID Mapping: Tracking every single variable, constant, and function as a unique SPIR-V Result ID (%1, %2, etc.).
* Control Flow Graph (CFG): Explicitly defining basic blocks (OpLabel), branches (OpBranch), and loops with structured control flow markers (OpLoopMerge, OpSelectionMerge).
and so on.

https://github.com/NucleantUI/NucleantVulkan

contains SpirV / ShaderC for the SpirV Bytecode part, i assume we just going to write directly to Spirv related code, but ShaderC is there is ever needed also...
but PyShader is going to work with the Nucleant eco system for now, so no need for own dep handling of vulkan stuff...


vector types examples

float:
* float2
* float3
* float4

float16:
* half2
* half3
* half4


int32:
* int2
* int3
* int4

int16:
* short2
* short3
* short4


defined vars must be type annotated if not assigned by type right away

a: float3
b: int4
c: float = 2

d = float4(a, c)

floats/ints properties

* .r .g .b .a .rg .rgb 
* .x .y .z .w .xy .xyz

mostly like metal does it with float2-4 int2-4 etc.. 

use OpenGL 450 function api like smoothstep

code is limited to normal shader rules

like 

```py

# we cant import other normal python libs, only maybe own internal lib for all shader api
# for now classes is not allowed, until right solution is found in terms of pyclass -> struct
# but we can make as many functions we want in global space
# kwargs is not allowed either..

# lambdas should just be converted to a global function which is called instead..

def main(...) -> float4:
    # this is per pixel call
    
    color = float4(1, 0, 0, 1)
    color.rgb *= 0.5

    color.rgb = color.rgb + 0.5

    color.r = color.r / 2
    # we just return the final pixel color
    # not returning anything which is considered None, should just result in same pixel color input is just forwarded
    return color
    
```



research:

libs that uses PySwiftAst
* https://github.com/Py-Swift/PySwiftKitDemoPlugin





* write files for future reading

* vector-types.md
* shader-api-status.md (overview of what shader api functions implemented vs todos)