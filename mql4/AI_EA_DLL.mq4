//+------------------------------------------------------------------+
//| AI_EA_DLL.mq4                                                    |
//| AI Trading Bridge — Expert Advisor (DLL version)                 |
//| Connects via AI_Bridge.dll (no Python bridge required)           |
//| Supports up to 5 simultaneous strategies (S1–S5)                 |
//+------------------------------------------------------------------+
#property strict
#property description "AI Trading Bridge EA"
#property description "Set S1_Enable=true (and fill S1_Prompt) to activate a strategy"
#property description "All strategies are disabled by default (S1_Enable..S5_Enable = false)"

//── DLL import ───────────────────────────────────────────────────────
#import "AI_Bridge.dll"
   int  Bridge_Register  (int account, string server, int license_type,
                          uchar &out_buf[], int buf_size);
   int  Bridge_Init   (int sid, string prompt, string symbol,
                       int tf, double lot, int sl, int tp, int account,
                       string token,
                       uchar &out_buf[], int buf_size);
   int  Bridge_Check  (int sid, string values_json, int account,
                       uchar &out_buf[], int buf_size);
   void Bridge_Stop   (int sid);
   int  Bridge_Version(uchar &out_buf[], int buf_size);
   int  Bridge_GetLastLog  (uchar &out_buf[], int buf_size);
   int  Bridge_WsConnect   (string account, string token,
                            uchar &out_buf[], int buf_size);
   int  Bridge_WsPoll      (uchar &out_buf[], int buf_size);
   void Bridge_WsDisconnect();
   int  Bridge_WsGetStatus (uchar &out_buf[], int buf_size);
   int  Bridge_WsSend      (string msg);
   int  Bridge_Ping        (uchar &out_buf[], int buf_size);
#import

//── Logging ──────────────────────────────────────────────────────────
bool EnableLog = false;
#define LOG if(EnableLog) Print

//── Strategy 1 ───────────────────────────────────────────────────────
extern bool            S1_Enable      = false;
extern string          S1_Prompt      = "Buy EURUSD when MA20 crosses above MA50 and RSI14 < 65";
extern ENUM_TIMEFRAMES S1_Default_TF  = PERIOD_H1;
extern double          S1_Default_Lot = 0.10;
extern int             S1_Default_SL  = 50;
extern int             S1_Default_TP  = 100;

//── Strategy 2 ───────────────────────────────────────────────────────
extern bool            S2_Enable      = false;
extern string          S2_Prompt      = "";
extern ENUM_TIMEFRAMES S2_Default_TF  = PERIOD_H4;
extern double          S2_Default_Lot = 0.05;
extern int             S2_Default_SL  = 40;
extern int             S2_Default_TP  = 80;

//── Strategy 3 ───────────────────────────────────────────────────────
extern bool            S3_Enable      = false;
extern string          S3_Prompt      = "";
extern ENUM_TIMEFRAMES S3_Default_TF  = PERIOD_D1;
extern double          S3_Default_Lot = 0.01;
extern int             S3_Default_SL  = 200;
extern int             S3_Default_TP  = 400;

//── Strategy 4 ───────────────────────────────────────────────────────
extern bool            S4_Enable      = false;
extern string          S4_Prompt      = "";
extern ENUM_TIMEFRAMES S4_Default_TF  = PERIOD_H1;
extern double          S4_Default_Lot = 0.10;
extern int             S4_Default_SL  = 50;
extern int             S4_Default_TP  = 100;

//── Strategy 5 ───────────────────────────────────────────────────────
extern bool            S5_Enable      = false;
extern string          S5_Prompt      = "";
extern ENUM_TIMEFRAMES S5_Default_TF  = PERIOD_H1;
extern double          S5_Default_Lot = 0.10;
extern int             S5_Default_SL  = 50;
extern int             S5_Default_TP  = 100;

//── Internal constants ────────────────────────────────────────────────
#define MAX_STRATEGIES 5
#define MAX_INDICATORS 50
#define MAX_OHLC_BARS  50
#define MAGIC_BASE        88800
#define CHAT_ORDER_MAGIC  20250518
#define BUF_SIZE       65536
#define OBJ_PREFIX     "AIB_"
#define BRIDGE_VERSION "3.0.0"
#define FRONTEND_URL   "http://aitraiding.up.railway.app"

//── Structs ───────────────────────────────────────────────────────────
struct IndConfig {
   string name; string type; string symbol;
   int timeframe; int period; int method; int applied; int shift;
   int line; double deviation; int ma_shift;
   int fast_period; int slow_period; int signal_period;
   int k_period; int d_period; int slowing;
   double sar_step; double sar_max;
   int p1; int p2; int p3;
   int s1; int s2; int s3;
   string custom_name; int buffer_index;
   double custom_p[6];
};

struct StrategySlot {
   bool      active;
   bool      enabled;   // true=place orders, false=monitor only (no trades)
   string    prompt;
   string    symbol;
   int       tf;
   double    lot;
   int       sl;
   int       tp;
   string    action;     // BUY / SELL — từ Bridge_Init response
   IndConfig inds[MAX_INDICATORS];
   int       ind_count;
   int       ohlc_bars;
   datetime  last_bar;
   long      chart_id;   // chart mở tự động cho strategy này
};

StrategySlot g_slots[MAX_STRATEGIES];
int          g_active             = 0;
int          g_account            = 0;
string       g_token              = "";
datetime     g_last_signal_bar[MAX_STRATEGIES]; // cooldown: 1 signal per bar

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
void PrintDllLog(string prefix)
{
   uchar log_buf[];
   ArrayResize(log_buf, 65536);
   int n = Bridge_GetLastLog(log_buf, 65536);
   if (n <= 0) return;
   string full = CharArrayToString(log_buf, 0, -1);
   // Print in 200-char chunks so MT4 journal doesn't truncate lines
   int len = StringLen(full);
   for (int pos = 0; pos < len; pos += 200)
      LOG(prefix, " | ", StringSubstr(full, pos, 200));
}

void ShowChatURL(string token)
{
   string chat_url = FRONTEND_URL + "/chat?token=" + token;
   LOG("[AI Bridge] Chat URL: ", chat_url);
   Alert("Access chat bot URL:\n\n" + chat_url +
         "\n\nOpen this URL in your browser to access the chat.");
}

