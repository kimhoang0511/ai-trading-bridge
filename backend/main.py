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

VALID_OPS  = {"add", "update", "delete"}
VALID_SID  = range(0, 5)        # slots 0-4
VALID_TFS  = {0, 1, 5, 15, 30, 60, 240, 1440, 10080}


def _conv_get(account: str) -> list:
    return _conv_store.get(account, [])


def _conv_append(account: str, role: str, content: str) -> None:
    h = _conv_store.setdefault(account, [])
    h.append({"role": role, "content": content})
    if len(h) > _CONV_MAX:
        _conv_store[account] = h[-_CONV_MAX:]
    _last_activity[account] = time.time()


def _strategy_store_save(account: str, sid: int, data: dict) -> None:
    strategy_store.setdefault(account, {})[sid] = data


def _strategy_store_delete(account: str, sid: int) -> None:
    strategy_store.get(account, {}).pop(sid, None)


def _strategy_context(account: str) -> str:
    """Build a strategy summary string to inject into Claude's system prompt."""
    ss = strategy_store.get(account, {})
    if not ss:
        return "Current strategies in EA: none configured yet."
    tf_map = {0:"auto",1:"M1",5:"M5",15:"M15",30:"M30",60:"H1",240:"H4",1440:"D1",10080:"W1"}
    lines = ["Current strategies in EA:"]
    for sid in sorted(ss):
        s  = ss[sid]
        tf = tf_map.get(int(s.get("tf", 0)), str(s.get("tf", 0)))
        lines.append(
            f"  S{sid+1} (sid={sid}): {s.get('action','?')} {s.get('symbol','?')} {tf}"
            f" | lot={s.get('lot',0.1)} SL={s.get('sl',50)} TP={s.get('tp',100)}"
            f" | prompt: \"{s.get('prompt','')[:80]}\""
        )
    return "\n".join(lines)


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

