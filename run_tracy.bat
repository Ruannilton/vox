@echo off
setlocal

:: VS-15 (REQ-TRC-01) + VS-16 (REQ-CPU-02): build com Tracy ligado e call
:: stacks de profundidade 10. Exige vendor\tracy\tracy.lib; se ausente, gere
:: com tools\build_tracy_client.bat. A UI Tracy fica em
:: tools\tracy\tracy-profiler.exe; encontrada, o script a abre antes do app.

if not exist ".\vendor\tracy\tracy.lib" goto sem_lib
goto com_lib
:sem_lib
echo ERRO: vendor\tracy\tracy.lib ausente.
echo Gere a biblioteca com: tools\build_tracy_client.bat
exit /b 1
:com_lib

if exist ".\tools\tracy\tracy-profiler.exe" goto com_ui
echo UI Tracy nao encontrada em tools\tracy\tracy-profiler.exe.
echo Baixe o pacote Windows de https://github.com/wolfpld/tracy/releases/tag/v0.14.1
echo e extraia para tools\tracy\ - ou abra a UI manualmente e de Connect.
goto pos_ui
:com_ui
echo Abrindo Tracy Profiler: tools\tracy\tracy-profiler.exe
start "" ".\tools\tracy\tracy-profiler.exe"
:pos_ui

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

odin build .\src\ -out:./bin/vox.exe -define:TRACY_ENABLE=true -define:TRACY_CALLSTACK=10 || exit /b 1
chdir ./bin
vox.exe %*