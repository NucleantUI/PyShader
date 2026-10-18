# allow importing modules

we should now support the ability to write pyshader modules which a pyshader script can import
ofcourse same rules applies as before only works with things from pyshader module
we cant use builtin libs or any other python libs as before..

and ofc all modules need to be in some agreeded area
like a unique site-packages just for this
where we can also define deps to other modules by the pyproject.toml way
and uv supported..

how should it work..

* when imports besides pyshader is detected
locate the file that matches the module import
then by PySwiftAst find and extract the imports (should only fetch of what is used, soo wildcard * doesnt mean include all, only what is used in the code or module)
then just include it in the final spirv code as if it was written in the main pyshader itself.