int OnInit()
{
   g_account = (int)AccountNumber();

   // ── 0. DLL smoke-test — verify DLL loaded without internal exception ──
   {
      uchar ping_buf[];
      ArrayResize(ping_buf, 256);
      int ping_rc = Bridge_Ping(ping_buf, 256);
      string ping_res = CharArrayToString(ping_buf, 0, -1);
      LOG("[AI Bridge] Bridge_Ping rc=", ping_rc, " res=", ping_res);
      if (ping_rc != 0) {
         Alert("[AI Bridge] DLL failed self-test: ", ping_res,
               "\nCheck %APPDATA%\\AI_Bridge\\startup.log for details.");
         return INIT_FAILED;
      }
   }

   // ── 1. License check & registration ──────────────────────────────────
   int    lic_type = (int)MQLInfoInteger(MQL_LICENSE_TYPE);
   string srv      = AccountServer();

   // Gọi backend để lưu account + server_broker vào DB
   uchar reg_buf[];
   ArrayResize(reg_buf, 2048);
   int reg_rc = Bridge_Register(g_account, srv, lic_type, reg_buf, 2048);
   string reg_res = CharArrayToString(reg_buf, 0, -1);
   LOG("[AI Bridge] Bridge_Register rc=", reg_rc, " res=", StringSubstr(reg_res, 0, 200));

   if (reg_rc != 0) {
      string msg = ExtractStr(reg_res, "message");
      if (StringLen(msg) == 0) msg = "License server unavailable";
      Alert("[AI Bridge] " + msg);
      LOG("[AI Bridge] Registration FAILED: ", msg);
      return INIT_FAILED;
   }

   if (reg_rc == 0) {
      // Lấy JWT token từ backend (production + dev khi backend chạy)
      g_token = ExtractStr(reg_res, "token");
      string lic_name = ExtractStr(reg_res, "license_type");
      LOG("[AI Bridge] License OK — type=", lic_name, " token=", StringSubstr(g_token, 0, 20), "...");
   }

   if (StringLen(g_token) == 0) {
      // Backend không trả token (dev mode offline) → tạo dev token local
      int ts   = (int)TimeCurrent();
      int salt = MathAbs((g_account * 7919) ^ (ts * 1337));
      string payload = IntegerToString(g_account) + ":"
                     + IntegerToString(ts) + ":"
                     + IntegerToString(salt);
      string hex = "";
      int key = 0x5B;
      for (int ci = 0; ci < StringLen(payload); ci++) {
         int ch  = StringGetCharacter(payload, ci);
         int enc = ch ^ ((key + ci * 7) & 0xFF);
         hex += StringFormat("%02x", enc);
      }
      g_token = "d." + hex;
      LOG("[AI Bridge] DEV MODE offline — local token generated");
   }

   ShowChatURL(g_token);

   // ── 2. Load strategies ────────────────────────────────────────────────
   ArrayInitialize(g_last_signal_bar, 0);
   CleanObjects();
   LoadSlots();

   if (g_active == 0)
      LOG("[AI Bridge] No strategy enabled locally — use chat bot to add strategies.");

   // Show DLL version
   uchar ver_buf[];
   ArrayResize(ver_buf, 64);
   Bridge_Version(ver_buf, 64);
   LOG("AI Bridge DLL v", CharArrayToString(ver_buf, 0, ArraySize(ver_buf)));

   // Init each active strategy
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;

      uchar out[];
      ArrayResize(out, BUF_SIZE);

      int rc = Bridge_Init(
         i,
         g_slots[i].prompt,
         g_slots[i].symbol,
         g_slots[i].tf,
         g_slots[i].lot,
         g_slots[i].sl,
         g_slots[i].tp,
         g_account,
         g_token,
         out, BUF_SIZE
      );

      string res = CharArrayToString(out, 0, -1);
      if (StringFind(res, "\"status\":\"ok\"") < 0) {
         // Print full DLL debug log — shows raw backend response, token, etc.
         PrintDllLog("DLL_LOG S" + IntegerToString(i));
         string err = ExtractStr(res, "message");
         if (StringLen(err) == 0) err = (StringLen(res) > 0) ? res : "(empty response)";
         LOG("Strategy ", i, " init failed: ", err);
         if (StringFind(res, "License") >= 0) {
            Alert("License invalid. Purchase at: https://www.mql5.com/en/market");
            return INIT_FAILED;
         }
         g_slots[i].active = false;
         g_active--;
         continue;
      }

      ParseIndList(i, res);

      int tf_from_bridge = (int)ExtractNum(res, "tf");
      if (tf_from_bridge > 0) g_slots[i].tf = tf_from_bridge;

      // Override symbol with Claude-detected value (handles typos, "gold"→XAUUSD, etc.)
      string sym_from_bridge = ExtractStr(res, "symbol");
      if (StringLen(sym_from_bridge) > 0 && sym_from_bridge != g_slots[i].symbol) {
         LOG("S", i, " symbol overridden by Claude: ", g_slots[i].symbol, " → ", sym_from_bridge);
         g_slots[i].symbol = sym_from_bridge;
      }

      // Gán symbol/timeframe của strategy vào từng indicator nếu chưa được set
      // → đảm bảo panel và corner label đọc cùng 1 TF
      for (int k = 0; k < g_slots[i].ind_count; k++) {
         if (StringLen(g_slots[i].inds[k].symbol) == 0)
            g_slots[i].inds[k].symbol    = g_slots[i].symbol;
         if (g_slots[i].inds[k].timeframe == 0)
            g_slots[i].inds[k].timeframe = g_slots[i].tf;
      }

      // Lưu action (BUY/SELL) từ Bridge_Init response
      string act = ExtractStr(res, "action");
      if (StringLen(act) > 0) g_slots[i].action = act;

      // Open a dedicated chart for each active strategy
      g_slots[i].chart_id = OpenStrategyChart(i);

      LOG("Strategy ", i, " OK (", g_slots[i].symbol, " ",
            TFtoStr(g_slots[i].tf), " ", g_slots[i].action, "): ",
            StringSubstr(g_slots[i].prompt, 0, 50));
   }

   if (g_active == 0)
      LOG("[AI Bridge] No active strategy — waiting for chat bot to add strategies.");

   // Draw each strategy's panel on its own chart
   for (int j = 0; j < MAX_STRATEGIES; j++) {
      if (!g_slots[j].active || g_slots[j].chart_id <= 0) continue;
      DrawStrategyInfo(j, g_slots[j].chart_id);
      DrawIndicators(j, g_slots[j].chart_id);
      ChartRedraw(g_slots[j].chart_id);
   }

   LOG(g_active, " strategies active. EA running.");
   EventSetTimer(1);   // poll WS queue every second regardless of ticks

   // ── 3. Connect WebSocket for real-time strategy events ────────────────────
   {
      uchar ws_buf[];
      ArrayResize(ws_buf, 512);
      // Bridge_WsConnect waits up to 3s and returns the actual connection result:
      //   0  = connected OK
      //   1  = thread launched but timed out (still connecting in background)
      //  -1  = connection failed (check message field for reason)
      int ws_rc = Bridge_WsConnect(IntegerToString(g_account), g_token, ws_buf, 512);
      string ws_res     = CharArrayToString(ws_buf, 0, -1);
      string ws_msg     = ExtractStr(ws_res, "message");
      string ws_conn    = ExtractStr(ws_res, "connected");

      if (ws_rc == 0 || ws_rc == 1) {
         // Push correct enabled state so backend strategy_store reflects S*_Enable params
         for (int _i = 0; _i < MAX_STRATEGIES; _i++) {
            if (!g_slots[_i].active) continue;
            string _en_msg = "{\"event\":\"strategy_update\",\"sid\":" + IntegerToString(_i)
                           + ",\"enabled\":" + (g_slots[_i].enabled ? "1" : "0") + "}";
            Bridge_WsSend(_en_msg);
         }
      }

      if (ws_rc == 0) {
         // rc=0 = connected (Bridge_WsConnect only returns 0 when g_ws_connected==true)
         LOG("[AI Bridge] WebSocket CONNECTED — account=", g_account,
               "  reconnect_count=", (int)ExtractNum(ws_res, "reconnect_count"));
      } else if (ws_rc == 1) {
         LOG("[AI Bridge] WebSocket: thread started, connecting in background...");
         LOG("[AI Bridge]   → Check %APPDATA%\\AI_Bridge\\bridge.log if it stays disconnected");
      } else {
         // rc=-1: genuine failure
         string detail = (StringLen(ws_msg) > 0) ? ws_msg : ws_res;
         LOG("[AI Bridge] WebSocket FAILED (rc=", ws_rc, "): ", detail);
         LOG("[AI Bridge]   → Strategy updates from chat will NOT work.");
         LOG("[AI Bridge]   → Check: backend running? host=ai-tra-bridge-backend-production.up.railway.app reachable?");
         Alert("[AI Bridge] WebSocket connection failed:\n" + detail +
               "\n\nStrategy chat updates will not reach the EA.\n"
               "Check bridge.log: %APPDATA%\\AI_Bridge\\bridge.log");
      }
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTimer — poll WS queue every second (no tick dependency)       |
//+------------------------------------------------------------------+
void OnTimer()
{
   // ── Reconnect detection: push enabled state whenever a new WS connection is made ──
   // Covers both initial connect and auto-reconnect after network drop.
   // More reliable than the OnInit push (which can be dropped if ws_rc==1).
   static int s_last_reconnect = -1;
   uchar st_buf[];
   ArrayResize(st_buf, 256);
   if (Bridge_WsGetStatus(st_buf, 256) == 1) {
      int rc_n = (int)ExtractNum(CharArrayToString(st_buf, 0, -1), "reconnect_count");
      if (rc_n > 0 && rc_n != s_last_reconnect) {
         s_last_reconnect = rc_n;
         for (int _i = 0; _i < MAX_STRATEGIES; _i++) {
            if (!g_slots[_i].active) continue;
            string _msg = "{\"event\":\"strategy_update\",\"sid\":" + IntegerToString(_i)
                        + ",\"enabled\":" + (g_slots[_i].enabled ? "1" : "0") + "}";
            Bridge_WsSend(_msg);
         }
         LOG("[WS] enabled state pushed after connect #", rc_n);
      }
   }

   // ── Poll WS message queue ──
   uchar ws_out[];
   ArrayResize(ws_out, BUF_SIZE);
   int ws_n = Bridge_WsPoll(ws_out, BUF_SIZE);
   if (ws_n > 0) {
      string ws_msg = CharArrayToString(ws_out, 0, -1);
      LOG("[WS-Timer] event: ", StringSubstr(ws_msg, 0, 100));
      HandleWsEvent(ws_msg);
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
// HandleWsEvent forward declaration (defined below order handlers)

void OnTick()
{
   // WS polling moved to OnTimer (fires every 1s regardless of tick frequency)

   // Periodic WS status check — log every 60 ticks for diagnostics
   static int ws_tick_cnt = 0;
   ws_tick_cnt++;
   if (ws_tick_cnt >= 60) {
      ws_tick_cnt = 0;
      uchar st_buf[];
      ArrayResize(st_buf, 512);
      int st_rc = Bridge_WsGetStatus(st_buf, 512);
      string st  = CharArrayToString(st_buf, 0, -1);
      string connected    = ExtractStr(st, "connected");
      string last_err     = ExtractStr(st, "last_error");
      int    reconnect_n  = (int)ExtractNum(st, "reconnect_count");
      int    q_sz         = (int)ExtractNum(st, "queue_size");
      if (st_rc == 1) {
         LOG("[WS-Status] connected=true  reconnects=", reconnect_n,
               "  queue=", q_sz);
      } else {
         LOG("[WS-Status] DISCONNECTED  reconnects=", reconnect_n,
               "  last_err=", last_err);
      }
   }

   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;

      datetime cur_bar = iTime(g_slots[i].symbol, g_slots[i].tf, 0);

      // Redraw indicators 1 lần/bar (tránh vẽ lại hàng nghìn lần/ngày)
      if (cur_bar != g_slots[i].last_bar) {
         g_slots[i].last_bar = cur_bar;
         if (g_slots[i].chart_id > 0)
            DrawIndicators(i, g_slots[i].chart_id);
      }

      // Gọi DLL mỗi tick — EvalCond chạy local, không có network
      string values_json = BuildValues(i);
      uchar out[];
      ArrayResize(out, BUF_SIZE);
      Bridge_Check(i, values_json, g_account, out, BUF_SIZE);

      string res = CharArrayToString(out, 0, -1);
      if (res == "") continue;

      // Cooldown: chỉ xử lý signal 1 lần mỗi bar, bỏ qua NONE
      string action = ExtractStr(res, "action");
      if (action == "" || action == "NONE") continue;

      // EXIT bypasses bar cooldown — close immediately when condition triggers
      if (action == "EXIT") {
         HandleSignal(i, res);
         g_last_signal_bar[i] = 0; // reset so re-entry is possible next bar
         continue;
      }

      // Entry: 1 signal per bar cooldown
      if (cur_bar == g_last_signal_bar[i]) continue;
      g_last_signal_bar[i] = cur_bar;
      HandleSignal(i, res);
   }
}


//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   string why = "";
   switch(reason) {
      case REASON_REMOVE:     why="removed from chart"; break;
      case REASON_RECOMPILE:  why="recompiled";         break;
      case REASON_CHARTCHANGE:why="symbol/tf changed";  break;
      case REASON_CHARTCLOSE: why="chart closed";       break;
      case REASON_PARAMETERS: why="parameters changed"; break;
      case REASON_ACCOUNT:    why="account changed";    break;
      default:                why="reason="+IntegerToString(reason); break;
   }
   LOG("OnDeinit: ", why);

   EventKillTimer();
   Bridge_WsDisconnect();

   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;
      Bridge_Stop(i);
   }
   // Đóng chart riêng của từng strategy
   for (int j = 0; j < MAX_STRATEGIES; j++) {
      if (g_slots[j].chart_id > 0 && g_slots[j].chart_id != ChartID())
         ChartClose(g_slots[j].chart_id);
      g_slots[j].chart_id = 0;
   }
   CleanObjects();
   LOG("EA stopped.");
}

//+------------------------------------------------------------------+
//| Build JSON values payload                                        |
//+------------------------------------------------------------------+
string BuildValues(int sid)
{
   StrategySlot s = g_slots[sid];
   string parts[];
   int    n = s.ohlc_bars * 5 + s.ind_count + 6; // 6 fixed: ask,bid,point,spread,time,bar_time
   ArrayResize(parts, n);
   int idx = 0;

   for (int i = 0; i < s.ohlc_bars; i++) {
      string si = IntegerToString(i);
      parts[idx++] = "\"open_"  +si+"\":"+DoubleToStr(iOpen (s.symbol,s.tf,i),5);
      parts[idx++] = "\"high_"  +si+"\":"+DoubleToStr(iHigh (s.symbol,s.tf,i),5);
      parts[idx++] = "\"low_"   +si+"\":"+DoubleToStr(iLow  (s.symbol,s.tf,i),5);
      parts[idx++] = "\"close_" +si+"\":"+DoubleToStr(iClose(s.symbol,s.tf,i),5);
      parts[idx++] = "\"volume_"+si+"\":"+DoubleToStr((double)iVolume(s.symbol,s.tf,i),0);
   }

   parts[idx++] = "\"ask\":"      +DoubleToStr(MarketInfo(s.symbol,MODE_ASK),5);
   parts[idx++] = "\"bid\":"      +DoubleToStr(MarketInfo(s.symbol,MODE_BID),5);
   parts[idx++] = "\"point\":"   +DoubleToStr(MarketInfo(s.symbol,MODE_POINT),5);
   parts[idx++] = "\"spread\":"  +DoubleToStr(MarketInfo(s.symbol,MODE_SPREAD),1);
   parts[idx++] = "\"time\":"    +IntegerToString((int)TimeCurrent());
   parts[idx++] = "\"bar_time\":"+IntegerToString((int)iTime(s.symbol,s.tf,0));

   for (int i = 0; i < s.ind_count; i++) {
      double val = CalcIndicator(s.inds[i]);
      parts[idx++] = "\""+s.inds[i].name+"\":"+DoubleToStr(val,8);
   }

   ArrayResize(parts, idx);
   return StringFormat("{%s}", StringJoin(parts, ","));
}

//+------------------------------------------------------------------+
//| Handle WebSocket event from backend                              |
//+------------------------------------------------------------------+
// ── Order management helpers ─────────────────────────────────────────────────

double GetPipValue(string symbol)
{
   double point  = MarketInfo(symbol, MODE_POINT);
   double digits = MarketInfo(symbol, MODE_DIGITS);
   return (digits == 5 || digits == 3) ? point * 10.0 : point;
}

string BuildOrderJson(int ticket)
{
   if (!OrderSelect(ticket, SELECT_BY_TICKET)) return "";
   string t = OrderType() == OP_BUY ? "BUY" : "SELL";
   return "{\"ticket\":"      + IntegerToString(ticket)
        + ",\"symbol\":\""    + OrderSymbol()                       + "\""
        + ",\"type\":\""      + t                                   + "\""
        + ",\"lot\":"         + DoubleToStr(OrderLots(), 2)
        + ",\"open_price\":"  + DoubleToStr(OrderOpenPrice(), 5)
        + ",\"sl\":"          + DoubleToStr(OrderStopLoss(), 5)
        + ",\"tp\":"          + DoubleToStr(OrderTakeProfit(), 5)
        + ",\"profit\":"      + DoubleToStr(OrderProfit(), 2)
        + ",\"magic\":"       + IntegerToString((int)OrderMagicNumber())
        + ",\"open_time\":"   + IntegerToString((int)OrderOpenTime())
        + "}";
}

string HistoryCloseReason(double close_price, double sl, double tp, string sym)
{
   // MT4 overwrites comment to "[sl]"/"[tp]"/"[so]" when broker closes the order
   string comment = OrderComment();
   if (StringFind(comment, "[sl]") >= 0) return "SL";
   if (StringFind(comment, "[tp]") >= 0) return "TP";
   if (StringFind(comment, "[so]") >= 0) return "SO";

   // Fallback: price comparison (covers manual EA closes where comment unchanged)
   double point = MarketInfo(sym, MODE_POINT);
   double tol   = point * 5;
   if (sl > 0 && MathAbs(close_price - sl) <= tol) return "SL";
   if (tp > 0 && MathAbs(close_price - tp) <= tol) return "TP";
   return "manual";
}