CLAUDE_API_KEY  = os.getenv("CLAUDE_API_KEY", "")
FRONTEND_URL    = os.getenv("FRONTEND_URL",  "http://192.168.21.1:3000")

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
        return JSONResponse({"status": "error", "message": "Token không hợp lệ hoặc đã hết hạn"}, status_code=401)

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
- iADX:        {"name":"adx14","type":"iADX","period":14,"applied":0,"shift":0}
- iMACD:       {"name":"macd","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"shift":0}
- iBands:      {"name":"bb20","type":"iBands","period":20,"deviation":2.0,"method":0,"applied":0,"shift":0}
- iStochastic: {"name":"sto","type":"iStochastic","kperiod":5,"dperiod":3,"slowing":3,"method":0,"shift":0}
- iSAR:        {"name":"sar","type":"iSAR","step":0.02,"maximum":0.2,"shift":0}
- iAlligator:  {"name":"alli","type":"iAlligator","p1":13,"s1":8,"p2":8,"s2":5,"p3":5,"s3":3,"method":1,"applied":4,"shift":0}
- iIchimoku:   {"name":"ichi","type":"iIchimoku","p1":9,"p2":26,"p3":52,"shift":0}

CONDITION TYPES:
- {"type":"AND","args":[...]}
- {"type":"OR","args":[...]}
- {"type":"NOT","arg":{...}}
- {"type":"CMP","left":"var_name"|number,"op":">/</>=/<=/==/!=","right":"var_name"|number}
- {"type":"FN","name":"fn_name","params":{"i":0,"n":3}}

PA FUNCTIONS: is_bull(i), is_bear(i), is_doji(i), is_hammer(i), is_shooting_star(i),
is_pin_bar(i), is_bull_engulfing(), is_bear_engulfing(), is_morning_star(), is_evening_star(),
is_uptrend(n), is_downtrend(n), is_bull_breakout(n), is_bear_breakout(n)

CROSSOVER RULE: "X crosses above Y" requires BOTH current and _prev variants:
  indicators: X(shift=0), X_prev(shift=1), Y(shift=0), Y_prev(shift=1)
  condition: CMP(X > Y) AND CMP(X_prev < Y_prev)

CRITICAL RULES:
1. If instruction mentions ANY indicator, add it to indicators array AND reference in condition.
2. Each indicator name used in condition MUST appear in indicators array.
3. action: BUY or SELL only.
4. symbol: extract from instruction, normalize to MT4 format (e.g. "gold"→"XAUUSD").
5. tf: minutes (1,5,15,30,60,240,1440); 0 if not specified.
6. sl_pip and tp_pip must be > 0; tp_pip >= sl_pip * 0.5.
7. ohlc_bars: minimum bars needed (crossover=2, default=3)."""

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
                  '{"type":"CMP","left":"rsi14","op":"<","right":70}]}}')
_FEW_SHOT_USER2 = ('Instruction: "Sell USDJPY H4 when MACD crosses below signal and Stochastic > 80. SL 30, TP 60"\n'
                   'Symbol: USDJPY\nDefault lot: 0.100000, SL: 30 pips, TP: 60 pips')
_FEW_SHOT_ASST2 = ('{"action":"SELL","tf":240,"lot":0.1,"sl_pip":30,"tp_pip":60,"ohlc_bars":2,'
                   '"indicators":['
                   '{"name":"macd_main","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"shift":0},'
                   '{"name":"macd_main_prev","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"shift":1},'
                   '{"name":"macd_sig","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"shift":0},'
                   '{"name":"macd_sig_prev","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"shift":1},'
                   '{"name":"sto_main","type":"iStochastic","kperiod":5,"dperiod":3,"slowing":3,"method":0,"shift":0}],'
                   '"condition":{"type":"AND","args":['
                   '{"type":"AND","args":['
                   '{"type":"CMP","left":"macd_main","op":"<","right":"macd_sig"},'
                   '{"type":"CMP","left":"macd_main_prev","op":">","right":"macd_sig_prev"}]},'
                   '{"type":"CMP","left":"sto_main","op":">","right":80}]}}')

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
                model="claude-sonnet-4-6",
                max_tokens=2000,
                system=INIT_SYSTEM_PROMPT,
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

**LIST** — Describe what each slot does (answer from conversation context)

## CONVERSATION RULES

1. **TOPIC GUARD** — If the user's message is not about strategy CRUD, politely decline
   in the user's own language and redirect to strategy management.
   Do not answer the off-topic question.

2. **COLLECT** — If required info is missing or ambiguous, ask ONE focused question.
   Do not ask multiple questions at once. Do not proceed until the answer is clear.

3. **CONFIRM** — Before executing ADD/UPDATE/DELETE, show a clear summary and ask:
   "Xác nhận?" / "Confirm?" — wait for explicit approval before emitting [EXECUTE].

4. **EXECUTE** — Only append [EXECUTE] AFTER the user explicitly confirms with:
   yes / đồng ý / confirm / ok / xác nhận / chắc chắn / sure / proceed

5. **LANGUAGE** — Always detect and reply in the same language the user writes in.
   Supported: Vietnamese, English, Chinese (Simplified/Traditional), Japanese, Korean,
   Spanish, French, German, Portuguese, Thai, Indonesian, Malay, Arabic, Russian, Italian.
   If the language is unrecognized, default to English.

6. **PROMPT FIELD** — Always write the `prompt` value inside [EXECUTE] in clear English,
   regardless of what language the user typed in.

7. **NO SUCCESS TEXT** — When you append [EXECUTE], do NOT write any success/confirmation
   message in the reply body. Write ONLY a brief neutral closing line like
   "Đang xử lý..." or "Processing..." — the system will inject the actual result status.

## [EXECUTE] FORMAT

Append EXACTLY ONE of these at the very end of your reply (nothing after it):

  [EXECUTE:{"op":"add","sid":N,"prompt":"<English description>","lot":0.1,"sl":50,"tp":100,"tf":0}]
  [EXECUTE:{"op":"update","sid":N,"lot":0.2}]
  [EXECUTE:{"op":"update","sid":N,"prompt":"<new English description>","sl":30}]
  [EXECUTE:{"op":"delete","sid":N}]

Rules:
- N = 0 for S1, 1 for S2, 2 for S3, 3 for S4, 4 for S5
- tf in minutes: M1=1 M5=5 M15=15 M30=30 H1=60 H4=240 D1=1440 (0 if not specified)
- "update": only include the changed fields + sid
- "delete": only include sid
- Do NOT wrap [EXECUTE] in markdown, quotes, or code blocks

## EXAMPLES

### Example A (Vietnamese — ADD, collecting info)
User: thêm strategy mua gold khi RSI dưới 30
Assistant: Bạn muốn thêm vào slot nào (S1–S5)?

User: S2
Assistant: Xác nhận thêm Strategy **S2**?
• Lệnh: **MUA XAUUSD** khi RSI(14) < 30
• Lot: 0.10 | SL: 50 pip | TP: 100 pip | TF: tự động phát hiện
Trả lời **"đồng ý"** để xác nhận.

User: đồng ý
Assistant: Đang xử lý...
[EXECUTE:{"op":"add","sid":1,"prompt":"Buy XAUUSD when RSI(14) is below 30","lot":0.10,"sl":50,"tp":100,"tf":0}]

### Example B (English — UPDATE)
User: change S1 SL to 30 and lot to 0.2
Assistant: Confirm update **S1**?
• SL: 50 → **30 pip**
• Lot: 0.10 → **0.20**
Reply "yes" to confirm.

User: yes
Assistant: Processing...
[EXECUTE:{"op":"update","sid":0,"sl":30,"lot":0.20}]

### Example C (DELETE)
User: xóa strategy 3
Assistant: Xác nhận xóa **S3**? Strategy này sẽ bị deactivate ngay lập tức.
Trả lời **"đồng ý"** để xác nhận.

User: đồng ý
Assistant: Đang xử lý...
[EXECUTE:{"op":"delete","sid":2}]

### Example D (off-topic — reply in user's language)
User (Vietnamese): EURUSD hôm nay thế nào?
Assistant: Xin lỗi, tôi chỉ hỗ trợ quản lý Strategy (thêm/sửa/xóa). Bạn muốn làm gì với strategy?

User (Chinese): 今天EURUSD怎么样？
Assistant: 抱歉，我只支持交易策略管理（添加/修改/删除）。您想对策略做什么？

User (Japanese): EURUSDは今日どうですか？
Assistant: 申し訳ありませんが、私は取引戦略の管理（追加/編集/削除）のみをサポートしています。戦略について何をしたいですか？
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

    # ── Build multi-turn messages from server-side history ────────────────
    messages = _conv_get(user.account_number) + [{"role": "user", "content": message}]

    try:
        resp = await asyncio.wait_for(
            _claude.messages.create(
                model="claude-sonnet-4-6",
                max_tokens=1024,
                system=STRATEGY_SYSTEM_PROMPT + "\n\n## CURRENT EA STRATEGIES\n"
                       + _strategy_context(user.account_number),
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
        op  = action.get("op", "")
        sid = int(action.get("sid", 0))

        # ── Validate [EXECUTE] fields ─────────────────────────────────────
        if op not in VALID_OPS:
            logger.warning(f"CRUD blocked: invalid op={op!r} account={user.account_number}")
            action = None  # drop silently — Claude misbehaved

        elif sid not in VALID_SID:
            logger.warning(f"CRUD blocked: sid={sid} out of range account={user.account_number}")
            action = None

        elif op == "add":
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
                            "indicators": config.get("indicators", []),
                            "condition":  config.get("condition",  {}),
                        }
                    }
                    _strategy_store_save(acct, sid, {
                        "prompt": prompt_str,
                        "lot":    resolved_lot,
                        "sl":     resolved_sl,
                        "tp":     resolved_tp,
                        "tf":     config.get("tf",     tf),
                        "action": config.get("action", "BUY"),
                        "symbol": config.get("symbol", ""),
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
                                "indicators": config.get("indicators", []),
                                "condition":  config.get("condition",  {}),
                            }
                        }
                        _strategy_store_save(acct, sid, {
                            "prompt": new_prompt,
                            "lot":    resolved_lot,
                            "sl":     resolved_sl,
                            "tp":     resolved_tp,
                            "tf":     config.get("tf",     new_tf),
                            "action": config.get("action", "BUY"),
                            "symbol": config.get("symbol", new_sym),
                        })
                        await ws_broadcast(acct, payload)
                        crud_result = "sent" if ea_connected else "no_ea"
                else:
                    # Parameters only (lot/sl/tp/tf) → partial update, keep condition tree
                    upd: dict = {"event": "strategy_update", "sid": sid}
                    for k in ("lot", "sl", "tp", "tf"):
                        if k in action:
                            upd[k] = action[k]
                    _strategy_store_save(acct, sid, {**existing, **{
                        k: upd[k] for k in ("lot", "sl", "tp", "tf") if k in upd
                    }})
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
            reply += (
                "\n\n---\n"
                "❌ **Lỗi:** Không thể phân tích strategy từ mô tả của bạn. "
                "Vui lòng mô tả rõ hơn (instrument, hướng BUY/SELL, điều kiện vào lệnh) và thử lại."
            )
        elif crud_result == "error":
            reply += (
                f"\n\n---\n"
                f"❌ **Lỗi khi gửi đến EA:** `{crud_error}`\n"
                f"Vui lòng kiểm tra kết nối và thử lại."
            )
        elif crud_result in ("no_ea", "sent"):
            if crud_result == "no_ea":
                op_vi = {"add": "thêm", "update": "cập nhật", "delete": "xóa"}.get(op, op)
                reply += (
                    f"\n\n---\n"
                    f"⚠️ **EA chưa kết nối WebSocket** — lệnh {op_vi} đã ghi nhận nhưng chưa áp dụng vào MT4.\n"
                    f"Khởi động lại EA để đồng bộ."
                )
            else:
                slot_name = f"S{sid + 1}"
                op_msg = {
                    "add":    f"✅ **Strategy {slot_name} đã được áp dụng vào EA thành công!**",
                    "update": f"✅ **Strategy {slot_name} đã được cập nhật thành công!**",
                    "delete": f"✅ **Strategy {slot_name} đã bị xóa thành công!**",
                }.get(op, "✅ **Thao tác thành công!**")
                reply = reply or ""
                reply += f"\n\n---\n{op_msg}"

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
                # DLL sends all active sessions on connect — sync strategy_store
                strategies = data.get("strategies", [])
                for s in strategies:
                    sid = int(s.get("sid", -1))
                    if 0 <= sid <= 4:
                        _strategy_store_save(account_number, sid, {
                            "prompt": s.get("prompt", ""),
                            "lot":    s.get("lot",    0.1),
                            "sl":     s.get("sl",     50),
                            "tp":     s.get("tp",     100),
                            "tf":     s.get("tf",     0),
                            "action": s.get("action", "BUY"),
                            "symbol": s.get("symbol", ""),
                        })
                logger.info(f"WS-EA strategy_hello: {len(strategies)} sessions for {account_number}")
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

    except WebSocketDisconnect:
        ws_ea_clients.pop(account_number, None)
        logger.info(f"WS-EA disconnected: {account_number}")


# ── Chat core — shared by HTTP and WebSocket handlers ─────────────────────────

async def _handle_chat_ws(message: str, user: "User") -> str:
    """Full chat pipeline: rate-limit → sanitize → Claude → CRUD dispatch → feedback."""
    if len(message) > _MSG_MAX_LEN:
        return f"⚠️ Tin nhắn quá dài (tối đa {_MSG_MAX_LEN} ký tự)."

    if "[EXECUTE:" in message:
        message = message.replace("[EXECUTE:", "[BLOCKED:")

    if not _rate_check(user.account_number):
        return f"⚠️ Quá nhiều yêu cầu. Giới hạn: {_RATE_LIMIT} lần/{_RATE_WINDOW}s. Vui lòng thử lại sau."

    if not CLAUDE_API_KEY:
        return "⚠️ Claude API key chưa được cấu hình."

    messages = _conv_get(user.account_number) + [{"role": "user", "content": message}]

    try:
        resp = await asyncio.wait_for(
            _claude.messages.create(
                model="claude-sonnet-4-6",
                max_tokens=1024,
                system=STRATEGY_SYSTEM_PROMPT + "\n\n## CURRENT EA STRATEGIES\n"
                       + _strategy_context(user.account_number),
                messages=messages,
            ),
            timeout=30.0,
        )
    except asyncio.TimeoutError:
        return "⚠️ Claude API timeout. Vui lòng thử lại."
    except anthropic.AuthenticationError:
        return "⚠️ Claude API key không hợp lệ."
    except anthropic.APIConnectionError:
        return "⚠️ Không thể kết nối Claude API."
    except Exception as e:
        return f"⚠️ Lỗi Claude: {e}"

    reply = resp.content[0].text

    _conv_append(user.account_number, "user",      message)
    _conv_append(user.account_number, "assistant", reply)

    action = _extract_execute(reply)
    if action:
        op  = action.get("op", "")
        sid = int(action.get("sid", 0))

        if op not in VALID_OPS:
            logger.warning(f"CRUD blocked: invalid op={op!r} account={user.account_number}")
            action = None
        elif sid not in VALID_SID:
            logger.warning(f"CRUD blocked: sid={sid} out of range account={user.account_number}")
            action = None
        elif op == "add":
            action["lot"] = max(0.01, min(float(action.get("lot", 0.1)), 100.0))
            action["sl"]  = max(1,    min(int(action.get("sl",  50)),   10000))
            action["tp"]  = max(1,    min(int(action.get("tp",  100)),  10000))
            action["tf"]  = int(action.get("tf", 0)) if int(action.get("tf", 0)) in VALID_TFS else 0
        elif op == "update":
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
                            "indicators": config.get("indicators", []),
                            "condition":  config.get("condition",  {}),
                        }
                    }
                    _strategy_store_save(acct, sid, {
                        "prompt": prompt_str,
                        "lot":    resolved_lot,
                        "sl":     resolved_sl,
                        "tp":     resolved_tp,
                        "tf":     config.get("tf",     tf),
                        "action": config.get("action", "BUY"),
                        "symbol": config.get("symbol", ""),
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
                                "indicators": config.get("indicators", []),
                                "condition":  config.get("condition",  {}),
                            }
                        }
                        _strategy_store_save(acct, sid, {
                            "prompt": new_prompt,
                            "lot":    resolved_lot,
                            "sl":     resolved_sl,
                            "tp":     resolved_tp,
                            "tf":     config.get("tf",     new_tf),
                            "action": config.get("action", "BUY"),
                            "symbol": config.get("symbol", new_sym),
                        })
                        await ws_ea_push(acct, payload)
                        crud_result = "sent" if ea_connected else "no_ea"
                else:
                    # Parameters only (lot/sl/tp/tf) → partial update, keep condition tree
                    upd: dict = {"event": "strategy_update", "sid": sid}
                    for k in ("lot", "sl", "tp", "tf"):
                        if k in action:
                            upd[k] = action[k]
                    _strategy_store_save(acct, sid, {**existing, **{
                        k: upd[k] for k in ("lot", "sl", "tp", "tf") if k in upd
                    }})
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
            reply += (
                "\n\n---\n"
                "❌ **Lỗi:** Không thể phân tích strategy từ mô tả của bạn. "
                "Vui lòng mô tả rõ hơn (instrument, hướng BUY/SELL, điều kiện vào lệnh) và thử lại."
            )
        elif crud_result == "error":
            reply += (
                f"\n\n---\n"
                f"❌ **Lỗi khi gửi đến EA:** `{crud_error}`\n"
                f"Vui lòng kiểm tra kết nối và thử lại."
            )
        elif crud_result in ("no_ea", "sent"):
            if crud_result == "no_ea":
                op_vi = {"add": "thêm", "update": "cập nhật", "delete": "xóa"}.get(op, op)
                reply += (
                    f"\n\n---\n"
                    f"⚠️ **EA chưa kết nối WebSocket** — lệnh {op_vi} đã ghi nhận "
                    f"nhưng chưa áp dụng vào MT4.\nKhởi động lại EA để đồng bộ."
                )
            else:
                slot_name = f"S{sid + 1}"
                op_msg = {
                    "add":    f"✅ **Strategy {slot_name} đã được áp dụng vào EA thành công!**",
                    "update": f"✅ **Strategy {slot_name} đã được cập nhật thành công!**",
                    "delete": f"✅ **Strategy {slot_name} đã bị xóa thành công!**",
                }.get(op, "✅ **Thao tác thành công!**")
                reply += f"\n\n---\n{op_msg}"

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
            data = await ws.receive_json()
            event = data.get("event", "")

            if event == "ping":
                await ws.send_json({"event": "pong"})

            elif event == "chat_message":
                message = str(data.get("message", "")).strip()
                if not message:
                    continue

                # Reuse the full chat pipeline (rate limit, input sanitize, Claude, CRUD)
                reply = await _handle_chat_ws(message, user)
                await ws.send_json({"event": "chat_reply", "reply": reply})

    except WebSocketDisconnect:
        ws_chat_clients.pop(account_number, None)
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
