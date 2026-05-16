# PA_HELPERS is a string that gets exec()'d into the sandbox namespace.
# Claude-generated check(v) functions can call any of these freely.

PA_HELPERS = '''
# ══════════════════════════════════════════════════════════════════
# PRICE ACTION HELPER LIBRARY  —  injected into every sandbox
# All functions receive `v` (values dict from EA) as first argument.
# Candle index: 0 = current (most recent closed), 1 = previous, etc.
# ══════════════════════════════════════════════════════════════════

# ── OHLC accessors ───────────────────────────────────────────────
def O(v, i=0): return v.get(f"open_{i}",   0.0)
def H(v, i=0): return v.get(f"high_{i}",   0.0)
def L(v, i=0): return v.get(f"low_{i}",    0.0)
def C(v, i=0): return v.get(f"close_{i}",  0.0)
def Vol(v, i=0): return v.get(f"volume_{i}", 0.0)

# ── Basic candle metrics ─────────────────────────────────────────
def body(v, i=0):
    return abs(C(v,i) - O(v,i))

def upper_wick(v, i=0):
    return H(v,i) - max(O(v,i), C(v,i))

def lower_wick(v, i=0):
    return min(O(v,i), C(v,i)) - L(v,i)

def candle_range(v, i=0):
    return H(v,i) - L(v,i)

def is_bull(v, i=0):
    return C(v,i) > O(v,i)

def is_bear(v, i=0):
    return C(v,i) < O(v,i)

def body_ratio(v, i=0):
    r = candle_range(v, i)
    return body(v,i) / r if r > 0 else 0.0

def wick_ratio(v, i=0):
    return 1.0 - body_ratio(v, i)

def midpoint(v, i=0):
    return (H(v,i) + L(v,i)) / 2.0

def body_mid(v, i=0):
    return (O(v,i) + C(v,i)) / 2.0

# ── Single candle patterns ───────────────────────────────────────
def is_doji(v, i=0, threshold=0.1):
    return body_ratio(v, i) < threshold

def is_spinning_top(v, i=0):
    b  = body_ratio(v, i)
    uw = upper_wick(v, i)
    lw = lower_wick(v, i)
    r  = candle_range(v, i)
    if r == 0: return False
    return 0.1 < b < 0.35 and uw/r > 0.2 and lw/r > 0.2

def is_marubozu(v, i=0, threshold=0.95):
    return body_ratio(v, i) >= threshold

def is_hammer(v, i=0):
    b  = body(v, i)
    lw = lower_wick(v, i)
    uw = upper_wick(v, i)
    if b == 0: return False
    return lw >= b * 2.0 and uw <= b * 0.3

def is_inverted_hammer(v, i=0):
    b  = body(v, i)
    uw = upper_wick(v, i)
    lw = lower_wick(v, i)
    if b == 0: return False
    return uw >= b * 2.0 and lw <= b * 0.3

def is_shooting_star(v, i=0):
    return is_inverted_hammer(v, i) and is_bear(v, i)

def is_hanging_man(v, i=0):
    return is_hammer(v, i) and is_bear(v, i)

def is_bull_hammer(v, i=0):
    return is_hammer(v, i) and is_bull(v, i)

def is_pin_bar_bull(v, i=0):
    lw = lower_wick(v, i)
    b  = body(v, i)
    uw = upper_wick(v, i)
    r  = candle_range(v, i)
    if r == 0: return False
    return lw >= r * 0.6 and b <= r * 0.25 and uw <= r * 0.15

def is_pin_bar_bear(v, i=0):
    uw = upper_wick(v, i)
    b  = body(v, i)
    lw = lower_wick(v, i)
    r  = candle_range(v, i)
    if r == 0: return False
    return uw >= r * 0.6 and b <= r * 0.25 and lw <= r * 0.15

def is_pin_bar(v, i=0):
    return is_pin_bar_bull(v, i) or is_pin_bar_bear(v, i)

# ── Two candle patterns ──────────────────────────────────────────
def is_bull_engulfing(v):
    if not (is_bear(v,1) and is_bull(v,0)): return False
    return (body(v,0) > body(v,1)
            and H(v,0) >= H(v,1)
            and L(v,0) <= L(v,1))

def is_bear_engulfing(v):
    if not (is_bull(v,1) and is_bear(v,0)): return False
    return (body(v,0) > body(v,1)
            and H(v,0) >= H(v,1)
            and L(v,0) <= L(v,1))

def is_bull_harami(v):
    return (is_bear(v,1) and is_bull(v,0)
            and O(v,0) > C(v,1)
            and C(v,0) < O(v,1)
            and body(v,0) < body(v,1))

def is_bear_harami(v):
    return (is_bull(v,1) and is_bear(v,0)
            and O(v,0) < C(v,1)
            and C(v,0) > O(v,1)
            and body(v,0) < body(v,1))

def is_piercing(v):
    mid_prev = body_mid(v, 1)
    return (is_bear(v,1) and is_bull(v,0)
            and O(v,0) < L(v,1)
            and C(v,0) > mid_prev
            and C(v,0) < O(v,1))

def is_dark_cloud(v):
    mid_prev = body_mid(v, 1)
    return (is_bull(v,1) and is_bear(v,0)
            and O(v,0) > H(v,1)
            and C(v,0) < mid_prev
            and C(v,0) > C(v,1))

def is_tweezer_top(v):
    pt = v.get("point", 0.00001)
    return (is_bull(v,1) and is_bear(v,0)
            and abs(H(v,0) - H(v,1)) <= pt * 3)

def is_tweezer_bottom(v):
    pt = v.get("point", 0.00001)
    return (is_bear(v,1) and is_bull(v,0)
            and abs(L(v,0) - L(v,1)) <= pt * 3)

# ── Three candle patterns ────────────────────────────────────────
def is_morning_star(v):
    big_bear = is_bear(v,2) and body_ratio(v,2) > 0.6
    small    = body_ratio(v,1) < 0.3
    big_bull = is_bull(v,0)  and body_ratio(v,0) > 0.6
    gap_down = max(O(v,1), C(v,1)) < C(v,2)
    confirm  = C(v,0) > body_mid(v, 2)
    return big_bear and small and big_bull and gap_down and confirm

def is_evening_star(v):
    big_bull = is_bull(v,2) and body_ratio(v,2) > 0.6
    small    = body_ratio(v,1) < 0.3
    big_bear = is_bear(v,0)  and body_ratio(v,0) > 0.6
    gap_up   = min(O(v,1), C(v,1)) > C(v,2)
    confirm  = C(v,0) < body_mid(v, 2)
    return big_bull and small and big_bear and gap_up and confirm

def is_three_white_soldiers(v):
    return (is_bull(v,2) and is_bull(v,1) and is_bull(v,0)
            and C(v,1) > C(v,2) and C(v,0) > C(v,1)
            and O(v,1) > O(v,2) and O(v,0) > O(v,1)
            and body_ratio(v,2) > 0.5
            and body_ratio(v,1) > 0.5
            and body_ratio(v,0) > 0.5)

def is_three_black_crows(v):
    return (is_bear(v,2) and is_bear(v,1) and is_bear(v,0)
            and C(v,1) < C(v,2) and C(v,0) < C(v,1)
            and O(v,1) < O(v,2) and O(v,0) < O(v,1)
            and body_ratio(v,2) > 0.5
            and body_ratio(v,1) > 0.5
            and body_ratio(v,0) > 0.5)

def is_three_inside_up(v):
    return is_bear_harami(v) and is_bull(v,0) and C(v,0) > O(v,2)

def is_three_inside_down(v):
    return is_bull_harami(v) and is_bear(v,0) and C(v,0) < O(v,2)

# ── Market structure ─────────────────────────────────────────────
def is_higher_high(v, n=3):
    return all(H(v,i) > H(v,i+1) for i in range(n-1))

def is_lower_low(v, n=3):
    return all(L(v,i) < L(v,i+1) for i in range(n-1))

def is_higher_low(v, n=3):
    return all(L(v,i) > L(v,i+1) for i in range(n-1))

def is_lower_high(v, n=3):
    return all(H(v,i) < H(v,i+1) for i in range(n-1))

def is_uptrend(v, n=4):
    half = max(n // 2, 2)
    return is_higher_high(v, half) and is_higher_low(v, half)

def is_downtrend(v, n=4):
    half = max(n // 2, 2)
    return is_lower_high(v, half) and is_lower_low(v, half)

def is_consolidating(v, n=5):
    highs    = [H(v,i) for i in range(n)]
    lows     = [L(v,i) for i in range(n)]
    rng      = max(highs) - min(lows)
    avg_body = sum(body(v,i) for i in range(n)) / n
    return rng < avg_body * n * 0.5 if avg_body > 0 else False

# ── Breakout ─────────────────────────────────────────────────────
def is_bull_breakout(v, n=20):
    recent_high = max(H(v,i) for i in range(1, n+1))
    return C(v,0) > recent_high and is_bull(v,0)

def is_bear_breakout(v, n=20):
    recent_low = min(L(v,i) for i in range(1, n+1))
    return C(v,0) < recent_low and is_bear(v,0)

def near_round_number(v, pip_range=10):
    price   = C(v, 0)
    point   = v.get("point", 0.00001)
    step    = point * 1000
    nearest = round(price / step) * step
    return abs(price - nearest) < point * pip_range

# ── Momentum ─────────────────────────────────────────────────────
def momentum(v, n=3):
    return C(v,0) - C(v,n)

def is_accelerating_up(v, n=3):
    return all(C(v,i) > C(v,i+1) for i in range(n))

def is_accelerating_down(v, n=3):
    return all(C(v,i) < C(v,i+1) for i in range(n))

# ── Volume ───────────────────────────────────────────────────────
def is_high_volume(v, n=5, multiplier=1.5):
    if n < 1: return False
    avg = sum(Vol(v,i) for i in range(1, n+1)) / n
    return Vol(v,0) > avg * multiplier if avg > 0 else False

# ── Divergence (approximate) ─────────────────────────────────────
def is_bull_divergence(v, ind_key, n=5):
    try:
        price_ll = L(v,0) < min(L(v,i) for i in range(1, n))
        ind_vals = [v.get(f"{ind_key}_{i}", v.get(ind_key, 50)) for i in range(1, n)]
        ind_hl   = v.get(ind_key, 50) > min(ind_vals)
        return price_ll and ind_hl
    except: return False

def is_bear_divergence(v, ind_key, n=5):
    try:
        price_hh = H(v,0) > max(H(v,i) for i in range(1, n))
        ind_vals = [v.get(f"{ind_key}_{i}", v.get(ind_key, 50)) for i in range(1, n)]
        ind_lh   = v.get(ind_key, 50) < max(ind_vals)
        return price_hh and ind_lh
    except: return False
'''
