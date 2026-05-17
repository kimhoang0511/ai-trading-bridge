"""Tests for bridge/pa_helpers.py — Price Action helper functions.

All functions are executed through the sandbox (same as production path).
"""

import pytest
from sandbox import run

# ── Helper to run a PA expression via sandbox ──────────────────────────────────

def pa(expr: str, v: dict) -> bool | None:
    code = f"def check(v):\n    return bool({expr})\n"
    ok, result, err = run(code, v)
    assert ok, f"Sandbox error running `{expr}`: {err}"
    return result


def pa_float(expr: str, v: dict) -> float:
    code = f"def check(v):\n    x = {expr}\n    return x > -99999\n"
    code_val = f"def check(v):\n    return float({expr}) > -99999\n"
    # Get the actual float via a comparison trick — run the raw expression
    exec_code = f"def check(v):\n    result = {expr}\n    return result > -99999\n"
    ok, _, err = run(exec_code, v)
    assert ok, f"Sandbox error: {err}"
    # Re-run to get the value itself (use a custom code)
    val_code = f"def check(v):\n    return float({expr})\n"
    ok2, result2, err2 = run(val_code, v)
    assert ok2, f"Sandbox error: {err2}"
    return result2

# ── Candle factory ────────────────────────────────────────────────────────────

def candle(o, h, l, c, i=0, vol=1000) -> dict:
    return {
        f"open_{i}":   o,
        f"high_{i}":   h,
        f"low_{i}":    l,
        f"close_{i}":  c,
        f"volume_{i}": vol,
    }

def multi(*candles) -> dict:
    """Merge multiple candle dicts (index 0=current, 1=prev, ...)."""
    v = {"point": 0.00001}
    for i, (o, h, l, c) in enumerate(candles):
        v.update(candle(o, h, l, c, i=i))
    return v

# ── OHLC accessors ────────────────────────────────────────────────────────────

class TestOHLCAccessors:
    V = multi((1.08, 1.09, 1.07, 1.085))

    def test_open(self):   assert pa("O(v, 0) == 1.08",  self.V)
    def test_high(self):   assert pa("H(v, 0) == 1.09",  self.V)
    def test_low(self):    assert pa("L(v, 0) == 1.07",  self.V)
    def test_close(self):  assert pa("C(v, 0) == 1.085", self.V)
    def test_volume(self): assert pa("Vol(v, 0) == 1000", {**self.V, "volume_0": 1000})

    def test_missing_key_returns_zero(self):
        assert pa("O(v, 9) == 0.0", self.V)

# ── Basic candle metrics ──────────────────────────────────────────────────────

class TestCandleMetrics:
    def test_body_bullish(self):
        v = multi((1.08, 1.09, 1.07, 1.085))
        assert pa("abs(body(v, 0) - 0.005) < 0.0001", v)

    def test_upper_wick(self):
        # H=1.09, max(O=1.08, C=1.085)=1.085 → wick = 0.005
        v = multi((1.08, 1.09, 1.07, 1.085))
        assert pa("abs(upper_wick(v, 0) - 0.005) < 0.0001", v)

    def test_lower_wick(self):
        # min(O=1.08, C=1.085)=1.08, L=1.07 → wick = 0.01
        v = multi((1.08, 1.09, 1.07, 1.085))
        assert pa("abs(lower_wick(v, 0) - 0.01) < 0.0001", v)

    def test_candle_range(self):
        v = multi((1.08, 1.09, 1.07, 1.085))
        assert pa("abs(candle_range(v, 0) - 0.02) < 0.0001", v)

    def test_is_bull(self):
        v = multi((1.08, 1.09, 1.07, 1.085))
        assert pa("is_bull(v, 0)", v)

    def test_is_bear(self):
        v = multi((1.085, 1.09, 1.07, 1.08))
        assert pa("is_bear(v, 0)", v)

    def test_body_ratio_marubozu(self):
        # Perfect marubozu: O=L, C=H
        v = multi((1.08, 1.09, 1.08, 1.09))
        assert pa("body_ratio(v, 0) > 0.99", v)

    def test_body_ratio_doji(self):
        # Doji: O≈C, large wicks
        v = multi((1.085, 1.09, 1.07, 1.085))
        assert pa("body_ratio(v, 0) < 0.01", v)

    def test_zero_range_body_ratio(self):
        v = multi((1.08, 1.08, 1.08, 1.08))
        assert pa("body_ratio(v, 0) == 0.0", v)

# ── Single candle patterns ─────────────────────────────────────────────────────

