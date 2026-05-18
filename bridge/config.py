import os
import sys

# ── Anthropic API ─────────────────────────────────────────────────────────────
HARDCODED_KEY = "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"  # paste your key here: "sk-ant-api03-..."

def _load_api_key() -> str:
    # 1. Hardcoded in config.py
    if HARDCODED_KEY:
        return HARDCODED_KEY
    # 2. Environment variable
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if key:
        return key
    # 3. api_key.txt next to the exe (or script directory)
    base = getattr(sys, "_MEIPASS", None) or os.path.dirname(os.path.abspath(__file__))
    key_file = os.path.join(base, "api_key.txt")
    if os.path.isfile(key_file):
        with open(key_file, encoding="utf-8") as f:
            key = f.read().strip()
    return key

ANTHROPIC_API_KEY = _load_api_key()
ANTHROPIC_MODEL   = os.environ.get("CLAUDE_PARSE_MODEL", "claude-sonnet-4-6")
MAX_TOKENS        = 1000

# ── HTTP Server ───────────────────────────────────────────────────────────────
HTTP_HOST = "0.0.0.0"
HTTP_PORT = 8080

# ── Strategy limits ───────────────────────────────────────────────────────────
MAX_STRATEGIES    = 5       # must match EA extern params count
OHLC_BARS_DEFAULT = 5       # fallback if Claude doesn't specify
OHLC_BARS_MAX     = 50      # hard cap to prevent huge payloads

# ── Security ──────────────────────────────────────────────────────────────────
SANDBOX_TIMEOUT_MS = 100    # ms — kill strategy execution if exceeded
MAX_CODE_LENGTH    = 2000   # characters
MIN_TP_SL_RATIO    = 0.5    # TP must be at least 50% of SL

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_SIGNALS       = True    # log every BUY/SELL signal
LOG_CANDLES       = False   # log every candle check (verbose)
