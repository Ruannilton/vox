
@echo off
setlocal

echo Compilando shaders...
set "IN_DIR=.src\assets\shaders"
set "OUT_DIR=.\bin"

:: Cria o diretório de saída caso não exista
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo Compilando shaders...

:: Percorre todos os arquivos .slang no diretório de entrada
for %%I in ("%IN_DIR%\*.slang") do (
    echo [BUILD] %%~nxI
    slangc "%%I" -target spirv -o "%OUT_DIR%\%%~nI.spv"
)

echo.
echo Finalizado!

odin build .\src\  -out:./bin/vox.exe
chdir ./bin
start vox.exe