string BuildHistoryOrderJson(int ticket)
{
   if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY)) return "";
   if (OrderType() != OP_BUY && OrderType() != OP_SELL) return "";
   string t       = OrderType() == OP_BUY ? "BUY" : "SELL";
   string sym     = OrderSymbol();
   double close_p = OrderClosePrice();
   double sl      = OrderStopLoss();
   double tp      = OrderTakeProfit();
   string reason  = HistoryCloseReason(close_p, sl, tp, sym);
   // Opener: inferred from magic (Chat / Strategy / Manual)
   int    magic   = (int)OrderMagicNumber();
   string opener;
   if      (magic == CHAT_ORDER_MAGIC)              opener = "chat";
   else if (magic >= MAGIC_BASE && magic < MAGIC_BASE + MAX_STRATEGIES)
                                                    opener = "S" + IntegerToString(magic - MAGIC_BASE + 1);
   else if (magic == 0)                             opener = "manual";
   else                                             opener = "ext";
   return "{\"ticket\":"          + IntegerToString(ticket)
        + ",\"symbol\":\""        + sym                               + "\""
        + ",\"type\":\""          + t                                 + "\""
        + ",\"lot\":"             + DoubleToStr(OrderLots(), 2)
        + ",\"open_price\":"      + DoubleToStr(OrderOpenPrice(), 5)
        + ",\"close_price\":"     + DoubleToStr(close_p, 5)
        + ",\"sl\":"              + DoubleToStr(sl, 5)
        + ",\"tp\":"              + DoubleToStr(tp, 5)
        + ",\"profit\":"          + DoubleToStr(OrderProfit(), 2)
        + ",\"swap\":"            + DoubleToStr(OrderSwap(), 2)
        + ",\"commission\":"      + DoubleToStr(OrderCommission(), 2)
        + ",\"magic\":"           + IntegerToString(magic)
        + ",\"opener\":\""        + opener                            + "\""
        + ",\"comment\":\""       + OrderComment()                    + "\""
        + ",\"close_reason\":\""  + reason                           + "\""
        + ",\"open_time\":"       + IntegerToString((int)OrderOpenTime())
        + ",\"close_time\":"      + IntegerToString((int)OrderCloseTime())
        + "}";
}

void HandleOrderOpen(string msg)
{
   string req_id  = ExtractStr(msg, "request_id");
   string symbol       = ExtractStr(msg, "symbol");
   string typ          = ExtractStr(msg, "type");
   double lot          = ExtractNum(msg, "lot");
   double sl_pips      = ExtractNum(msg, "sl");
   double tp_pips      = ExtractNum(msg, "tp");
   double sl_abs       = ExtractNum(msg, "sl_price");  // absolute price level
   double tp_abs       = ExtractNum(msg, "tp_price");  // absolute price level

   if (StringLen(symbol) == 0) symbol = Symbol();
   if (lot <= 0) lot = 0.01;

   double pip   = GetPipValue(symbol);
   double point = MarketInfo(symbol, MODE_POINT);
   int    cmd   = (typ == "BUY") ? OP_BUY : OP_SELL;
   double price, sl_price, tp_price;

   double min_stop = (MarketInfo(symbol, MODE_STOPLEVEL) + 5) * point;

   if (cmd == OP_BUY) {
      price = MarketInfo(symbol, MODE_ASK);
      // sl_price absolute takes priority over pips
      if (sl_abs > 0)
         sl_price = sl_abs;
      else if (sl_pips > 0)
         sl_price = price - MathMax(sl_pips * pip, min_stop);
      else
         sl_price = 0;
      // tp_price absolute takes priority over pips
      if (tp_abs > 0)
         tp_price = tp_abs;
      else if (tp_pips > 0)
         tp_price = price + MathMax(tp_pips * pip, min_stop);
      else
         tp_price = 0;
   } else {
      price = MarketInfo(symbol, MODE_BID);
      if (sl_abs > 0)
         sl_price = sl_abs;
      else if (sl_pips > 0)
         sl_price = price + MathMax(sl_pips * pip, min_stop);
      else
         sl_price = 0;
      if (tp_abs > 0)
         tp_price = tp_abs;
      else if (tp_pips > 0)
         tp_price = price - MathMax(tp_pips * pip, min_stop);
      else
         tp_price = 0;
   }

   LOG("[WS] order_open ", symbol, " type=", typ,
         " pip=", pip, " min_stop=", min_stop,
         " sl_pips=", sl_pips, " sl_abs=", sl_abs, " sl_price=", sl_price,
         " tp_pips=", tp_pips, " tp_abs=", tp_abs, " tp_price=", tp_price);

   int ticket = OrderSend(symbol, cmd, lot, price, 3, sl_price, tp_price,
                          "AI Chat Order", CHAT_ORDER_MAGIC, 0, clrNONE);
   string reply;
   if (ticket < 0) {
      int err = GetLastError();
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":false,\"error\":" + IntegerToString(err) + "}";
      LOG("[WS] order_open FAILED err=", err);
   } else {
      OrderSelect(ticket, SELECT_BY_TICKET);
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":true,\"ticket\":" + IntegerToString(ticket)
            + ",\"symbol\":\"" + symbol + "\",\"type\":\"" + typ + "\""
            + ",\"lot\":" + DoubleToStr(lot, 2)
            + ",\"open_price\":" + DoubleToStr(OrderOpenPrice(), 5) + "}";
      LOG("[WS] order_open OK ticket=", ticket, " ", typ, " ", symbol, " lot=", lot);
   }
   Bridge_WsSend(reply);
}

void HandleOrderClose(string msg)
{
   string req_id = ExtractStr(msg, "request_id");
   int    ticket = (int)ExtractNum(msg, "ticket");
   string reply;

   if (!OrderSelect(ticket, SELECT_BY_TICKET)) {
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":false,\"error\":\"ticket_not_found\"}";
   } else {
      string sym   = OrderSymbol();
      int    cmd   = OrderType();
      double lot   = OrderLots();
      double close = (cmd == OP_BUY) ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
      double profit= OrderProfit();
      bool   ok    = OrderClose(ticket, lot, close, 3, clrNONE);
      if (ok) {
         reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
               + ",\"success\":true,\"ticket\":" + IntegerToString(ticket)
               + ",\"close_price\":" + DoubleToStr(close, 5)
               + ",\"profit\":" + DoubleToStr(profit, 2) + "}";
         LOG("[WS] order_close OK ticket=", ticket, " profit=", profit);
      } else {
         int err = GetLastError();
         reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
               + ",\"success\":false,\"error\":" + IntegerToString(err) + "}";
         LOG("[WS] order_close FAILED err=", err);
      }
   }
   Bridge_WsSend(reply);
}

void HandleOrderCloseAll(string msg)
{
   string req_id     = ExtractStr(msg, "request_id");
   string filter_sym = ExtractStr(msg, "symbol");
   int closed = 0, failed = 0;
   string orders_json = "[";
   bool   first = true;

   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS)) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if (StringLen(filter_sym) > 0 && OrderSymbol() != filter_sym) continue;

      int    ticket  = OrderTicket();
      string sym     = OrderSymbol();
      string typ     = (OrderType() == OP_BUY) ? "BUY" : "SELL";
      double lot     = OrderLots();
      double profit  = OrderProfit();
      double price   = (OrderType() == OP_BUY) ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);

      if (OrderClose(ticket, lot, price, 3, clrNONE)) {
         if (!first) orders_json += ",";
         first = false;
         orders_json += "{\"ticket\":" + IntegerToString(ticket)
                      + ",\"symbol\":\"" + sym + "\""
                      + ",\"type\":\"" + typ + "\""
                      + ",\"lot\":" + DoubleToStr(lot, 2)
                      + ",\"close_price\":" + DoubleToStr(price, 5)
                      + ",\"profit\":" + DoubleToStr(profit, 2) + "}";
         closed++;
         LOG("[WS] order_close_all: closed ticket=", ticket, " profit=", profit);
      } else {
         failed++;
         LOG("[WS] order_close_all: failed ticket=", ticket, " err=", GetLastError());
      }
   }
   orders_json += "]";

   string reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
                + ",\"success\":true,\"closed\":" + IntegerToString(closed)
                + ",\"failed\":" + IntegerToString(failed)
                + ",\"orders\":" + orders_json + "}";
   Bridge_WsSend(reply);
   LOG("[WS] order_close_all done closed=", closed, " failed=", failed);
}

void HandleOrderModify(string msg)
{
   string req_id     = ExtractStr(msg, "request_id");
   int    ticket     = (int)ExtractNum(msg, "ticket");
   double new_sl_pip = ExtractNum(msg, "sl");
   double new_tp_pip = ExtractNum(msg, "tp");
   string reply;

   if (!OrderSelect(ticket, SELECT_BY_TICKET)) {
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":false,\"error\":\"ticket_not_found\"}";
      Bridge_WsSend(reply);
      return;
   }

   string sym        = OrderSymbol();
   int    cmd        = OrderType();
   double pip        = GetPipValue(sym);
   double point      = MarketInfo(sym, MODE_POINT);
   double open_price = OrderOpenPrice();
   double cur_bid    = MarketInfo(sym, MODE_BID);
   double cur_ask    = MarketInfo(sym, MODE_ASK);
   double old_sl     = OrderStopLoss();
   double old_tp     = OrderTakeProfit();

   // SL/TP pips measured from ORDER OPEN PRICE (entry level)
   double sl = (new_sl_pip > 0)
      ? ((cmd == OP_BUY) ? open_price - new_sl_pip * pip
                         : open_price + new_sl_pip * pip)
      : OrderStopLoss();
   double tp = (new_tp_pip > 0)
      ? ((cmd == OP_BUY) ? open_price + new_tp_pip * pip
                         : open_price - new_tp_pip * pip)
      : OrderTakeProfit();

   // Enforce broker minimum stop level from CURRENT market price
   double min_stop = (MarketInfo(sym, MODE_STOPLEVEL) + 2) * point;
   if (cmd == OP_BUY) {
      if (sl > 0 && sl > cur_bid - min_stop) sl = cur_bid - min_stop;
      if (tp > 0 && tp < cur_ask + min_stop) tp = cur_ask + min_stop;
   } else {
      if (sl > 0 && sl < cur_ask + min_stop) sl = cur_ask + min_stop;
      if (tp > 0 && tp > cur_bid - min_stop) tp = cur_bid - min_stop;
   }

   LOG("[WS] order_modify ticket=", ticket, " sym=", sym,
         " open=", open_price,
         " new_sl_pip=", new_sl_pip, " sl_price=", sl,
         " new_tp_pip=", new_tp_pip, " tp_price=", tp,
         " min_stop=", min_stop);

   bool ok = OrderModify(ticket, open_price, sl, tp, 0, clrNONE);
   if (ok) {
      // Read back actual values to confirm
      OrderSelect(ticket, SELECT_BY_TICKET);
      double actual_sl = OrderStopLoss();
      double actual_tp = OrderTakeProfit();
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":true,\"ticket\":" + IntegerToString(ticket)
            + ",\"old_sl\":" + DoubleToStr(old_sl, 5)
            + ",\"old_tp\":" + DoubleToStr(old_tp, 5)
            + ",\"sl\":" + DoubleToStr(actual_sl, 5)
            + ",\"tp\":" + DoubleToStr(actual_tp, 5) + "}";
      LOG("[WS] order_modify OK ticket=", ticket,
            " actual_sl=", actual_sl, " actual_tp=", actual_tp);
   } else {
      int err = GetLastError();
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":false,\"error\":" + IntegerToString(err) + "}";
      LOG("[WS] order_modify FAILED err=", err,
            " sl=", sl, " tp=", tp, " min_stop=", min_stop);
   }
   Bridge_WsSend(reply);
}

void HandleOrderListRequest(string msg)
{
   string req_id = ExtractStr(msg, "request_id");
   string json   = "[";
   bool   first  = true;

   for (int i = 0; i < OrdersTotal(); i++) {
      if (!OrderSelect(i, SELECT_BY_POS)) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      if (!first) json += ",";
      first = false;
      json += BuildOrderJson(OrderTicket());
   }
   json += "]";

   string reply = "{\"event\":\"order_list\",\"request_id\":\"" + req_id + "\""
                + ",\"orders\":" + json + "}";
   Bridge_WsSend(reply);
   LOG("[WS] order_list sent total=", OrdersTotal());
}