class TestSingleCandlePatterns:
    def test_is_doji(self):
        v = multi((1.085, 1.09, 1.07, 1.085))
        assert pa("is_doji(v, 0)", v)

    def test_not_doji(self):
        v = multi((1.08, 1.09, 1.07, 1.089))
        assert pa("not is_doji(v, 0)", v)

    def test_is_marubozu(self):
        v = multi((1.08, 1.09, 1.08, 1.09))
        assert pa("is_marubozu(v, 0)", v)

    def test_is_hammer(self):
        # Long lower wick, small body, tiny upper wick
        # O=1.088, C=1.09 (bull), L=1.08 → lower_wick=0.008, body=0.002
        v = multi((1.088, 1.0905, 1.08, 1.09))
        assert pa("is_hammer(v, 0)", v)

    def test_is_shooting_star(self):
        # Bear candle, long upper wick
        # O=1.092, C=1.088 (bear), H=1.10, L=1.087
        v = multi((1.092, 1.10, 1.087, 1.088))
        assert pa("is_shooting_star(v, 0)", v)

    def test_is_pin_bar_bull(self):
        # Long lower wick ≥60% of range, small body, tiny upper wick
        # range=0.03: L=1.07, H=1.10, O=1.098, C=1.099
        v = multi((1.098, 1.100, 1.070, 1.099))
        assert pa("is_pin_bar_bull(v, 0)", v)

    def test_is_pin_bar_bear(self):
        # Long upper wick
        # range=0.03: L=1.10, H=1.13, O=1.101, C=1.102
        v = multi((1.101, 1.130, 1.100, 1.102))
        assert pa("is_pin_bar_bear(v, 0)", v)

# ── Two candle patterns ───────────────────────────────────────────────────────

class TestTwoCandlePatterns:
    def test_bull_engulfing(self):
        # i=1 bear: O=1.09 C=1.08; i=0 bull: O=1.075 C=1.095
        v = multi(
            (1.075, 1.096, 1.074, 1.095),  # i=0 bull, engulfs
            (1.090, 1.091, 1.079, 1.080),  # i=1 bear
        )
        assert pa("is_bull_engulfing(v)", v)

    def test_bear_engulfing(self):
        v = multi(
            (1.095, 1.096, 1.074, 1.075),  # i=0 bear, engulfs
            (1.080, 1.091, 1.079, 1.090),  # i=1 bull
        )
        assert pa("is_bear_engulfing(v)", v)

    def test_not_engulfing_same_direction(self):
        v = multi(
            (1.08, 1.09, 1.07, 1.085),  # i=0 bull
            (1.08, 1.09, 1.07, 1.085),  # i=1 also bull
        )
        assert pa("not is_bull_engulfing(v)", v)

# ── Market structure ──────────────────────────────────────────────────────────

class TestMarketStructure:
    def test_is_higher_high(self):
        # Highs decreasing from past to present: H_0 > H_1 > H_2
        v = multi(
            (1.0, 1.09, 1.0, 1.0),  # i=0 highest H
            (1.0, 1.08, 1.0, 1.0),  # i=1
            (1.0, 1.07, 1.0, 1.0),  # i=2
        )
        assert pa("is_higher_high(v, 3)", v)

    def test_is_lower_low(self):
        # Lows getting lower from past: L_0 < L_1 < L_2
        v = multi(
            (1.0, 1.09, 1.06, 1.0),  # i=0 lowest L
            (1.0, 1.08, 1.07, 1.0),
            (1.0, 1.07, 1.08, 1.0),
        )
        assert pa("is_lower_low(v, 3)", v)

    def test_is_uptrend(self):
        # Uptrend: HH + HL — 4 candles, half=2 so needs HH(2) + HL(2)
        v = multi(
            (1.082, 1.09, 1.081, 1.088),  # i=0: H=1.09 > H[1]=1.08
            (1.079, 1.080, 1.078, 1.079), # i=1: H=1.08, L=1.078 > L[2]
        )
        assert pa("is_higher_high(v, 2) and is_higher_low(v, 2)", v)

    def test_is_accelerating_up(self):
        # close_0 > close_1 > close_2 > close_3
        v = {}
        for i, c in enumerate([1.09, 1.08, 1.07, 1.06]):
            v.update(candle(c - 0.001, c + 0.001, c - 0.002, c, i=i))
        assert pa("is_accelerating_up(v, 3)", v)

    def test_is_accelerating_down(self):
        # close_0 < close_1 < close_2 < close_3
        v = {}
        for i, c in enumerate([1.06, 1.07, 1.08, 1.09]):
            v.update(candle(c - 0.001, c + 0.001, c - 0.002, c, i=i))
        assert pa("is_accelerating_down(v, 3)", v)

# ── Momentum ──────────────────────────────────────────────────────────────────

class TestMomentum:
    def test_positive_momentum(self):
        v = {}
        v.update(candle(1.0, 1.1, 1.0, 1.09, i=0))
        v.update(candle(1.0, 1.1, 1.0, 1.08, i=3))
        assert pa("momentum(v, 3) > 0", v)

    def test_negative_momentum(self):
        v = {}
        v.update(candle(1.0, 1.1, 1.0, 1.07, i=0))
        v.update(candle(1.0, 1.1, 1.0, 1.09, i=3))
        assert pa("momentum(v, 3) < 0", v)

# ── Volume ────────────────────────────────────────────────────────────────────

class TestVolume:
    def test_high_volume(self):
        v = {"point": 0.00001}
        # Current volume = 3000, avg of past 5 = 1000 → ratio 3x > 1.5x
        v.update(candle(1.08, 1.09, 1.07, 1.085, i=0, vol=3000))
        for i in range(1, 6):
            v.update(candle(1.08, 1.09, 1.07, 1.085, i=i, vol=1000))
        assert pa("is_high_volume(v, 5)", v)

    def test_normal_volume(self):
        v = {"point": 0.00001}
        for i in range(6):
            v.update(candle(1.08, 1.09, 1.07, 1.085, i=i, vol=1000))
        assert pa("not is_high_volume(v, 5)", v)
