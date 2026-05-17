"""Tests for bridge/sandbox.py — execution sandbox (Layer 2) and output validation (Layer 3)."""

import pytest
from sandbox import run, validate_output

# ── Helpers ───────────────────────────────────────────────────────────────────

V = {"close_0": 1.08, "open_0": 1.079, "high_0": 1.081, "low_0": 1.078, "volume_0": 1000}

# ── run() — normal execution ──────────────────────────────────────────────────

class TestSandboxRun:
    def test_returns_true(self):
        code = "def check(v):\n    return True"
        ok, result, err = run(code, V)
        assert ok is True
        assert result is True
        assert err == ""

    def test_returns_false(self):
        code = "def check(v):\n    return False"
        ok, result, err = run(code, V)
        assert ok is True
        assert result is False

    def test_reads_values(self):
        code = "def check(v):\n    return v['close_0'] > 1.07"
        ok, result, err = run(code, V)
        assert ok and result is True

    def test_math_operations(self):
        code = "def check(v):\n    avg = (v['close_0'] + v['open_0']) / 2\n    return avg > 1.078"
        ok, result, err = run(code, V)
        assert ok and result is True

    def test_helper_function_available(self):
        # PA helpers are injected: is_bull should work
        code = "def check(v):\n    return is_bull(v, 0)"
        ok, result, err = run(code, V)
        assert ok, f"Sandbox error: {err}"
        assert isinstance(result, bool)

    def test_min_max_builtins(self):
        code = "def check(v):\n    return min(v['close_0'], v['open_0']) > 1.07"
        ok, result, err = run(code, V)
        assert ok and result is True

    def test_exception_in_code_is_caught(self):
        code = "def check(v):\n    return 1 / 0"
        ok, result, err = run(code, V)
        assert ok is False
        assert result is None
        assert "ZeroDivisionError" in err

    def test_key_error_is_caught(self):
        code = "def check(v):\n    return v['nonexistent_key'] > 0"
        ok, result, err = run(code, V)
        assert ok is False
        assert "KeyError" in err

# ── run() — timeout enforcement ───────────────────────────────────────────────

class TestSandboxTimeout:
    def test_infinite_loop_times_out(self):
        code = "def check(v):\n    while True:\n        pass\n    return True"
        ok, result, err = run(code, V, timeout_ms=200)
        assert ok is False
        assert result is None
        assert "timed out" in err.lower()

    def test_fast_code_completes_within_timeout(self):
        code = "def check(v):\n    return v['close_0'] > 0"
        ok, result, err = run(code, V, timeout_ms=500)
        assert ok is True

# ── run() — sandbox isolation ─────────────────────────────────────────────────

class TestSandboxIsolation:
    def test_import_blocked_at_runtime(self):
        # Even if analyzer somehow passes, runtime exec should fail
        code = "def check(v):\n    import os\n    return True"
        ok, result, err = run(code, V)
        assert ok is False

    def test_open_blocked_at_runtime(self):
        code = "def check(v):\n    open('x.txt')\n    return True"
        ok, result, err = run(code, V)
        assert ok is False

    def test_strategies_dont_share_state(self):
        # Module-level `x = 99` in code_a must not be visible in code_b
        code_a = "x = 99\ndef check(v):\n    return True"
        code_b = (
            "def check(v):\n"
            "    try:\n"
            "        _ = x\n"
            "        return False\n"  # x leaked → fail
            "    except:\n"
            "        return True\n"   # x not visible → isolated
        )
        run(code_a, V)
        ok, result, err = run(code_b, V)
        assert ok is True, f"Sandbox error: {err}"
        assert result is True

# ── validate_output() ─────────────────────────────────────────────────────────

class TestValidateOutput:
    BASE_CONFIG = {"action": "BUY", "lot": 0.1, "sl_pip": 50.0, "tp_pip": 100.0}

    def test_false_returns_none(self):
        valid, signal, err = validate_output(False, self.BASE_CONFIG)
        assert valid is True
        assert signal == {"action": "NONE"}
        assert err == ""

    def test_true_returns_buy_signal(self):
        valid, signal, err = validate_output(True, self.BASE_CONFIG)
        assert valid is True
        assert signal["action"] == "BUY"
        assert signal["lot"] == 0.1
        assert signal["sl"] == 50.0
        assert signal["tp"] == 100.0

    def test_sell_action(self):
        cfg = {**self.BASE_CONFIG, "action": "SELL"}
        valid, signal, err = validate_output(True, cfg)
        assert valid and signal["action"] == "SELL"

    def test_non_bool_result_rejected(self):
        valid, signal, err = validate_output(1, self.BASE_CONFIG)
        assert valid is False
        assert "bool" in err.lower()

    def test_none_result_rejected(self):
        valid, signal, err = validate_output(None, self.BASE_CONFIG)
        assert valid is False

    def test_string_result_rejected(self):
        valid, signal, err = validate_output("BUY", self.BASE_CONFIG)
        assert valid is False

    def test_invalid_action_rejected(self):
        cfg = {**self.BASE_CONFIG, "action": "HOLD"}
        valid, signal, err = validate_output(True, cfg)
        assert valid is False
        assert "action" in err.lower()

    def test_lot_zero_rejected(self):
        cfg = {**self.BASE_CONFIG, "lot": 0.0}
        valid, signal, err = validate_output(True, cfg)
        assert valid is False
        assert "lot" in err.lower()

    def test_lot_too_large_rejected(self):
        cfg = {**self.BASE_CONFIG, "lot": 101.0}
        valid, signal, err = validate_output(True, cfg)
        assert valid is False

    def test_sl_zero_rejected(self):
        cfg = {**self.BASE_CONFIG, "sl_pip": 0.0}
        valid, signal, err = validate_output(True, cfg)
        assert valid is False
        assert "stop loss" in err.lower()

    def test_tp_zero_rejected(self):
        cfg = {**self.BASE_CONFIG, "tp_pip": 0.0}
        valid, signal, err = validate_output(True, cfg)
        assert valid is False
        assert "take profit" in err.lower()

    def test_tp_sl_ratio_too_low_rejected(self):
        # TP/SL < 0.5 should be rejected
        cfg = {**self.BASE_CONFIG, "sl_pip": 100.0, "tp_pip": 10.0}
        valid, signal, err = validate_output(True, cfg)
        assert valid is False
        assert "ratio" in err.lower()

    def test_tp_sl_ratio_exactly_minimum_accepted(self):
        # TP = SL * 0.5 is exactly on the boundary
        cfg = {**self.BASE_CONFIG, "sl_pip": 100.0, "tp_pip": 50.0}
        valid, signal, err = validate_output(True, cfg)
        assert valid is True
