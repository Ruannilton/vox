@echo off
setlocal EnableDelayedExpansion

:: VS-15 (REQ-TRC-01): reproduz vendor/tracy/tracy.lib (Tracy client C++
:: v0.14.1, x64) a partir de oskarnp/odin-tracy (bindings Odin oficiais).
:: Requer toolchain MSVC x64 (Visual Studio com "C++ build tools"); o
:: build_windows.cmd do próprio repo localiza o vsdevcmd via vswhere.
::
:: Uso: tools\build_tracy_client.bat   (a partir da raiz do repo)

set "ROOT=%~dp0.."
set "ROOT=%ROOT:\tools\..=%"
set "WORK=%TEMP%\odin-tracy-build"

if exist "%WORK%" rmdir /S /Q "%WORK%"

echo [TRACY] Clonando oskarnp/odin-tracy (com submodule tracy v0.14.1)...
git clone --recurse-submodules https://github.com/oskarnp/odin-tracy "%WORK%" || exit /b 1

pushd "%WORK%"
echo [TRACY] Compilando client C++ (cl -MD -O2 -DTRACY_ENABLE)...
:: -MD (nao -MT do upstream): o runtime do projeto linka o CRT dinamico
:: (mesma flag do vma_windows_x86_64.lib); -MT causa /FAILIFMISMATCH no link.
sed "s/-MT /-MD /" build_windows.cmd > build_md.cmd || (popd & exit /b 1)
call build_md.cmd || (popd & exit /b 1)
popd

if not exist "%WORK%\tracy.lib" (
    echo [TRACY] ERRO: tracy.lib nao foi gerada.
    exit /b 1
)

echo [TRACY] Copiando artefatos para vendor\tracy\...
if not exist "%ROOT%\vendor\tracy" mkdir "%ROOT%\vendor\tracy"
copy /Y "%WORK%\tracy.lib" "%ROOT%\vendor\tracy\tracy.lib" || exit /b 1
copy /Y "%WORK%\bindings.odin" "%ROOT%\vendor\tracy\bindings.odin" || exit /b 1
copy /Y "%WORK%\wrapper.odin" "%ROOT%\vendor\tracy\wrapper.odin" || exit /b 1
copy /Y "%WORK%\allocator.odin" "%ROOT%\vendor\tracy\allocator.odin" || exit /b 1

echo [TRACY] OK — vendor\tracy atualizado.
exit /b 0
