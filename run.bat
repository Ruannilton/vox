
@echo off
setlocal

echo Compilando shaders...
set "IN_DIR=.\src\assets\shaders"
set "OUT_DIR=.\bin"

:: Cria o diretório de saída caso não exista
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

echo Compilando shaders...

:: Percorre todos os arquivos .slang do diretório de entrada
:: (common.slang é biblioteca compartilhada — importada, não compilada sozinha)
for %%I in ("%IN_DIR%\*.slang") do (
    if /I not "%%~nxI"=="common.slang" (
        echo [BUILD] %%~nxI
        slangc "%%I" -target spirv -o "%OUT_DIR%\%%~nI.spv"
    )
)

echo.
echo Copiando assets (VS-12)...
:: assets/ versionado na raiz; o app roda com cwd em bin/ e le assets/blocks.json
if not exist ".\assets" mkdir ".\assets"
xcopy /E /I /Y ".\assets" ".\bin\assets" >nul

echo.
echo Finalizado!

odin build .\src\  -out:./bin/vox.exe
chdir ./bin
start vox.exe