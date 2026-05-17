"""
bridge_entry.py — Python entry point, compiled by Nuitka → bridge_entry.pyd
Exposes 3 functions callable from AI_Bridge.dll (C++ wrapper):
  init_strategy(sid, prompt, symbol, tf, lot, sl, tp, account) → str (JSON)
  check_signal(sid, values_json, account)                       → str (JSON)
  stop_strategy(sid)                                            → None
"""

import json
import sys
import os

# Ensure bridge modules are importable (same dir as this file)
_dir = os.path.dirname(os.path.abspath(__file__))
if _dir not in sys.path:
    sys.path.insert(0, _dir)

from strategy import dispatch as _dispatch
from license_validator import check_license as _check_license

import logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[logging.FileHandler(
        os.path.join(os.environ.get("APPDATA", "."), "AI_Bridge", "bridge.log"),
        encoding="utf-8"
    )]
)
log = logging.getLogger("bridge_entry")


def init_strategy(sid: int, prompt: str, symbol: str, tf: int,
                  lot: float, sl: int, tp: int, account: int) -> str:
    """Initialize a strategy slot. Returns JSON string."""
    log.info(f"[S{sid}] init_strategy account={account} symbol={symbol}")

    if not _check_license(account):
        log.warning(f"[S{sid}] License invalid for account {account}")
        return json.dumps({
            "status": "error",
            "message": "License invalid. Purchase at: https://www.mql5.com/en/market"
        })

    data = {
        "cmd":    "init",
        "sid":    sid,
        "prompt": prompt,
        "symbol": symbol,
        "tf":     tf,
        "lot":    lot,
        "sl":     sl,
        "tp":     tp,
    }
    try:
        result = _dispatch(data)
        log.info(f"[S{sid}] init_strategy → {result.get('status')}")
        return json.dumps(result)
    except Exception as e:
        log.error(f"[S{sid}] init_strategy error: {e}")
        return json.dumps({"status": "error", "message": str(e)})


def check_signal(sid: int, values_json: str, account: int) -> str:
    """Check trading signal. Returns JSON string."""
    if not _check_license(account):
        return json.dumps({"action": "NONE"})

    try:
        values = json.loads(values_json)
    except Exception as e:
        log.error(f"[S{sid}] check_signal JSON parse error: {e}")
        return json.dumps({"action": "NONE"})

    try:
        result = _dispatch({"cmd": "check", "sid": sid, "values": values})
        return json.dumps(result)
    except Exception as e:
        log.error(f"[S{sid}] check_signal error: {e}")
        return json.dumps({"action": "NONE"})


def stop_strategy(sid: int) -> None:
    """Remove a strategy slot."""
    try:
        _dispatch({"cmd": "stop", "sid": sid})
        log.info(f"[S{sid}] stopped")
    except Exception as e:
        log.error(f"[S{sid}] stop_strategy error: {e}")
