# compile / precompile pyshader file/modules into spirv

both command and buildtool plugins should look in the root of package
and locate pyshader.toml

the toml will tell what pyshader files to process, and ofc each section defines final
spirv file to generate output 2..
and if any site-packages path is specified (general for all sections)
