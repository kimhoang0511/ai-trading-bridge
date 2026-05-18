"""
AI Bridge — License Backend
POST /register  — đăng ký / cập nhật user từ AI_Bridge.DLL
GET  /health    — health check

Request body (JSON):
  {"account_number":"12345678","server_broker":"ICMarkets-Live","license_type":"DEMO"}

Response (JSON):
  {"status":"ok","token":"eyJ...","license_type":"DEMO"}
  {"status":"error","message":"..."}
"""

import asyncio
import logging
import os
import time
from datetime import datetime, timezone

import anthropic
import uvicorn
from fastapi import FastAPI, Depends, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from auth import create_token, decode_token
from config import HOST, PORT
from database import SessionLocal, User, Strategy, init_db, get_db

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

VALID_LICENSES = {"DEMO", "FULL", "TIME"}

ws_ea_clients:   dict = {}   # account_number → WebSocket (AI_Bridge.cpp DLL)
ws_chat_clients: dict = {}   # account_number → WebSocket (Frontend)

# ── Server-side conversation history (prevents client history injection) ──────
_conv_store: dict = {}          # account_number → [{"role", "content"}, ...]
strategy_store: dict = {}       # account_number → {sid: {prompt,lot,sl,tp,tf,action,symbol}}
_CONV_MAX     = 20              # max messages kept per account
_MSG_MAX_LEN  = 2000            # max chars per user message
_RATE_WINDOW  = 60              # seconds
_RATE_LIMIT   = 20              # max requests per account per window
_rate_counters: dict = {}       # account_number → [timestamp, ...]
_last_activity: dict = {}       # account_number → last seen time.time()
_STALE_TTL    = 3600            # evict accounts idle for >1 hour

_claude: "anthropic.AsyncAnthropic | None" = None

VALID_OPS        = {"add", "update", "delete"}
VALID_ORDER_OPS  = {"order_open", "order_close", "order_close_all", "order_modify", "order_list",
                    "order_history_last", "order_history_48h", "market_query"}
VALID_SID        = range(0, 5)        # slots 0-4
VALID_TFS        = {0, 1, 5, 15, 30, 60, 240, 1440, 10080}
CHAT_ORDER_MAGIC = 20250518           # magic number for chat-opened orders

_ea_pending: dict = {}                # account_number → asyncio.Future (order request/response)
_account_locks: dict = {}             # account_number → asyncio.Lock (prevent concurrent CRUD)
_context_cache: dict = {}             # account_number → (version_key, context_str)
_WS_MSG_MAX_BYTES = 65_536            # 64 KB hard limit per WS message


def _conv_get(account: str) -> list:
    return _conv_store.get(account, [])


def _conv_append(account: str, role: str, content: str) -> None:
    h = _conv_store.setdefault(account, [])
    h.append({"role": role, "content": content})
    if len(h) > _CONV_MAX:
        _conv_store[account] = h[-_CONV_MAX:]
    _last_activity[account] = time.time()


def _conv_update_last_assistant(account: str, new_content: str) -> None:
    """Replace the most recent assistant message in history (used after order execution)."""
    hist = _conv_store.get(account, [])
    for i in range(len(hist) - 1, -1, -1):
        if hist[i]["role"] == "assistant":
            hist[i]["content"] = new_content
            return


def _strategy_store_save(account: str, sid: int, data: dict) -> None:
    strategy_store.setdefault(account, {})[sid] = data
    _context_cache.pop(account, None)


def _strategy_store_delete(account: str, sid: int) -> None:
    strategy_store.get(account, {}).pop(sid, None)
    _context_cache.pop(account, None)


def _strategy_context(account: str) -> str:
    """Build a strategy summary string to inject into Claude's system prompt (cached)."""
    if account in _context_cache:
        return _context_cache[account]
    ss = strategy_store.get(account, {})
    if not ss:
        result = "Current strategies in EA: none configured yet."
        _context_cache[account] = result
        return result
    tf_map = {0:"auto",1:"M1",5:"M5",15:"M15",30:"M30",60:"H1",240:"H4",1440:"D1",10080:"W1"}
    lines = ["Current strategies in EA:"]
    for sid in sorted(ss):
        s       = ss[sid]
        tf      = tf_map.get(int(s.get("tf", 0)), str(s.get("tf", 0)))
        enabled = s.get("enabled", True)
        status  = "ON" if enabled else "OFF"
        lines.append(
            f"  S{sid+1} (sid={sid}) [{status}]: {s.get('action','?')} {s.get('symbol','?')} {tf}"
            f" | lot={s.get('lot',0.1)} SL={s.get('sl',50)} TP={s.get('tp',100)}"
            f" | prompt: \"{s.get('prompt','')[:80]}\""
        )
    result = "\n".join(lines)
    _context_cache[account] = result
    return result


def _rate_check(account: str) -> bool:
    """Return True if under limit, False if exceeded."""
    now = time.time()
    ts  = _rate_counters.setdefault(account, [])
    # Remove timestamps older than the window
    _rate_counters[account] = [t for t in ts if now - t < _RATE_WINDOW]
    if len(_rate_counters[account]) >= _RATE_LIMIT:
        return False
    _rate_counters[account].append(now)
    return True

CLAUDE_API_KEY    = os.getenv("CLAUDE_API_KEY",    "")
FRONTEND_URL      = os.getenv("FRONTEND_URL",     "http://192.168.21.1:3000")
CLAUDE_CHAT_MODEL      = os.getenv("CLAUDE_CHAT_MODEL",      "claude-haiku-4-5")
CLAUDE_PARSE_MODEL     = os.getenv("CLAUDE_PARSE_MODEL",     "claude-sonnet-4-6")
CLAUDE_CHAT_MAX_TOKENS = int(os.getenv("CLAUDE_CHAT_MAX_TOKENS",  "2048"))
CLAUDE_PARSE_MAX_TOKENS= int(os.getenv("CLAUDE_PARSE_MAX_TOKENS", "2000"))

