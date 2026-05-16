"""
Strategy management — parse, store, and evaluate trading strategies.
Each strategy is identified by sid (0..MAX_STRATEGIES-1).
"""

import json
import logging
from anthropic import Anthropic

from config import (
    ANTHROPIC_API_KEY, ANTHROPIC_MODEL, MAX_TOKENS,
    OHLC_BARS_DEFAULT, OHLC_BARS_MAX, LOG_SIGNALS, LOG_CANDLES
)
from analyzer import analyze
from sandbox import run as sandbox_run, validate_output

log = logging.getLogger("strategy")

client = Anthropic(api_key=ANTHROPIC_API_KEY)

# strategies[sid] = {
#   "code":       str,    # def check(v): ...
#   "action":     str,    # "BUY" or "SELL"
#   "lot":        float,
#   "sl_pip":     float,
#   "tp_pip":     float,
#   "indicators": list,   # indicator configs for EA
#   "ohlc_bars":  int,    # how many OHLC bars EA must send
#   "symbol":     str,
# }
strategies: dict[int, dict] = {}


SYSTEM_PROMPT = """\
You are a trading strategy parser. Convert a natural language trading instruction into a JSON config.

OUTPUT FORMAT (return only valid JSON, no explanation, no markdown fences):
{
  "action": "BUY or SELL or BOTH",
  "lot": 0.1,
  "sl_pip": 50,
  "tp_pip": 100,
  "ohlc_bars": 3,
  "indicators": [
    {"name": "ma20",      "type": "iMA",   "period": 20, "method": 1, "applied": 0, "shift": 0},
    {"name": "ma20_prev", "type": "iMA",   "period": 20, "method": 1, "applied": 0, "shift": 1},
    {"name": "rsi14",     "type": "iRSI",  "period": 14, "applied": 0, "shift": 0}
  ],
  "code": "def check(v: dict) -> bool:\\n    cross_up = v['ma20'] > v['ma50'] and v['ma20_prev'] < v['ma50_prev']\\n    rsi_ok = v['rsi14'] < 65\\n    return cross_up and rsi_ok"
}

RULES:
- ohlc_bars: minimum bars needed (engulfing=2, morning star=3, breakout 20=21, default=3)
- indicators: only list what check(v) actually uses; add _prev variants for crossover detection
- code: must be def check(v: dict) -> bool: with return bool
- code: may use PA helper functions: is_bull_engulfing(v), is_pin_bar_bull(v,i), is_uptrend(v,n), etc.
- code: NO import, NO exec, NO open, NO os/sys
- action BOTH: generate separate BUY and SELL signals (return "BUY" or "SELL" string instead of bool — NOT supported, use single direction)
- If user says both buy and sell, pick the entry direction from context

INDICATOR TYPES: iMA, iRSI, iMACD, iBands, iStochastic, iADX, iCCI, iATR, iSAR, iWPR,
iMomentum, iAlligator, iIchimoku, iMFI, iOBV, iForce, iFractals, iHighest, iLowest,
iDEMA, iTEMA, iFrAMA, iStdDev, iClose, iOpen, iHigh, iLow, iVolume, Ask, Bid
"""


