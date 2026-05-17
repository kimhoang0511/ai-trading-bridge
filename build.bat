@echo off
setlocal

echo ============================================================
echo  AI Trading Bridge -- Build Script
echo ============================================================
echo.

:: Check Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Python not found. Install from https://python.org
    pause & exit /b 1
)

:: Install / upgrade build tools
echo [1/4] Installing dependencies...
pip install -r bridge\requirements.txt --quiet
pip install pyinstaller --quiet
if errorlevel 1 (
    echo [ERROR] pip install failed.
    pause & exit /b 1
)

:: Kill running instance before cleaning (prevents PermissionError)
echo [2/4] Stopping any running bridge instance...
taskkill /f /im AI_Trading_Bridge.exe >nul 2>&1

:: Clean previous build
echo        Cleaning previous build...
if exist dist\AI_Trading_Bridge.exe del /f /q dist\AI_Trading_Bridge.exe
if exist build rmdir /s /q build

:: Build
echo [3/4] Building .exe (may take 1-2 minutes)...
pyinstaller ai_trading_bridge.spec --clean --noconfirm
if errorlevel 1 (
    echo [ERROR] Build failed. See output above.
    pause & exit /b 1
)

:: Copy api_key.txt template
echo [4/4] Finalizing...
if not exist dist\api_key.txt (
    echo PASTE_YOUR_ANTHROPIC_KEY_HERE > dist\api_key.txt
)

echo.
echo ============================================================
echo  BUILD SUCCESS
echo  Output: dist\AI_Trading_Bridge.exe
echo.
echo  Before running, open dist\api_key.txt and paste your
echo  Anthropic API key (from https://console.anthropic.com)
echo ============================================================
echo.
pause