app = FastAPI(title="AI Bridge License Server", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


async def _cleanup_stale():
    """Background task: evict accounts that have been idle longer than _STALE_TTL."""
    while True:
        await asyncio.sleep(600)
        now   = time.time()
        stale = [a for a, t in list(_last_activity.items()) if now - t > _STALE_TTL]
        for a in stale:
            _conv_store.pop(a, None)
            strategy_store.pop(a, None)
            _rate_counters.pop(a, None)
            _last_activity.pop(a, None)
            _context_cache.pop(a, None)
            _account_locks.pop(a, None)
        # Also prune _rate_counters keys for accounts that never appeared in _last_activity
        for a in list(_rate_counters.keys()):
            if a not in _last_activity:
                _rate_counters.pop(a, None)
        if stale:
            logger.info(f"Evicted {len(stale)} stale accounts: {stale}")


@app.on_event("startup")
async def on_startup():
    global _claude
    init_db()
    _claude = anthropic.AsyncAnthropic(api_key=CLAUDE_API_KEY)
    asyncio.create_task(_cleanup_stale())
    logger.info(f"License server started — http://{HOST}:{PORT}")


# ── Auth helper ───────────────────────────────────────────────────────────────

def _verify_account(token: str, db) -> "User":
    """Decode token → verify account+server exist in DB. Raises HTTPException on failure."""
    from fastapi import HTTPException
    if not token:
        raise HTTPException(status_code=401, detail="Missing token")

    if token.startswith("d."):
        # Dev token: XOR decode to extract account number
        try:
            hex_part = token[2:]
            key = 0x5B
            raw = bytes(
                int(hex_part[i:i+2], 16) ^ ((key + (i // 2) * 7) & 0xFF)
                for i in range(0, len(hex_part), 2)
            ).decode("ascii")
            account_number = str(int(raw.split(":")[0]))
        except Exception:
            raise HTTPException(status_code=401, detail="Invalid token")
        user = db.query(User).filter(User.account_number == account_number).first()
    else:
        try:
            payload = decode_token(token)
        except Exception:
            raise HTTPException(status_code=401, detail="Invalid or expired token")
        user = db.query(User).filter(
            User.account_number == payload["account_number"],
            User.server_broker  == payload["server_broker"],
        ).first()

    if not user:
        raise HTTPException(status_code=404, detail="Account not registered")
    return user


# ── Health check ──────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


# ── Register endpoint ─────────────────────────────────────────────────────────

@app.post("/register")
async def register(request: Request, db: Session = Depends(get_db)):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"status": "error", "message": "Invalid JSON body"}, status_code=400)

    account_number = str(body.get("account_number", "")).strip()
    server_broker  = str(body.get("server_broker",  "")).strip()
    license_type   = str(body.get("license_type",   "")).strip().upper()

    # ── Validate ──────────────────────────────────────────────────────────
    if not account_number or not server_broker:
        return JSONResponse(
            {"status": "error", "message": "Missing account_number or server_broker"},
            status_code=400,
        )

    if license_type not in VALID_LICENSES:
        return JSONResponse(
            {"status": "error", "message": f"Invalid license_type '{license_type}'. Must be DEMO, FULL or TIME."},
            status_code=400,
        )

    # ── Upsert ────────────────────────────────────────────────────────────
    token = create_token(account_number, server_broker, license_type)
    now   = datetime.now(timezone.utc)

    user = db.query(User).filter(
        User.account_number == account_number,
        User.server_broker  == server_broker,
    ).first()

    if user is None:
        user = User(
            account_number=account_number,
            server_broker=server_broker,
            license_type=license_type,
            active_date=now,
            token=token,
        )
        db.add(user)
        db.commit()
        logger.info(f"NEW  {account_number}@{server_broker} [{license_type}]")
    else:
        if user.license_type != license_type:
            logger.info(f"UPD  {account_number}@{server_broker} {user.license_type}→{license_type}")
            user.license_type = license_type
        user.token      = token
        user.updated_at = now
        db.commit()
        logger.info(f"OK   {account_number}@{server_broker} [{license_type}]")

    return {"status": "ok", "token": token, "license_type": license_type}


# ── Verify token ──────────────────────────────────────────────────────────────

@app.get("/verify")
def verify(token: str, db: Session = Depends(get_db)):
    # Dev token: "d.{xor_hex}" — decode account number then verify in DB
    if token.startswith("d."):
        try:
            hex_part = token[2:]
            key = 0x5B
            raw = bytes(
                int(hex_part[i:i+2], 16) ^ ((key + (i // 2) * 7) & 0xFF)
                for i in range(0, len(hex_part), 2)
            ).decode("ascii")
            account = int(raw.split(":")[0])
        except Exception:
            return JSONResponse({"status": "error", "message": "Invalid token"}, status_code=401)

        # Verify account tồn tại trong DB
        user = db.query(User).filter(User.account_number == account).first()
        if not user:
            return JSONResponse({"status": "error", "message": "Account not registered"}, status_code=404)

        return {
            "status":         "ok",
            "account_number": user.account_number,
            "server_broker":  user.server_broker,
            "license_type":   user.license_type,
            "active_date":    user.active_date.isoformat() if user.active_date else None,
        }

    try:
        payload = decode_token(token)
    except Exception:
        return JSONResponse({"status": "error", "message": "Invalid or expired token"}, status_code=401)

    user = db.query(User).filter(
        User.account_number == payload["account_number"],
        User.server_broker  == payload["server_broker"],
    ).first()

    if not user:
        return JSONResponse({"status": "error", "message": "User not found"}, status_code=404)

    return {
        "status":         "ok",
        "account_number": user.account_number,
        "server_broker":  user.server_broker,
        "license_type":   user.license_type,
        "active_date":    user.active_date.isoformat() if user.active_date else None,
    }


# ── Strategy init — parse prompt via Claude ───────────────────────────────────

INIT_SYSTEM_PROMPT = """You are a trading strategy parser. Convert a natural language trading instruction into a JSON config.

OUTPUT FORMAT (return ONLY valid JSON, no markdown, no explanation):
{
  "action": "BUY",
  "symbol": "EURUSD",
  "tf": 60,
  "lot": 0.1,
  "sl_pip": 50,
  "tp_pip": 100,
  "ohlc_bars": 3,
  "indicators": [
    {"name":"ma20","type":"iMA","period":20,"method":1,"applied":0,"shift":0},
    {"name":"ma20_prev","type":"iMA","period":20,"method":1,"applied":0,"shift":1},
    {"name":"ma50","type":"iMA","period":50,"method":1,"applied":0,"shift":0},
    {"name":"ma50_prev","type":"iMA","period":50,"method":1,"applied":0,"shift":1},
    {"name":"rsi14","type":"iRSI","period":14,"applied":0,"shift":0}
  ],
  "condition": {
    "type": "AND",
    "args": [
      {"type":"AND","args":[
        {"type":"CMP","left":"ma20","op":">","right":"ma50"},
        {"type":"CMP","left":"ma20_prev","op":"<","right":"ma50_prev"}
      ]},
      {"type":"CMP","left":"rsi14","op":"<","right":65}
    ]
  },
  "exit_condition": {
    "type": "AND",
    "args": [
      {"type":"CMP","left":"ma20","op":"<","right":"ma50"},
      {"type":"CMP","left":"ma20_prev","op":">","right":"ma50_prev"}
    ]
  }
}

INDICATOR TYPES and REQUIRED FIELDS:
- iMA:         {"name":"ma20","type":"iMA","period":20,"method":1,"applied":0,"shift":0}
               method: 0=SMA,1=EMA,2=SMMA,3=LWMA | applied: 0=Close,1=Open,2=High,3=Low
- iRSI:        {"name":"rsi14","type":"iRSI","period":14,"applied":0,"shift":0}
- iCCI:        {"name":"cci14","type":"iCCI","period":14,"applied":0,"shift":0}
- iWPR:        {"name":"wpr14","type":"iWPR","period":14,"shift":0}
- iMomentum:   {"name":"mom14","type":"iMomentum","period":14,"applied":0,"shift":0}
- iATR:        {"name":"atr14","type":"iATR","period":14,"shift":0}
- iADX:        {"name":"adx14","type":"iADX","period":14,"applied":0,"line":0,"shift":0}
               line: 0=ADX value, 1=+DI, 2=-DI. ALWAYS set "line" explicitly.
- iMACD:       {"name":"macd_main","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"line":0,"shift":0}
               line: 0=main, 1=signal. ALWAYS set "line". For crossover: TWO entries (line=0 + line=1).
- iBands:      {"name":"bb20_upper","type":"iBands","period":20,"deviation":2.0,"method":0,"applied":0,"line":1,"shift":0}
               line: 0=middle, 1=upper, 2=lower. ALWAYS set "line". One entry per band needed.
- iStochastic: {"name":"sto_k","type":"iStochastic","kperiod":5,"dperiod":3,"slowing":3,"method":0,"line":0,"shift":0}
               line: 0=%K (main), 1=%D (signal). ALWAYS set "line" explicitly.
- iSAR:        {"name":"sar","type":"iSAR","step":0.02,"maximum":0.2,"shift":0}
- iAlligator:  {"name":"alli_jaw","type":"iAlligator","p1":13,"s1":8,"p2":8,"s2":5,"p3":5,"s3":3,"method":1,"applied":4,"line":1,"shift":0}
               line: 1=Jaw, 2=Teeth, 3=Lips. ALWAYS set "line". One entry per line needed.
- iIchimoku:   {"name":"ichi_tenkan","type":"iIchimoku","p1":9,"p2":26,"p3":52,"line":1,"shift":0}
               line: 1=Tenkan, 2=Kijun, 3=Senkou A, 4=Senkou B, 5=Chikou. ALWAYS set "line".

CONDITION TYPES:
- {"type":"AND","args":[...]}
- {"type":"OR","args":[...]}
- {"type":"NOT","arg":{...}}
- {"type":"CMP","left":"var_name"|number|EXPR,"op":">/</>=/<=/==/!=","right":"var_name"|number|EXPR}
- {"type":"FN","name":"fn_name","params":{"i":0,"n":3}}
- {"type":"EXPR","op":"+|-|*|/|abs","left":"var_name"|number|EXPR,"right":"var_name"|number|EXPR}
  EXPR computes arithmetic on indicator values or literals. Use inside CMP left/right.
  abs is unary — only "left" needed: {"type":"EXPR","op":"abs","left":{...}}
  Examples:
    (ema20 - ema50) > 10 pips  → CMP(EXPR(ema20 - ema50) > EXPR(point * 100))
    price 1% above ma50        → CMP(close_0 > EXPR(ma50 * 1.01))
    |ema20 - ema50| > 20 pips  → CMP(EXPR(op="abs",left=EXPR(ema20-ema50)) > EXPR(point*200))
    spread < 2 pips            → CMP(spread < EXPR(point * 20))
    rsi_gap = rsi14 - 50 > 10  → CMP(EXPR(rsi14 - 50) > 10)
  NOTE: "point" is always available as a value (the symbol's pip point size).

PA FUNCTIONS (use in FN node, ONLY names from this list):
  Single-candle (i=bar index, default 0):
    is_bull(i), is_bear(i), is_doji(i), is_marubozu(i),
    is_hammer(i), is_inverted_hammer(i), is_shooting_star(i), is_hanging_man(i),
    is_pin_bar(i), is_pin_bar_bull(i), is_pin_bar_bear(i), is_spinning_top(i)
  Two-candle (no params — uses bar 0 and bar 1, needs ohlc_bars>=2):
    is_bull_engulfing(), is_bear_engulfing(), is_bull_harami(), is_bear_harami(),
    is_piercing(), is_dark_cloud(), is_tweezer_top(), is_tweezer_bottom()
  Three-candle (no params — uses bars 0-2, needs ohlc_bars>=3):
    is_morning_star(), is_evening_star(),
    is_three_white_soldiers(), is_three_black_crows(),
    is_three_inside_up(), is_three_inside_down()
  Market structure (n=lookback bars):
    is_higher_high(n), is_lower_low(n), is_higher_low(n), is_lower_high(n),
    is_uptrend(n), is_downtrend(n), is_consolidating(n),
    is_bull_breakout(n), is_bear_breakout(n),
    is_high_volume(n), is_accelerating_up(n), is_accelerating_down(n),
    near_round_number()

CROSSOVER RULE: "X crosses above Y" requires BOTH current and _prev variants:
  indicators: X(shift=0), X_prev(shift=1), Y(shift=0), Y_prev(shift=1)
  condition: CMP(X > Y) AND CMP(X_prev < Y_prev)

CONSEC RULE: "condition for N consecutive bars" — expand inline to AND with shifted names:
  "RSI14 < 30 for 3 bars" →
    indicators: rsi14(shift=0), rsi14_1(shift=1), rsi14_2(shift=2)
    condition: AND(CMP(rsi14<30), CMP(rsi14_1<30), CMP(rsi14_2<30))
  Name pattern: {name} for shift=0, {name}_1 for shift=1, {name}_N for shift=N.

TIME RULE: Use TIME node for session/hour filters:
  {"type":"TIME","from":900,"to":1700}   → broker time 09:00–17:00
  {"type":"TIME","from":2200,"to":200}   → crosses midnight (22:00–02:00)
  "from" and "to" are HHMM integers (24h). Always combine with AND.

SEQ RULE: "after A, then B on next bar" — use SEQ node for 2-step sequence:
  {"type":"SEQ","step1":{...},"step2":{...},"bars":3}
  step1 fires → DLL waits for a new bar → checks step2.
  "bars" = max bars to wait for step2 before resetting (default 3).
  SEQ fires a signal only when step2 confirms. step1 sets pending state.
  Example: "after RSI<30, wait for bullish candle" →
    indicators: rsi14(shift=0)
    condition: SEQ(step1: CMP(rsi14<30), step2: FN(is_bull,i=0), bars=3)
  IMPORTANT: SEQ maintains persistent state — always place SEQ at the top level
  or as the FIRST argument in AND. If SEQ is not evaluated every tick (e.g.
  short-circuited as a later AND arg), its state machine will stall.
  LIMIT: Only ONE SEQ node is allowed per condition tree (entry or exit separately).
  Do NOT use two SEQ nodes in the same condition.

CRITICAL RULES:
1. If instruction mentions ANY indicator, add it to indicators array AND reference in condition.
2. Each indicator name used in condition or exit_condition MUST appear in indicators array.
3. action: BUY or SELL only.
4. symbol: extract from instruction, normalize to MT4 format (e.g. "gold"→"XAUUSD").
5. tf: minutes (1,5,15,30,60,240,1440); 0 if not specified.
6. sl_pip and tp_pip must be > 0; tp_pip >= sl_pip * 0.5.
7. ohlc_bars: minimum bars needed (crossover=2, default=3).
   For PA FN with parameter n:
     is_bull_breakout(n) / is_bear_breakout(n)  → ohlc_bars = n+1 (default n=20 → 21)
     is_high_volume(n) / is_accelerating_up(n) / is_accelerating_down(n) → ohlc_bars = n+1
     is_consolidating(n) / is_uptrend(n) / is_downtrend(n) → ohlc_bars = n
   DLL clamps automatically if ohlc_bars is too small, but the lookback is reduced.
   Always set ohlc_bars to the exact value required. MAX ohlc_bars = 50.
8. exit_condition: ALWAYS include this field. If the instruction mentions an explicit exit/close condition, parse it here using the same indicator variable names from indicators array. If no explicit exit is mentioned, infer a logical reversal: for a BUY entry using crossover X>Y, the exit is X<Y crossover. If no reversal can be inferred, output "exit_condition": {} (empty = rely on SL/TP only).
9. MAX indicators: 15. If more are needed, keep only the most essential ones.
10. Only use FN names from the PA FUNCTIONS list above. NEVER invent function names.
11. UNSUPPORTED strategies: If the strategy requires something this system cannot model
    (news/fundamentals, sentiment, ML predictions, custom/proprietary indicators, inter-symbol
    correlation, order flow, or any condition not expressible as indicator CMP/FN logic),
    output ONLY: {"action":"UNSUPPORTED","reason":"<one sentence English explanation>"}
    Do NOT attempt to fake a condition for an unsupported strategy."""

_FEW_SHOT_USER = ('Instruction: "Buy GBPUSD when EMA20 crosses above EMA50 and RSI14 < 70"\n'
                  'Symbol: GBPUSD\nDefault lot: 0.100000, SL: 40 pips, TP: 80 pips')
_FEW_SHOT_ASST = ('{"action":"BUY","tf":0,"lot":0.1,"sl_pip":40,"tp_pip":80,"ohlc_bars":2,'
                  '"indicators":['
                  '{"name":"ema20","type":"iMA","period":20,"method":1,"applied":0,"shift":0},'
                  '{"name":"ema20_prev","type":"iMA","period":20,"method":1,"applied":0,"shift":1},'
                  '{"name":"ema50","type":"iMA","period":50,"method":1,"applied":0,"shift":0},'
                  '{"name":"ema50_prev","type":"iMA","period":50,"method":1,"applied":0,"shift":1},'
                  '{"name":"rsi14","type":"iRSI","period":14,"applied":0,"shift":0}],'
                  '"condition":{"type":"AND","args":['
                  '{"type":"AND","args":['
                  '{"type":"CMP","left":"ema20","op":">","right":"ema50"},'
                  '{"type":"CMP","left":"ema20_prev","op":"<","right":"ema50_prev"}]},'
                  '{"type":"CMP","left":"rsi14","op":"<","right":70}]},'
                  '"exit_condition":{"type":"AND","args":['
                  '{"type":"CMP","left":"ema20","op":"<","right":"ema50"},'
                  '{"type":"CMP","left":"ema20_prev","op":">","right":"ema50_prev"}]}}')
_FEW_SHOT_USER2 = ('Instruction: "Sell USDJPY H4 when MACD crosses below signal and Stochastic > 80. SL 30, TP 60"\n'
                   'Symbol: USDJPY\nDefault lot: 0.100000, SL: 30 pips, TP: 60 pips')
_FEW_SHOT_ASST2 = ('{"action":"SELL","tf":240,"lot":0.1,"sl_pip":30,"tp_pip":60,"ohlc_bars":2,'
                   '"indicators":['
                   '{"name":"macd_main","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"line":0,"shift":0},'
                   '{"name":"macd_main_prev","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"line":0,"shift":1},'
                   '{"name":"macd_sig","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"line":1,"shift":0},'
                   '{"name":"macd_sig_prev","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"line":1,"shift":1},'
                   '{"name":"sto_k","type":"iStochastic","kperiod":5,"dperiod":3,"slowing":3,"method":0,"line":0,"shift":0}],'
                   '"condition":{"type":"AND","args":['
                   '{"type":"AND","args":['
                   '{"type":"CMP","left":"macd_main","op":"<","right":"macd_sig"},'
                   '{"type":"CMP","left":"macd_main_prev","op":">","right":"macd_sig_prev"}]},'
                   '{"type":"CMP","left":"sto_k","op":">","right":80}]},'
                   '"exit_condition":{"type":"AND","args":['
                   '{"type":"CMP","left":"macd_main","op":">","right":"macd_sig"},'
                   '{"type":"CMP","left":"macd_main_prev","op":"<","right":"macd_sig_prev"}]}}')

async def _call_init_claude(
    prompt: str,
    symbol: str = "",
    lot: float = 0.1,
    sl: int = 50,
    tp: int = 100,
    tf: int = 0,
) -> "dict | None":
    """Call Claude with INIT_SYSTEM_PROMPT to parse a strategy. Returns config dict or None."""
    if not CLAUDE_API_KEY or _claude is None:
        return None
    import json as _json
    user_msg = (f'Instruction: "{prompt}"\n'
                f'Symbol: {symbol or "EURUSD"}\n'
                f'Default lot: {lot:.6f}, SL: {sl} pips, TP: {tp} pips')
    try:
        resp = await asyncio.wait_for(
            _claude.messages.create(
                model=CLAUDE_PARSE_MODEL,
                max_tokens=CLAUDE_PARSE_MAX_TOKENS,
                system=[{"type": "text", "text": INIT_SYSTEM_PROMPT,
                          "cache_control": {"type": "ephemeral"}}],
                messages=[
                    {"role": "user",      "content": _FEW_SHOT_USER},
                    {"role": "assistant", "content": _FEW_SHOT_ASST},
                    {"role": "user",      "content": _FEW_SHOT_USER2},
                    {"role": "assistant", "content": _FEW_SHOT_ASST2},
                    {"role": "user",      "content": user_msg},
                ],
            ),
            timeout=30.0,
        )
        text = resp.content[0].text
        s, e = text.find("{"), text.rfind("}")
        if s == -1 or e == -1:
            return None
        return _json.loads(text[s:e + 1])
    except asyncio.TimeoutError:
        logger.error("_call_init_claude timeout after 30s")
        return None
    except Exception as ex:
        logger.error(f"_call_init_claude error: {ex}")
        return None


_SUPPORTED_FN: frozenset = frozenset({
    # single-candle
    "is_bull", "is_bear", "is_doji", "is_marubozu",
    "is_hammer", "is_inverted_hammer", "is_shooting_star", "is_hanging_man",
    "is_pin_bar_bull", "is_pin_bar_bear", "is_pin_bar", "is_spinning_top",
    # two-candle
    "is_bull_engulfing", "is_bear_engulfing",
    "is_bull_harami",   "is_bear_harami",
    "is_piercing",      "is_dark_cloud",
    "is_tweezer_top",   "is_tweezer_bottom",
    # three-candle
    "is_morning_star",        "is_evening_star",
    "is_three_white_soldiers","is_three_black_crows",
    "is_three_inside_up",     "is_three_inside_down",
    # market structure
    "is_higher_high", "is_lower_low", "is_higher_low", "is_lower_high",
    "is_uptrend",     "is_downtrend", "is_consolidating",
    "is_bull_breakout","is_bear_breakout",
    "is_high_volume",  "is_accelerating_up", "is_accelerating_down",
    "near_round_number",
})

_MAX_INDICATORS = 15


def _collect_condition_vars(node: dict, out: set) -> None:
    """Recursively collect all indicator variable names referenced in a condition tree."""
    if not isinstance(node, dict):
        return
    t = node.get("type", "")
    if t == "CMP":
        for side in ("left", "right"):
            v = node.get(side)
            if isinstance(v, str):
                out.add(v)
            elif isinstance(v, dict):
                _collect_condition_vars(v, out)   # EXPR nested in CMP
    elif t == "EXPR":
        for side in ("left", "right"):
            v = node.get(side)
            if isinstance(v, str):
                out.add(v)
            elif isinstance(v, dict):
                _collect_condition_vars(v, out)
    elif t in ("AND", "OR"):
        for child in node.get("args", []):
            _collect_condition_vars(child, out)
    elif t == "NOT":
        _collect_condition_vars(node.get("arg", {}), out)
    elif t == "SEQ":
        _collect_condition_vars(node.get("step1", {}), out)
        _collect_condition_vars(node.get("step2", {}), out)


def _collect_fn_names(node: dict, out: set) -> None:
    """Recursively collect all FN names used in a condition tree."""
    if not isinstance(node, dict):
        return
    t = node.get("type", "")
    if t == "FN":
        name = node.get("name", "")
        if name:
            out.add(name)
    elif t in ("AND", "OR"):
        for child in node.get("args", []):
            _collect_fn_names(child, out)
    elif t == "NOT":
        _collect_fn_names(node.get("arg", {}), out)
    elif t == "SEQ":
        _collect_fn_names(node.get("step1", {}), out)
        _collect_fn_names(node.get("step2", {}), out)


def _validate_strategy_config(config: dict) -> "tuple[bool, str]":
    """Validate a config dict returned by _call_init_claude.
    Returns (ok, error_code). error_code is machine-readable English —
    callers must NOT display it directly; inject into history for Claude to explain.
    """
    action = config.get("action", "")
    if action not in ("BUY", "SELL"):
        return False, "missing_action:expected BUY or SELL"

    cond = config.get("condition", {})
    if not isinstance(cond, dict) or not cond.get("type"):
        return False, "missing_condition:no technical entry condition found"

    indicators = config.get("indicators", [])
    if len(indicators) > _MAX_INDICATORS:
        return False, f"too_many_indicators:{len(indicators)}>max={_MAX_INDICATORS}"

    ind_names = {ind.get("name") for ind in indicators if ind.get("name")}
    exit_cond = config.get("exit_condition", {})

    # Check all CMP vars are declared in indicators
    used_vars: set = set()
    _collect_condition_vars(cond, used_vars)
    if isinstance(exit_cond, dict) and exit_cond.get("type"):
        _collect_condition_vars(exit_cond, used_vars)
    missing_ind = used_vars - ind_names
    if missing_ind:
        return False, f"unknown_indicators:{','.join(sorted(missing_ind))}"

    # Check all FN names are supported by DLL
    used_fns: set = set()
    _collect_fn_names(cond, used_fns)
    if isinstance(exit_cond, dict) and exit_cond.get("type"):
        _collect_fn_names(exit_cond, used_fns)
    unsupported_fns = used_fns - _SUPPORTED_FN
    if unsupported_fns:
        return False, f"unsupported_fn:{','.join(sorted(unsupported_fns))}"

    return True, ""


def _extract_execute(text: str) -> "dict | None":
    """Extract and parse the [EXECUTE:{...}] block from Claude's reply."""
    import json as _json
    pos = text.find("[EXECUTE:")
    if pos < 0:
        return None
    start = pos + len("[EXECUTE:")
    if start >= len(text) or text[start] != "{":
        return None
    depth, end = 0, start
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end == start:
        return None
    try:
        return _json.loads(text[start:end])
    except Exception:
        return None


def _strip_execute(text: str) -> str:
    """Remove the [EXECUTE:{...}] block from the user-visible reply."""
    pos = text.find("[EXECUTE:")
    return text[:pos].rstrip() if pos >= 0 else text


_TF_MAP = {0:"auto",1:"M1",5:"M5",15:"M15",30:"M30",60:"H1",240:"H4",1440:"D1",10080:"W1"}

def _format_strategy_summary(acct: str, sid: int, op: str, ea_connected: bool,
                              old_values: "dict | None" = None) -> str:
    """Return a formatted strategy card to append after a successful add/update/delete."""
    slot_name = f"S{sid + 1}"
    if op == "delete":
        msg = f"✅ **{slot_name}** removed."
        if not ea_connected:
            msg += " ⚠️ EA not connected — will sync on reconnect."
        return f"\n\n---\n{msg}"

    s      = strategy_store.get(acct, {}).get(sid, {})
    tf_new = _TF_MAP.get(int(s.get("tf", 0)), str(s.get("tf", 0)))
    status = "✅" if ea_connected else "💾"
    lines  = [f"{status} **{slot_name} – {s.get('action','?')} {s.get('symbol','?')} ({tf_new})**"]

    if op == "update" and old_values:
        old     = old_values
        tf_old  = _TF_MAP.get(int(old.get("tf", 0)), str(old.get("tf", 0)))
        changes = []
        # enabled toggle
        old_en, new_en = old.get("enabled", True), s.get("enabled", True)
        if old_en != new_en:
            changes.append(f"**Status:** {'ON' if old_en else 'OFF'} → **{'ON' if new_en else 'OFF'}**")
        for field, label, suffix in [("lot", "Lot", ""), ("sl", "SL", " pip"), ("tp", "TP", " pip")]:
            ov, nv = old.get(field), s.get(field)
            if ov is not None and nv is not None and str(ov) != str(nv):
                changes.append(f"**{label}:** {ov}{suffix} → **{nv}{suffix}**")
        if tf_old != tf_new:
            changes.append(f"**TF:** {tf_old} → **{tf_new}**")
        if old.get("prompt") and old.get("prompt") != s.get("prompt"):
            lines.append(f"• **Entry:** {s.get('prompt', '')}")
        if changes:
            lines.append("• " + " | ".join(changes))
        else:
            lines.append(f"• **Lot:** {s.get('lot', 0.1)} | **SL:** {s.get('sl', 50)} pip | **TP:** {s.get('tp', 100)} pip")
    else:
        lines.append(f"• **Entry:** {s.get('prompt', '')}")
        lines.append(f"• **Lot:** {s.get('lot', 0.1)} | **SL:** {s.get('sl', 50)} pip | **TP:** {s.get('tp', 100)} pip")

    if not ea_connected:
        lines.append("⚠️ Strategy saved — will apply when EA reconnects.")
    return "\n\n---\n" + "\n".join(lines)


async def _ea_request(account: str, payload: dict, timeout: float = 8.0) -> "dict | None":
    """Send a request to EA via WebSocket and wait for the response."""
    import uuid as _uuid
    if account not in ws_ea_clients:
        return None
    payload["request_id"] = _uuid.uuid4().hex[:8]
    loop = asyncio.get_running_loop()
    fut = loop.create_future()
    _ea_pending[account] = fut
    try:
        await ws_ea_clients[account].send_json(payload)
        return await asyncio.wait_for(asyncio.shield(fut), timeout=timeout)
    except asyncio.TimeoutError:
        return None
    finally:
        _ea_pending.pop(account, None)


_MT4_ERRORS: dict = {
    130: "SL/TP too close to market price (ERR_INVALID_STOPS) — increase SL/TP or check broker stop level",
    131: "Invalid trade volume (ERR_INVALID_TRADE_VOLUME)",
    132: "Market is closed (ERR_MARKET_CLOSED)",
    133: "Trading is disabled (ERR_TRADE_DISABLED)",
    134: "Not enough money (ERR_NOT_ENOUGH_MONEY)",
    135: "Price changed (ERR_PRICE_CHANGED) — please retry",
    136: "Off quotes (ERR_OFF_QUOTES) — please retry",
    137: "Broker is busy (ERR_BROKER_BUSY) — please retry",
    138: "Requote — please retry",
    139: "Order is locked (ERR_ORDER_LOCKED)",
    141: "Too many requests (ERR_TOO_MANY_REQUESTS) — please retry later",
    145: "Modification denied — too close to market (ERR_TRADE_MODIFY_DENIED)",
    146: "Trade context is busy (ERR_TRADE_CONTEXT_BUSY) — please retry",
    148: "Too many open orders (ERR_TOO_MANY_ORDERS)",
    4109: "Trade is not allowed on this account",
}

def _mt4_error_msg(err) -> str:
    try:
        code = int(err)
        desc = _MT4_ERRORS.get(code, "")
        return f"`{code}`" + (f" — {desc}" if desc else "")
    except Exception:
        return f"`{err}`"


def _format_order_result(result: "dict | None", op: str) -> str:
    if result is None:
        return "\n\n---\n⚠️ EA timeout — no response received."
    if not result.get("success", False):
        err = result.get("error", "unknown")
        return f"\n\n---\n❌ Order failed: {_mt4_error_msg(err)}"
    if op == "order_open":
        ticket = result.get("ticket", "?")
        sym    = result.get("symbol", "")
        typ    = result.get("type",   "")
        lot    = result.get("lot",    0)
        price  = result.get("open_price", 0)
        return (f"\n\n---\n✅ **Order opened**\n"
                f"• Ticket: **#{ticket}** | {typ} {sym}\n"
                f"• Lot: {lot} | Open price: {price:.5f}")
    if op == "order_close":
        ticket = result.get("ticket", "?")
        profit = result.get("profit", 0)
        price  = result.get("close_price", 0)
        sign   = "+" if profit >= 0 else ""
        return (f"\n\n---\n✅ **Order #{ticket} closed**\n"
                f"• Close price: {price:.5f} | P&L: **{sign}{profit:.2f}**")
    if op == "order_close_all":
        closed = result.get("closed", 0)
        failed = result.get("failed", 0)
        orders = result.get("orders", [])
        msg    = f"\n\n---\n✅ **Closed {closed} order(s)**"
        if failed:
            msg += f" | ⚠️ {failed} failed"
        total_pnl = 0.0
        for o in orders:
            ticket  = o.get("ticket", "?")
            sym     = o.get("symbol", "")
            typ     = o.get("type", "")
            lot     = o.get("lot", 0)
            price   = o.get("close_price", 0)
            profit  = o.get("profit", 0)
            total_pnl += profit
            sign    = "+" if profit >= 0 else ""
            msg += (f"\n• **#{ticket}** {typ} {sym} {lot}lot"
                    f" | Close: {price:.5f} | P&L: **{sign}{profit:.2f}**")
        if len(orders) > 1:
            sign = "+" if total_pnl >= 0 else ""
            msg += f"\n• **Total P&L: {sign}{total_pnl:.2f}**"
        return msg
    if op == "order_modify":
        ticket  = result.get("ticket", "?")
        old_sl  = result.get("old_sl", None)
        old_tp  = result.get("old_tp", None)
        sl      = result.get("sl",     None)
        tp      = result.get("tp",     None)
        def _fp(v): return f"{float(v):.5f}" if v is not None and float(v) != 0 else "—"
        def _arrow(old, new):
            o, n = _fp(old), _fp(new)
            return f"{o} → **{n}**" if o != n else f"**{n}**"
        return (f"\n\n---\n✅ **Order #{ticket} modified**\n"
                f"• SL: {_arrow(old_sl, sl)} | TP: {_arrow(old_tp, tp)}")
    return "\n\n---\n✅ Done"


def _order_source(magic: int) -> str:
    if magic == CHAT_ORDER_MAGIC:
        return "Chat"
    if 88800 <= magic <= 88804:
        return f"S{magic - 88800 + 1}"
    if magic == 0:
        return "Manual"
    return f"Ext(#{magic})"

def _format_order_list(orders: list) -> str:
    if not orders:
        return "\n\n---\n📋 **No open orders.**"
    lines = [f"\n\n---\n📋 **Open Orders ({len(orders)}):**"]
    for i, o in enumerate(orders, 1):
        typ       = o.get("type",       "?")
        sym       = o.get("symbol",     "?")
        ticket    = o.get("ticket",     "?")
        lot       = o.get("lot",        0)
        price     = o.get("open_price", 0)
        profit    = o.get("profit",     0)
        magic     = int(o.get("magic",  0))
        open_time = int(o.get("open_time", 0))
        sign      = "+" if profit >= 0 else ""
        pnl_clr   = "+" if profit >= 0 else ""
        source    = _order_source(magic)
        time_str  = (datetime.fromtimestamp(open_time, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
                     if open_time else "?")
        sl        = float(o.get("sl", 0))
        tp        = float(o.get("tp", 0))
        sl_str    = f"{sl:.5f}" if sl else "—"
        tp_str    = f"{tp:.5f}" if tp else "—"
        lines.append(
            f"\n**{i}. #{ticket}** — {typ} {sym}\n"
            f"   • Lot: {lot} | Open: {price:.5f} | P&L: **{pnl_clr}{profit:.2f}**\n"
            f"   • SL: {sl_str} | TP: {tp_str}\n"
            f"   • Source: **{source}** | {time_str}"
        )
    return "\n".join(lines)


def _format_order_history(orders: list, mode: str, limit: int = 0) -> str:
    if not orders:
        return "\n\n---\n📋 **No order history found.**"
    title = f"Last {limit} orders" if mode == "last" else "Orders in last 48h"
    lines = [f"\n\n---\n📜 **Order History — {title} ({len(orders)}):**"]
    total_pnl = 0.0
    _CLOSE_REASON_LABEL = {"SL": "🔴 SL hit", "TP": "🟢 TP hit", "SO": "💀 Stop out", "manual": "✋ Closed manually"}
    _OPENER_LABEL = {"chat": "💬 Chat", "manual": "👤 Manual", "ext": "🔌 External"}

    for i, o in enumerate(orders, 1):
        typ          = o.get("type",         "?")
        sym          = o.get("symbol",       "?")
        ticket       = o.get("ticket",       "?")
        lot          = o.get("lot",          0)
        open_price   = float(o.get("open_price",  0))
        close_price  = float(o.get("close_price", 0))
        profit       = float(o.get("profit",      0))
        swap         = float(o.get("swap",        0))
        commission   = float(o.get("commission",  0))
        open_time    = int(o.get("open_time",  0))
        close_time   = int(o.get("close_time", 0))
        magic        = int(o.get("magic",      0))
        opener_raw   = o.get("opener", "")
        close_reason = o.get("close_reason", "")
        total_pnl   += profit
        # Opener label: prefer EA-provided field, fall back to magic-derived
        if opener_raw.startswith("S"):
            opener_label = f"🤖 Strategy {opener_raw}"
        elif opener_raw in _OPENER_LABEL:
            opener_label = _OPENER_LABEL[opener_raw]
        else:
            opener_label = _order_source(magic)
        closed_label = _CLOSE_REASON_LABEL.get(close_reason, f"✋ {close_reason}" if close_reason else "—")
        sign         = "+" if profit >= 0 else ""
        open_str     = (datetime.fromtimestamp(open_time,  tz=timezone.utc).strftime("%m/%d %H:%M")
                        if open_time  else "?")
        close_str    = (datetime.fromtimestamp(close_time, tz=timezone.utc).strftime("%m/%d %H:%M")
                        if close_time else "?")
        lines.append(
            f"\n**{i}. #{ticket}** — {typ} {sym}\n"
            f"   • Lot: {lot} | Open: {open_price:.5f} → Close: {close_price:.5f}\n"
            f"   • P&L: **{sign}{profit:.2f}** | Swap: {swap:.2f} | Comm: {commission:.2f}\n"
            f"   • Opened by: **{opener_label}** | Closed: **{closed_label}** | {open_str} → {close_str}"
        )
    sign = "+" if total_pnl >= 0 else ""
    lines.append(f"\n**Total P&L: {sign}{total_pnl:.2f}**")
    return "\n".join(lines)


def _format_market_data(data: dict) -> str:
    """Format EA market_data response into a compact text block for Claude to analyze."""
    from datetime import datetime as _dt
    symbol  = data.get("symbol", "?")
    tf      = int(data.get("tf", 0))
    tf_str  = _TF_MAP.get(tf, f"{tf}m")
    ask     = float(data.get("ask", 0))
    bid     = float(data.get("bid", 0))
    spread  = float(data.get("spread", 0))
    bars    = data.get("bars", [])
    inds    = data.get("indicators", {})

    lines = [f"Symbol: {symbol} | TF: {tf_str} | Ask: {ask:.5f} | Bid: {bid:.5f} | Spread: {spread:.1f} pip"]

    if bars:
        lines.append("OHLCV (i=0 is current/latest bar):")
        for b in bars[:20]:
            i   = b.get("i", 0)
            t   = b.get("time", 0)
            ts  = _dt.utcfromtimestamp(t).strftime("%Y-%m-%d %H:%M") if t else "?"
            o, h, l, c = b.get("open",0), b.get("high",0), b.get("low",0), b.get("close",0)
            vol = b.get("volume", 0)
            lines.append(f"  [{i}] {ts}  O:{o:.5f}  H:{h:.5f}  L:{l:.5f}  C:{c:.5f}  V:{vol}")

    if inds:
        lines.append("Indicators (index = bar shift, 0=current):")
        for name, values in inds.items():
            if isinstance(values, list) and values:
                vals = "  ".join(f"[{i}]{float(v):.5f}" for i, v in enumerate(values))
                lines.append(f"  {name}: {vals}")

    return "\n".join(lines)


async def _handle_order_execute(action: dict, account: str) -> str:
    """Dispatch an order_* op to the EA and return a formatted result string."""
    op = action.get("op", "")
    if account not in ws_ea_clients:
        return "\n\n---\n⚠️ EA not connected — cannot execute order commands."

    if op == "order_list":
        result = await _ea_request(account, {"event": "order_list_request"})
        if result is None:
            return "\n\n---\n⚠️ `order_list_timeout`"
        return _format_order_list(result.get("orders", []))

    if op == "order_open":
        result = await _ea_request(account, {
            "event":  "order_open",
            "symbol": action.get("symbol", "EURUSD"),
            "type":   action.get("type",   "BUY"),
            "lot":    float(action.get("lot", 0.1)),
            "sl":     float(action.get("sl",  50)),
            "tp":     float(action.get("tp",  100)),
            "magic":  CHAT_ORDER_MAGIC,
        })
        return _format_order_result(result, op)

    if op == "order_close":
        result = await _ea_request(account, {
            "event":  "order_close",
            "ticket": int(action.get("ticket", 0)),
        })
        return _format_order_result(result, op)

    if op == "order_close_all":
        payload: dict = {"event": "order_close_all"}
        if action.get("symbol"):
            payload["symbol"] = action["symbol"]
        result = await _ea_request(account, payload)
        return _format_order_result(result, op)

    if op == "order_modify":
        result = await _ea_request(account, {
            "event":  "order_modify",
            "ticket": int(action.get("ticket", 0)),
            "sl":     float(action.get("sl", 0)),
            "tp":     float(action.get("tp", 0)),
        })
        return _format_order_result(result, op)

    if op == "order_history_last":
        limit = max(1, int(action.get("limit", 10)))
        result = await _ea_request(account, {"event": "order_history_last_request", "limit": limit})
        if result is None:
            return "\n\n---\n⚠️ `order_history_timeout`"
        return _format_order_history(result.get("orders", []), "last", limit)

    if op == "order_history_48h":
        result = await _ea_request(account, {"event": "order_history_48h_request"})
        if result is None:
            return "\n\n---\n⚠️ `order_history_timeout`"
        return _format_order_history(result.get("orders", []), "48h")

    # market_query is handled separately (needs second Claude call) — should not reach here
    return "\n\n---\n⚠️ `unknown_order_op`"


@app.post("/init")
async def strategy_init(request: Request, db: Session = Depends(get_db)):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"status": "error", "message": "Invalid JSON"}, status_code=400)

    # ── Auth: verify account+server exist in DB ───────────────────────────
    try:
        _verify_account(body.get("token", ""), db)
    except Exception as e:
        msg = getattr(e, "detail", None) or str(e)
        code = getattr(e, "status_code", 401)
        logger.warning(f"Init auth failed: {msg}")
        return JSONResponse({"status": "error", "message": str(msg)}, status_code=code)

    prompt  = str(body.get("prompt",  "")).strip()
    symbol  = str(body.get("symbol",  "EURUSD")).strip()
    tf      = int(body.get("tf",      0))
    lot     = float(body.get("lot",   0.1))
    sl      = int(body.get("sl",      50))
    tp      = int(body.get("tp",      100))
    account = int(body.get("account", 0))
    sid     = int(body.get("sid",     0))

    if not prompt:
        return JSONResponse({"status": "error", "message": "Missing prompt"}, status_code=400)
    if not CLAUDE_API_KEY:
        return JSONResponse({"status": "error", "message": "Claude API key not configured"}, status_code=500)

    config = await _call_init_claude(prompt, symbol, lot, sl, tp, tf)
    if config is None:
        return JSONResponse({"status": "error", "message": "Claude parse failed"}, status_code=500)

    # Persist strategy so chat bot can answer "what is Strategy X?"
    _strategy_store_save(str(account), sid, {
        "prompt": prompt,
        "lot":    config.get("lot",    lot),
        "sl":     config.get("sl_pip", sl),
        "tp":     config.get("tp_pip", tp),
        "tf":     config.get("tf",     tf),
        "action": config.get("action", "BUY"),
        "symbol": config.get("symbol", symbol),
    })

    logger.info(f"Init S{sid} account={account} symbol={symbol} action={config.get('action')} tf={config.get('tf')}")
    return {"status": "ok", "config": config}


# ── Chat — Strategy Manager ────────────────────────────────────────────────────

STRATEGY_SYSTEM_PROMPT = """\
You are **AI Strategy Manager** for MetaTrader 4 (AI Trading Bridge).
Your ONLY function is helping users manage their trading strategies via CRUD operations.
Politely refuse all unrelated topics (market analysis, general chat, etc.).

## STRATEGY SLOTS
S1 (sid=0) · S2 (sid=1) · S3 (sid=2) · S4 (sid=3) · S5 (sid=4)

## OPERATIONS & REQUIRED INFORMATION

**ADD** — Create a new strategy in a slot:
  - prompt : Complete strategy description — MUST include:
              (1) direction: BUY or SELL
              (2) instrument: e.g. EURUSD, XAUUSD, USDJPY
              (3) entry condition: indicator(s) or price-action pattern
  - sid    : Target slot S1–S5 (ask if not stated)
  - lot    : Lot size (default 0.10 if not stated)
  - sl     : Stop loss in pips (default 50 if not stated)
  - tp     : Take profit in pips (default 100 if not stated)
  - tf     : Timeframe M1/M5/M15/M30/H1/H4/D1 (0 = auto-detect from prompt)

**UPDATE** — Modify one or more fields of an existing strategy:
  - sid + at least one field to change (prompt/lot/sl/tp/tf)

**DELETE** — Remove a strategy from a slot:
  - sid only

**ENABLE / DISABLE** — Toggle a strategy on or off (no confirmation needed):
  - sid : target slot
  - ON  : strategy resumes placing orders when conditions match
  - OFF : strategy keeps running but will NOT place any orders (monitor only)

**LIST** — Describe what each slot does (answer from conversation context)

## CONVERSATION RULES

0. **CONCISE** — Keep every reply short and direct. Use 1–3 sentences for confirmations,
   clarifications, and status updates. Only list details when the user explicitly asks.
   Never repeat information the user already provided.

1. **TOPIC GUARD** — You handle: strategy CRUD, manual orders, live market data queries,
   and strategy suggestions/advice for users who don't know what to create.
   Politely decline anything else (general chat, news, fundamentals, predictions) in the user's
   own language and redirect to what you can do. Do not answer off-topic questions.

2. **COLLECT** — If required info is missing or ambiguous, ask ONE focused question.
   Do not ask multiple questions at once. Do not proceed until the answer is clear.

3. **CONFIRM** — Before executing ADD/UPDATE/DELETE (or any order OPEN/CLOSE/MODIFY),
   show a clear summary and ask "Confirm?" (in the user's language) in one reply, then STOP.
   Wait for the user's next message before emitting [EXECUTE].
   NEVER simulate, anticipate, or write the user's confirmation yourself ("User: yes", etc.).
   Even if the user says "immediately", "right now", "сейчас", "ahora", or any urgency word — still confirm first.

4. **EXECUTE** — Only append [EXECUTE] AFTER the user explicitly confirms with:
   yes / confirm / ok / sure / proceed / да / 是 / sí / sim / oui
   One [EXECUTE] per reply, never in the same reply as the confirmation question.

5. **LANGUAGE** — Always detect and reply in the same language the user writes in.
   Accept any language. Do NOT reject or redirect the user to another language.

6. **PROMPT FIELD** — Always write the `prompt` value inside [EXECUTE] in clear English,
   regardless of what language the user typed in.

7. **TEXT BEFORE [EXECUTE]** — The system strips [EXECUTE] and everything after it before
   showing the reply to the user. Use this to your advantage:
   - If there are MORE pending operations after this one, write the confirmation question
     for the NEXT operation on the line(s) BEFORE [EXECUTE]. The user will see that
     question along with the result of the current operation.
   - If this is the LAST (or only) operation, write nothing — just emit [EXECUTE] alone.

8. **ONE OPERATION PER TURN** — Emit exactly ONE [EXECUTE] per response. For multiple
   requested operations, chain them: write the next confirmation question → then [EXECUTE]
   for the current one. Never emit two or more [EXECUTE] in a single reply.

   Example — user asks to delete S1, S2, S3:
   Turn 1 (collecting): "Confirm delete S1?"
   Turn 2 (user confirms S1, pre-ask S2): "Confirm delete S2? • Strategy: ..." [EXECUTE:delete S1]
   Turn 3 (user confirms S2, pre-ask S3): "Confirm delete S3? • Strategy: ..." [EXECUTE:delete S2]
   Turn 4 (user confirms S3, last op):    [EXECUTE:delete S3]

## [EXECUTE] FORMAT

Append EXACTLY ONE of these at the very end of your reply (nothing after it):

  [EXECUTE:{"op":"add","sid":N,"prompt":"<English description>","lot":0.1,"sl":50,"tp":100,"tf":0}]
  [EXECUTE:{"op":"update","sid":N,"lot":0.2}]
  [EXECUTE:{"op":"update","sid":N,"prompt":"<new English description>","sl":30}]
  [EXECUTE:{"op":"update","sid":N,"enabled":false}]
  [EXECUTE:{"op":"update","sid":N,"enabled":true}]
  [EXECUTE:{"op":"delete","sid":N}]

Rules:
- N = 0 for S1, 1 for S2, 2 for S3, 3 for S4, 4 for S5
- tf in minutes: M1=1 M5=5 M15=15 M30=30 H1=60 H4=240 D1=1440 (0 if not specified)
- "update": only include the changed fields + sid
- "delete": only include sid
- Do NOT wrap [EXECUTE] in markdown, quotes, or code blocks

## ORDER MANAGEMENT

Besides automated strategies, you can execute **manual trade orders** directly.

**OPEN** — Place a new market order:
  - symbol : instrument (e.g. EURUSD, XAUUSD); extract from user message
  - type   : BUY or SELL
  - lot    : lot size (default 0.10)
  - sl     : stop loss in pips (default 50)
  - tp     : take profit in pips (default 100)

**CLOSE** — Close a specific order (ask for ticket if not provided):
  - ticket : numeric order ticket

**CLOSE ALL** — Close all chat-managed orders:
  - symbol : optional instrument filter

**MODIFY** — Change SL/TP of an existing order:
  - ticket : numeric order ticket
  - sl     : new SL in pips (omit to keep current)
  - tp     : new TP in pips (omit to keep current)

**LIST** — Show current open chat-managed orders (no confirmation needed):
  - no parameters

**HISTORY LAST N** — Show the last N closed orders (no confirmation needed):
  - limit : number of orders to retrieve (e.g. 5, 10, 20)

**HISTORY 48H** — Show all closed orders in the last 48 hours (no confirmation needed):
  - no parameters

Order [EXECUTE] formats:
  [EXECUTE:{"op":"order_open","symbol":"EURUSD","type":"BUY","lot":0.1,"sl":50,"tp":100}]
  [EXECUTE:{"op":"order_close","ticket":12345}]
  [EXECUTE:{"op":"order_close_all"}]
  [EXECUTE:{"op":"order_close_all","symbol":"EURUSD"}]
  [EXECUTE:{"op":"order_modify","ticket":12345,"sl":30,"tp":150}]
  [EXECUTE:{"op":"order_list"}]
  [EXECUTE:{"op":"order_history_last","limit":10}]
  [EXECUTE:{"op":"order_history_48h"}]

Notes:
- "Chat-managed orders" = orders opened through this chat (tracked by magic number).
  You cannot close or modify orders opened automatically by EA strategies.
- Confirm before OPEN / CLOSE / CLOSE ALL / MODIFY — same rules as strategy CRUD.
- LIST, HISTORY LAST N, and HISTORY 48H do not require confirmation — emit [EXECUTE] immediately.
- If user specifies a count ("last 10 orders", "последние 5 ордеров", "最近10笔", "últimas 10 órdenes") → use `order_history_last` with that limit.
- If count is unspecified ("recent orders", "orders today", "история ордеров", "历史订单", "48h") → use `order_history_48h`.

## MARKET DATA QUERY

You can fetch live price and indicator data directly from MT4.

**QUERY** — Get OHLCV bars and indicator values (no confirmation needed):
  - symbol     : instrument, e.g. "EURUSD", "XAUUSD", "USDJPY"
  - tf         : timeframe in minutes (1/5/15/30/60/240/1440)
  - bars       : how many candles to fetch (1–50, default 5 for current; 1 for just latest price)
  - indicators : list of indicators to compute (same format as strategy indicators)

[EXECUTE] format:
  [EXECUTE:{"op":"market_query","symbol":"EURUSD","tf":60,"bars":5,"indicators":[
    {"name":"rsi14","type":"iRSI","period":14,"applied":0,"shift":0},
    {"name":"ma20","type":"iMA","period":20,"method":1,"applied":0,"shift":0}
  ]}]

  For current price only (no indicators):
  [EXECUTE:{"op":"market_query","symbol":"EURUSD","tf":60,"bars":1,"indicators":[]}]

Indicator format rules: same as strategy indicators (iMA/iRSI/iMACD/iBands/iATR/iADX/iRSI/iCCI/iSAR/iStochastic/iWPR/iAlligator/iIchimoku/etc.)
Use `"shift":0` for current bar, `"shift":1` for previous bar.
For multi-bar indicator history, set `bars=N` — the system returns values at shifts 0..N-1 automatically.

**Temporal mapping — translate time expressions to bar count + timeframe:**
- "yesterday" / "hôm qua" / "вчера" / "ayer"          → tf=1440 (D1), bars=2
- "last week" / "tuần trước" / "на прошлой неделе"     → tf=1440, bars=7
- "last 3 days"                                         → tf=1440, bars=4
- "this week so far"                                    → tf=1440, bars=5
- "last hour"                                           → tf=60, bars=2
- "last 4 hours"                                        → tf=240, bars=2
- current price only                                    → bars=1

Always map temporal questions to bar shifts. Never say you cannot fetch historical data — you can fetch up to 50 bars on any timeframe.

## STRATEGY SUGGESTIONS

When a user says they don't know what strategy to create, asks for ideas, or asks "what should I
trade", offer 5 ready-to-use examples covering different styles. Present them as a numbered list
in the user's language. Each entry must show:
  • Name / style
  • Direction + instrument + entry condition (one sentence)
  • Default SL / TP suggestion

**Starter menu (adapt instrument/language to user context):**

1. **MA Crossover (trend-following)**
   Buy EURUSD when EMA20 crosses above EMA50 on H1 · SL 50 / TP 100

2. **RSI Oversold/Overbought (mean-reversion)**
   Buy EURUSD when RSI(14) drops below 30 on H1 · SL 40 / TP 80

3. **MACD Cross (momentum)**
   Buy EURUSD when MACD line crosses above signal line on H4 · SL 60 / TP 120

4. **Bollinger Band Bounce (range)**
   Buy EURUSD when price closes below lower Bollinger Band (20,2) on H1 · SL 40 / TP 80

5. **Candlestick Pattern (price action)**
   Buy EURUSD when bullish engulfing pattern appears on H4 · SL 50 / TP 100

After presenting the list, ask which one they want to try (or if they want a customized version).
Once the user picks one, immediately proceed into the normal ADD flow (collect slot/lot/SL/TP if
not already clear, then confirm and execute).

Do NOT ask "do you want suggestions?" — just offer them proactively when the user is lost.

## SYSTEM LIMITATIONS

This system ONLY supports strategies expressible as:
- Technical indicator comparisons (MA, RSI, MACD, Bollinger, Stochastic, CCI, ADX, ATR, SAR, Ichimoku, Alligator, Momentum, WPR)
- Price action candle patterns (engulfing, hammer, doji, morning/evening star, etc.)
- Market structure functions (uptrend, downtrend, breakout, consolidation)
- Combinations of the above with AND/OR/NOT logic

CANNOT support (decline gracefully in user's language, suggest a supported alternative):
- News or fundamental-based conditions ("when Fed raises rates", "when NFP is released")
- Sentiment or social media signals
- Machine learning or AI price predictions
- Custom/proprietary indicators not in the supported list
- Inter-symbol correlation ("when gold rises, sell USD")
- Order flow, volume profile, market depth, DOM
- Any condition that cannot be expressed as indicator thresholds or candle patterns

When declining, always: (1) explain what is unsupported, (2) suggest the closest supported alternative if one exists.

## EVENT TAGS (injected by system — never write these yourself)

After [EXECUTE], the system appends one of these tags to the conversation:
- `[STRATEGY_EVENT:applied:<op>:<slot>]`           → operation succeeded, EA applied it
- `[STRATEGY_EVENT:saved_not_applied:<op>:<slot>]` → saved but EA not connected
- `[STRATEGY_EVENT:ea_error:<detail>]`             → EA returned an error
- `[STRATEGY_ERROR:<code>]`                        → config validation failed

When you see one of these tags in the history, explain the outcome to the user in their
own language in a natural, friendly way. Do NOT expose the raw tag to the user.

### ORDER RESULT EVENTS (injected by system after order execution)

After an order [EXECUTE] is processed, the system replaces your reply with the MT4 result.
In subsequent turns, your previous assistant message in history will contain the result text,
for example:
  "✅ **Order opened** • Ticket: **#12345** | BUY EURUSD ..."
  "✅ **Order #12345 closed** • Close price: 1.08512 | P&L: **+12.50**"
  "❌ Order failed: `ERR_REQUOTE`"
  "⚠️ EA timeout — no response received."

When you see such a result in history:
- Refer to it naturally for PAST actions ("your order opened at ...", "the close succeeded")
- If it shows a failure, offer to retry or suggest next steps
- Do NOT re-emit [EXECUTE] for the same operation unless the user explicitly requests a retry

**CRITICAL — live order queries:**
When the user asks about CURRENT open orders — e.g.
  EN: "show orders", "what orders do I have", "list orders", "open positions"
  RU: "текущие ордера", "открытые позиции"
  ZH: "当前订单", "持仓"
  ES: "órdenes abiertas", "posiciones"
  PT: "ordens abertas", "posições"
— you MUST emit `[EXECUTE:{"op":"order_list"}]` immediately — do NOT answer from history.
Order state (P&L, SL, TP) changes every tick; history is stale. No confirmation needed.

**CRITICAL — order history queries:**
When the user asks about PAST/CLOSED orders — e.g.
  EN: "order history", "last 10 orders", "closed orders", "orders today"
  RU: "история ордеров", "последние 10 ордеров"
  ZH: "订单历史", "最近10笔"
  ES: "historial de órdenes", "últimas 10 órdenes"
  PT: "histórico de ordens", "últimas 10 ordens"
— emit the appropriate [EXECUTE] immediately. Do NOT answer from history. Rules:
- Specific count → `[EXECUTE:{"op":"order_history_last","limit":N}]`
- Unspecified / "today" / "48h" → `[EXECUTE:{"op":"order_history_48h"}]`
No confirmation needed.

**CRITICAL — market data queries:**
When the user asks about price, indicator values, candles, spread, or any live market data — e.g.
  EN: "EURUSD price", "RSI14 H1", "MACD XAUUSD", "last H4 candle", "is market overbought", "current spread"
  RU: "цена EURUSD", "RSI на H1", "текущая цена золота", "свечи H4"
  ZH: "欧元美元价格", "RSI14 H1", "黄金当前价", "H4 K线"
  ES: "precio EURUSD", "RSI14 en H1", "precio actual del oro"
  PT: "preço EURUSD", "RSI14 H1", "preço atual do ouro"
— ALWAYS emit market_query [EXECUTE] immediately. Do NOT make up values. Fetch live data first.
No confirmation needed.

**CRITICAL — live strategy queries:**
When the user asks about current strategies — e.g.
  EN: "list strategies", "what strategies are active", "show S1"
  RU: "список стратегий", "активные стратегии"
  ZH: "策略列表", "当前策略"
  ES: "listar estrategias", "estrategias activas"
— answer using ONLY the `## CURRENT EA STRATEGIES` context injected into the system prompt.
It is always fresh. Do NOT reconstruct from conversation history.

**CRITICAL — enable/disable (no confirmation needed):**
When the user wants to disable a strategy — e.g.
  EN: "disable S1", "turn off S2", "pause strategy 1", "stop S1 trading"
  RU: "отключить S1", "выключить стратегию 1"
  ZH: "关闭S1", "停用策略1"
  ES: "desactivar S1", "pausar estrategia 1"
→ emit `[EXECUTE:{"op":"update","sid":N,"enabled":false}]` immediately.
When the user wants to enable — e.g.
  EN: "enable S1", "turn on S2", "resume S1"
  RU: "включить S1"  ZH: "启用S1"  ES: "activar S1"
→ emit `[EXECUTE:{"op":"update","sid":N,"enabled":true}]` immediately.
Do NOT ask for confirmation — this is a reversible toggle, not a destructive action.

**For `applied` or `saved_not_applied` with op=`add` or op=`update`:**
Reply with a success message AND a full summary of the strategy, formatted as:

  ✅ [Slot] – [Direction] [Symbol] ([Timeframe])
  • Entry : [entry condition from prompt, in user's language]
  • Lot   : [lot] | SL: [sl] pip | TP: [tp] pip

  (add "⚠️ EA not connected — strategy saved, will apply when EA reconnects." if saved_not_applied)

**For op=`delete`:** brief confirmation only — no summary needed.

Error codes for `[STRATEGY_ERROR:...]`:
- `missing_action`               → direction (BUY/SELL) was not determinable
- `missing_condition`            → no technical entry condition could be parsed
- `unknown_indicators:<x>`       → indicator `x` was referenced but not declared
- `unsupported_fn:<x>`           → PA function `x` is not supported by the system
- `too_many_indicators:<n>>`     → strategy uses too many indicators (max 15)
- `unsupported:<reason>`         → strategy requires unsupported features
- `parse_failed`                 → config could not be generated

## EXAMPLES

### Example A (English — ADD, collecting info)
User: add strategy buy gold when RSI below 30
Assistant: Which slot would you like to use (S1–S5)?

User: S2
Assistant: Confirm add to **S2**?
• Direction: **BUY XAUUSD** when RSI(14) < 30
• Lot: 0.10 | SL: 50 pip | TP: 100 pip | TF: auto-detect
Reply "yes" to confirm.

User: yes
Assistant: [EXECUTE:{"op":"add","sid":1,"prompt":"Buy XAUUSD when RSI(14) is below 30","lot":0.10,"sl":50,"tp":100,"tf":0}]

### Example B (English — UPDATE)
User: change S1 SL to 30 and lot to 0.2
Assistant: Confirm update **S1**?
• SL: 50 → **30 pip**
• Lot: 0.10 → **0.20**
Reply "yes" to confirm.

User: yes
Assistant: [EXECUTE:{"op":"update","sid":0,"sl":30,"lot":0.20}]

### Example C (market query — emit immediately, no confirmation)
User: What is the current RSI14 on EURUSD H1?
Assistant: [EXECUTE:{"op":"market_query","symbol":"EURUSD","tf":60,"bars":3,"indicators":[{"name":"rsi14","type":"iRSI","period":14,"applied":0,"shift":0}]}]

User: цена XAUUSD сейчас?
Assistant: [EXECUTE:{"op":"market_query","symbol":"XAUUSD","tf":60,"bars":1,"indicators":[]}]

User: 黄金现在多少钱？
Assistant: [EXECUTE:{"op":"market_query","symbol":"XAUUSD","tf":60,"bars":1,"indicators":[]}]

### Example D (Russian — ADD)
User: Добавить стратегию покупки EURUSD когда RSI ниже 30, слот S1
Assistant: Подтвердите добавление в **S1**?
• Направление: **BUY EURUSD** при RSI(14) < 30
• Лот: 0.10 | SL: 50 пип | TP: 100 пип
Ответьте "да" для подтверждения.

User: да
Assistant: [EXECUTE:{"op":"add","sid":0,"prompt":"Buy EURUSD when RSI(14) is below 30","lot":0.10,"sl":50,"tp":100,"tf":0}]

### Example E (off-topic — reply in user's language)
User (English): What do you think about the Fed interest rate decision?
Assistant: I can't provide macroeconomic analysis. I support: strategy management (add/update/delete), manual orders, and live market data queries (price, indicators). What would you like to do?

User (Chinese): 你觉得美联储会加息吗？
Assistant: 抱歉，我不支持宏观经济分析。我支持：策略管理（添加/修改/删除）、手动下单、实时行情查询。请问您需要什么帮助？

User (Spanish): ¿Qué opinas del petróleo?
Assistant: Lo siento, no ofrezco análisis fundamentales. Puedo ayudarte con: gestión de estrategias, órdenes manuales y consultas de datos de mercado en vivo. ¿En qué puedo ayudarte?
"""


@app.post("/chat/message")
async def chat_message(request: Request, db: Session = Depends(get_db)):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"status": "error", "message": "Invalid JSON"}, status_code=400)

    token   = body.get("token", "")
    message = str(body.get("message", "")).strip()
    # NOTE: client-sent history is intentionally ignored — server manages conversation
    # state to prevent fake-assistant history injection attacks.

    if not message:
        return JSONResponse({"status": "error", "message": "Missing message"}, status_code=400)

    # ── Input length guard ────────────────────────────────────────────────
    if len(message) > _MSG_MAX_LEN:
        return JSONResponse(
            {"status": "error", "message": f"Message too long (max {_MSG_MAX_LEN} chars)"},
            status_code=400,
        )

    # ── Strip [EXECUTE:...] attempts from user input ──────────────────────
    if "[EXECUTE:" in message:
        message = message.replace("[EXECUTE:", "[BLOCKED:")

    try:
        user = _verify_account(token, db)
    except Exception as e:
        msg = getattr(e, "detail", None) or str(e)
        code = getattr(e, "status_code", 401)
        return JSONResponse({"status": "error", "message": str(msg)}, status_code=code)

    # ── Rate limit ────────────────────────────────────────────────────────
    if not _rate_check(user.account_number):
        return JSONResponse(
            {"status": "error", "message": f"Too many requests. Limit: {_RATE_LIMIT} per {_RATE_WINDOW}s"},
            status_code=429,
        )

    if not CLAUDE_API_KEY:
        return JSONResponse({"status": "error", "message": "Claude API key not configured"}, status_code=500)

    # ── Per-account lock: prevent concurrent CRUD race conditions ─────────
    lock = _account_locks.setdefault(user.account_number, asyncio.Lock())
    async with lock:
        return await _handle_chat_http(message, user)


async def _handle_chat_http(message: str, user: "User") -> JSONResponse:
    """Inner HTTP chat handler — runs inside per-account lock."""
    # ── Build multi-turn messages from server-side history ────────────────
    messages = _conv_get(user.account_number) + [{"role": "user", "content": message}]

    try:
        resp = await asyncio.wait_for(
            _claude.messages.create(
                model=CLAUDE_CHAT_MODEL,
                max_tokens=CLAUDE_CHAT_MAX_TOKENS,
                system=[
                    {"type": "text", "text": STRATEGY_SYSTEM_PROMPT,
                     "cache_control": {"type": "ephemeral"}},
                    {"type": "text", "text": "\n\n## CURRENT EA STRATEGIES\n"
                                             + _strategy_context(user.account_number)},
                ],
                messages=messages,
            ),
            timeout=30.0,
        )
    except asyncio.TimeoutError:
        return JSONResponse({"status": "error", "message": "Claude API timeout"}, status_code=504)
    except anthropic.AuthenticationError:
        return JSONResponse({"status": "error", "message": "Claude API key invalid"}, status_code=500)
    except anthropic.APIConnectionError:
        return JSONResponse({"status": "error", "message": "Cannot reach Claude API"}, status_code=503)
    except Exception as e:
        return JSONResponse({"status": "error", "message": str(e)}, status_code=500)

    reply = resp.content[0].text

    # ── Persist conversation to server-side store ────────────────────────
    _conv_append(user.account_number, "user",      message)
    _conv_append(user.account_number, "assistant", reply)

    # ── Parse and execute CRUD action if present ─────────────────────────
    action = _extract_execute(reply)
    if action:
        op = action.get("op", "")

        # ── Order ops (no sid required) ───────────────────────────────────
        if op == "market_query":
            reply = _strip_execute(reply)
            acct  = user.account_number
            mq_result = await _ea_request(acct, {
                "event":      "market_query_request",
                "symbol":     action.get("symbol", ""),
                "tf":         int(action.get("tf", 60)),
                "bars":       min(int(action.get("bars", 5)), 50),
                "indicators": action.get("indicators", []),
            }, timeout=10.0)
            if mq_result is None:
                reply += "\n\n---\n⚠️ `market_query_timeout` — EA did not respond."
            else:
                formatted = _format_market_data(mq_result)
                # Second Claude call (Haiku — cheaper/faster for data summarization)
                inject_msgs = _conv_get(acct) + [{
                    "role": "user",
                    "content": (
                        f"[MARKET_DATA from MT4]\n{formatted}\n[/MARKET_DATA]\n"
                        "Answer the user's question based on the data above. "
                        "Be concise. Do NOT reproduce a raw table — "
                        "summarize key values inline or as a short bullet list."
                    ),
                }]
                try:
                    resp2 = await asyncio.wait_for(
                        _claude.messages.create(
                            model="claude-haiku-4-5-20251001",
                            max_tokens=CLAUDE_CHAT_MAX_TOKENS,
                            system=STRATEGY_SYSTEM_PROMPT,
                            messages=inject_msgs,
                        ),
                        timeout=20.0,
                    )
                    reply = resp2.content[0].text
                except Exception:
                    reply = formatted  # fallback: show raw data
            _conv_update_last_assistant(acct, reply)
            action = None

        elif op in VALID_ORDER_OPS:
            reply = _strip_execute(reply)
            reply += await _handle_order_execute(action, user.account_number)
            _conv_update_last_assistant(user.account_number, reply)
            action = None  # mark as handled

        else:
            sid = int(action.get("sid", 0))

        # ── Validate strategy [EXECUTE] fields ────────────────────────────
        if action is not None and op not in VALID_OPS:
            logger.warning(f"CRUD blocked: invalid op={op!r} account={user.account_number}")
            action = None

        elif action is not None and sid not in VALID_SID:
            logger.warning(f"CRUD blocked: sid={sid} out of range account={user.account_number}")
            action = None

        elif action is not None and op == "add":
            raw_lot = action.get("lot", 0.1)
            raw_sl  = action.get("sl",  50)
            raw_tp  = action.get("tp",  100)
            raw_tf  = action.get("tf",  0)
            action["lot"] = max(0.01, min(float(raw_lot), 100.0))
            action["sl"]  = max(1,    min(int(raw_sl),   10000))
            action["tp"]  = max(1,    min(int(raw_tp),   10000))
            action["tf"]  = int(raw_tf) if int(raw_tf) in VALID_TFS else 0

        elif op == "update":
            if "lot" in action: action["lot"] = max(0.01, min(float(action["lot"]), 100.0))
            if "sl"  in action: action["sl"]  = max(1,    min(int(action["sl"]),   10000))
            if "tp"  in action: action["tp"]  = max(1,    min(int(action["tp"]),   10000))
            if "tf"  in action: action["tf"]  = int(action["tf"]) if int(action["tf"]) in VALID_TFS else 0

    if action:
        op  = action.get("op", "")
        sid = int(action.get("sid", 0))
        ea_connected = user.account_number in ws_ea_clients

        # Track outcome: "sent" | "no_ea" | "parse_error" | "error"
        crud_result = "no_op"
        crud_error  = ""

        acct = user.account_number
        try:
            if op == "add":
                prompt_str = action.get("prompt", "")
                lot = float(action.get("lot", 0.1))
                sl  = int(action.get("sl",  50))
                tp  = int(action.get("tp",  100))
                tf  = int(action.get("tf",  0))

                config = await _call_init_claude(prompt_str, lot=lot, sl=sl, tp=tp, tf=tf)
                if config is None:
                    crud_result = "parse_error"
                elif config.get("action") == "UNSUPPORTED":
                    crud_result = "parse_error"
                    crud_error  = f"unsupported:{config.get('reason', 'strategy too complex')}"
                else:
                    _ok, _reason = _validate_strategy_config(config)
                    if not _ok:
                        crud_result = "parse_error"
                        crud_error  = _reason
                    else:
                        resolved_lot = config.get("lot",       lot)
                        resolved_sl  = config.get("sl_pip",    sl)
                        resolved_tp  = config.get("tp_pip",    tp)
                        payload: dict = {
                            "event": "strategy_add",
                            "sid":   sid,
                            "config": {
                                "prompt":     prompt_str,
                                "lot":        resolved_lot,
                                "sl_pip":     resolved_sl,
                                "sl":         resolved_sl,
                                "tp_pip":     resolved_tp,
                                "tp":         resolved_tp,
                                "tf":         config.get("tf",        tf),
                                "action":     config.get("action",    "BUY"),
                                "symbol":     config.get("symbol",    ""),
                                "ohlc_bars":  config.get("ohlc_bars", 3),
                                "indicators":      config.get("indicators",      []),
                                "condition":       config.get("condition",       {}),
                                "exit_condition":  config.get("exit_condition",  {}),
                            }
                        }
                        _strategy_store_save(acct, sid, {
                            "prompt":  prompt_str,
                            "lot":     resolved_lot,
                            "sl":      resolved_sl,
                            "tp":      resolved_tp,
                            "tf":      config.get("tf",     tf),
                            "action":  config.get("action", "BUY"),
                            "symbol":  config.get("symbol", ""),
                            "enabled": True,
                        })
                        await ws_broadcast(acct, payload)
                        crud_result = "sent" if ea_connected else "no_ea"

            elif op == "update":
                existing = strategy_store.get(acct, {}).get(sid, {})
                if "prompt" in action:
                    # Prompt changed → re-parse condition tree
                    new_prompt = action["prompt"]
                    new_lot = float(action.get("lot", existing.get("lot", 0.1)))
                    new_sl  = int(action.get("sl",  existing.get("sl",  50)))
                    new_tp  = int(action.get("tp",  existing.get("tp",  100)))
                    new_tf  = int(action.get("tf",  existing.get("tf",  0)))
                    new_sym = existing.get("symbol", "")
                    config = await _call_init_claude(new_prompt, symbol=new_sym,
                                                     lot=new_lot, sl=new_sl,
                                                     tp=new_tp, tf=new_tf)
                    if config is None:
                        crud_result = "parse_error"
                    elif config.get("action") == "UNSUPPORTED":
                        crud_result = "parse_error"
                        crud_error  = f"unsupported:{config.get('reason', 'strategy too complex')}"
                    else:
                        _ok, _reason = _validate_strategy_config(config)
                        if not _ok:
                            crud_result = "parse_error"
                            crud_error  = _reason
                        else:
                            resolved_lot = config.get("lot",    new_lot)
                            resolved_sl  = config.get("sl_pip", new_sl)
                            resolved_tp  = config.get("tp_pip", new_tp)
                            payload = {
                                "event": "strategy_add",
                                "sid":   sid,
                                "config": {
                                    "prompt":     new_prompt,
                                    "lot":        resolved_lot,
                                    "sl_pip":     resolved_sl,
                                    "sl":         resolved_sl,
                                    "tp_pip":     resolved_tp,
                                    "tp":         resolved_tp,
                                    "tf":         config.get("tf",        new_tf),
                                    "action":     config.get("action",    "BUY"),
                                    "symbol":     config.get("symbol",    new_sym),
                                    "ohlc_bars":  config.get("ohlc_bars", 3),
                                    "indicators":      config.get("indicators",      []),
                                    "condition":       config.get("condition",       {}),
                                    "exit_condition":  config.get("exit_condition",  {}),
                                }
                            }
                            _strategy_store_save(acct, sid, {
                                "prompt":  new_prompt,
                                "lot":     resolved_lot,
                                "sl":      resolved_sl,
                                "tp":      resolved_tp,
                                "tf":      config.get("tf",     new_tf),
                                "action":  config.get("action", "BUY"),
                                "symbol":  config.get("symbol", new_sym),
                                "enabled": existing.get("enabled", True),
                            })
                            await ws_broadcast(acct, payload)
                            crud_result = "sent" if ea_connected else "no_ea"
                else:
                    # Parameters only (lot/sl/tp/tf/enabled) → partial update
                    upd: dict = {"event": "strategy_update", "sid": sid}
                    store_upd: dict = {}
                    for k in ("lot", "sl", "tp", "tf"):
                        if k in action:
                            upd[k] = action[k]
                            store_upd[k] = action[k]
                    if "enabled" in action:
                        en = bool(action["enabled"])
                        upd["enabled"] = 1 if en else 0   # EA reads as number
                        store_upd["enabled"] = en
                    _strategy_store_save(acct, sid, {**existing, **store_upd})
                    await ws_broadcast(acct, upd)
                    crud_result = "sent" if ea_connected else "no_ea"

            elif op == "delete":
                _strategy_store_delete(acct, sid)
                await ws_broadcast(acct, {"event": "strategy_delete", "sid": sid})
                crud_result = "sent" if ea_connected else "no_ea"

            logger.info(f"CRUD op={op} sid={sid} account={acct} "
                        f"ea={ea_connected} result={crud_result}")

        except Exception as ex:
            crud_result = "error"
            crud_error  = str(ex)
            logger.error(f"CRUD execute error op={op} sid={sid}: {ex}")

        # Strip [EXECUTE] and append result feedback
        reply = _strip_execute(reply)

        if crud_result == "parse_error":
            error_code = crud_error or "parse_failed"
            # Inject into history so Claude explains in the user's language next turn
            _conv_append(user.account_number, "assistant",
                         f"[STRATEGY_ERROR:{error_code}]")
            reply += f"\n\n❌ `strategy_error:{error_code}`"
        elif crud_result == "error":
            tag = f"[STRATEGY_EVENT:ea_error:{crud_error}]"
            _conv_append(user.account_number, "assistant", tag)
            reply += f"\n\n❌ `ea_error:{crud_error}`"
        elif crud_result in ("no_ea", "sent"):
            reply += _format_strategy_summary(
                user.account_number, sid, op, ea_connected=(crud_result == "sent"),
                old_values=existing if op == "update" else None,
            )

    logger.info(f"Chat {user.account_number}: {message[:50]}...")
    return {"status": "ok", "reply": reply}


# ── Chat URL for QR ────────────────────────────────────────────────────────────

@app.get("/chat/url")
def chat_url(token: str, db: Session = Depends(get_db)):
    try:
        _verify_account(token, db)
    except Exception as e:
        return JSONResponse({"status": "error", "message": str(e.detail)}, status_code=e.status_code)
    return {"url": f"{FRONTEND_URL}/chat?token={token}"}


# ── WebSocket — DLL (AI_Bridge.cpp) ───────────────────────────────────────────

@app.websocket("/ws/ea/{account_number}")
async def ws_ea_connect(
    ws: WebSocket,
    account_number: str,
    token: str = "",
    db: Session = Depends(get_db),
):
    try:
        _verify_account(token, db)
    except Exception:
        await ws.close(code=4001)
        return

    old = ws_ea_clients.pop(account_number, None)
    if old:
        try:
            await old.close(code=1001)
        except Exception:
            pass
    await ws.accept()
    ws_ea_clients[account_number] = ws
    _last_activity[account_number] = time.time()
    logger.info(f"WS-EA connected: {account_number}")

    try:
        await ws.send_json({"event": "connected"})
        while True:
            data = await ws.receive_json()
            event = data.get("event", "")

            if event == "ping":
                await ws.send_json({"event": "pong"})

            elif event == "strategy_hello":
                # DLL sends all active sessions on connect — merge into strategy_store
                # Backend is source of truth: only fill slots not already stored
                # (preserves chat-based lot/sl/tp modifications across EA restarts)
                strategies = data.get("strategies", [])
                existing_store = strategy_store.get(account_number, {})
                for s in strategies:
                    sid = int(s.get("sid", -1))
                    if 0 <= sid <= 4 and sid not in existing_store:
                        _strategy_store_save(account_number, sid, {
                            "prompt":  s.get("prompt", ""),
                            "lot":     s.get("lot",    0.1),
                            "sl":      s.get("sl",     50),
                            "tp":      s.get("tp",     100),
                            "tf":      s.get("tf",     0),
                            "action":  s.get("action", "BUY"),
                            "symbol":  s.get("symbol", ""),
                            "enabled": True,
                        })
                logger.info(f"WS-EA strategy_hello: {len(strategies)} sessions for {account_number}")

                # Push any stored parameter changes back to EA (lot/sl/tp/tf only —
                # indicators stay as set by Bridge_Init; don't send prompt/symbol here)
                ea_by_sid = {int(s.get("sid", -1)): s for s in strategies if 0 <= int(s.get("sid", -1)) <= 4}
                current_store = strategy_store.get(account_number, {})
                for sid, stored in current_store.items():
                    ea = ea_by_sid.get(sid, {})
                    upd: dict = {"event": "strategy_update", "sid": sid}
                    for k in ("lot", "sl", "tp", "tf"):
                        stored_v = stored.get(k)
                        ea_v     = ea.get(k)
                        if stored_v is not None and stored_v != ea_v:
                            upd[k] = stored_v
                    # Always sync enabled (EA resets to true on reconnect)
                    stored_enabled = stored.get("enabled", True)
                    upd["enabled"] = 1 if stored_enabled else 0
                    await ws_ea_push(account_number, upd)
                    logger.info(f"WS-EA re-sync S{sid+1}: {upd}")

                # Forward live strategy list to frontend if connected
                await ws_chat_push(account_number, {
                    "event":      "strategy_list",
                    "strategies": [{"sid": sid, **d}
                                   for sid, d in strategy_store.get(account_number, {}).items()],
                })

            elif event == "strategy_update":
                sid = int(data.get("sid", -1))
                if 0 <= sid <= 4:
                    existing = strategy_store.get(account_number, {}).get(sid, {})
                    updated  = {**existing, **{
                        k: data[k] for k in ("prompt","lot","sl","tp","tf","action","symbol")
                        if k in data
                    }}
                    _strategy_store_save(account_number, sid, updated)
                    await ws_chat_push(account_number, {"event": "strategy_update", "sid": sid, **updated})

            elif event == "strategy_delete":
                sid = int(data.get("sid", -1))
                if 0 <= sid <= 4:
                    _strategy_store_delete(account_number, sid)
                    await ws_chat_push(account_number, {"event": "strategy_delete", "sid": sid})

            elif event == "signal_order_fail":
                sid    = int(data.get("sid", 0)) + 1
                action = data.get("action", "ORDER")
                sym    = data.get("symbol", "")
                lot    = data.get("lot", 0)
                reason = data.get("reason", f"error {data.get('err', '?')}")
                reply  = (f"❌ **S{sid} {action} {sym}** failed — {reason}\n"
                          f"Lot: {lot}")
                await ws_chat_push(account_number, {"event": "chat_reply", "reply": reply})

            elif event in ("order_result", "order_list", "order_history", "market_data"):
                fut = _ea_pending.get(account_number)
                if fut and not fut.done():
                    fut.set_result(data)

    except WebSocketDisconnect:
        ws_ea_clients.pop(account_number, None)
        # Cancel pending EA request so callers don't wait for the full timeout
        fut = _ea_pending.pop(account_number, None)
        if fut and not fut.done():
            fut.cancel()
        logger.info(f"WS-EA disconnected: {account_number}")


# ── Chat core — shared by HTTP and WebSocket handlers ─────────────────────────

async def _handle_chat_ws(message: str, user: "User") -> str:
    """Full chat pipeline: sanitize → Claude → CRUD dispatch → feedback.
    Rate-limit and lock are applied by the caller before invoking this."""
    if len(message) > _MSG_MAX_LEN:
        return f"⚠️ `message_too_long:max={_MSG_MAX_LEN}`"

    if "[EXECUTE:" in message:
        message = message.replace("[EXECUTE:", "[BLOCKED:")

    if not CLAUDE_API_KEY:
        return "⚠️ `claude_api_key_not_configured`"

    messages = _conv_get(user.account_number) + [{"role": "user", "content": message}]

    try:
        resp = await asyncio.wait_for(
            _claude.messages.create(
                model=CLAUDE_CHAT_MODEL,
                max_tokens=CLAUDE_CHAT_MAX_TOKENS,
                system=[
                    {"type": "text", "text": STRATEGY_SYSTEM_PROMPT,
                     "cache_control": {"type": "ephemeral"}},
                    {"type": "text", "text": "\n\n## CURRENT EA STRATEGIES\n"
                                             + _strategy_context(user.account_number)},
                ],
                messages=messages,
            ),
            timeout=30.0,
        )
    except asyncio.TimeoutError:
        return "⚠️ `claude_timeout`"
    except anthropic.AuthenticationError:
        return "⚠️ `claude_auth_error`"
    except anthropic.APIConnectionError:
        return "⚠️ `claude_connection_error`"
    except Exception as e:
        return f"⚠️ `claude_error:{e}`"

    reply = resp.content[0].text

    _conv_append(user.account_number, "user",      message)
    _conv_append(user.account_number, "assistant", reply)

    action = _extract_execute(reply)
    if action:
        op = action.get("op", "")

        # ── Order ops ─────────────────────────────────────────────────────
        if op == "market_query":
            reply = _strip_execute(reply)
            acct  = user.account_number
            mq_result = await _ea_request(acct, {
                "event":      "market_query_request",
                "symbol":     action.get("symbol", ""),
                "tf":         int(action.get("tf", 60)),
                "bars":       min(int(action.get("bars", 5)), 50),
                "indicators": action.get("indicators", []),
            }, timeout=10.0)
            if mq_result is None:
                reply += "\n\n---\n⚠️ `market_query_timeout` — EA did not respond."
            else:
                formatted = _format_market_data(mq_result)
                inject_msgs = _conv_get(acct) + [{
                    "role": "user",
                    "content": (
                        f"[MARKET_DATA from MT4]\n{formatted}\n[/MARKET_DATA]\n"
                        "Answer the user's question based on the data above. "
                        "Be concise. Do NOT reproduce a raw table — "
                        "summarize key values inline or as a short bullet list."
                    ),
                }]
                try:
                    resp2 = await asyncio.wait_for(
                        _claude.messages.create(
                            model=CLAUDE_CHAT_MODEL,
                            max_tokens=CLAUDE_CHAT_MAX_TOKENS,
                            system=[{"type": "text", "text": STRATEGY_SYSTEM_PROMPT,
                                     "cache_control": {"type": "ephemeral"}}],
                            messages=inject_msgs,
                        ),
                        timeout=30.0,
                    )
                    reply = resp2.content[0].text
                except Exception:
                    reply = formatted
            _conv_update_last_assistant(acct, reply)
            action = None

        elif op in VALID_ORDER_OPS:
            reply = _strip_execute(reply)
            reply += await _handle_order_execute(action, user.account_number)
            _conv_update_last_assistant(user.account_number, reply)
            action = None

        else:
            sid = int(action.get("sid", 0))

        if action is not None and op not in VALID_OPS:
            logger.warning(f"CRUD blocked: invalid op={op!r} account={user.account_number}")
            action = None
        elif action is not None and sid not in VALID_SID:
            logger.warning(f"CRUD blocked: sid={sid} out of range account={user.account_number}")
            action = None
        elif action is not None and op == "add":
            action["lot"] = max(0.01, min(float(action.get("lot", 0.1)), 100.0))
            action["sl"]  = max(1,    min(int(action.get("sl",  50)),   10000))
            action["tp"]  = max(1,    min(int(action.get("tp",  100)),  10000))
            action["tf"]  = int(action.get("tf", 0)) if int(action.get("tf", 0)) in VALID_TFS else 0
        elif action is not None and op == "update":
            if "lot" in action: action["lot"] = max(0.01, min(float(action["lot"]), 100.0))
            if "sl"  in action: action["sl"]  = max(1,    min(int(action["sl"]),   10000))
            if "tp"  in action: action["tp"]  = max(1,    min(int(action["tp"]),   10000))
            if "tf"  in action: action["tf"]  = int(action["tf"]) if int(action["tf"]) in VALID_TFS else 0

    if action:
        op  = action.get("op", "")
        sid = int(action.get("sid", 0))
        ea_connected = user.account_number in ws_ea_clients
        crud_result  = "no_op"
        crud_error   = ""
        acct         = user.account_number

        try:
            if op == "add":
                prompt_str = action.get("prompt", "")
                lot = float(action.get("lot", 0.1))
                sl  = int(action.get("sl",  50))
                tp  = int(action.get("tp",  100))
                tf  = int(action.get("tf",  0))

                config = await _call_init_claude(prompt_str, lot=lot, sl=sl, tp=tp, tf=tf)
                if config is None:
                    crud_result = "parse_error"
                elif config.get("action") == "UNSUPPORTED":
                    crud_result = "parse_error"
                    crud_error  = f"unsupported:{config.get('reason', 'strategy too complex')}"
                else:
                    _ok, _reason = _validate_strategy_config(config)
                    if not _ok:
                        crud_result = "parse_error"
                        crud_error  = _reason
                    else:
                        resolved_lot = config.get("lot",       lot)
                        resolved_sl  = config.get("sl_pip",    sl)
                        resolved_tp  = config.get("tp_pip",    tp)
                        payload: dict = {
                            "event": "strategy_add",
                            "sid":   sid,
                            "config": {
                                "prompt":     prompt_str,
                                "lot":        resolved_lot,
                                "sl_pip":     resolved_sl,
                                "sl":         resolved_sl,
                                "tp_pip":     resolved_tp,
                                "tp":         resolved_tp,
                                "tf":         config.get("tf",        tf),
                                "action":     config.get("action",    "BUY"),
                                "symbol":     config.get("symbol",    ""),
                                "ohlc_bars":  config.get("ohlc_bars", 3),
                                "indicators":      config.get("indicators",      []),
                                "condition":       config.get("condition",       {}),
                                "exit_condition":  config.get("exit_condition",  {}),
                            }
                        }
                        _strategy_store_save(acct, sid, {
                            "prompt":  prompt_str,
                            "lot":     resolved_lot,
                            "sl":      resolved_sl,
                            "tp":      resolved_tp,
                            "tf":      config.get("tf",     tf),
                            "action":  config.get("action", "BUY"),
                            "symbol":  config.get("symbol", ""),
                            "enabled": True,
                        })
                        await ws_ea_push(acct, payload)
                        crud_result = "sent" if ea_connected else "no_ea"

            elif op == "update":
                existing = strategy_store.get(acct, {}).get(sid, {})
                if "prompt" in action:
                    # Prompt changed → re-parse condition tree
                    new_prompt = action["prompt"]
                    new_lot = float(action.get("lot", existing.get("lot", 0.1)))
                    new_sl  = int(action.get("sl",  existing.get("sl",  50)))
                    new_tp  = int(action.get("tp",  existing.get("tp",  100)))
                    new_tf  = int(action.get("tf",  existing.get("tf",  0)))
                    new_sym = existing.get("symbol", "")
                    config = await _call_init_claude(new_prompt, symbol=new_sym,
                                                     lot=new_lot, sl=new_sl,
                                                     tp=new_tp, tf=new_tf)
                    if config is None:
                        crud_result = "parse_error"
                    elif config.get("action") == "UNSUPPORTED":
                        crud_result = "parse_error"
                        crud_error  = f"unsupported:{config.get('reason', 'strategy too complex')}"
                    else:
                        _ok, _reason = _validate_strategy_config(config)
                        if not _ok:
                            crud_result = "parse_error"
                            crud_error  = _reason
                        else:
                            resolved_lot = config.get("lot",    new_lot)
                            resolved_sl  = config.get("sl_pip", new_sl)
                            resolved_tp  = config.get("tp_pip", new_tp)
                            payload = {
                                "event": "strategy_add",
                                "sid":   sid,
                                "config": {
                                    "prompt":     new_prompt,
                                    "lot":        resolved_lot,
                                    "sl_pip":     resolved_sl,
                                    "sl":         resolved_sl,
                                    "tp_pip":     resolved_tp,
                                    "tp":         resolved_tp,
                                    "tf":         config.get("tf",        new_tf),
                                    "action":     config.get("action",    "BUY"),
                                    "symbol":     config.get("symbol",    new_sym),
                                    "ohlc_bars":  config.get("ohlc_bars", 3),
                                    "indicators":      config.get("indicators",      []),
                                    "condition":       config.get("condition",       {}),
                                    "exit_condition":  config.get("exit_condition",  {}),
                                }
                            }
                            _strategy_store_save(acct, sid, {
                                "prompt":  new_prompt,
                                "lot":     resolved_lot,
                                "sl":      resolved_sl,
                                "tp":      resolved_tp,
                                "tf":      config.get("tf",     new_tf),
                                "action":  config.get("action", "BUY"),
                                "symbol":  config.get("symbol", new_sym),
                                "enabled": existing.get("enabled", True),
                            })
                            await ws_ea_push(acct, payload)
                            crud_result = "sent" if ea_connected else "no_ea"
                else:
                    # Parameters only (lot/sl/tp/tf/enabled) → partial update
                    upd: dict = {"event": "strategy_update", "sid": sid}
                    store_upd: dict = {}
                    for k in ("lot", "sl", "tp", "tf"):
                        if k in action:
                            upd[k] = action[k]
                            store_upd[k] = action[k]
                    if "enabled" in action:
                        en = bool(action["enabled"])
                        upd["enabled"] = 1 if en else 0
                        store_upd["enabled"] = en
                    _strategy_store_save(acct, sid, {**existing, **store_upd})
                    await ws_ea_push(acct, upd)
                    crud_result = "sent" if ea_connected else "no_ea"

            elif op == "delete":
                _strategy_store_delete(acct, sid)
                await ws_ea_push(acct, {"event": "strategy_delete", "sid": sid})
                crud_result = "sent" if ea_connected else "no_ea"

            logger.info(f"CRUD op={op} sid={sid} account={acct} "
                        f"ea={ea_connected} result={crud_result}")

        except Exception as ex:
            crud_result = "error"
            crud_error  = str(ex)
            logger.error(f"CRUD execute error op={op} sid={sid}: {ex}")

        reply = _strip_execute(reply)

        if crud_result == "parse_error":
            error_code = crud_error or "parse_failed"
            # Inject into history so Claude explains in the user's language next turn
            _conv_append(user.account_number, "assistant",
                         f"[STRATEGY_ERROR:{error_code}]")
            reply += f"\n\n❌ `strategy_error:{error_code}`"
        elif crud_result == "error":
            reply += (
                f"\n\n---\n"
                f"❌ **EA error:** `{crud_error}`\n"
                f"Please check the connection and try again."
            )
        elif crud_result in ("no_ea", "sent"):
            reply += _format_strategy_summary(
                user.account_number, sid, op, ea_connected=(crud_result == "sent"),
                old_values=existing if op == "update" else None,
            )

    logger.info(f"Chat {user.account_number}: {message[:50]}...")
    return reply


# ── WebSocket — Frontend chat client ──────────────────────────────────────────

@app.websocket("/ws/chat/{account_number}")
async def ws_chat_connect(
    ws: WebSocket,
    account_number: str,
    token: str = "",
    db: Session = Depends(get_db),
):
    try:
        user = _verify_account(token, db)
    except Exception:
        await ws.close(code=4001)
        return

    old = ws_chat_clients.pop(account_number, None)
    if old:
        try:
            await old.close(code=1001)
        except Exception:
            pass
    await ws.accept()
    ws_chat_clients[account_number] = ws
    _last_activity[account_number] = time.time()
    logger.info(f"WS-Chat connected: {account_number}")

    # Immediately push current strategy state
    ss = strategy_store.get(account_number, {})
    await ws.send_json({
        "event":      "strategy_list",
        "strategies": [{"sid": sid, **d} for sid, d in ss.items()],
    })

    try:
        while True:
            raw = await ws.receive_text()

            # Hard size limit — reject oversized frames immediately
            if len(raw.encode()) > _WS_MSG_MAX_BYTES:
                await ws.send_json({"event": "error", "message": "message_too_large"})
                continue

            try:
                data = __import__("json").loads(raw)
            except Exception:
                continue

            event = data.get("event", "")

            if event == "ping":
                await ws.send_json({"event": "pong"})

            elif event == "chat_message":
                message = str(data.get("message", "")).strip()
                if not message:
                    continue

                # Rate limit on WS (same as HTTP)
                if not _rate_check(user.account_number):
                    await ws.send_json({
                        "event": "chat_reply",
                        "reply": f"⚠️ `rate_limited:max={_RATE_LIMIT}/{_RATE_WINDOW}s`",
                    })
                    continue

                # Per-account lock: prevent concurrent CRUD race conditions
                lock = _account_locks.setdefault(user.account_number, asyncio.Lock())
                async with lock:
                    reply = await _handle_chat_ws(message, user)
                await ws.send_json({"event": "chat_reply", "reply": reply})

    except WebSocketDisconnect:
        ws_chat_clients.pop(account_number, None)
        # Cancel any pending EA request future for this account
        fut = _ea_pending.pop(account_number, None)
        if fut and not fut.done():
            fut.cancel()
        logger.info(f"WS-Chat disconnected: {account_number}")


async def ws_ea_push(account_number: str, payload: dict):
    """Send an event to the connected DLL (AI_Bridge.cpp)."""
    ws = ws_ea_clients.get(account_number)
    if ws:
        try:
            await ws.send_json(payload)
        except Exception:
            ws_ea_clients.pop(account_number, None)


async def ws_chat_push(account_number: str, payload: dict):
    """Send an event to the connected frontend chat client."""
    ws = ws_chat_clients.get(account_number)
    if ws:
        try:
            await ws.send_json(payload)
        except Exception:
            ws_chat_clients.pop(account_number, None)


# Keep backward-compat alias used in /chat/message CRUD
async def ws_broadcast(account_number: str, payload: dict):
    await ws_ea_push(account_number, payload)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run("main:app", host=HOST, port=PORT, reload=False)
