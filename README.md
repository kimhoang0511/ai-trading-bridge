# AI Trading EA — Project Journal

> Natural language → trading strategy → MT4/MT5 execution  
> A Python Bridge that lets users describe trading strategies in plain text and executes them automatically.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture](#2-architecture)
3. [File Structure](#3-file-structure)
4. [Setup & Installation](#4-setup--installation)
5. [Component Reference](#5-component-reference)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Key Design Decisions](#7-key-design-decisions)
8. [Known Limitations](#8-known-limitations)
9. [Roadmap](#9-roadmap)

---

## 1. Project Overview

### What It Does

Users type a trading strategy in natural language. The EA executes it automatically on MT4/MT5.

```
User: "Buy EURUSD when MA20 crosses above MA50, RSI14 < 65, lot 0.1, SL 50 pips, TP 100 pips"
  ↓
Claude API → parses intent → generates Python check(v) function + indicator list
  ↓
EA collects OHLC + indicators every new candle → sends to Bridge
  ↓
Bridge evaluates check(v) → returns BUY / SELL / NONE
  ↓
EA places order on MT4/MT5
```

### Selling Model

- Published as a single EA on MQL5 Market
- Each buyer runs the EA locally on their own machine
- Python Bridge runs locally alongside MT4
- Up to 5 strategies simultaneously per user (S1–S5 params)
- Each strategy can trade a different symbol and timeframe

---

## 2. Architecture

### Flow Diagram

```
┌─────────────────────────────────────────────────────────┐
│  USER MACHINE (local)                                    │
│                                                          │
│  MT4/MT5                                                 │
│  ┌──────────────────────────────────────┐               │
│  │  AI_EA.mq4                           │               │
│  │  ├── Strategy S1: EURUSD H1         │               │
│  │  ├── Strategy S2: GBPUSD H4         │               │
│  │  ├── Strategy S3: XAUUSD D1         │               │
│  │  └── (S4, S5 empty = disabled)      │               │
│  └──────────────┬───────────────────────┘               │
│                 │ Named Pipe (1–5ms)                     │
│  ┌──────────────▼───────────────────────┐               │
│  │  Python Bridge (bridge/main.py)      │               │
│  │  ├── Pipe server (1 connection)      │               │
│  │  ├── strategies{} dict               │               │
│  │  │   ├── sid=0 → {code, config}     │               │
│  │  │   ├── sid=1 → {code, config}     │               │
│  │  │   └── sid=2 → {code, config}     │               │
│  │  ├── PA Helpers (injected sandbox)   │               │
│  │  └── Static analyzer + sandbox      │               │
│  └──────────────┬───────────────────────┘               │
│                 │ HTTPS (init only)                      │
└─────────────────┼───────────────────────────────────────┘
                  │
        ┌─────────▼──────────┐
        │   Claude API       │
        │   (Anthropic)      │
        │   Parse prompt →   │
        │   generate code    │
        └────────────────────┘
```

### Communication Protocol

| Phase | Direction | Transport | Frequency |
|-------|-----------|-----------|-----------|
| Init | EA → Bridge → Claude API | Named Pipe + HTTPS | Once per strategy |
| Check | EA → Bridge | Named Pipe | Once per new candle |
| Signal | Bridge → EA | Named Pipe | Once per new candle |

### Message Format

**Init request** (EA → Bridge):
```json
{
  "cmd": "init",
  "sid": 0,
  "prompt": "Buy EURUSD when MA20 crosses MA50",
  "symbol": "EURUSD",
  "tf": 60,
  "lot": 0.1,
  "sl": 50,
  "tp": 100
}
```

**Init response** (Bridge → EA):
```json
{
  "status": "ok",
  "indicators": [
    {"name": "ma20", "type": "iMA", "period": 20, "method": 1, "applied": 0, "shift": 0},
    {"name": "ma20_prev", "type": "iMA", "period": 20, "method": 1, "applied": 0, "shift": 1},
    {"name": "ma50", "type": "iMA", "period": 50, "method": 1, "applied": 0, "shift": 0},
    {"name": "ma50_prev", "type": "iMA", "period": 50, "method": 1, "applied": 0, "shift": 1},
    {"name": "rsi14", "type": "iRSI", "period": 14, "applied": 0, "shift": 0}
  ],
  "ohlc_bars": 3
}
```

**Check request** (EA → Bridge):
```json
{
  "cmd": "check",
  "sid": 0,
  "values": {
    "open_0": 1.08210, "high_0": 1.08350, "low_0": 1.08180, "close_0": 1.08290, "volume_0": 1234,
    "open_1": 1.08100, "high_1": 1.08220, "low_1": 1.08050, "close_1": 1.08200, "volume_1": 987,
    "ask": 1.08295, "bid": 1.08290, "point": 0.00001,
    "ma20": 1.08230, "ma20_prev": 1.08190,
    "ma50": 1.08215, "ma50_prev": 1.08220,
    "rsi14": 58.3
  }
}
```

**Signal response** (Bridge → EA):
```json
{"action": "BUY", "lot": 0.1, "sl": 50, "tp": 100}
```
or
```json
{"action": "NONE"}
```

---

## 3. File Structure

```
ai-trading-bridge/
│
├── README.md                    ← This file
│
├── bridge/
│   ├── main.py                  ← Entry point — run this to start Bridge
│   ├── bridge.py                ← Named Pipe server
│   ├── strategy.py              ← Strategy management (init, check, dispatch)
│   ├── pa_helpers.py            ← Price Action helper functions (injected into sandbox)
│   ├── analyzer.py              ← Static code analysis (security layer 1)
│   ├── sandbox.py               ← Safe code execution (security layer 2)
│   ├── config.py                ← Configuration (API key, pipe names, limits)
│   └── requirements.txt         ← Python dependencies
│
├── mql4/
│   └── AI_EA.mq4               ← MQL4 Expert Advisor (compile in MetaEditor)
│
└── docs/
    ├── INDICATORS.md            ← All supported MT4 indicators + params
    ├── PA_PATTERNS.md           ← All supported Price Action patterns
    └── STRATEGY_EXAMPLES.md    ← Example prompts and generated code
```

---

## 4. Setup & Installation

### Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Python | 3.10+ | Windows only (Named Pipe) |
| MT4 or MT5 | Any recent | MetaEditor included |
| Anthropic API key | — | https://console.anthropic.com |
| pywin32 | 306+ | For Named Pipe |

### Step 1 — Python environment

```bash
cd ai-trading-bridge/bridge
pip install -r requirements.txt
```

### Step 2 — Configure API key

Edit `bridge/config.py`:
```python
ANTHROPIC_API_KEY = "sk-ant-..."   # your key here
```

Or set environment variable:
```bash
set ANTHROPIC_API_KEY=sk-ant-...
```

### Step 3 — Start the Bridge

```bash
cd ai-trading-bridge/bridge
python main.py
```

Expected output:
```
[Bridge] PA Helpers loaded
[Bridge] Pipe server started
[Bridge] Waiting for EA on \\.\pipe\ea_to_bridge ...
```

### Step 4 — Compile the EA

1. Open MetaEditor (F4 in MT4)
2. Open `mql4/AI_EA.mq4`
3. Press F7 to compile
4. No errors → ready

### Step 5 — Configure EA in MT4

1. Open a chart
2. Drag `AI_EA` from Navigator onto the chart
3. Set parameters:

```
S1_Prompt = "Buy EURUSD when MA20 crosses above MA50 and RSI14 < 65"
S1_Symbol = "EURUSD"
S1_TF     = 60       (60=H1, 240=H4, 1440=D1)
S1_Lot    = 0.1
S1_SL     = 50
S1_TP     = 100

S2_Prompt = "Sell GBPUSD when RSI > 70 and price touches BB upper"
S2_Symbol = "GBPUSD"
S2_TF     = 240
S2_Lot    = 0.05
S2_SL     = 40
S2_TP     = 80

S3_Prompt = ""  (leave empty to disable)
```

4. Enable "Allow DLL imports" if needed
5. Check "Allow WebRequest" is not needed (using Named Pipe)

### Step 6 — Verify connection

Bridge terminal should show:
```
[Bridge] EA connected!
[S0] EURUSD: Parsing "Buy EURUSD when MA20 crosses above MA50..."
[S0] Strategy loaded OK. Indicators: ma20, ma20_prev, ma50, ma50_prev, rsi14
[S1] GBPUSD: Parsing "Sell GBPUSD when RSI > 70..."
[S1] Strategy loaded OK. Indicators: rsi14, bb_upper
```

---

## 5. Component Reference

### bridge/config.py

```python
ANTHROPIC_API_KEY = ""           # Required
ANTHROPIC_MODEL   = "claude-sonnet-4-20250514"
MAX_TOKENS        = 1000
MAX_STRATEGIES    = 5            # Match EA MAX_STRATEGIES
PIPE_EA_TO_BRIDGE = r"\\.\pipe\ea_to_bridge"
PIPE_BRIDGE_TO_EA = r"\\.\pipe\bridge_to_ea"
SANDBOX_TIMEOUT_MS = 100
MAX_CODE_LENGTH    = 2000
OHLC_BARS_DEFAULT  = 5
OHLC_BARS_MAX      = 50
```

### Indicator Types Supported

All MT4 built-in indicators via dynamic mapping:

| Type | Params | Notes |
|------|--------|-------|
| `iMA` | period, method(0-3), applied, ma_shift, shift | method: 0=SMA 1=EMA 2=SMMA 3=LWMA |
| `iRSI` | period, applied, shift | |
| `iMACD` | fast, slow, signal, applied, line(0=main,1=signal), shift | |
| `iBands` | period, deviation, ma_shift, applied, line(0=main,1=upper,2=lower), shift | |
| `iStochastic` | kperiod, dperiod, slowing, method, line(0=K,1=D), shift | |
| `iADX` | period, applied, line(0=ADX,1=DI+,2=DI-), shift | |
| `iCCI` | period, applied, shift | |
| `iATR` | period, shift | |
| `iSAR` | step, maximum, shift | |
| `iWPR` | period, shift | |
| `iMomentum` | period, applied, shift | |
| `iAlligator` | jaw_period, jaw_shift, teeth_period, teeth_shift, lips_period, lips_shift, method, applied, line(0=jaw,1=teeth,2=lips), shift | |
| `iIchimoku` | tenkan, kijun, senkou, line(0-4), shift | |
| `iMFI` | period, shift | |
| `iOBV` | applied, shift | |
| `iForce` | period, method, applied, shift | |
| `iATR` | period, shift | |
| `iFractals` | line(0=upper,1=lower), shift | |
| `iHighest` | period, shift | Returns price of highest high |
| `iLowest` | period, shift | Returns price of lowest low |
| `iClose/iOpen/iHigh/iLow` | shift | Raw price data |
| `iVolume` | shift | |
| `iCustom` | custom_name, buffer_index, custom_p[0..5], shift | Any installed custom indicator |
| `Ask/Bid/Spread` | — | Current market prices |

### PA Helper Functions

Injected into sandbox — available in all `check(v)` functions:

**Basic candle:**
```python
O(v, i)          # open of candle i
H(v, i)          # high
L(v, i)          # low  
C(v, i)          # close
body(v, i)       # abs(close - open)
upper_wick(v, i) # high - max(open, close)
lower_wick(v, i) # min(open, close) - low
candle_range(v, i) # high - low
is_bull(v, i)    # close > open
is_bear(v, i)    # close < open
body_ratio(v, i) # body / range
```

**Single candle patterns:**
```python
is_doji(v, i)
is_spinning_top(v, i)
is_marubozu(v, i)
is_hammer(v, i)
is_inverted_hammer(v, i)
is_shooting_star(v, i)
is_hanging_man(v, i)
is_bull_hammer(v, i)
is_pin_bar_bull(v, i)
is_pin_bar_bear(v, i)
is_pin_bar(v, i)
```

**Two candle patterns:**
```python
is_bull_engulfing(v)
is_bear_engulfing(v)
is_bull_harami(v)
is_bear_harami(v)
is_piercing(v)
is_dark_cloud(v)
is_tweezer_top(v)
is_tweezer_bottom(v)
```

**Three candle patterns:**
```python
is_morning_star(v)
is_evening_star(v)
is_three_white_soldiers(v)
is_three_black_crows(v)
is_three_inside_up(v)
is_three_inside_down(v)
```

**Market structure:**
```python
is_higher_high(v, n=3)
is_lower_low(v, n=3)
is_higher_low(v, n=3)
is_lower_high(v, n=3)
is_uptrend(v, n=4)
is_downtrend(v, n=4)
is_consolidating(v, n=5)
```

**Breakout & momentum:**
```python
is_bull_breakout(v, n=20)    # close > highest N bars
is_bear_breakout(v, n=20)    # close < lowest N bars
near_round_number(v, pip_range=10)
momentum(v, n=3)
is_accelerating_up(v, n=3)
is_accelerating_down(v, n=3)
```

**Divergence (approximate):**
```python
is_bull_divergence(v, ind_key, n=5)
is_bear_divergence(v, ind_key, n=5)
```

### Security Layers

**Layer 1 — Static Analysis** (`analyzer.py`):
- AST parse — rejects syntax errors
- Blacklist: `import`, `exec`, `open`, `os`, `sys`, `__import__`, all dunder attributes
- Regex scan: `chr()`, `base64`, `eval()`, `__class__`
- Structure check: must contain `def check(v): ... return bool`
- Length limit: max 2000 characters

**Layer 2 — Sandbox Execution** (`sandbox.py`):
- `__builtins__` stripped to safe math/logic only
- Thread-local sandbox (no shared state between strategies)
- 100ms timeout per execution
- All exceptions caught and logged

**Layer 3 — Output Validation** (`strategy.py`):
- Result must be `bool` (not None, int, string)
- `lot` must be 0 < lot ≤ 100
- `sl_pip` must be > 0 (stop loss mandatory)
- `tp_pip` must be > 0 (take profit mandatory)
- TP/SL ratio ≥ 0.5

---

## 6. Implementation Checklist

### Phase 1 — Core Bridge

- [ ] `bridge/config.py` — API key, pipe names, limits
- [ ] `bridge/pa_helpers.py` — all PA functions as a string constant
- [ ] `bridge/analyzer.py` — static analysis (AST + regex)
- [ ] `bridge/sandbox.py` — thread-local sandbox + timeout
- [ ] `bridge/strategy.py` — handle_init(), handle_check(), dispatch()
- [ ] `bridge/bridge.py` — Named Pipe server (single connection loop)
- [ ] `bridge/main.py` — entry point, startup banner
- [ ] `bridge/requirements.txt`

### Phase 2 — MQL4 EA

- [ ] Strategy struct (prompt, symbol, tf, lot, sl, tp, inds[], ohlc_bars, last_bar)
- [ ] LoadStrategies() — parse S1..S5 extern params
- [ ] OnInit() — open pipe, init all active strategies
- [ ] ParseStrategyConfig() — parse Bridge response (indicators list)
- [ ] CalcAny() — universal indicator calculator (all MT4 built-ins)
- [ ] BuildValues() — build JSON payload (OHLC + indicators)
- [ ] OnTick() — check new candle per strategy, send/receive
- [ ] HandleSignal() — place order with strategy-specific magic number
- [ ] PipeSend() / PipeRecv() — pipe I/O helpers
- [ ] OnDeinit() — send stop, close pipes

### Phase 3 — Testing

- [ ] Test with 1 strategy (MA crossover)
- [ ] Test with 3 strategies simultaneously
- [ ] Test security: inject dangerous code in prompt
- [ ] Test timeout: strategy with infinite loop
- [ ] Test with PA patterns (engulfing, pin bar)
- [ ] Benchmark: latency per candle with 5 strategies

### Phase 4 — Packaging (for MQL5 Market)

- [ ] Bundle Python Bridge as .exe (PyInstaller)
- [ ] Write user setup guide (1-page PDF)
- [ ] Record demo video
- [ ] Submit to MQL5 Market

---

## 7. Key Design Decisions

### Why Named Pipe instead of HTTP?

HTTP WebRequest in MT4 creates a new TCP connection per request (~20–50ms overhead). Named Pipe is a kernel-level IPC mechanism — connection stays open, latency ~1–5ms. For per-candle execution this is 10× faster.

### Why Claude generates `def check(v)` code instead of a condition string?

A condition string (`"ma20 > ma50 and rsi14 < 65"`) handles simple indicator logic but fails for Price Action (engulfing candles, trend structure, momentum sequences). A full Python function lets Claude express any logic, including multi-bar comparisons and helper function calls.

### Why PA helpers are injected instead of imported?

The sandbox blocks all `import` statements for security. Injecting PA_HELPERS via `exec()` into the sandbox namespace makes functions available without import. The base sandbox is built once at startup; each request gets a thread-local copy.

### Why StrategyID (sid) instead of per-chart pipes?

A single pipe connection is simpler for users to set up (no port conflicts, no firewall issues). Each message carries a `sid` field so Bridge can route to the correct strategy's config and code. Magic numbers (`88800 + sid`) keep orders from different strategies separate in MT4's order manager.

### Why one EA instead of multiple EA instances?

Users buying from MQL5 Market get one `.ex4` file. Running multiple copies of the same EA is confusing and increases support burden. Embedding up to 5 strategy slots (S1–S5) in a single EA is cleaner — users just leave slots empty to disable them.

---

## 8. Known Limitations

| Limitation | Severity | Workaround |
|------------|----------|------------|
| Windows only (Named Pipe) | Medium | Linux users can swap for Unix socket |
| 5 strategy slots max | Low | Increase MAX_STRATEGIES constant |
| No trailing stop loss | Medium | Implement in EA separately (no Bridge needed) |
| No partial close | Medium | Implement in EA separately |
| No exit condition | Medium | Add `check_exit(v)` alongside `check_entry(v)` |
| Divergence is approximate | Low | Use exact swing detection for precision |
| Dynamic trendlines | High | Not feasible without ML model |
| Claude API latency on init | Low | Only runs once, not on every candle |
| Named Pipe: 1 EA at a time | — | By design — 1 user, 1 EA, many strategies |

---

## 9. Roadmap

### v1.0 — MVP (current scope)
- [x] Architecture design
- [x] PA Helpers library
- [x] Security sandbox
- [ ] Full implementation
- [ ] Basic testing

### v1.1 — Exit conditions
- [ ] `check_exit(v)` alongside `check_entry(v)`
- [ ] Bridge returns `{"entry": bool, "exit": bool}`
- [ ] EA closes open orders on exit signal

### v1.2 — Order management
- [ ] Trailing stop loss (EA-side, no Bridge needed)
- [ ] Partial close (EA-side)
- [ ] Break-even (EA-side)

### v1.3 — Packaging
- [ ] PyInstaller → single `.exe` for Bridge
- [ ] Auto-updater for Bridge
- [ ] License key validation
- [ ] Usage analytics (opt-in)

### v2.0 — Server mode
- [ ] Bridge moves to cloud server
- [ ] EA communicates via HTTPS instead of Named Pipe
- [ ] Multi-user support
- [ ] Web dashboard for strategy management

---

*Last updated: generated from design session*  
*Stack: Python 3.10+, MQL4, Anthropic Claude API, Windows Named Pipe*