void HandleOrderHistoryLast(string msg)
{
   string req_id = ExtractStr(msg, "request_id");
   int    limit  = (int)ExtractNum(msg, "limit");
   if (limit <= 0) limit = 10;

   int    total = OrdersHistoryTotal();
   string json  = "[";
   bool   first = true;
   int    count = 0;

   for (int i = total - 1; i >= 0 && count < limit; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      string entry = BuildHistoryOrderJson(OrderTicket());
      if (StringLen(entry) == 0) continue;
      if (!first) json += ",";
      first = false;
      json += entry;
      count++;
   }
   json += "]";

   string reply = "{\"event\":\"order_history\",\"request_id\":\"" + req_id + "\""
                + ",\"orders\":" + json + "}";
   Bridge_WsSend(reply);
   LOG("[WS] order_history_last sent count=", count, " limit=", limit);
}

void HandleOrderHistory48h(string msg)
{
   string   req_id  = ExtractStr(msg, "request_id");
   datetime cutoff  = TimeCurrent() - 48 * 3600;
   int      total   = OrdersHistoryTotal();
   string   json    = "[";
   bool     first   = true;
   int      count   = 0;

   for (int i = total - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if (OrderCloseTime() < cutoff) continue;
      string entry = BuildHistoryOrderJson(OrderTicket());
      if (StringLen(entry) == 0) continue;
      if (!first) json += ",";
      first = false;
      json += entry;
      count++;
   }
   json += "]";

   string reply = "{\"event\":\"order_history\",\"request_id\":\"" + req_id + "\""
                + ",\"orders\":" + json + "}";
   Bridge_WsSend(reply);
   LOG("[WS] order_history_48h sent count=", count);
}

// ── Market query ────────────────────────────────────────────────────────────

void HandleMarketQueryRequest(string msg)
{
   string req_id = ExtractStr(msg, "request_id");
   string symbol = ExtractStr(msg, "symbol");
   int    tf     = (int)ExtractNum(msg, "tf");
   int    bars   = (int)ExtractNum(msg, "bars");

   if (StringLen(symbol) == 0) symbol = Symbol();
   if (tf <= 0)   tf   = 0;
   if (bars <= 0) bars = 5;
   if (bars > 50) bars = 50;

   // OHLCV bars
   string bars_json = "[";
   for (int i = 0; i < bars; i++) {
      if (i > 0) bars_json += ",";
      bars_json += "{\"i\":"     + IntegerToString(i)
                + ",\"time\":"   + IntegerToString((int)iTime(symbol, tf, i))
                + ",\"open\":"   + DoubleToStr(iOpen(symbol,  tf, i), 5)
                + ",\"high\":"   + DoubleToStr(iHigh(symbol,  tf, i), 5)
                + ",\"low\":"    + DoubleToStr(iLow(symbol,   tf, i), 5)
                + ",\"close\":"  + DoubleToStr(iClose(symbol, tf, i), 5)
                + ",\"volume\":" + IntegerToString((int)iVolume(symbol, tf, i))
                + "}";
   }
   bars_json += "]";

   // Indicators — iterate objects in "indicators":[{...},{...}]
   string inds_json    = "{";
   bool   first_ind    = true;
   string inds_key     = "\"indicators\":[";
   int    scan         = StringFind(msg, inds_key);
   int    arr_close    = -1;

   if (scan >= 0) {
      scan      += StringLen(inds_key);
      arr_close  = StringFind(msg, "]", scan);  // end of indicators array
      int ind_n  = 0;

      while (ind_n < 20) {
         int ob = StringFind(msg, "{", scan);
         if (ob < 0 || (arr_close >= 0 && ob > arr_close)) break;
         int oe = StringFind(msg, "}", ob);
         if (oe < 0) break;

         string blk = StringSubstr(msg, ob, oe - ob + 1);

         IndConfig c;
         c.name          = ExtractStr(blk, "name");
         c.type          = ExtractStr(blk, "type");
         c.symbol        = symbol;
         c.timeframe     = tf;
         c.period        = (int)ExtractNum(blk, "period");
         c.method        = (int)ExtractNum(blk, "method");
         c.applied       = (int)ExtractNum(blk, "applied");
         c.shift         = (int)ExtractNum(blk, "shift");
         c.line          = (int)ExtractNum(blk, "line");
         c.deviation     =      ExtractNum(blk, "deviation");
         c.ma_shift      = (int)ExtractNum(blk, "ma_shift");
         c.fast_period   = (int)ExtractNum(blk, "fast");
         c.slow_period   = (int)ExtractNum(blk, "slow");
         c.signal_period = (int)ExtractNum(blk, "signal");
         c.k_period      = (int)ExtractNum(blk, "kperiod");
         c.d_period      = (int)ExtractNum(blk, "dperiod");
         c.slowing       = (int)ExtractNum(blk, "slowing");
         c.sar_step      =      ExtractNum(blk, "step");
         c.sar_max       =      ExtractNum(blk, "maximum");
         c.p1            = (int)ExtractNum(blk, "p1");
         c.p2            = (int)ExtractNum(blk, "p2");
         c.p3            = (int)ExtractNum(blk, "p3");
         c.s1            = (int)ExtractNum(blk, "s1");
         c.s2            = (int)ExtractNum(blk, "s2");
         c.s3            = (int)ExtractNum(blk, "s3");
         c.buffer_index  = (int)ExtractNum(blk, "buffer_index");
         c.custom_name   =      ExtractStr(blk, "custom_name");

         if (StringLen(c.name) > 0 && StringLen(c.type) > 0) {
            if (!first_ind) inds_json += ",";
            first_ind = false;
            inds_json += "\"" + c.name + "\":[";
            int base_shift = c.shift;
            for (int b = 0; b < bars; b++) {
               if (b > 0) inds_json += ",";
               c.shift = base_shift + b;
               inds_json += DoubleToStr(CalcIndicator(c), 6);
            }
            inds_json += "]";
            ind_n++;
         }
         scan = oe + 1;
      }
   }
   inds_json += "}";

   double ask_p    = MarketInfo(symbol, MODE_ASK);
   double bid_p    = MarketInfo(symbol, MODE_BID);
   double spread_p = MarketInfo(symbol, MODE_SPREAD) * MarketInfo(symbol, MODE_POINT) * 10.0;

   string reply = "{\"event\":\"market_data\""
                + ",\"request_id\":\"" + req_id + "\""
                + ",\"symbol\":\"" + symbol + "\""
                + ",\"tf\":"      + IntegerToString(tf)
                + ",\"ask\":"     + DoubleToStr(ask_p,    5)
                + ",\"bid\":"     + DoubleToStr(bid_p,    5)
                + ",\"spread\":"  + DoubleToStr(spread_p, 2)
                + ",\"bars\":"    + bars_json
                + ",\"indicators\":" + inds_json
                + "}";
   Bridge_WsSend(reply);
   LOG("[WS] market_query response sent symbol=", symbol,
         " tf=", tf, " bars=", bars);
}

// ── WS event dispatcher ──────────────────────────────────────────────────────

void HandleWsEvent(string msg)
{
   string event = ExtractStr(msg, "event");
   if (event == "ping" || event == "connected" || event == "pong") return;

   // Order events — no sid required, handle first
   if (event == "order_open")         { HandleOrderOpen(msg);        return; }
   if (event == "order_close")        { HandleOrderClose(msg);       return; }
   if (event == "order_close_all")    { HandleOrderCloseAll(msg);    return; }
   if (event == "order_modify")       { HandleOrderModify(msg);      return; }
   if (event == "order_list_request")         { HandleOrderListRequest(msg);       return; }
   if (event == "order_history_last_request") { HandleOrderHistoryLast(msg);       return; }
   if (event == "order_history_48h_request")  { HandleOrderHistory48h(msg);        return; }
   if (event == "market_query_request")       { HandleMarketQueryRequest(msg);     return; }

   if (event == "strategy_list_request") {
      string _rpl = "{\"event\":\"strategy_list_response\",\"strategies\":[";
      bool _first = true;
      for (int _ri = 0; _ri < MAX_STRATEGIES; _ri++) {
         if (!g_slots[_ri].active) continue;
         if (!_first) _rpl += ",";
         string _prompt = g_slots[_ri].prompt;
         StringReplace(_prompt, "\"", "'");
         _rpl += "{\"sid\":"      + IntegerToString(_ri)
               + ",\"enabled\":"  + (g_slots[_ri].enabled ? "1" : "0")
               + ",\"lot\":"      + DoubleToStr(g_slots[_ri].lot, 2)
               + ",\"sl\":"       + IntegerToString(g_slots[_ri].sl)
               + ",\"tp\":"       + IntegerToString(g_slots[_ri].tp)
               + ",\"tf\":"       + IntegerToString(g_slots[_ri].tf)
               + ",\"action\":\"" + g_slots[_ri].action + "\""
               + ",\"symbol\":\"" + g_slots[_ri].symbol + "\""
               + ",\"prompt\":\"" + _prompt + "\""
               + "}";
         _first = false;
      }
      _rpl += "]}";
      Bridge_WsSend(_rpl);
      return;
   }

   // Strategy events — require valid sid
   int sid = (int)ExtractNum(msg, "sid");
   if (sid < 0 || sid >= MAX_STRATEGIES) {
      LOG("[WS] unknown sid in event: ", StringSubstr(msg, 0, 80));
      return;
   }

   if (event == "strategy_sync" || event == "strategy_add") {
      // Full config pushed from frontend — apply all fields + parse indicator list
      bool was_inactive = !g_slots[sid].active;

      string new_prompt = ExtractStr(msg, "prompt");
      double new_lot    = ExtractNum(msg, "lot");
      int    new_sl     = (int)ExtractNum(msg, "sl");
      int    new_tp     = (int)ExtractNum(msg, "tp");
      int    new_tf     = (int)ExtractNum(msg, "tf");
      string new_action = ExtractStr(msg, "action");
      string new_symbol = ExtractStr(msg, "symbol");

      if (StringLen(new_prompt) > 0) g_slots[sid].prompt = new_prompt;
      if (new_lot > 0)               g_slots[sid].lot    = new_lot;
      if (new_sl  > 0)               g_slots[sid].sl     = new_sl;
      if (new_tp  > 0)               g_slots[sid].tp     = new_tp;
      if (new_tf  > 0)               g_slots[sid].tf     = new_tf;
      if (StringLen(new_action) > 0) g_slots[sid].action = new_action;
      if (StringLen(new_symbol) > 0) g_slots[sid].symbol = new_symbol;

      // Parse full indicator list from the JSON payload
      ParseIndList(sid, msg);

      // Fill missing symbol/tf on each indicator from the slot defaults
      for (int k = 0; k < g_slots[sid].ind_count; k++) {
         if (StringLen(g_slots[sid].inds[k].symbol) == 0)
            g_slots[sid].inds[k].symbol    = g_slots[sid].symbol;
         if (g_slots[sid].inds[k].timeframe == 0)
            g_slots[sid].inds[k].timeframe = g_slots[sid].tf;
      }

      g_slots[sid].active = true;
      if (was_inactive) { g_active++; g_slots[sid].enabled = true; g_last_signal_bar[sid] = 0; }
      if (StringFind(msg, "\"enabled\"") >= 0)
         g_slots[sid].enabled = ((int)ExtractNum(msg, "enabled") != 0);

      LOG("[WS] ", event, " S", sid,
            " sym=",  g_slots[sid].symbol,
            " tf=",   g_slots[sid].tf,
            " act=",  g_slots[sid].action,
            " inds=", g_slots[sid].ind_count,
            " prompt=", StringSubstr(g_slots[sid].prompt, 0, 40));

      // Each strategy has its own dedicated chart
      if (g_slots[sid].chart_id <= 0) {
         // New slot — open a dedicated chart window
         g_slots[sid].chart_id = OpenStrategyChart(sid);
      } else {
         // Chart already exists — switch symbol/TF if changed
         string cur_sym = ChartSymbol(g_slots[sid].chart_id);
         int    cur_tf  = (int)ChartPeriod(g_slots[sid].chart_id);
         if (cur_sym != g_slots[sid].symbol || cur_tf != g_slots[sid].tf) {
            if (g_slots[sid].chart_id == ChartID()) {
               // Never change main chart symbol/TF — open a dedicated chart instead
               g_slots[sid].chart_id = OpenStrategyChart(sid);
            } else {
               ChartSetSymbolPeriod(g_slots[sid].chart_id, g_slots[sid].symbol, g_slots[sid].tf);
               ObjectsDeleteAll(g_slots[sid].chart_id, OBJ_PREFIX);
            }
         }
      }

      if (g_slots[sid].chart_id > 0) {
         DrawStrategyInfo(sid, g_slots[sid].chart_id);
         DrawIndicators(sid, g_slots[sid].chart_id);
         ChartRedraw(g_slots[sid].chart_id);
      }
   }
   else if (event == "strategy_update") {
      // Partial update — only fields present in the payload
      string upd_prompt = ExtractStr(msg, "prompt");
      double upd_lot    = ExtractNum(msg, "lot");
      int    upd_sl     = (int)ExtractNum(msg, "sl");
      int    upd_tp     = (int)ExtractNum(msg, "tp");
      int    upd_tf     = (int)ExtractNum(msg, "tf");

      if (StringLen(upd_prompt) > 0) g_slots[sid].prompt = upd_prompt;
      if (upd_lot > 0) g_slots[sid].lot = upd_lot;
      if (upd_sl  > 0) g_slots[sid].sl  = upd_sl;
      if (upd_tp  > 0) g_slots[sid].tp  = upd_tp;
      if (upd_tf  > 0) {
         int old_tf = g_slots[sid].tf;
         g_slots[sid].tf = upd_tf;
         // Sync indicator timeframes that were using the old slot tf
         for (int k = 0; k < g_slots[sid].ind_count; k++)
            if (g_slots[sid].inds[k].timeframe == old_tf)
               g_slots[sid].inds[k].timeframe = upd_tf;
      }

      if (StringFind(msg, "\"enabled\"") >= 0)
         g_slots[sid].enabled = ((int)ExtractNum(msg, "enabled") != 0);

      LOG("[WS] strategy_update S", sid,
            " lot=", g_slots[sid].lot,
            " sl=",  g_slots[sid].sl,
            " tp=",  g_slots[sid].tp,
            " enabled=", g_slots[sid].enabled);

      if (g_slots[sid].chart_id > 0) {
         if (upd_tf > 0) {
            if (g_slots[sid].chart_id == ChartID()) {
               // Never change main chart symbol/TF — open a dedicated chart instead
               g_slots[sid].chart_id = OpenStrategyChart(sid);
            } else {
               ChartSetSymbolPeriod(g_slots[sid].chart_id, g_slots[sid].symbol, g_slots[sid].tf);
               ObjectsDeleteAll(g_slots[sid].chart_id, OBJ_PREFIX);
            }
            DrawIndicators(sid, g_slots[sid].chart_id);
         }
         DrawStrategyInfo(sid, g_slots[sid].chart_id);
         ChartRedraw(g_slots[sid].chart_id);
      }
   }
   else if (event == "strategy_delete") {
      if (g_slots[sid].active) {
         Bridge_Stop(sid);
         g_slots[sid].active = false;
         g_last_signal_bar[sid] = 0;
         g_active = MathMax(g_active - 1, 0);
         // Close this slot's dedicated chart window (or clean up objects if on main chart)
         if (g_slots[sid].chart_id > 0) {
            if (g_slots[sid].chart_id != ChartID())
               ChartClose(g_slots[sid].chart_id);
            else
               ObjectsDeleteAll(g_slots[sid].chart_id, OBJ_PREFIX + "INFO_");
         }
         g_slots[sid].chart_id = 0;
         LOG("[WS] strategy_delete S", sid, " — deactivated");
      }
   }
   else {
      LOG("[WS] unhandled event=", event);
   }
}

