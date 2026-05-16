import os

# ── Anthropic API ─────────────────────────────────────────────────────────────
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")   # set via env var
ANTHROPIC_MODEL   = "claude-sonnet-4-6"
MAX_TOKENS        = 1000

# ── Named Pipe ────────────────────────────────────────────────────────────────
PIPE_EA_TO_BRIDGE = r"\\.\pipe\ea_to_bridge"
PIPE_BRIDGE_TO_EA = r"\\.\pipe\bridge_to_ea"
PIPE_BUFFER_SIZE  = 65536   # 64KB

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
