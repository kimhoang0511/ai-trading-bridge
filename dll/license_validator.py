"""
license_validator.py — License validation via online server.
- Validates MT4 account number against license server
- Caches result 24h (works offline after first validation)
- Grace period: if server unreachable, uses last cached result
"""

import hashlib
import json
import os
import time
import urllib.request
import urllib.error

# ── Config ─────────────────────────────────────────────────────────────────────
LICENSE_SERVER  = "https://api.yourdomain.com/license/validate"
CACHE_TTL       = 86400   # 24 hours
GRACE_PERIOD    = 604800  # 7 days — allow offline use if server unreachable

# Set True during development/testing. Must be False before publishing on Market.
DEV_MODE = True

# ── Cache ──────────────────────────────────────────────────────────────────────
_cache_dir  = os.path.join(os.environ.get("APPDATA", "."), "AI_Bridge")
_cache_file = os.path.join(_cache_dir, "license.json")
_mem_cache: dict = {}   # account → {"valid": bool, "ts": float}


def _load_disk_cache() -> dict:
    try:
        with open(_cache_file, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def _save_disk_cache(cache: dict) -> None:
    try:
        os.makedirs(_cache_dir, exist_ok=True)
        with open(_cache_file, "w") as f:
            json.dump(cache, f)
    except Exception:
        pass


def _get_hwid() -> str:
    """Generate hardware fingerprint from CPU + disk serial."""
    try:
        import subprocess
        r = subprocess.run(
            ["wmic", "csproduct", "get", "uuid"],
            capture_output=True, text=True, timeout=5
        )
        return hashlib.sha256(r.stdout.strip().encode()).hexdigest()[:20]
    except Exception:
        return "unknown"


def check_license(account: int) -> bool:
    """
    Validate MT4 account license.
    Returns True if licensed, False otherwise.
    """
    if DEV_MODE:
        return True

    now   = time.time()
    key   = str(account)

    # 1. Memory cache (fastest)
    if key in _mem_cache:
        entry = _mem_cache[key]
        if now - entry["ts"] < CACHE_TTL:
            return entry["valid"]

    # 2. Disk cache (survives process restart)
    disk = _load_disk_cache()
    if key in disk:
        entry = disk[key]
        if now - entry["ts"] < CACHE_TTL:
            _mem_cache[key] = entry
            return entry["valid"]

    # 3. Online validation
    valid = _validate_online(account)

    if valid is None:
        # Server unreachable — use last known result within grace period
        if key in disk and now - disk[key]["ts"] < GRACE_PERIOD:
            return disk[key]["valid"]
        return False

    # Save to both caches
    entry = {"valid": valid, "ts": now}
    _mem_cache[key] = entry
    disk[key] = entry
    _save_disk_cache(disk)
    return valid


def _validate_online(account: int):
    """
    Call license server. Returns True/False, or None if unreachable.
    """
    try:
        payload = json.dumps({
            "account": account,
            "hwid":    _get_hwid(),
            "product": "ai-trading-bridge",
        }).encode("utf-8")

        req = urllib.request.Request(
            LICENSE_SERVER,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return bool(data.get("valid", False))

    except urllib.error.HTTPError as e:
        if e.code == 403:
            return False    # Explicitly rejected
        return None         # Server error → treat as unreachable
    except Exception:
        return None         # Network error → grace period applies
