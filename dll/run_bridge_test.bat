@echo off
cd /d "%~dp0"
setlocal EnableDelayedExpansion

echo ============================================================
echo  AI Bridge — Bridge_Init JSON Test
echo ============================================================

:: ── Auto-find MSVC x86 toolchain ─────────────────────────────
where cl >nul 2>&1
if errorlevel 1 (
    set VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist !VSWHERE! set VSWHERE="%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist !VSWHERE! (
        for /f "usebackq tokens=*" %%i in (
            `!VSWHERE! -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`
        ) do set VS_PATH=%%i
        if defined VS_PATH (
            call "!VS_PATH!\VC\Auxiliary\Build\vcvars32.bat" >nul 2>&1
        ) else (
            echo [ERROR] Visual Studio Build Tools not found.
            pause & exit /b 1
        )
    ) else (
        echo [ERROR] vswhere.exe not found.
        pause & exit /b 1
    )
)

:: ── Build ─────────────────────────────────────────────────────
echo [1/2] Compiling test_bridge_init.cpp...
cl /nologo /MD /O2 /EHsc /W3 test_bridge_init.cpp /Fe:test_bridge_init.exe >nul
if errorlevel 1 (
    echo [ERROR] Compile failed.
    pause & exit /b 1
)

:: ── Copy DLL next to exe so LoadLibrary finds it ─────────────
if exist ..\dist\dll\AI_Bridge.dll (
    copy /Y ..\dist\dll\AI_Bridge.dll AI_Bridge.dll >nul
    echo [INFO] Copied AI_Bridge.dll from dist\dll\
) else if exist AI_Bridge.dll (
    echo [INFO] Using AI_Bridge.dll in current directory
) else (
    echo [WARN] AI_Bridge.dll not found in dist\dll\ or current directory
    echo        Build the DLL first with build.bat, or copy manually
)

:: ── Run with default test prompt ─────────────────────────────
echo [2/2] Running test...
echo.

:: You can change the args: SYMBOL "PROMPT" TF
:: test_bridge_init.exe EURUSD "Buy when EMA8 crosses above EMA21 and RSI14 < 60" 60
test_bridge_init.exe EURUSD "Buy EURUSD when MA20 crosses above MA50 and RSI14 is below 65. Lot 0.1, SL 50 pips, TP 100 pips." 60

:: ── Cleanup ───────────────────────────────────────────────────
del /q test_bridge_init.exe test_bridge_init.obj 2>nul
