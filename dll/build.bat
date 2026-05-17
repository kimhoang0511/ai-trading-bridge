@echo off
cd /d "%~dp0"
setlocal EnableDelayedExpansion

echo ============================================================
echo  AI Bridge DLL v2 -- Pure C++ Build (No Python required)
echo  Output: AI_Bridge.dll
echo ============================================================
echo.

set OUT_DIR=..\dist\dll

:: ── Auto-find MSVC x86 toolchain ─────────────────────────────────────────────
where cl >nul 2>&1
if errorlevel 1 (
    echo [INFO] Searching for MSVC...
    set VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist !VSWHERE! set VSWHERE="%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"

    if exist !VSWHERE! (
        for /f "usebackq tokens=*" %%i in (
            `!VSWHERE! -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`
        ) do set VS_PATH=%%i

        if defined VS_PATH (
            call "!VS_PATH!\VC\Auxiliary\Build\vcvars32.bat" >nul 2>&1
            echo [INFO] MSVC x86 loaded.
        ) else (
            echo [ERROR] Visual Studio Build Tools not found.
            echo         Download: https://visualstudio.microsoft.com/visual-cpp-build-tools/
            pause & exit /b 1
        )
    ) else (
        echo [ERROR] vswhere.exe not found. Install Visual Studio Build Tools first.
        pause & exit /b 1
    )
)

mkdir %OUT_DIR% 2>nul

:: ── Compile ───────────────────────────────────────────────────────────────────
echo [1/1] Compiling AI_Bridge.cpp...
cl /nologo /LD /MD /O2 /W3 /EHsc ^
   AI_Bridge.cpp ^
   /link /OUT:AI_Bridge.dll /DEF:AI_Bridge.def ^
   winhttp.lib user32.lib

if errorlevel 1 (
    echo.
    echo [ERROR] Build failed. See errors above.
    pause & exit /b 1
)

copy /Y AI_Bridge.dll %OUT_DIR%\ >nul
del /q AI_Bridge.exp AI_Bridge.lib *.obj 2>nul

echo.
echo ============================================================
echo  BUILD SUCCESS
echo  Output: %OUT_DIR%\AI_Bridge.dll
echo.
echo  Setup steps:
echo    1. Copy AI_Bridge.dll to: MT4\MQL4\Libraries\
echo    2. Create api_key.txt in: MT4\MQL4\Libraries\
echo       Content: paste your Anthropic API key (sk-ant-...)
echo    3. Attach AI_EA_DLL to chart in MT4
echo ============================================================
echo.
pause
