@echo off
cd /d "%~dp0"
setlocal EnableDelayedExpansion

echo ============================================================
echo  AI Bridge — Run Tests
echo ============================================================

where cl >nul 2>&1
if errorlevel 1 (
    set VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if not exist !VSWHERE! set VSWHERE="%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist !VSWHERE! (
        for /f "usebackq tokens=*" %%i in (`!VSWHERE! -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VS_PATH=%%i
        if defined VS_PATH (
            call "!VS_PATH!\VC\Auxiliary\Build\vcvars32.bat" >nul 2>&1
        )
    )
)

echo [1/2] Compiling test...
cl /nologo /MD /O2 /EHsc /W3 test_conditions.cpp /Fe:test_conditions.exe >nul
if errorlevel 1 ( echo [ERROR] Compile failed. & pause & exit /b 1 )

echo [2/2] Running tests...
echo.
test_conditions.exe
set EXIT=%ERRORLEVEL%

echo.
if %EXIT%==0 ( echo  ALL TESTS PASSED ) else ( echo  SOME TESTS FAILED )
echo ============================================================
del /q test_conditions.exe test_conditions.obj 2>nul
pause