//+------------------------------------------------------------------+
//| Handle signal from Bridge                                        |
//+------------------------------------------------------------------+
void HandleSignal(int sid, string res)
{
   string action = ExtractStr(res, "action");
   if (action == "" || action == "NONE") return;
   if (!g_slots[sid].enabled) {
      LOG("S", sid+1, " signal skipped (strategy disabled): ", action);
      return;
   }

   StrategySlot s   = g_slots[sid];
   string       sym = s.symbol;
   double       pt  = MarketInfo(sym, MODE_POINT) * 10;
   int          magic = MAGIC_BASE + sid;

   double lot    = s.lot;
   double sl_pip = s.sl;
   double tp_pip = s.tp;

   double ovLot = ExtractNum(res, "lot");
   double ovSL  = ExtractNum(res, "sl");
   double ovTP  = ExtractNum(res, "tp");
   if (ovLot > 0) lot    = ovLot;
   if (ovSL  > 0) sl_pip = ovSL;
   if (ovTP  > 0) tp_pip = ovTP;

   if (action == "EXIT") {
      CloseOrderByMagic(sym, magic);
      return;
   }

   if (HasOpenOrder(sym, magic)) return;

   string slot_tag    = "AI-S" + IntegerToString(sid+1) + ": ";
   int    max_entry   = 31 - StringLen(slot_tag) - 3;
   bool   truncated   = StringLen(s.prompt) > max_entry;
   string entry_short = StringSubstr(s.prompt, 0, max_entry) + (truncated ? "..." : "");
   string order_comment = slot_tag + entry_short;

   if (action == "BUY") {
      double ask = MarketInfo(sym, MODE_ASK);
      int ticket = OrderSend(sym, OP_BUY, lot, ask, 3,
                             ask - sl_pip*pt, ask + tp_pip*pt,
                             order_comment, magic, 0, clrBlue);
      if (ticket > 0) {
         LOG("S", sid, " BUY ", sym, " lot=", lot);
         DrawSignalArrow(sid, "BUY", sym, s.tf);
      } else {
         int err = GetLastError();
         LOG("S", sid, " BUY failed: ", err);
         NotifyOrderFail(sid, "BUY", sym, lot, err);
      }
   }
   else if (action == "SELL") {
      double bid = MarketInfo(sym, MODE_BID);
      int ticket = OrderSend(sym, OP_SELL, lot, bid, 3,
                             bid + sl_pip*pt, bid - tp_pip*pt,
                             order_comment, magic, 0, clrRed);
      if (ticket > 0) {
         LOG("S", sid, " SELL ", sym, " lot=", lot);
         DrawSignalArrow(sid, "SELL", sym, s.tf);
      } else {
         int err = GetLastError();
         LOG("S", sid, " SELL failed: ", err);
         NotifyOrderFail(sid, "SELL", sym, lot, err);
      }
   }
}

string OrderErrorStr(int err)
{
   switch(err) {
      case 130: return "Invalid stops — SL/TP too close to price (ERR_INVALID_STOPS)";
      case 131: return "Invalid lot size (ERR_INVALID_TRADE_VOLUME)";
      case 132: return "Market is closed (ERR_MARKET_CLOSED)";
      case 133: return "Trading is disabled on this account (ERR_TRADE_DISABLED)";
      case 134: return "Not enough money (ERR_NOT_ENOUGH_MONEY)";
      case 135: return "Price changed — retry (ERR_PRICE_CHANGED)";
      case 136: return "No quotes available (ERR_OFF_QUOTES)";
      case 137: return "Broker is busy (ERR_BROKER_BUSY)";
      case 138: return "Requote — price moved (ERR_REQUOTE)";
      case 145: return "Modification denied (ERR_TRADE_MODIFY_DENIED)";
      case 146: return "Trade context busy (ERR_TRADE_CONTEXT_BUSY)";
      case 4109: return "DLL calls not allowed — enable DLL imports in EA settings";
      default:  return "Unknown error " + IntegerToString(err);
   }
}

void NotifyOrderFail(int sid, string action, string sym, double lot, int err)
{
   string msg = "{\"event\":\"signal_order_fail\""
              + ",\"sid\":"      + IntegerToString(sid)
              + ",\"action\":\"" + action + "\""
              + ",\"symbol\":\"" + sym    + "\""
              + ",\"lot\":"      + DoubleToStr(lot, 2)
              + ",\"err\":"      + IntegerToString(err)
              + ",\"reason\":\"" + OrderErrorStr(err) + "\""
              + "}";
   Bridge_WsSend(msg);
}

//+------------------------------------------------------------------+
//| ParseSymbolFromPrompt — detect forex/commodity pair in prompt    |
//+------------------------------------------------------------------+
string ParseSymbolFromPrompt(string prompt)
{
   string syms[] = {
      "XAUUSD","XAGUSD","XPTUSD","XPDUSD",
      "EURUSD","GBPUSD","USDJPY","USDCHF","USDCAD","AUDUSD","NZDUSD",
      "EURGBP","EURJPY","EURCHF","EURCAD","EURAUD","EURNZD",
      "GBPJPY","GBPCHF","GBPCAD","GBPAUD","GBPNZD",
      "AUDJPY","AUDCHF","AUDCAD","AUDNZD",
      "NZDJPY","NZDCHF","NZDCAD",
      "CADJPY","CADCHF","CHFJPY",
      "USDHKD","USDSGD","USDMXN","USDNOK","USDSEK","USDDKK","USDPLN","USDZAR",
      "BTCUSD","ETHUSD","LTCUSD","XRPUSD"
   };
   string upper = prompt;
   StringToUpper(upper);
   // Strip separators so "GBP/USD", "GBP USD", "GBP-USD", "GBP_USD" all match
   StringReplace(upper, "/", "");
   StringReplace(upper, "-", "");
   StringReplace(upper, "_", "");
   StringReplace(upper, " ", "");
   for (int i = 0; i < ArraySize(syms); i++)
      if (StringFind(upper, syms[i]) >= 0) return syms[i];
   return "";
}

//+------------------------------------------------------------------+
//| LoadSlots / CalcIndicator / ParseIndList — same as HTTP version  |
//+------------------------------------------------------------------+
void LoadSlots()
{
   string prompts[MAX_STRATEGIES];
   bool   enables[MAX_STRATEGIES];
   int    tfs[MAX_STRATEGIES];
   double lots[MAX_STRATEGIES];
   int    sls[MAX_STRATEGIES];
   int    tps[MAX_STRATEGIES];

   prompts[0]=S1_Prompt; prompts[1]=S2_Prompt; prompts[2]=S3_Prompt;
   prompts[3]=S4_Prompt; prompts[4]=S5_Prompt;
   enables[0]=S1_Enable; enables[1]=S2_Enable; enables[2]=S3_Enable;
   enables[3]=S4_Enable; enables[4]=S5_Enable;
   tfs[0]=S1_Default_TF;  tfs[1]=S2_Default_TF;  tfs[2]=S3_Default_TF;
   tfs[3]=S4_Default_TF;  tfs[4]=S5_Default_TF;
   lots[0]=S1_Default_Lot; lots[1]=S2_Default_Lot; lots[2]=S3_Default_Lot;
   lots[3]=S4_Default_Lot; lots[4]=S5_Default_Lot;
   sls[0]=S1_Default_SL; sls[1]=S2_Default_SL; sls[2]=S3_Default_SL;
   sls[3]=S4_Default_SL; sls[4]=S5_Default_SL;
   tps[0]=S1_Default_TP; tps[1]=S2_Default_TP; tps[2]=S3_Default_TP;
   tps[3]=S4_Default_TP; tps[4]=S5_Default_TP;

   g_active = 0;
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      g_slots[i].active    = (StringLen(prompts[i]) > 0);
      g_slots[i].enabled   = enables[i];
      g_slots[i].prompt    = prompts[i];
      g_slots[i].symbol    = Symbol(); // fallback = chart hiện tại; Claude sẽ override
      g_slots[i].tf        = tfs[i];
      g_slots[i].lot       = lots[i];
      g_slots[i].sl        = sls[i];
      g_slots[i].tp        = tps[i];
      g_slots[i].last_bar  = 0;
      g_slots[i].ind_count = 0;
      g_slots[i].ohlc_bars = 5;
      g_slots[i].chart_id  = 0;
      g_slots[i].action    = "";

      // Auto-detect symbol from prompt — Claude sẽ override tiếp trong Bridge_Init
      if (g_slots[i].active) {
         string detected = ParseSymbolFromPrompt(prompts[i]);
         if (StringLen(detected) > 0) {
            LOG("S", i, " symbol from prompt: ", detected);
            g_slots[i].symbol = detected;
         }
         g_active++;
      }
   }
}

bool HasOpenOrder(string sym, int magic)
{
   for (int i = OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() == sym && OrderMagicNumber() == magic) return true;
   }
   return false;
}

