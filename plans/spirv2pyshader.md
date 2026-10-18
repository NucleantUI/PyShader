
# implement Spirv to PyShader

please pull it off in new files in the PyShader 
but still allows to use the enums etc for op code stuff

or either make spirv opcode part as seperate target so both 
current target and spirv2pyshader can use them.

later we can make 

# make new Package outside PyShader called Glsl2PyShader

i guess using https://github.com/khronosgroup/spirv-cross
to make the glsl example shadertoy into spirv and then PyShader code from spirv.