"""
Sandbox execution — Layer 2 security.
Executes Claude-generated check(v) functions in a restricted namespace
with a per-thread sandbox, stripped builtins, and timeout enforcement.
"""

import threading
from typing import Any

from pa_helpers import PA_HELPERS
from config import SANDBOX_TIMEOUT_MS

# Safe builtins — math, logic, collections only
SAFE_BUILTINS: dict[str, Any] = {
    # Math
    "abs": abs, "round": round, "min": min, "max": max,
    "sum": sum, "pow": pow,
    # Type conversions
    "bool": bool, "int": int, "float": float, "str": str,
    # Collections
    "list": list, "dict": dict, "tuple": tuple, "set": set,
    "len": len, "range": range,
    # Iteration
    "enumerate": enumerate, "zip": zip,
    "sorted": sorted, "reversed": reversed,
    # Logic
    "all": all, "any": any,
    # Constants
    "True": True, "False": False, "None": None,
}

# Thread-local storage — each thread gets its own sandbox
_local = threading.local()


def _get_base_sandbox() -> dict:
    """Build or return the thread-local base sandbox with PA helpers pre-loaded."""
    if not hasattr(_local, "base_sandbox"):
        sb: dict = {"__builtins__": SAFE_BUILTINS}
        exec(PA_HELPERS, sb)  # inject PA helper functions
        # Remove exec artifacts
        sb.pop("__doc__", None)
        sb.pop("__spec__", None)
        _local.base_sandbox = sb
    return _local.base_sandbox


class TimeoutError(Exception):
    pass


class SandboxError(Exception):
    pass


def run(code: str, values: dict, timeout_ms: int = SANDBOX_TIMEOUT_MS) -> tuple[bool, bool | None, str]:
    """
    Execute check(v) in a sandboxed namespace.

    Args:
        code:       Python code string containing def check(v): ...
        values:     dict of indicator/OHLC values from EA
        timeout_ms: kill execution after this many milliseconds

    Returns:
        (success, result, error_message)
        success=True  → result is a bool (True=signal, False=no signal)
        success=False → result is None, error_message explains why
    """
    result_container: dict[str, Any] = {"result": None, "error": None}

    def _target():
        try:
            # Fresh copy of base sandbox per request (shallow copy is safe —
            # PA helpers are pure functions with no mutable state)
            sandbox = dict(_get_base_sandbox())
            sandbox["__builtins__"] = SAFE_BUILTINS

            # Load strategy code
            compiled = compile(code, "<strategy>", "exec")
            exec(compiled, sandbox)

            # Call check(v)
            check_fn = sandbox.get("check")
            if not callable(check_fn):
                result_container["error"] = "check() function not found after exec"
                return

            result = check_fn(values)
            result_container["result"] = result

        except MemoryError:
            result_container["error"] = "Memory limit exceeded"
        except RecursionError:
            result_container["error"] = "Recursion limit exceeded"
        except Exception as exc:
            result_container["error"] = f"{type(exc).__name__}: {exc}"

    thread = threading.Thread(target=_target, daemon=True)
    thread.start()
    thread.join(timeout=timeout_ms / 1000.0)

    if thread.is_alive():
        # Thread still running = timeout. We can't kill Python threads,
        # but daemon=True ensures it won't block process exit.
        return False, None, f"Execution timed out after {timeout_ms}ms"

    if result_container["error"]:
        return False, None, result_container["error"]

    return True, result_container["result"], ""


def validate_output(result: Any, config: dict) -> tuple[bool, dict, str]:
    """
    Layer 3: validate the bool result and build the signal dict.

    Returns:
        (valid, signal_dict, error_message)
    """
    # Result must be a Python bool
    if not isinstance(result, bool):
        return False, {}, f"check() must return bool, got {type(result).__name__}"

    if not result:
        return True, {"action": "NONE"}, ""

    # Validate trading params
    action  = config.get("action", "")
    lot     = float(config.get("lot", 0))
    sl_pip  = float(config.get("sl_pip", 0))
    tp_pip  = float(config.get("tp_pip", 0))

    if action not in ("BUY", "SELL"):
        return False, {}, f"Invalid action: '{action}' (must be BUY or SELL)"

    if not (0 < lot <= 100):
        return False, {}, f"Invalid lot size: {lot} (must be 0 < lot ≤ 100)"

    if sl_pip <= 0:
        return False, {}, "Stop Loss is required (sl_pip must be > 0)"

    if tp_pip <= 0:
        return False, {}, "Take Profit is required (tp_pip must be > 0)"

    from config import MIN_TP_SL_RATIO
    if tp_pip < sl_pip * MIN_TP_SL_RATIO:
        return False, {}, f"TP/SL ratio too low: {tp_pip}/{sl_pip} < {MIN_TP_SL_RATIO}"

    return True, {
        "action": action,
        "lot":    lot,
        "sl":     sl_pip,
        "tp":     tp_pip,
    }, ""