void CloseOrderByMagic(string sym, int magic)
{
   for (int i = OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      double price = (OrderType() == OP_BUY)
                     ? MarketInfo(sym, MODE_BID)
                     : MarketInfo(sym, MODE_ASK);
      bool ok = OrderClose(OrderTicket(), OrderLots(), price, 3, clrYellow);
      if (!ok) LOG("CloseOrderByMagic failed ticket=", OrderTicket(), " err=", GetLastError());
      else     LOG("S", magic - MAGIC_BASE, " EXIT closed ticket=", OrderTicket());
   }
}

void ParseIndList(int sid, string json)
{
   g_slots[sid].ind_count = 0;
   g_slots[sid].ohlc_bars = 5;

   string bars_str = ExtractStr(json, "ohlc_bars");
   if (bars_str != "")
      g_slots[sid].ohlc_bars = (int)MathMin(StringToInteger(bars_str), MAX_OHLC_BARS);

   int pos = 0;
   while (g_slots[sid].ind_count < MAX_INDICATORS) {
      int s = StringFind(json, "{\"name\"", pos);
      if (s < 0) break;
      int depth = 0, e = s;
      for (int i = s; i < StringLen(json); i++) {
         ushort c = StringGetCharacter(json, i);
         if (c == '{') depth++;
         else if (c == '}') { depth--; if (depth == 0) { e = i+1; break; } }
      }
      string block = StringSubstr(json, s, e - s);
      int idx = g_slots[sid].ind_count;

      g_slots[sid].inds[idx].name          = ExtractStr(block, "name");
      g_slots[sid].inds[idx].type          = ExtractStr(block, "type");
      g_slots[sid].inds[idx].symbol        = ExtractStr(block, "symbol");
      g_slots[sid].inds[idx].timeframe     = (int)ExtractNum(block, "timeframe");
      g_slots[sid].inds[idx].period        = (int)ExtractNum(block, "period");
      g_slots[sid].inds[idx].method        = (int)ExtractNum(block, "method");
      g_slots[sid].inds[idx].applied       = (int)ExtractNum(block, "applied");
      g_slots[sid].inds[idx].shift         = (int)ExtractNum(block, "shift");
      g_slots[sid].inds[idx].line          = (int)ExtractNum(block, "line");
      g_slots[sid].inds[idx].deviation     = ExtractNum(block, "deviation");
      g_slots[sid].inds[idx].ma_shift      = (int)ExtractNum(block, "ma_shift");
      g_slots[sid].inds[idx].fast_period   = (int)ExtractNum(block, "fast");
      g_slots[sid].inds[idx].slow_period   = (int)ExtractNum(block, "slow");
      g_slots[sid].inds[idx].signal_period = (int)ExtractNum(block, "signal");
      g_slots[sid].inds[idx].k_period      = (int)ExtractNum(block, "kperiod");
      g_slots[sid].inds[idx].d_period      = (int)ExtractNum(block, "dperiod");
      g_slots[sid].inds[idx].slowing       = (int)ExtractNum(block, "slowing");
      g_slots[sid].inds[idx].sar_step      = ExtractNum(block, "step");
      g_slots[sid].inds[idx].sar_max       = ExtractNum(block, "maximum");
      g_slots[sid].inds[idx].p1            = (int)ExtractNum(block, "p1");
      g_slots[sid].inds[idx].p2            = (int)ExtractNum(block, "p2");
      g_slots[sid].inds[idx].p3            = (int)ExtractNum(block, "p3");
      g_slots[sid].inds[idx].s1            = (int)ExtractNum(block, "s1");
      g_slots[sid].inds[idx].s2            = (int)ExtractNum(block, "s2");
      g_slots[sid].inds[idx].s3            = (int)ExtractNum(block, "s3");
      g_slots[sid].inds[idx].custom_name   = ExtractStr(block, "custom_name");
      g_slots[sid].inds[idx].buffer_index  = (int)ExtractNum(block, "buffer_index");

      if (g_slots[sid].inds[idx].deviation   == 0) g_slots[sid].inds[idx].deviation   = 2.0;
      if (g_slots[sid].inds[idx].sar_step    == 0) g_slots[sid].inds[idx].sar_step    = 0.02;
      if (g_slots[sid].inds[idx].sar_max     == 0) g_slots[sid].inds[idx].sar_max     = 0.2;
      if (g_slots[sid].inds[idx].fast_period == 0) g_slots[sid].inds[idx].fast_period = 12;
      if (g_slots[sid].inds[idx].slow_period == 0) g_slots[sid].inds[idx].slow_period = 26;
      if (g_slots[sid].inds[idx].signal_period==0) g_slots[sid].inds[idx].signal_period= 9;
      if (g_slots[sid].inds[idx].k_period    == 0) g_slots[sid].inds[idx].k_period    = 5;
      if (g_slots[sid].inds[idx].d_period    == 0) g_slots[sid].inds[idx].d_period    = 3;
      if (g_slots[sid].inds[idx].slowing     == 0) g_slots[sid].inds[idx].slowing     = 3;

      g_slots[sid].ind_count++;
      pos = e;
   }
}

double CalcIndicator(IndConfig &c)
{
   string sym = (c.symbol != "") ? c.symbol : Symbol();
   int    tf  = (c.timeframe > 0) ? c.timeframe : 0;
   int    sh  = c.shift;
   int    ap  = (c.applied > 0) ? c.applied : PRICE_CLOSE;

   if (c.type=="iClose")     return iClose(sym,tf,sh);
   if (c.type=="iOpen")      return iOpen(sym,tf,sh);
   if (c.type=="iHigh")      return iHigh(sym,tf,sh);
   if (c.type=="iLow")       return iLow(sym,tf,sh);
   if (c.type=="iVolume")    return (double)iVolume(sym,tf,sh);
   if (c.type=="Ask")        return MarketInfo(sym,MODE_ASK);
   if (c.type=="Bid")        return MarketInfo(sym,MODE_BID);
   if (c.type=="iHighest")   return iHigh(sym,tf,iHighest(sym,tf,MODE_HIGH,c.period,sh));
   if (c.type=="iLowest")    return iLow(sym,tf,iLowest(sym,tf,MODE_LOW,c.period,sh));
   if (c.type=="iMA")        return iMA(sym,tf,c.period,c.ma_shift,c.method,ap,sh);
   if (c.type=="iDEMA")      return iMA(sym,tf,c.period,c.ma_shift,MODE_EMA,ap,sh);
   if (c.type=="iTEMA")      return iMA(sym,tf,c.period,c.ma_shift,MODE_EMA,ap,sh);
   if (c.type=="iFrAMA")     return iMA(sym,tf,c.period,c.ma_shift,MODE_SMMA,ap,sh);
   if (c.type=="iAMA")       return iMA(sym,tf,c.period,c.ma_shift,MODE_EMA,ap,sh);
   if (c.type=="iStdDev")    return iStdDev(sym,tf,c.period,c.ma_shift,c.method,ap,sh);
   if (c.type=="iRSI")       return iRSI(sym,tf,c.period,ap,sh);
   if (c.type=="iCCI")       return iCCI(sym,tf,c.period,ap,sh);
   if (c.type=="iWPR")       return iWPR(sym,tf,c.period,sh);
   if (c.type=="iMomentum")  return iMomentum(sym,tf,c.period,ap,sh);
   if (c.type=="iMACD")      return iMACD(sym,tf,c.fast_period,c.slow_period,c.signal_period,ap,c.line,sh);
   if (c.type=="iBands")     return iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,c.line,sh);
   if (c.type=="iStochastic")return iStochastic(sym,tf,c.k_period,c.d_period,c.slowing,c.method,0,c.line,sh);
   if (c.type=="iADX")       return iADX(sym,tf,c.period,ap,c.line,sh);
   if (c.type=="iSAR")       return iSAR(sym,tf,c.sar_step,c.sar_max,sh);
   if (c.type=="iATR")       return iATR(sym,tf,c.period,sh);
   if (c.type=="iMFI")       return iMFI(sym,tf,c.period,sh);
   if (c.type=="iOBV")       return iOBV(sym,tf,ap,sh);
   if (c.type=="iForce")     return iForce(sym,tf,c.period,c.method,ap,sh);
   if (c.type=="iAlligator") return iAlligator(sym,tf,c.p1,c.s1,c.p2,c.s2,c.p3,c.s3,c.method,ap,c.line,sh);
   if (c.type=="iIchimoku")  return iIchimoku(sym,tf,c.p1,c.p2,c.p3,c.line,sh);
   if (c.type=="iFractals")  return iFractals(sym,tf,c.line,sh);
   if (c.type=="iCustom")    return iCustom(sym,tf,c.custom_name,
                                c.custom_p[0],c.custom_p[1],c.custom_p[2],
                                c.custom_p[3],c.custom_p[4],c.custom_p[5],
                                c.buffer_index,sh);
   LOG("Unknown indicator: ", c.type);
   return 0.0;
}

//── JSON helpers ──────────────────────────────────────────────────────
string ExtractStr(string json, string key)
{
   string s = "\""+key+"\":\"";
   int p = StringFind(json, s);
   if (p < 0) return "";
   p += StringLen(s);
   int e = StringFind(json, "\"", p);
   if (e < 0) return "";
   return StringSubstr(json, p, e-p);
}

double ExtractNum(string json, string key)
{
   string s = "\""+key+"\":";
   int p = StringFind(json, s);
   if (p < 0) return 0.0;
   p += StringLen(s);
   int e  = StringFind(json, ",", p);
   int e2 = StringFind(json, "}", p);
   if (e < 0 || (e2 >= 0 && e2 < e)) e = e2;
   if (e < 0) return 0.0;
   return StringToDouble(StringSubstr(json, p, e-p));
}

string TFtoStr(int tf)
{
   switch(tf) {
      case 1:    return "M1";
      case 5:    return "M5";
      case 15:   return "M15";
      case 30:   return "M30";
      case 60:   return "H1";
      case 240:  return "H4";
      case 1440: return "D1";
      case 10080:return "W1";
      default:   return IntegerToString(tf)+"m";
   }
}

string StringJoin(string &arr[], string sep)
{
   string r = "";
   int len = ArraySize(arr);
   for (int i = 0; i < len; i++) {
      r += arr[i];
      if (i < len-1) r += sep;
   }
   return r;
}

//+------------------------------------------------------------------+
//| Draw BUY/SELL arrow on chart at current bar                      |
//+------------------------------------------------------------------+
void DrawSignalArrow(int sid, string action, string sym, int tf)
{
   long cid = g_slots[sid].chart_id;
   if (cid <= 0) {
      if (sym != Symbol()) return;
      cid = ChartID();
   }

   datetime bar_time = iTime(sym, tf, 1);
   string   obj_name = OBJ_PREFIX + "SIG_" + IntegerToString(sid)
                       + "_" + IntegerToString((int)bar_time);

   ObjectDelete(cid, obj_name);

   if (action == "BUY") {
      double price = iLow(sym, tf, 1) - MarketInfo(sym, MODE_POINT) * 50;
      ObjectCreate(cid, obj_name, OBJ_ARROW, 0, bar_time, price);
      ObjectSetInteger(cid, obj_name, OBJPROP_ARROWCODE, 241);
      ObjectSetInteger(cid, obj_name, OBJPROP_COLOR,     clrDodgerBlue);
      ObjectSetInteger(cid, obj_name, OBJPROP_WIDTH,     2);
      ObjectSetString (cid, obj_name, OBJPROP_TOOLTIP,
         "AI BUY S"+(string)(sid+1)+" | "+sym+" "+TFtoStr(tf));
   }
   else if (action == "SELL") {
      double price = iHigh(sym, tf, 1) + MarketInfo(sym, MODE_POINT) * 50;
      ObjectCreate(cid, obj_name, OBJ_ARROW, 0, bar_time, price);
      ObjectSetInteger(cid, obj_name, OBJPROP_ARROWCODE, 242);
      ObjectSetInteger(cid, obj_name, OBJPROP_COLOR,     clrCrimson);
      ObjectSetInteger(cid, obj_name, OBJPROP_WIDTH,     2);
      ObjectSetString (cid, obj_name, OBJPROP_TOOLTIP,
         "AI SELL S"+(string)(sid+1)+" | "+sym+" "+TFtoStr(tf));
   }

   ChartRedraw(cid);
}


