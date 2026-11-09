# pep 517 build backend

make PyShader/src/pyshader_builder into a build backend
to compile the shader into example
direct spirv as we do with the buildtool
but also example OpenGL ES2 which is what kivy uses..
but should still just look for the pyshader.toml or what it was buildtool was looking for
but also inside pyproject.toml


# OpenGL ES2 export 
allow to export to es2..

if we are using feature in pyshader that opengl es2 dont support 
then backend should throw error and show what unsupported code is used... 