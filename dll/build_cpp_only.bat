@echo off
:: build_cpp_only.bat -- Compile AI_Bridge.dll (pure C++, no Python)
:: Requires: Visual Studio x86 build tools

setlocal EnableDelayedExpansion

set OUT_DIR=..\dist\dll

:: ── Auto-find MSVC x86 ────────────────────────────────────────────────────────
where cl >nul 2>&1
if errorlevel 1 (
    set VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist !VSWHERE! set VSWHERE="%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist !VSWHERE! (
        for /f "usebackq tokens=*" %%i in (
            `!VSWHERE! -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`
        ) do set VS_PATH=%%i
        call "!VS_PATH!\VC\Auxiliary\Build\vcvars32.bat" >nul 2>&1
    ) else (
        echo [ERROR] vswhere.exe not found.
        pause & exit /b 1
    )
)

:: ── Compile DLL ───────────────────────────────────────────────────────────────
echo Compiling AI_Bridge.dll...
cl /nologo /LD /MD /O2 /W3 /TP ^
   AI_Bridge.cpp ^
   /link /OUT:AI_Bridge.dll /DEF:AI_Bridge.def ^
   winhttp.lib user32.lib ^
   /NODEFAULTLIB:LIBCMT

if errorlevel 1 (
    echo [ERROR] Compile failed.
    pause & exit /b 1
)

mkdir %OUT_DIR% 2>nul
copy /Y AI_Bridge.dll %OUT_DIR%\ >nul
del /q *.obj *.exp *.lib 2>nul

echo.
echo ================================================
echo  OK: AI_Bridge.dll built successfully
echo  Output: %OUT_DIR%\AI_Bridge.dll
echo.
echo  Copy to MT4: ^<Terminal^>\MQL4\Libraries\AI_Bridge.dll
echo ================================================
pause