//+------------------------------------------------------------------+
//| Strategy info panel on auto-opened chart                         |
//+------------------------------------------------------------------+
// Format indicator value + label for panel display
string FormatIndValue(IndConfig &c)
{
   string label = c.name;
   if (StringFind(c.name, "_prev") >= 0) return "";

   string ann = "";
   if      (c.type=="iMACD")      ann="("+IntegerToString(c.fast_period)+","+IntegerToString(c.slow_period)+")";
   else if (c.type=="iStochastic")ann="("+IntegerToString(c.k_period)+","+IntegerToString(c.d_period)+")";
   else if (c.type=="iAlligator") ann="("+IntegerToString(c.p1)+","+IntegerToString(c.p2)+","+IntegerToString(c.p3)+")";
   else if (c.type=="iIchimoku")  ann="("+IntegerToString(c.p1)+","+IntegerToString(c.p2)+","+IntegerToString(c.p3)+")";
   else if (c.period > 0)         ann="("+IntegerToString(c.period)+")";

   // c.symbol và c.timeframe đã được gán đúng từ strategy slot trong OnInit
   double val = CalcIndicator(c);

   // Format value
   string vs = "";
   int    dp  = 5;
   if (c.type=="iRSI"||c.type=="iCCI"||c.type=="iWPR"||c.type=="iMomentum"||
       c.type=="iMACD"||c.type=="iStochastic"||c.type=="iADX") dp=2;
   else if (c.type=="iATR"||c.type=="iStdDev") dp=5;
   vs = DoubleToStr(val, dp);

   // Overbought/oversold note
   string note = "";
   if      (c.type=="iRSI")        note=(val>70)?"  OB":(val<30)?"  OS":"";
   else if (c.type=="iCCI")        note=(val>100)?"  OB":(val<-100)?"  OS":"";
   else if (c.type=="iStochastic") note=(val>80)?"  OB":(val<20)?"  OS":"";
   else if (c.type=="iWPR")        note=(val>-20)?"  OB":(val<-80)?"  OS":"";

   // Pad label to fixed width for alignment
   string full_label = label + ann;
   while (StringLen(full_label) < 18) full_label += " ";
   return full_label + vs + note;
}

// Color for indicator panel line
color IndPanelColor(IndConfig &c)
{
   double val = CalcIndicator(c);
   if (c.type=="iRSI")        return (val>70)?clrCrimson:(val<30)?clrLimeGreen:clrSilver;
   if (c.type=="iCCI")        return (val>100)?clrCrimson:(val<-100)?clrLimeGreen:clrSilver;
   if (c.type=="iStochastic") return (val>80)?clrCrimson:(val<20)?clrLimeGreen:clrSilver;
   if (c.type=="iWPR")        return (val>-20)?clrCrimson:(val<-80)?clrLimeGreen:clrSilver;
   if (c.type=="iMACD"||c.type=="iMomentum") return (val>0)?clrLimeGreen:clrCrimson;
   if (c.type=="iMA"||c.type=="iDEMA"||c.type=="iTEMA"||c.type=="iFrAMA"||c.type=="iAMA")
      return (c.period<=10)?clrDeepSkyBlue:(c.period<=25)?clrDodgerBlue:
             (c.period<=60)?clrOrangeRed:(c.period<=120)?clrGold:clrMagenta;
   if (c.type=="iBands"||c.type=="iSAR") return clrRoyalBlue;
   return clrSilver;
}

