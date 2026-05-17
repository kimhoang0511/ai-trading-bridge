"""Tests for bridge/strategy.py — dispatch, handle_check, handle_stop.

handle_init() calls the Claude API so it is NOT tested here.
"""

import pytest
from unittest.mock import patch, MagicMock

# ── Import strategy with a mocked Anthropic client ───────────────────────────
# strategy.py creates `client = Anthropic(api_key=...)` at module level.
# We patch it before import so no real API call is made.

with patch("anthropic.Anthropic"):
    import strategy
    from strategy import dispatch, handle_check, handle_stop, strategies


# ── Fixtures ──────────────────────────────────────────────────────────────────

SIMPLE_CODE = "def check(v):\n    return v['ma20'] > v['ma50']\n"

BASE_CONFIG = {
    "code":       SIMPLE_CODE,
    "action":     "BUY",
    "lot":        0.1,
    "sl_pip":     50.0,
    "tp_pip":     100.0,
    "ohlc_bars":  3,
    "indicators": [{"name": "ma20"}, {"name": "ma50"}],
    "symbol":     "EURUSD",
}

SAMPLE_VALUES = {
    "close_0": 1.08, "open_0": 1.079, "high_0": 1.081, "low_0": 1.078,
    "close_1": 1.079, "open_1": 1.078, "high_1": 1.080, "low_1": 1.077,
    "close_2": 1.078, "open_2": 1.077, "high_2": 1.079, "low_2": 1.076,
    "ask": 1.0801, "bid": 1.0800, "point": 0.00001,
    "ma20": 1.0820,  # ma20 > ma50 → BUY
    "ma50": 1.0810,
}


@pytest.fixture(autouse=True)
def clean_strategies():
    """Reset global strategies dict before each test."""
    strategies.clear()
    yield
    strategies.clear()


# ── dispatch() ───────────────────────────────────────────────────────────────

class TestDispatch:
    def test_unknown_cmd_returns_none(self):
        result = dispatch({"cmd": "unknown", "sid": 0})
        assert result == {"action": "NONE"}

    def test_empty_cmd_returns_none(self):
        result = dispatch({"sid": 0})
        assert result == {"action": "NONE"}

    def test_check_cmd_routes_to_handle_check(self):
        strategies[0] = BASE_CONFIG
        result = dispatch({"cmd": "check", "sid": 0, "values": SAMPLE_VALUES})
        assert "action" in result

    def test_stop_cmd_routes_to_handle_stop(self):
        strategies[0] = BASE_CONFIG
        result = dispatch({"cmd": "stop", "sid": 0})
        assert result == {"status": "ok"}
        assert 0 not in strategies

    def test_sid_defaults_to_zero(self):
        strategies[0] = BASE_CONFIG
        result = dispatch({"cmd": "check", "values": SAMPLE_VALUES})
        assert "action" in result


# ── handle_check() ────────────────────────────────────────────────────────────

class TestHandleCheck:
    def test_no_strategy_loaded_returns_none(self):
        result = handle_check(0, {"values": SAMPLE_VALUES})
        assert result == {"action": "NONE"}

    def test_buy_signal_when_ma20_above_ma50(self):
        strategies[0] = BASE_CONFIG
        result = handle_check(0, {"values": SAMPLE_VALUES})
        assert result["action"] == "BUY"
        assert result["lot"] == 0.1
        assert result["sl"] == 50.0
        assert result["tp"] == 100.0

    def test_no_signal_when_ma20_below_ma50(self):
        strategies[0] = BASE_CONFIG
        v = {**SAMPLE_VALUES, "ma20": 1.079, "ma50": 1.082}
        result = handle_check(0, {"values": v})
        assert result["action"] == "NONE"

    def test_sell_signal(self):
        cfg = {**BASE_CONFIG, "action": "SELL",
               "code": "def check(v):\n    return v['ma20'] < v['ma50']\n"}
        strategies[0] = cfg
        v = {**SAMPLE_VALUES, "ma20": 1.079, "ma50": 1.082}
        result = handle_check(0, {"values": v})
        assert result["action"] == "SELL"

    def test_empty_values_does_not_crash(self):
        strategies[0] = BASE_CONFIG
        result = handle_check(0, {"values": {}})
        # check() will get 0.0 defaults → ma20(0) < ma50(0) → False → NONE
        assert result["action"] == "NONE"

    def test_sandbox_error_returns_none(self):
        cfg = {**BASE_CONFIG, "code": "def check(v):\n    return 1/0\n"}
        strategies[0] = cfg
        result = handle_check(0, {"values": SAMPLE_VALUES})
        assert result["action"] == "NONE"

    def test_multiple_sids_independent(self):
        strategies[0] = BASE_CONFIG
        strategies[1] = {
            **BASE_CONFIG,
            "action": "SELL",
            "code": "def check(v):\n    return v['ma20'] < v['ma50']\n",
        }
        v_buy  = {**SAMPLE_VALUES, "ma20": 1.082, "ma50": 1.080}
        v_sell = {**SAMPLE_VALUES, "ma20": 1.079, "ma50": 1.082}

        r0 = handle_check(0, {"values": v_buy})
        r1 = handle_check(1, {"values": v_sell})

        assert r0["action"] == "BUY"
        assert r1["action"] == "SELL"

    def test_non_bool_check_result_returns_none(self):
        # check() returns int, not bool → validate_output should reject
        cfg = {**BASE_CONFIG, "code": "def check(v):\n    return 1\n"}
        strategies[0] = cfg
        result = handle_check(0, {"values": SAMPLE_VALUES})
        assert result["action"] == "NONE"


# ── handle_stop() ─────────────────────────────────────────────────────────────

class TestHandleStop:
    def test_stop_removes_strategy(self):
        strategies[0] = BASE_CONFIG
        result = handle_stop(0)
        assert result == {"status": "ok"}
        assert 0 not in strategies

    def test_stop_nonexistent_sid_is_safe(self):
        result = handle_stop(99)
        assert result == {"status": "ok"}

    def test_stop_only_removes_target_sid(self):
        strategies[0] = BASE_CONFIG
        strategies[1] = BASE_CONFIG
        handle_stop(0)
        assert 0 not in strategies
        assert 1 in strategies