def handle_init(sid: int, data: dict) -> dict:
    """Parse a user prompt into a strategy and store it."""
    prompt = data.get("prompt", "").strip()
    symbol = data.get("symbol", "EURUSD")
    tf     = data.get("tf", 60)
    lot    = float(data.get("lot", 0.1))
    sl     = float(data.get("sl", 50))
    tp     = float(data.get("tp", 100))

    if not prompt:
        return {"status": "error", "message": "Empty prompt"}

    log.info(f"[S{sid}] {symbol}: Parsing '{prompt[:60]}...'")

    # Call Claude API
    try:
        response = client.messages.create(
            model=ANTHROPIC_MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM_PROMPT,
            messages=[{
                "role": "user",
                "content": (
                    f'Instruction: "{prompt}"\n'
                    f'Symbol: {symbol}, Timeframe: {tf} minutes\n'
                    f'Default lot: {lot}, SL: {sl} pips, TP: {tp} pips'
                )
            }]
        )
        raw = response.content[0].text.strip()
        # Strip markdown fences if present
        raw = raw.replace("```json", "").replace("```", "").strip()
        config = json.loads(raw)
    except json.JSONDecodeError as e:
        log.error(f"[S{sid}] JSON parse error: {e}\nRaw: {raw}")
        return {"status": "error", "message": f"Claude returned invalid JSON: {e}"}
    except Exception as e:
        log.error(f"[S{sid}] Claude API error: {e}")
        return {"status": "error", "message": f"Claude API error: {e}"}

    # Override with user-provided values if Claude didn't set them
    config.setdefault("action",  "BUY")
    config.setdefault("lot",     lot)
    config.setdefault("sl_pip",  sl)
    config.setdefault("tp_pip",  tp)
    config.setdefault("ohlc_bars", OHLC_BARS_DEFAULT)
    config["ohlc_bars"] = min(int(config["ohlc_bars"]), OHLC_BARS_MAX)
    config["symbol"] = symbol

    # Static analysis
    code = config.get("code", "")
    ok, errors = analyze(code)
    if not ok:
        log.warning(f"[S{sid}] Static analysis failed: {errors}")
        return {"status": "error", "message": "Code rejected by analyzer", "errors": errors}

    # Dry-run with dummy values to catch runtime errors
    dummy = {f"close_{i}": 1.08 for i in range(config["ohlc_bars"])}
    dummy.update({f"open_{i}": 1.079 for i in range(config["ohlc_bars"])})
    dummy.update({f"high_{i}": 1.081 for i in range(config["ohlc_bars"])})
    dummy.update({f"low_{i}": 1.078  for i in range(config["ohlc_bars"])})
    dummy.update({f"volume_{i}": 1000 for i in range(config["ohlc_bars"])})
    dummy["ask"] = 1.0801
    dummy["bid"] = 1.0800
    dummy["point"] = 0.00001
    for ind in config.get("indicators", []):
        dummy[ind["name"]] = 1.0

    ok, _, err = sandbox_run(code, dummy, timeout_ms=500)
    if not ok:
        log.warning(f"[S{sid}] Dry-run failed: {err}")
        return {"status": "error", "message": f"Code dry-run failed: {err}"}

    # Store strategy
    strategies[sid] = config
    log.info(f"[S{sid}] Loaded OK. Indicators: {[i['name'] for i in config.get('indicators', [])]}")

    return {
        "status":     "ok",
        "indicators": config.get("indicators", []),
        "ohlc_bars":  config["ohlc_bars"],
    }


def handle_check(sid: int, data: dict) -> dict:
    """Evaluate a strategy against current market values."""
    values = data.get("values", {})
    config = strategies.get(sid)

    if not config:
        return {"action": "NONE"}

    if LOG_CANDLES:
        log.debug(f"[S{sid}] Check: {list(values.keys())[:5]}...")

    # Execute strategy code in sandbox
    ok, result, err = sandbox_run(config["code"], values)

    if not ok:
        log.error(f"[S{sid}] Sandbox error: {err}")
        return {"action": "NONE"}

    # Validate output
    ok, signal, err = validate_output(result, config)

    if not ok:
        log.error(f"[S{sid}] Output validation error: {err}")
        return {"action": "NONE"}

    if signal["action"] != "NONE" and LOG_SIGNALS:
        log.info(f"[S{sid}] SIGNAL → {signal['action']} {config.get('symbol','')} "
                 f"lot={signal['lot']} sl={signal['sl']} tp={signal['tp']}")

    return signal


def handle_stop(sid: int) -> dict:
    """Remove a strategy when EA stops."""
    if sid in strategies:
        sym = strategies[sid].get("symbol", "?")
        del strategies[sid]
        log.info(f"[S{sid}] {sym}: Strategy stopped")
    return {"status": "ok"}


def dispatch(data: dict) -> dict:
    """Route incoming message to the correct handler."""
    cmd = data.get("cmd", "")
    sid = int(data.get("sid", 0))

    if cmd == "init":
        return handle_init(sid, data)
    elif cmd == "check":
        return handle_check(sid, data)
    elif cmd == "stop":
        return handle_stop(sid)
    else:
        log.warning(f"Unknown cmd: {cmd}")
        return {"action": "NONE"}
