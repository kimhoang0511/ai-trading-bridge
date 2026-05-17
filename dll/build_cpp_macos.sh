#!/bin/bash
# build_cpp_macos.sh — Cross-compile AI_Bridge.dll trên macOS dùng MinGW
# Chỉ build C++ wrapper. Nuitka (bridge_entry.pyd) phải build trên Windows.
#
# Yêu cầu: brew install mingw-w64
# Yêu cầu: Python 3.12 embeddable package đã giải nén vào ./python312_embed/

set -e

PYTHON_EMBED="./python312_embed"
PYTHON_INC="$PYTHON_EMBED/include"
PYTHON_LIB="$PYTHON_EMBED/libs/python312.lib"
OUT="AI_Bridge.dll"

echo "=== Cross-compiling AI_Bridge.dll for Windows (x86_64) ==="

# Kiểm tra mingw
if ! command -v x86_64-w64-mingw32-g++ &>/dev/null; then
    echo "[ERROR] MinGW not found. Install: brew install mingw-w64"
    exit 1
fi

# Kiểm tra Python embeddable
if [ ! -d "$PYTHON_EMBED" ]; then
    echo "[ERROR] Python embeddable not found at $PYTHON_EMBED"
    echo "        Download from: https://www.python.org/downloads/windows/"
    echo "        Choose: 'Windows embeddable package (64-bit)'"
    echo "        Extract to: dll/python312_embed/"
    exit 1
fi

echo "[1/2] Compiling C++ → $OUT ..."
x86_64-w64-mingw32-g++ \
    -shared \
    -o "$OUT" \
    AI_Bridge.cpp \
    -I"$PYTHON_INC" \
    -L"$PYTHON_EMBED/libs" \
    -lpython312 \
    -static-libgcc \
    -static-libstdc++ \
    -Wl,--output-def,AI_Bridge_gen.def \
    -O2

echo "[2/2] Done: $OUT"
echo ""
echo "=== QUAN TRỌNG ==="
echo "bridge_entry.pyd phải được build trên Windows bằng Nuitka:"
echo "  cd dll"
echo "  python -m nuitka --module bridge_entry.py --include-package=anthropic"
echo ""
echo "Files cần copy vào MT4/MQL4/Libraries/:"
echo "  AI_Bridge.dll"
echo "  bridge_entry.pyd      (build trên Windows)"
echo "  python312.dll         (từ Python embeddable)"
echo "  python312.zip         (từ Python embeddable)"
echo "  anthropic/            (pip install anthropic)"
