@echo off
cd /d "%~dp0"
setlocal EnableDelayedExpansion

echo ============================================================
echo  AI Bridge MT5 TCP Socket -- Standalone EXE Build
echo  Output: ai_bridge_mt5.exe
echo ============================================================
echo.

set OUT_DIR=..\dist\exe

:: ── Auto-find MSVC x64 toolchain ─────────────────────────────────────────────
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
            call "!VS_PATH!\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
            echo [INFO] MSVC x64 loaded from: !VS_PATH!
        ) else (
            echo [ERROR] Visual Studio Build Tools not found.
            pause & exit /b 1
        )
    ) else (
        echo [ERROR] vswhere.exe not found. Install Visual Studio Build Tools first.
        pause & exit /b 1
    )
)

mkdir %OUT_DIR% 2>nul

:: ── Compile resource (icon) ───────────────────────────────────────────────────
echo [1/2] Compiling app.rc (icon resource)...
rc /nologo /fo app.res app.rc
if errorlevel 1 (
    echo [WARN] rc.exe failed -- building without embedded icon.
    set RES_FILE=
) else (
    set RES_FILE=app.res
)

:: ── Compile ───────────────────────────────────────────────────────────────────
echo [2/2] Compiling file_bridge_mt5.cpp (x64, /EHsc)...
cl /nologo /MD /O2 /W3 /EHsc ^
   file_bridge_mt5.cpp ^
   /link /OUT:ai_bridge_mt5.exe ^
   /SUBSYSTEM:WINDOWS ^
   winhttp.lib user32.lib gdi32.lib shell32.lib ^
   %RES_FILE%

if errorlevel 1 (
    echo.
    echo [ERROR] Compile failed. See errors above.
    pause & exit /b 1
)

:: ── Copy output ───────────────────────────────────────────────────────────────
copy /Y ai_bridge_mt5.exe %OUT_DIR%\ >nul
echo [OK] Copied to %OUT_DIR%\ai_bridge_mt5.exe

:: Cleanup intermediate files
del /q ai_bridge_mt5.exp ai_bridge_mt5.lib *.obj 2>nul

echo.
echo ============================================================
echo  BUILD SUCCESS
echo  Output: %OUT_DIR%\ai_bridge_mt5.exe
echo.
echo  Usage:
echo    1. Run ai_bridge_mt5.exe
echo    2. Click Start
echo    3. MT5 EA ket noi TCP toi 127.0.0.1:9876
echo    4. App xu ly va tra ket qua qua TCP socket
echo ============================================================
echo.
pause
