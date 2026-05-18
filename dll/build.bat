@echo off
cd /d "%~dp0"
setlocal EnableDelayedExpansion

echo ============================================================
echo  AI Bridge DLL v3 -- Pure C++ Build (No Python required)
echo  Output: AI_Bridge.dll
echo ============================================================
echo.

set OUT_DIR=..\dist\dll
set MT4_LIB_DIR=%APPDATA%\MetaQuotes\Terminal\Common\Files

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
            echo [INFO] MSVC x86 loaded from: !VS_PATH!
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

:: Verify cl.exe is x86 (required for MT4 32-bit)
cl 2>&1 | findstr /i "x86\|80x86\|for x86" >nul
if errorlevel 1 (
    echo [WARN] cl.exe may not be x86 -- MT4 requires 32-bit DLL.
    echo        If MT4 crashes on load, run vcvars32.bat manually then rebuild.
    echo.
)

mkdir %OUT_DIR% 2>nul

:: ── Compile ───────────────────────────────────────────────────────────────────
echo [1/1] Compiling AI_Bridge.cpp ^(x86, /EHsc^)...
cl /nologo /LD /MD /O2 /W3 /EHsc ^
   AI_Bridge.cpp ^
   /link /OUT:AI_Bridge.dll /DEF:AI_Bridge.def ^
   winhttp.lib user32.lib

if errorlevel 1 (
    echo.
    echo [ERROR] Compile failed. See errors above.
    echo         Common causes:
    echo           - Missing /EHsc  ^(already set above^)
    echo           - Forward-declaration issue: check symbol order in .cpp
    echo           - Wrong architecture: must use vcvars32.bat ^(x86^)
    pause & exit /b 1
)

:: ── Copy outputs ──────────────────────────────────────────────────────────────
copy /Y AI_Bridge.dll %OUT_DIR%\ >nul
echo [OK] Copied to %OUT_DIR%\AI_Bridge.dll

:: Auto-copy to MT4 Libraries if path exists
set MT4_FOUND=0
for /d %%T in ("%APPDATA%\MetaQuotes\Terminal\*") do (
    if exist "%%T\MQL4\Libraries" (
        copy /Y AI_Bridge.dll "%%T\MQL4\Libraries\AI_Bridge.dll" >nul
        echo [OK] Auto-copied to: %%T\MQL4\Libraries\
        set MT4_FOUND=1
    )
)
if !MT4_FOUND!==0 (
    echo [INFO] MT4 Libraries folder not found -- copy AI_Bridge.dll manually.
)

:: Cleanup intermediate files
del /q AI_Bridge.exp AI_Bridge.lib *.obj 2>nul

:: ── Print startup log location ────────────────────────────────────────────────
echo.
echo  Startup log ^(check after MT4 loads DLL^):
echo    %APPDATA%\AI_Bridge\startup.log

echo.
echo ============================================================
echo  BUILD SUCCESS  ^(v3^)
echo  Output: %OUT_DIR%\AI_Bridge.dll
echo.
echo  Setup steps:
echo    1. DLL auto-copied to MT4\MQL4\Libraries\ ^(if found^)
echo    2. Restart MT4 / reattach EA to chart
echo    3. Check startup.log if DLL crashes on load
echo ============================================================
echo.
pause