void DrawStrategyInfo(int sid, long cid)
{
   if (cid <= 0) return;

   string sym    = g_slots[sid].symbol;
   string tf_str = TFtoStr(g_slots[sid].tf);
   string action = (StringLen(g_slots[sid].action) > 0) ? g_slots[sid].action : "?";
   string prompt = g_slots[sid].prompt;
   int    ic     = g_slots[sid].ind_count;

   //── Build static lines ────────────────────────────────────────────
   #define MAX_PANEL_LINES 32
   string lines[MAX_PANEL_LINES];
   color  clrs [MAX_PANEL_LINES];
   int    fsz  [MAX_PANEL_LINES];
   int    n = 0;

   string en_tag = g_slots[sid].enabled ? "[ON]" : "[OFF]";
   lines[n]=">> STRATEGY "+IntegerToString(sid+1)+" "+en_tag; clrs[n]=clrGold; fsz[n]=10; n++;
   color en_clr = g_slots[sid].enabled ? clrAqua : clrOrange;
   lines[n]=sym+" "+tf_str+"   |   "+action;        clrs[n]=en_clr;    fsz[n]=9;  n++;
   lines[n]="Lot "+DoubleToStr(g_slots[sid].lot,2)
           +"  SL "+IntegerToString(g_slots[sid].sl)+" pip"
           +"  TP "+IntegerToString(g_slots[sid].tp)+" pip"; clrs[n]=clrSilver; fsz[n]=8; n++;

   // Prompt wrapped at 52 chars
   string prm = prompt;
   while (StringLen(prm) > 0 && n < MAX_PANEL_LINES - 2) {
      lines[n]=StringSubstr(prm,0,52); clrs[n]=C'180,180,180'; fsz[n]=7; n++;
      prm = (StringLen(prm)>52) ? StringSubstr(prm,52) : "";
   }

   //── Indicator section ────────────────────────────────────────────
   if (ic > 0) {
      // Separator
      lines[n]="─── Indicators ──────────────────"; clrs[n]=C'80,80,120'; fsz[n]=7; n++;

      for (int k = 0; k < ic && n < MAX_PANEL_LINES; k++) {
         string row = FormatIndValue(g_slots[sid].inds[k]);
         if (StringLen(row) == 0) continue;   // skip _prev variants
         lines[n] = row;
         clrs[n]  = IndPanelColor(g_slots[sid].inds[k]);
         fsz[n]   = 8;
         n++;
      }
   }

   //── Background panel ─────────────────────────────────────────────
   // Nếu vẽ trên chart chính (có dashboard), đẩy xuống dưới dashboard để không đè
   int x  = 10;
   int lh = 16;
   int dashboard_h = lh * (MAX_STRATEGIES + 2) + 20; // chiều cao panel dashboard
   int y  = (cid == ChartID()) ? dashboard_h + 10 : 10;
   string bg_n = OBJ_PREFIX+"INFO_BG_S"+IntegerToString(sid);
   if (ObjectFind(cid, bg_n) < 0)
      ObjectCreate(cid, bg_n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(cid, bg_n, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
   ObjectSetInteger(cid, bg_n, OBJPROP_XDISTANCE,   x - 6);
   ObjectSetInteger(cid, bg_n, OBJPROP_YDISTANCE,   y - 4);
   ObjectSetInteger(cid, bg_n, OBJPROP_XSIZE,       280);
   ObjectSetInteger(cid, bg_n, OBJPROP_YSIZE,       lh * n + 10);
   ObjectSetInteger(cid, bg_n, OBJPROP_BGCOLOR,     C'10,10,30');
   ObjectSetInteger(cid, bg_n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(cid, bg_n, OBJPROP_COLOR,       C'60,60,120');

   //── Text labels ──────────────────────────────────────────────────
   for (int j = 0; j < n; j++) {
      string ln = OBJ_PREFIX+"INFO_L"+IntegerToString(j)+"_S"+IntegerToString(sid);
      if (ObjectFind(cid, ln) < 0)
         ObjectCreate(cid, ln, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, ln, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(cid, ln, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(cid, ln, OBJPROP_YDISTANCE, y + j * lh);
      ObjectSetInteger(cid, ln, OBJPROP_COLOR,     clrs[j]);
      ObjectSetInteger(cid, ln, OBJPROP_FONTSIZE,  fsz[j]);
      ObjectSetString (cid, ln, OBJPROP_TEXT,      lines[j]);
   }
   // Hide unused labels from previous draws
   for (int j = n; j < MAX_PANEL_LINES; j++) {
      string ln = OBJ_PREFIX+"INFO_L"+IntegerToString(j)+"_S"+IntegerToString(sid);
      if (ObjectFind(cid, ln) >= 0)
         ObjectSetString(cid, ln, OBJPROP_TEXT, "");
   }
   #undef MAX_PANEL_LINES

   ChartRedraw(cid);
}

//+------------------------------------------------------------------+
//| Mở chart tự động cho strategy, trả về chart_id                  |
//+------------------------------------------------------------------+
long OpenStrategyChart(int sid)
{
   string sym = g_slots[sid].symbol;
   int    tf  = g_slots[sid].tf;

   // Không mở nếu đã là chart hiện tại (main chart của EA)
   if (sym == Symbol() && tf == Period())
      return ChartID();

   // Mỗi slot cần chart riêng — không dùng lại chart của slot khác,
   // kể cả khi cùng symbol+tf, vì panel/indicator sẽ bị đè.
   long cid = ChartOpen(sym, tf);
   if (cid <= 0) {
      LOG("[AI Bridge] Cannot open chart S", sid+1, " ", sym, " ", TFtoStr(tf));
      return 0;
   }

   // Đặt style: candlestick, dark theme
   ChartSetInteger(cid, CHART_MODE,             CHART_CANDLES);
   ChartSetInteger(cid, CHART_AUTOSCROLL,        true);
   ChartSetInteger(cid, CHART_SHIFT,             true);
   ChartSetInteger(cid, CHART_SHOW_GRID,         false);
   ChartSetInteger(cid, CHART_SHOW_VOLUMES,      false);
   ChartSetInteger(cid, CHART_COLOR_BACKGROUND,  C'15,15,25');
   ChartSetInteger(cid, CHART_COLOR_CANDLE_BULL, clrDodgerBlue);
   ChartSetInteger(cid, CHART_COLOR_CANDLE_BEAR, clrCrimson);
   ChartSetInteger(cid, CHART_COLOR_CHART_UP,    clrDodgerBlue);
   ChartSetInteger(cid, CHART_COLOR_CHART_DOWN,  clrCrimson);
   ChartSetInteger(cid, CHART_COLOR_GRID,        C'30,30,50');

   ChartRedraw(cid);
   return cid;
}

//+------------------------------------------------------------------+
//| Draw indicators on strategy chart                                |
//| MA/EMA → OBJ_TREND polyline  |  RSI/CCI/WPR → corner label     |
//+------------------------------------------------------------------+
void DrawIndicators(int sid, long cid)
{
   if (cid <= 0) return;
   int ic = g_slots[sid].ind_count;
   if (ic == 0) { ChartRedraw(cid); return; }

   // Force MT4 load history trước khi gọi iMA/iRSI
   RefreshRates();

   string sym  = g_slots[sid].symbol;
   int    tf   = g_slots[sid].tf;
   int    BARS = 80;

   int total_drawn = 0;
   int osc_row     = 0;   // riêng cho oscillator labels — tránh nhảy cách

   for (int k = 0; k < g_slots[sid].ind_count; k++) {
      IndConfig c  = g_slots[sid].inds[k];
      int       ap = (c.applied > 0) ? c.applied : PRICE_CLOSE;
      tf = (c.timeframe > 0) ? c.timeframe : g_slots[sid].tf;

      // Skip *_prev variants — same line, just shifted; don't draw twice
      if (StringFind(c.name, "_prev") >= 0) continue;

      //── Helper: vẽ OBJ_TREND polyline cho bất kỳ giá trị mảng nào ──
      #define DRAW_TREND_LINE(pfx, val_expr_i, val_expr_i1, clr_val, w_val) \
         { int _sd=0; \
           for (int _i=BARS;_i>=1;_i--) { \
              double _v1=(val_expr_i), _v2=(val_expr_i1); \
              if(_v1==0||_v2==0) continue; \
              datetime _t1=iTime(sym,tf,_i),_t2=iTime(sym,tf,_i-1); \
              string _o=(pfx)+IntegerToString(_i); \
              ObjectDelete(cid,_o); \
              ObjectCreate(cid,_o,OBJ_TREND,0,_t1,_v1,_t2,_v2); \
              ObjectSetInteger(cid,_o,OBJPROP_COLOR,     (clr_val)); \
              ObjectSetInteger(cid,_o,OBJPROP_WIDTH,     (w_val)); \
              ObjectSetInteger(cid,_o,OBJPROP_RAY,       false); \
              ObjectSetInteger(cid,_o,OBJPROP_SELECTABLE,false); \
              _sd++; } \
           total_drawn+=_sd; }

      //── Helper: vẽ corner label (CORNER_RIGHT_UPPER, anchor RIGHT) ──
      // ANCHOR_RIGHT_UPPER: text extend sang TRÁI từ anchor point
      // XDISTANCE=90: right-edge của text cách mép phải 90px (ngoài Y-axis)
      #define DRAW_OSC_LABEL(lbl_name, txt, clr_val) \
         { string _l=(lbl_name); ObjectDelete(cid,_l); \
           ObjectCreate(cid,_l,OBJ_LABEL,0,0,0); \
           ObjectSetInteger(cid,_l,OBJPROP_CORNER,    CORNER_RIGHT_UPPER); \
           ObjectSetInteger(cid,_l,OBJPROP_ANCHOR,    ANCHOR_RIGHT_UPPER); \
           ObjectSetInteger(cid,_l,OBJPROP_XDISTANCE, 90); \
           ObjectSetInteger(cid,_l,OBJPROP_YDISTANCE, 10+osc_row*20); \
           ObjectSetInteger(cid,_l,OBJPROP_COLOR,     (clr_val)); \
           ObjectSetInteger(cid,_l,OBJPROP_FONTSIZE,  9); \
           ObjectSetInteger(cid,_l,OBJPROP_SELECTABLE,false); \
           ObjectSetString (cid,_l,OBJPROP_TEXT,      (txt)); \
           osc_row++; }

      //── Moving Average (iMA, iDEMA, iTEMA, iFrAMA, iAMA) ─────────
      if (c.type=="iMA" || c.type=="iDEMA" || c.type=="iTEMA" ||
          c.type=="iFrAMA" || c.type=="iAMA")
      {
         color clr = (c.period <= 10)  ? clrDeepSkyBlue :
                     (c.period <= 25)  ? clrDodgerBlue   :
                     (c.period <= 60)  ? clrOrangeRed    :
                     (c.period <= 120) ? clrGold          : clrMagenta;
         string pfx = OBJ_PREFIX+"IND_"+c.name+"_S"+IntegerToString(sid)+"_";

         double test_v = iMA(sym,tf,c.period,c.ma_shift,c.method,ap,1);
         if (test_v == 0) continue;

         DRAW_TREND_LINE(pfx,
            iMA(sym,tf,c.period,c.ma_shift,c.method,ap,_i),
            iMA(sym,tf,c.period,c.ma_shift,c.method,ap,_i-1),
            clr, 1)

         // Label tên MA — anchor RIGHT_UPPER tại bar 0 để text extend sang trái
         // tránh bị cột Y-axis che khuất
         double cur = iMA(sym,tf,c.period,c.ma_shift,c.method,ap,0);
         string lbl = OBJ_PREFIX+"IND_LBL_"+c.name+"_S"+IntegerToString(sid);
         ObjectDelete(cid, lbl);
         ObjectCreate(cid, lbl, OBJ_TEXT, 0, iTime(sym,tf,0), cur);
         ObjectSetInteger(cid, lbl, OBJPROP_ANCHOR,     ANCHOR_RIGHT_UPPER);
         ObjectSetInteger(cid, lbl, OBJPROP_COLOR,      clr);
         ObjectSetInteger(cid, lbl, OBJPROP_FONTSIZE,   7);
         ObjectSetInteger(cid, lbl, OBJPROP_SELECTABLE, false);
         ObjectSetString (cid, lbl, OBJPROP_TEXT,
            c.name+"("+IntegerToString(c.period)+")");
      }

      //── Bollinger Bands ───────────────────────────────────────────
      else if (c.type=="iBands")
      {
         int    bm[] = {MODE_UPPER, MODE_MAIN, MODE_LOWER};
         color  bc[] = {clrRoyalBlue, clrSteelBlue, clrRoyalBlue};
         int    bw[] = {1, 2, 1};
         string bt[] = {"UP","MID","LO"};
         for (int b = 0; b < 3; b++) {
            string pfx = OBJ_PREFIX+"IND_"+c.name+"_"+bt[b]+"_S"+IntegerToString(sid)+"_";
            DRAW_TREND_LINE(pfx,
               iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,bm[b],_i),
               iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,bm[b],_i-1),
               bc[b], bw[b])
         }
      }

      //── Parabolic SAR — dots trên price chart ─────────────────────
      else if (c.type=="iSAR")
      {
         string pfx = OBJ_PREFIX+"IND_SAR_S"+IntegerToString(sid)+"_";
         int sar_drawn = 0;
         for (int i = BARS; i >= 0; i--) {
            double v = iSAR(sym,tf,c.sar_step,c.sar_max,i);
            if (v == 0) continue;
            datetime t = iTime(sym,tf,i);
            string obj = pfx+IntegerToString(i);
            ObjectDelete(cid, obj);
            ObjectCreate(cid, obj, OBJ_ARROW, 0, t, v);
            ObjectSetInteger(cid, obj, OBJPROP_ARROWCODE, 159); // dot
            ObjectSetInteger(cid, obj, OBJPROP_COLOR,     clrYellow);
            ObjectSetInteger(cid, obj, OBJPROP_WIDTH,     1);
            ObjectSetInteger(cid, obj, OBJPROP_SELECTABLE,false);
            sar_drawn++;
         }
         total_drawn += sar_drawn;
      }

      //── Alligator — 3 MA lines ────────────────────────────────────
      else if (c.type=="iAlligator")
      {
         int    al_mode[] = {MODE_GATORJAW, MODE_GATORTEETH, MODE_GATORLIPS};
         color  al_clr[]  = {clrBlue, clrRed, clrGreen};
         string al_tag[]  = {"JAW","TEETH","LIPS"};
         for (int a = 0; a < 3; a++) {
            string pfx = OBJ_PREFIX+"IND_ALLI_"+al_tag[a]+"_S"+IntegerToString(sid)+"_";
            DRAW_TREND_LINE(pfx,
               iAlligator(sym,tf,c.p1,c.s1,c.p2,c.s2,c.p3,c.s3,c.method,ap,al_mode[a],_i),
               iAlligator(sym,tf,c.p1,c.s1,c.p2,c.s2,c.p3,c.s3,c.method,ap,al_mode[a],_i-1),
               al_clr[a], 1)
         }
      }

      //── Ichimoku — 5 lines ────────────────────────────────────────
      else if (c.type=="iIchimoku")
      {
         int    ich_mode[] = {MODE_TENKANSEN, MODE_KIJUNSEN,
                              MODE_SENKOUSPANA, MODE_SENKOUSPANB, MODE_CHINKOUSPAN};
         color  ich_clr[]  = {clrDeepSkyBlue, clrCrimson,
                              clrLightGreen, clrOrangeRed, clrLime};
         string ich_tag[]  = {"TEN","KIJ","SPA","SPB","CHI"};
         for (int j = 0; j < 5; j++) {
            string pfx = OBJ_PREFIX+"IND_ICH_"+ich_tag[j]+"_S"+IntegerToString(sid)+"_";
            DRAW_TREND_LINE(pfx,
               iIchimoku(sym,tf,c.p1,c.p2,c.p3,ich_mode[j],_i),
               iIchimoku(sym,tf,c.p1,c.p2,c.p3,ich_mode[j],_i-1),
               ich_clr[j], 1)
         }
      }

      //── Oscillators: RSI, CCI, WPR, Momentum — corner label ──────
      else if (c.type=="iRSI" || c.type=="iCCI" ||
               c.type=="iWPR" || c.type=="iMomentum")
      {
         double val = 0;
         if      (c.type=="iRSI")      val = iRSI(sym,tf,c.period,ap,0);
         else if (c.type=="iCCI")      val = iCCI(sym,tf,c.period,ap,0);
         else if (c.type=="iWPR")      val = iWPR(sym,tf,c.period,0);
         else if (c.type=="iMomentum") val = iMomentum(sym,tf,c.period,ap,0);

         color  val_clr = clrSilver;
         string note    = "";
         if (c.type=="iRSI") {
            val_clr = (val>70) ? clrCrimson : (val<30) ? clrLimeGreen : clrSilver;
            note    = (val>70) ? " OB" : (val<30) ? " OS" : "";
         } else if (c.type=="iCCI") {
            val_clr = (val>100) ? clrCrimson : (val<-100) ? clrLimeGreen : clrSilver;
            note    = (val>100) ? " OB" : (val<-100) ? " OS" : "";
         }
         string txt = c.name+"("+IntegerToString(c.period)+"): "
                    + DoubleToStr(val,1) + note;
         DRAW_OSC_LABEL(OBJ_PREFIX+"IND_OSC_"+c.name+"_S"+IntegerToString(sid),
                        txt, val_clr)
      }

      //── MACD — label với main+signal ─────────────────────────────
      else if (c.type=="iMACD")
      {
         double main_v = iMACD(sym,tf,c.fast_period,c.slow_period,c.signal_period,ap,MODE_MAIN,0);
         double sig_v  = iMACD(sym,tf,c.fast_period,c.slow_period,c.signal_period,ap,MODE_SIGNAL,0);
         color clr = (main_v > 0) ? clrLimeGreen : clrCrimson;
         string txt = "MACD("+IntegerToString(c.fast_period)+","+IntegerToString(c.slow_period)+")"
                    + ": "+DoubleToStr(main_v,5)+" sig:"+DoubleToStr(sig_v,5);
         DRAW_OSC_LABEL(OBJ_PREFIX+"IND_OSC_"+c.name+"_S"+IntegerToString(sid), txt, clr)
      }

      //── Stochastic — label với main+signal ───────────────────────
      else if (c.type=="iStochastic")
      {
         double main_v = iStochastic(sym,tf,c.k_period,c.d_period,c.slowing,c.method,0,MODE_MAIN,0);
         double sig_v  = iStochastic(sym,tf,c.k_period,c.d_period,c.slowing,c.method,0,MODE_SIGNAL,0);
         color clr = (main_v>80) ? clrCrimson : (main_v<20) ? clrLimeGreen : clrSilver;
         string note = (main_v>80) ? " OB" : (main_v<20) ? " OS" : "";
         string txt = "STO("+IntegerToString(c.k_period)+"): "
                    + DoubleToStr(main_v,1)+note+" sig:"+DoubleToStr(sig_v,1);
         DRAW_OSC_LABEL(OBJ_PREFIX+"IND_OSC_"+c.name+"_S"+IntegerToString(sid), txt, clr)
      }

      //── ADX — label với main+DI+/-  ──────────────────────────────
      else if (c.type=="iADX")
      {
         double adx  = iADX(sym,tf,c.period,ap,MODE_MAIN,0);
         double diP  = iADX(sym,tf,c.period,ap,MODE_PLUSDI,0);
         double diM  = iADX(sym,tf,c.period,ap,MODE_MINUSDI,0);
         color clr = (adx>25) ? clrGold : clrSilver;
         string txt = "ADX("+IntegerToString(c.period)+"): "+DoubleToStr(adx,1)
                    + " +DI:"+DoubleToStr(diP,1)+" -DI:"+DoubleToStr(diM,1);
         DRAW_OSC_LABEL(OBJ_PREFIX+"IND_OSC_"+c.name+"_S"+IntegerToString(sid), txt, clr)
      }

      //── ATR / StdDev / MFI / OBV / Force — value label ──────────
      else if (c.type=="iATR"  || c.type=="iStdDev" || c.type=="iMFI" ||
               c.type=="iOBV"  || c.type=="iForce")
      {
         double val = 0;
         if      (c.type=="iATR")    val = iATR(sym,tf,c.period,0);
         else if (c.type=="iStdDev") val = iStdDev(sym,tf,c.period,c.ma_shift,c.method,ap,0);
         else if (c.type=="iMFI")    val = iMFI(sym,tf,c.period,0);
         else if (c.type=="iOBV")    val = iOBV(sym,tf,ap,0);
         else if (c.type=="iForce")  val = iForce(sym,tf,c.period,c.method,ap,0);
         int dp = (c.type=="iATR"||c.type=="iStdDev") ? 5 : 1;
         string txt = c.name+"("+IntegerToString(c.period)+"): "+DoubleToStr(val,dp);
         DRAW_OSC_LABEL(OBJ_PREFIX+"IND_OSC_"+c.name+"_S"+IntegerToString(sid),
                        txt, clrSilver)
      }

      else {
         LOG("[AI Bridge] Unknown indicator type: ", c.type);
      }
   }

   #undef DRAW_TREND_LINE
   #undef DRAW_OSC_LABEL

   DrawStrategyInfo(sid, cid);
   ChartRedraw(cid);
}

//+------------------------------------------------------------------+
//| Remove all EA objects from chart                                 |
//+------------------------------------------------------------------+
void CleanObjects()
{
   for (int i = ObjectsTotal() - 1; i >= 0; i--) {
      string name = ObjectName(i);
      if (StringFind(name, OBJ_PREFIX) == 0)
         ObjectDelete(name);
   }
}
