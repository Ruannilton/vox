@echo off
setlocal

:: VS-15 (REQ-TRC-01): build com Tracy ligado (-define:TRACY_ENABLE=true).
:: Exige vendor\tracy\tracy.lib; se ausente, gere com tools\build_tracy_client.bat.
:: A UI Tracy (tools\tracy\tracy-profiler.exe, release oficial v0.14.1) eh
:: opcional: encontrada, este script a abre automaticamente antes do app.

if not exist ".\vendor\tracy\tracy.lib" (
    echo ERRO: vendor\tracy\tracy.lib ausente.
    echo Gere a biblioteca com: tools\build_tracy_client.bat
    exit /b 1
)

if exist ".\tools\tracy\tracy-profiler.exe" (
    echo Abrindo Tracy Profiler (tools\tracy\tracy-profiler.exe)...
    start "" ".\tools\tracy\tracy-profiler.exe"
) else (
    echo UI Tracy nao encontrada em tools\tracy\tracy-profiler.exe.
    echo Baixe o pacote Windows de https://github.com/wolfpld/tracy/releases/tag/v0.14.1
    echo e extraia para tools\tracy\ — ou abra a UI manualmente e de Connect.
    echo.
)

echo Compilando shaders...
set "IN_DIR=.\src\assets\shaders"
set "OUT_DIR=.\bin"

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

for %%I in ("%IN_DIR%\*.slang") do (
    if /I not "%%~nxI"=="common.slang" (
        echo [BUILD] %%~nxI
        slangc "%%I" -target spirv -o "%OUT_DIR%\%%~nI.spv"
    )
)

echo.
echo Copiando assets (VS-12)...
if not exist ".\assets" mkdir ".\assets"
xcopy /E /I /Y ".\assets" ".\bin\assets" >nul

echo.
echo Finalizado!

odin build .\src\ -out:./bin/vox.exe -define:TRACY_ENABLE=true || exit /b 1
chdir ./bin
vox.exe %*
