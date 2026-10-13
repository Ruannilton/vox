
slangc ./assets/shaders/triangle.slang -target spirv -o ./bin/triangle.spv
odin build .\src\  -out:./bin/vox.exe
chdir ./bin
start vox.exe