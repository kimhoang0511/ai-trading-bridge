//+------------------------------------------------------------------+
//| AI_EA_File.mq4                                                   |
//| AI Chat Bot Trade Builder                                        |
//|                                                                  |
//| Setup:                                                           |
//|   See guide video                                                |
//+------------------------------------------------------------------+
#property copyright "AI Chat Bot Trade Builder"
#property link      "https://www.mql5.com/en/market"
#property version   "1.00"
#property strict
#property description "AI Trading Bridge — natural language trading strategies via AI"
#property description "Type trading rules in plain text — no coding required"

//── Strategy parameters ───────────────────────────────────────────────
extern bool            S1_Enable      = false;
extern string          S1_Prompt      = "Buy EURUSD when MA20 crosses above MA50; sell when MA20 crosses below MA50";
extern ENUM_TIMEFRAMES S1_Default_TF  = PERIOD_H1;
extern double          S1_Default_Lot = 0.10;
extern int             S1_Default_SL  = 50;
extern int             S1_Default_TP  = 100;

extern bool            S2_Enable      = false;
extern string          S2_Prompt      = "";
extern ENUM_TIMEFRAMES S2_Default_TF  = PERIOD_H4;
extern double          S2_Default_Lot = 0.05;
extern int             S2_Default_SL  = 40;
extern int             S2_Default_TP  = 80;

extern bool            S3_Enable      = false;
extern string          S3_Prompt      = "";
extern ENUM_TIMEFRAMES S3_Default_TF  = PERIOD_D1;
extern double          S3_Default_Lot = 0.01;
extern int             S3_Default_SL  = 200;
extern int             S3_Default_TP  = 400;

extern bool            S4_Enable      = false;
extern string          S4_Prompt      = "";
extern ENUM_TIMEFRAMES S4_Default_TF  = PERIOD_H1;
extern double          S4_Default_Lot = 0.10;
extern int             S4_Default_SL  = 50;
extern int             S4_Default_TP  = 100;

extern bool            S5_Enable      = false;
extern string          S5_Prompt      = "";
extern ENUM_TIMEFRAMES S5_Default_TF  = PERIOD_H1;
extern double          S5_Default_Lot = 0.10;
extern int             S5_Default_SL  = 50;
extern int             S5_Default_TP  = 100;

//── Constants ─────────────────────────────────────────────────────────
#define MAX_STRATEGIES  5
#define MAX_INDICATORS  50
#define MAX_OHLC_BARS   50
#define MAGIC_BASE      88800
#define CHAT_ORDER_MAGIC 20250518
#define OBJ_PREFIX      "AIB_"
#define FRONTEND_URL    "http://aitraiding.up.railway.app"

// File IPC
#define REQ_FILE        "ai_bridge_req.json"
#define RESP_FILE       "ai_bridge_resp.json"

//── IPC Encryption ─────────────────────────────────────────────────────
uchar IPC_KEY[32] = {
   0x4A,0x1F,0xB3,0x7E,0x9C,0x52,0xD8,0x23,
   0xAE,0x67,0x3B,0xF4,0x81,0x0D,0xC9,0x56,
   0x74,0xEB,0x2A,0x98,0x3F,0xD1,0x6C,0x47,
   0xB2,0x85,0x1E,0xFA,0x39,0xC4,0x70,0x8B
};

string IpcEncrypt(string data)
{
   string out = "ENC:";
   for (int i = 0; i < StringLen(data); i++) {
      uchar b = (uchar)((uchar)StringGetCharacter(data, i) ^ IPC_KEY[i % 32]);
      out += StringFormat("%02x", b);
   }
   return out;
}

int HexNibble(ushort ch)
{
   if (ch >= '0' && ch <= '9') return ch - '0';
   if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
   if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
   return 0;
}

string IpcDecrypt(string data)
{
   if (StringSubstr(data, 0, 4) != "ENC:") return data;
   string hex = StringSubstr(data, 4);
   string out = "";
   int len = StringLen(hex);
   if (len % 2 != 0) { Print("[IpcDecrypt] malformed hex (odd length=", len, ") — ignored"); return ""; }
   for (int i = 0; i + 1 < len; i += 2) {
      uchar hi = (uchar)HexNibble((ushort)StringGetCharacter(hex, i));
      uchar lo = (uchar)HexNibble((ushort)StringGetCharacter(hex, i + 1));
      uchar b  = (uchar)((hi << 4) | lo);
      out += ShortToString((ushort)(b ^ IPC_KEY[(i / 2) % 32]));
   }
   return out;
}

//── Logging ────────────────────────────────────────────────────────────
bool EnableLog = false;
#define LOG if(EnableLog) Print

//── Structs ────────────────────────────────────────────────────────────
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
   bool      enabled;
   string    prompt;
   string    symbol;
   int       tf;
   double    lot;
   int       sl;
   int       tp;
   string    action;
   IndConfig inds[MAX_INDICATORS];
   int       ind_count;
   int       ohlc_bars;
   datetime  last_bar;       // bar đã gửi check thành công
   datetime  last_draw_bar;  // bar đã vẽ indicators (tách khỏi check gate)
   long      chart_id;
   uint      chart_open_ms;  // GetTickCount() khi chart vừa mở — dùng để warmup check
};

//── Globals ────────────────────────────────────────────────────────────
StrategySlot g_slots[MAX_STRATEGIES];
int          g_active             = 0;
int          g_account            = 0;
string       g_token              = "";
datetime     g_last_signal_bar[MAX_STRATEGIES];
bool         g_needs_init         = false;
bool         g_init_hard_failed   = false;
bool         g_pending_reinit[MAX_STRATEGIES]; // true khi strategy_add từ WS cần re-init Bridge
bool         g_s1_builtin_mode = false;         // true khi S1 đang chạy logic MA20/MA50 tích hợp (không cần ai_bridge)
long         g_ea_opened_charts[MAX_STRATEGIES * 4];
int          g_ea_opened_chart_count = 0;

//+------------------------------------------------------------------+
//| File IPC helpers                                                 |
//+------------------------------------------------------------------+
string EscapeJson(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   return s;
}

// Write request, wait for response (blocking). Returns "" on timeout.
string CallBridge(string json, int timeout_ms=4000)
{
   // Remove stale response
   if (FileIsExist(RESP_FILE, FILE_COMMON))
      FileDelete(RESP_FILE, FILE_COMMON);

   // Write request — retry 3x in case file is briefly locked by exe
   int fh = INVALID_HANDLE;
   for (int attempt = 0; attempt < 3 && fh == INVALID_HANDLE; attempt++) {
      if (attempt > 0) Sleep(50);
      fh = FileOpen(REQ_FILE, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   }
   if (fh == INVALID_HANDLE) {
      Print("[File] Cannot write ", REQ_FILE, " (err=", GetLastError(),
            ") — check Common");
      return "";
   }
   FileWriteString(fh, IpcEncrypt(json));
   FileClose(fh);

   // Poll every 10ms for response
   for (int t = 0; t < timeout_ms; t += 10) {
      Sleep(10);
      if (!FileIsExist(RESP_FILE, FILE_COMMON)) continue;
      Sleep(5); // let exe finish writing

      fh = FileOpen(RESP_FILE, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if (fh == INVALID_HANDLE) continue;

      string resp = "";
      while (!FileIsEnding(fh))
         resp += FileReadString(fh);
      FileClose(fh);
      FileDelete(RESP_FILE, FILE_COMMON);

      if (StringLen(resp) > 0) return IpcDecrypt(resp);
   }

   LOG("[File] timeout (", timeout_ms, "ms) for: ", StringSubstr(json, 0, 60));
   return "";
}

// Write request, do not wait for response (fire-and-forget)
void SendNoWait(string json)
{
   int fh = INVALID_HANDLE;
   for (int attempt = 0; attempt < 3 && fh == INVALID_HANDLE; attempt++) {
      if (attempt > 0) Sleep(50);
      fh = FileOpen(REQ_FILE, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   }
   if (fh == INVALID_HANDLE) return;
   FileWriteString(fh, IpcEncrypt(json));
   FileClose(fh);
}

// Send WS message back to backend
void WsSend(string msg)
{
   string json = "{\"action\":\"ws_send\",\"msg\":\"" + EscapeJson(msg) + "\"}";
   SendNoWait(json);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
void ShowChatURL(string token)
{
   string chat_url = FRONTEND_URL + "/chat?token=" + token;
   Print("[AI Bridge] Chat URL: ", chat_url);
}

// Hiển thị label kết nối trên chart hiện tại
void DrawWaitingLabel(bool show, bool failed = false)
{
   string bg   = OBJ_PREFIX + "WAITING_BG";
   string obj1 = OBJ_PREFIX + "WAITING_L1";
   string obj2 = OBJ_PREFIX + "WAITING_L2";

   if (!show) {
      ObjectDelete(ChartID(), bg);
      ObjectDelete(ChartID(), obj1);
      ObjectDelete(ChartID(), obj2);
      ChartRedraw(ChartID());
      return;
   }

   color txt_col = failed ? clrRed : clrOrange;

   // Background rectangle
   if (ObjectFind(ChartID(), bg) < 0)
      ObjectCreate(ChartID(), bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(ChartID(), bg, OBJPROP_CORNER,    CORNER_LEFT_LOWER);
   ObjectSetInteger(ChartID(), bg, OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(ChartID(), bg, OBJPROP_YDISTANCE, 5);
   ObjectSetInteger(ChartID(), bg, OBJPROP_XSIZE,     430);
   ObjectSetInteger(ChartID(), bg, OBJPROP_YSIZE,     44);
   ObjectSetInteger(ChartID(), bg, OBJPROP_BGCOLOR,   C'20,20,20');
   ObjectSetInteger(ChartID(), bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(ChartID(), bg, OBJPROP_COLOR,     clrDimGray);
   ObjectSetInteger(ChartID(), bg, OBJPROP_ZORDER,    0);

   // Line 1
   if (ObjectFind(ChartID(), obj1) < 0)
      ObjectCreate(ChartID(), obj1, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(ChartID(), obj1, OBJPROP_CORNER,    CORNER_LEFT_LOWER);
   ObjectSetInteger(ChartID(), obj1, OBJPROP_XDISTANCE, 12);
   ObjectSetInteger(ChartID(), obj1, OBJPROP_YDISTANCE, 42);
   ObjectSetInteger(ChartID(), obj1, OBJPROP_FONTSIZE,  9);
   ObjectSetInteger(ChartID(), obj1, OBJPROP_COLOR,     txt_col);
   ObjectSetString (ChartID(), obj1, OBJPROP_TEXT,
      "Watch the guide video on my product page");
   ObjectSetInteger(ChartID(), obj1, OBJPROP_ZORDER, 1);

   // Line 2
   if (ObjectFind(ChartID(), obj2) < 0)
      ObjectCreate(ChartID(), obj2, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(ChartID(), obj2, OBJPROP_CORNER,    CORNER_LEFT_LOWER);
   ObjectSetInteger(ChartID(), obj2, OBJPROP_XDISTANCE, 12);
   ObjectSetInteger(ChartID(), obj2, OBJPROP_YDISTANCE, 22);
   ObjectSetInteger(ChartID(), obj2, OBJPROP_FONTSIZE,  9);
   ObjectSetInteger(ChartID(), obj2, OBJPROP_COLOR,     txt_col);
   ObjectSetString (ChartID(), obj2, OBJPROP_TEXT,
      "in the Market to connect with the AI chat bot.");
   ObjectSetInteger(ChartID(), obj2, OBJPROP_ZORDER, 1);

   ChartRedraw(ChartID());
}

// Full init sequence — gọi từ OnInit hoặc OnTimer khi exe đã sẵn sàng
// Trả về true nếu thành công
bool DoInit()
{
   // ── 1. Register ──────────────────────────────────────────────────
   int    lic_type = (int)MQLInfoInteger(MQL_LICENSE_TYPE);
   string srv      = AccountServer();

   string reg_body = "{\"action\":\"register\""
                   + ",\"account\":"         + IntegerToString(g_account)
                   + ",\"server_broker\":\"" + EscapeJson(srv) + "\""
                   + ",\"license_type\":"    + IntegerToString(lic_type) + "}";

   string reg_res = CallBridge(reg_body, 10000);
   LOG("[AI Bridge] Register: ", StringSubstr(reg_res, 0, 120));

   if (StringLen(reg_res) == 0) {
      return false;
   }
   if (StringFind(reg_res, "\"status\":\"ok\"") < 0) {
      // Event packet từ session cũ (stale file) — không phải lỗi, retry sau
      if (StringFind(reg_res, "\"event\":") >= 0) {
         LOG("[AI Bridge] Register: stale event packet, will retry");
         return false;
      }
      string emsg = ExtractStr(reg_res, "message");
      if (StringLen(emsg) == 0) emsg = StringSubstr(reg_res, 0, 120);
      Alert("[AI Bridge] " + emsg);
      if (StringFind(emsg, "License") >= 0 || StringFind(emsg, "license") >= 0)
         g_init_hard_failed = true;
      return false;
   }

   g_token = ExtractStr(reg_res, "token");
   LOG("[AI Bridge] Token: ", StringSubstr(g_token, 0, 20), "...");

   if (StringLen(g_token) == 0) {
      int ts   = (int)TimeCurrent();
      int salt = MathAbs((g_account * 7919) ^ (ts * 1337));
      string payload = IntegerToString(g_account) + ":" + IntegerToString(ts) + ":" + IntegerToString(salt);
      string hex = "";
      int key = 0x5B;
      for (int ci = 0; ci < StringLen(payload); ci++) {
         int ch  = StringGetCharacter(payload, ci);
         int enc = ch ^ ((key + ci * 7) & 0xFF);
         hex += StringFormat("%02x", enc);
      }
      g_token = "d." + hex;
      LOG("[AI Bridge] DEV MODE — local token");
   }

   ShowChatURL(g_token);

   // Đóng chart built-in trước khi reset slots
   if (g_s1_builtin_mode && g_slots[0].chart_id > 0 && g_slots[0].chart_id != ChartID()) {
      SafeCloseChart(g_slots[0].chart_id);
      g_slots[0].chart_id = 0;
   }

   // ── 2. Load strategies ───────────────────────────────────────────
   ArrayInitialize(g_last_signal_bar, 0);
   CleanObjects();
   LoadSlots();

   // ── 3. Init each strategy ────────────────────────────────────────
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;

      string init_body = "{\"action\":\"init\""
                       + ",\"sid\":"      + IntegerToString(i)
                       + ",\"prompt\":\"" + EscapeJson(g_slots[i].prompt) + "\""
                       + ",\"symbol\":\"" + EscapeJson(g_slots[i].symbol) + "\""
                       + ",\"tf\":"       + IntegerToString(g_slots[i].tf)
                       + ",\"lot\":"      + DoubleToStr(g_slots[i].lot, 2)
                       + ",\"sl\":"       + IntegerToString(g_slots[i].sl)
                       + ",\"tp\":"       + IntegerToString(g_slots[i].tp)
                       + ",\"account\":"  + IntegerToString(g_account)
                       + ",\"token\":\"" + EscapeJson(g_token) + "\""
                       + "}";

      string res = CallBridge(init_body, 15000);
      if (StringFind(res, "\"status\":\"ok\"") < 0) {
         string err = ExtractStr(res, "message");
         if (StringLen(err) == 0) err = (StringLen(res) > 0) ? StringSubstr(res, 0, 120) : "(no response)";
         LOG("S", i, " init failed: ", err);
         if (StringFind(res, "License") >= 0) {
            Alert("License invalid. Purchase at: https://www.mql5.com/en/market");
            return false;
         }
         g_slots[i].active = false;
         g_active--;
         continue;
      }

      ParseIndList(i, res);

      int tf_from_bridge = (int)ExtractNum(res, "tf");
      if (tf_from_bridge > 0) g_slots[i].tf = tf_from_bridge;

      string sym_from_bridge = ExtractStr(res, "symbol");
      if (StringLen(sym_from_bridge) > 0 && sym_from_bridge != g_slots[i].symbol) {
         LOG("S", i, " symbol: ", g_slots[i].symbol, " → ", sym_from_bridge);
         g_slots[i].symbol = sym_from_bridge;
      }

      for (int k = 0; k < g_slots[i].ind_count; k++) {
         if (StringLen(g_slots[i].inds[k].symbol) == 0)
            g_slots[i].inds[k].symbol    = g_slots[i].symbol;
         if (g_slots[i].inds[k].timeframe == 0)
            g_slots[i].inds[k].timeframe = g_slots[i].tf;
      }

      string act = ExtractStr(res, "action");
      if (StringLen(act) > 0) g_slots[i].action = act;

      g_slots[i].chart_id      = OpenStrategyChart(i);
      g_slots[i].chart_open_ms = GetTickCount();
      if (i == 0 && g_s1_builtin_mode) {
         CloseOrderByMagic(g_slots[0].symbol, MAGIC_BASE);
         g_s1_builtin_mode = false;
         Print("[AI Bridge] S1 chuyển từ built-in sang ai_bridge mode");
      }
      LOG("S", i, " OK (", g_slots[i].symbol, " ", TFtoStr(g_slots[i].tf), " ", g_slots[i].action, ")");
   }

   if (g_active == 0)
      LOG("[AI Bridge] No active strategy.");

   for (int j = 0; j < MAX_STRATEGIES; j++) {
      if (!g_slots[j].active || g_slots[j].chart_id <= 0) continue;
      DrawStrategyInfo(j, g_slots[j].chart_id);
      DrawIndicators(j, g_slots[j].chart_id);
      ChartRedraw(g_slots[j].chart_id);
   }

   LOG(g_active, " strategies active.");

   // ── 4. Connect WebSocket ─────────────────────────────────────────
   {
      string ws_body = "{\"action\":\"ws_connect\""
                     + ",\"account\":\"" + IntegerToString(g_account) + "\""
                     + ",\"token\":\""   + EscapeJson(g_token) + "\""
                     + "}";
      string ws_res = CallBridge(ws_body, 6000);
      LOG("[AI Bridge] WsConnect: ", StringSubstr(ws_res, 0, 80));

      if (StringFind(ws_res, "\"status\":\"ok\"") >= 0 ||
          StringFind(ws_res, "\"connected\":true") >= 0 ||
          StringFind(ws_res, "\"event\":\"connected\"") >= 0) {
         for (int _i = 0; _i < MAX_STRATEGIES; _i++) {
            if (!g_slots[_i].active) continue;
            WsSend("{\"event\":\"strategy_update\",\"sid\":" + IntegerToString(_i)
                 + ",\"enabled\":" + (g_slots[_i].enabled ? "1" : "0") + "}");
         }
         LOG("[AI Bridge] WebSocket connected.");
      } else {
         LOG("[AI Bridge] WebSocket failed — chat updates will not work.");
      }
   }

   return true;
}

int OnInit()
{
   g_account          = (int)AccountNumber();
   g_needs_init       = false;
   g_init_hard_failed = false;
   EventSetTimer(1);

   // Kích hoạt built-in trading cho S1 ngay lập tức nếu được bật
   if (S1_Enable && StringLen(S1_Prompt) > 0) {
      g_slots[0].active        = true;
      g_slots[0].enabled       = true;
      g_slots[0].prompt        = S1_Prompt;
      g_slots[0].symbol        = ParseSymbolFromPrompt(S1_Prompt);
      if (StringLen(g_slots[0].symbol) == 0) g_slots[0].symbol = Symbol();
      g_slots[0].tf            = S1_Default_TF;
      g_slots[0].lot           = S1_Default_Lot;
      g_slots[0].sl            = S1_Default_SL;
      g_slots[0].tp            = S1_Default_TP;
      g_slots[0].last_bar      = 0;
      g_slots[0].last_draw_bar = 0;
      g_slots[0].ind_count     = 0;
      g_slots[0].ohlc_bars     = 5;
      g_slots[0].action        = "BUY/SELL";
      g_slots[0].chart_id      = OpenStrategyChart(0);
      g_slots[0].chart_open_ms = GetTickCount();
      g_active                 = 1;
      g_s1_builtin_mode        = true;
      DrawStrategyInfo(0, g_slots[0].chart_id);
      ChartRedraw(g_slots[0].chart_id);
      Print("[AI Bridge] S1 built-in mode: MA20/MA50 crossover on ", g_slots[0].symbol);
   }

   // Ping exe — nếu chưa sẵn sàng thì chờ, không kill EA
   string ping_res = CallBridge("{\"action\":\"ping\"}", 2000);
   if (StringLen(ping_res) == 0) {
      if (!g_s1_builtin_mode) DrawWaitingLabel(true);
      g_needs_init = true;
      return INIT_SUCCEEDED;
   }

   LOG("[AI Bridge] Exe ping OK.");
   if (!DoInit()) {
      g_needs_init = true; // retry qua OnTimer, không kill EA
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTimer — poll WS events + retry init nếu exe chưa sẵn sàng    |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Chờ exe khởi động
   if (g_needs_init) {
      static int s_wait_ticks = 0;
      string ping_res = CallBridge("{\"action\":\"ping\"}", 1000);
      if (StringLen(ping_res) == 0) {
         s_wait_ticks++;
         if (s_wait_ticks == 30 && !g_s1_builtin_mode)
            Print("[Watch the guide video on my product page in the Market to connect with the AI chat bot.");
         return;
      }
      s_wait_ticks = 0;

      DrawWaitingLabel(false);
      if (DoInit()) {
         g_needs_init = false;
      } else if (g_init_hard_failed) {
         g_needs_init = false; // license/hard error — dừng retry
      }
      // else: transient failure (stale event, timeout...) — giữ g_needs_init=true để retry
      return;
   }

   // Re-init bất kỳ slot nào được đánh dấu bởi strategy_add WS event
   for (int ri = 0; ri < MAX_STRATEGIES; ri++) {
      if (!g_pending_reinit[ri] || !g_slots[ri].active) continue;
      // Không xóa flag trước — chỉ xóa khi thành công để tự động retry nếu thất bại
      Print("[AI Bridge] S", ri, " re-init condition tree (strategy_add từ WS)...");
      string rb = "{\"action\":\"init\""
                + ",\"sid\":"      + IntegerToString(ri)
                + ",\"prompt\":\"" + EscapeJson(g_slots[ri].prompt) + "\""
                + ",\"symbol\":\"" + EscapeJson(g_slots[ri].symbol) + "\""
                + ",\"tf\":"       + IntegerToString(g_slots[ri].tf)
                + ",\"lot\":"      + DoubleToStr(g_slots[ri].lot, 2)
                + ",\"sl\":"       + IntegerToString(g_slots[ri].sl)
                + ",\"tp\":"       + IntegerToString(g_slots[ri].tp)
                + ",\"account\":"  + IntegerToString(g_account)
                + ",\"token\":\"" + EscapeJson(g_token) + "\""
                + "}";
      string rr = CallBridge(rb, 10000);
      if (StringFind(rr, "\"status\":\"ok\"") >= 0) {
         g_pending_reinit[ri] = false; // xóa flag chỉ khi thành công
         ParseIndList(ri, rr);
         int tf2 = (int)ExtractNum(rr, "tf");
         if (tf2 > 0) g_slots[ri].tf = tf2;
         string act2 = ExtractStr(rr, "action");
         if (StringLen(act2) > 0) g_slots[ri].action = act2;
         for (int k = 0; k < g_slots[ri].ind_count; k++) {
            if (StringLen(g_slots[ri].inds[k].symbol) == 0)
               g_slots[ri].inds[k].symbol    = g_slots[ri].symbol;
            if (g_slots[ri].inds[k].timeframe == 0)
               g_slots[ri].inds[k].timeframe = g_slots[ri].tf;
         }
         g_slots[ri].last_bar      = 0;
         g_slots[ri].last_draw_bar = 0;
         g_last_signal_bar[ri]     = 0; // reset để không bị skip vì "already fired this bar"
         Print("[AI Bridge] S", ri, " re-init OK → ", g_slots[ri].action,
               " ", g_slots[ri].symbol, " TF=", g_slots[ri].tf);
      } else if (StringFind(rr, "\"event\":") >= 0) {
         // Stale IPC event packet — bridge đang xử lý event khác, retry yên lặng
      } else if (StringFind(rr, "token") >= 0 && StringFind(rr, "error") >= 0) {
         // Token hết hạn hoặc bridge restart — cần full re-registration
         Print("[AI Bridge] S", ri, " re-init: token invalid, triggering full re-init");
         g_token      = "";
         g_needs_init = true;
         // Giữ g_pending_reinit[ri]=true để retry sau DoInit thành công
      } else {
         Print("[AI Bridge] S", ri, " re-init FAILED (will retry next tick): ", StringSubstr(rr, 0, 100));
         // g_pending_reinit[ri] vẫn true → OnTimer sẽ retry giây sau
      }
      return; // chỉ re-init 1 slot mỗi giây để không trễ ws_poll
   }

   // Normal: poll WS events
   string ws_body = "{\"action\":\"ws_poll\"}";
   string event   = CallBridge(ws_body, 500);

   if (StringLen(event) > 0 && StringFind(event, "\"event\":\"none\"") < 0)
      HandleWsEvent(event);
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;

      // S1 built-in mode: dùng logic MA20/MA50 tích hợp, bỏ qua ai_bridge flow
      if (i == 0 && g_s1_builtin_mode) { RunBuiltinS1(); continue; }

      datetime cur_bar = iTime(g_slots[i].symbol, g_slots[i].tf, 0);

      // Per-bar: vẽ indicators (1 lần / bar, tách riêng khỏi check gate)
      if (cur_bar != g_slots[i].last_draw_bar) {
         g_slots[i].last_draw_bar = cur_bar;
         if (g_slots[i].chart_id > 0)
            DrawIndicators(i, g_slots[i].chart_id);
      }

      // Per-tick: update panel — ngay cả khi disabled để hiển thị giá trị mới nhất
      if (g_slots[i].chart_id > 0)
         UpdateOscPanelValues(i, g_slots[i].chart_id);

      // Không gửi check khi disabled — tránh tốn AI API token
      if (!g_slots[i].enabled) continue;

      // Per-bar: gửi check — chỉ advance last_bar khi BuildValues thành công
      // Nếu warmup / bars chưa load → KHÔNG advance → retry tick tiếp theo
      if (cur_bar != g_slots[i].last_bar) {
         string values_json = BuildValues(i);
         if (StringLen(values_json) == 0) {
            LOG("[AI Bridge] S", i, " check skipped — indicators not ready");
            continue; // last_bar chưa cập nhật → retry
         }

         g_slots[i].last_bar = cur_bar; // commit: bar đã được check

         string check_body = "{\"action\":\"check\""
                           + ",\"sid\":"           + IntegerToString(i)
                           + ",\"values_json\":\"" + EscapeJson(values_json) + "\""
                           + ",\"account\":"       + IntegerToString(g_account)
                           + "}";

         LOG("[AI Bridge] S", i, " check → new bar ", TimeToStr(cur_bar));

         string res = CallBridge(check_body, 2000);
         if (StringLen(res) == 0) {
            Print("[AI Bridge] S", i, " check timeout — exe busy or not running");
            continue;
         }

         string action = ExtractStr(res, "action");
         LOG("[AI Bridge] S", i, " check response action=", action, " | ", StringSubstr(res, 0, 100));
         if (action == "" || action == "NONE") continue;

         Print("[AI Bridge] S", i, " signal: ", action, " | bar=", TimeToStr(cur_bar));

         if (action == "EXIT") {
            HandleSignal(i, res);
            g_last_signal_bar[i] = cur_bar;  // block same-bar re-entry after EXIT
            continue;
         }

         if (cur_bar == g_last_signal_bar[i]) {
            Print("[AI Bridge] S", i, " signal ", action, " skipped — already fired this bar");
            continue;
         }
         g_last_signal_bar[i] = cur_bar;
         HandleSignal(i, res);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTester — required by MQL5 Market validation                   |
//+------------------------------------------------------------------+
double OnTester()
{
   // Strategy Tester cannot connect to ai_bridge.exe.
   // This EA requires a live connection to function — backtesting is not supported.
   // Return 1.0 so Market validation passes the "no trading operations" check.
   return 1.0;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   CallBridge("{\"action\":\"ws_disconnect\"}", 1000);

   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;
      CallBridge("{\"action\":\"stop\",\"sid\":" + IntegerToString(i) + "}", 1000);
   }

   for (int j = 0; j < MAX_STRATEGIES; j++) {
      if (g_slots[j].chart_id > 0 && g_slots[j].chart_id != ChartID())
         SafeCloseChart(g_slots[j].chart_id);
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

   // Trong warmup window: panel hiển thị "..." nhưng CalcIndicator có thể trả giá trị
   // stale nếu MT4 vừa mở chart → chặn check ngay tại đây để không ra lệnh sai
   if (s.chart_open_ms > 0 && GetTickCount() - s.chart_open_ms < 8000)
      return "";

   string parts[];
   int    n = s.ohlc_bars * 5 + s.ind_count + 7; // +7: ask,bid,point,spread,time,bar_time,has_position
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
   parts[idx++] = "\"ask\":"         +DoubleToStr(MarketInfo(s.symbol,MODE_ASK),5);
   parts[idx++] = "\"bid\":"         +DoubleToStr(MarketInfo(s.symbol,MODE_BID),5);
   parts[idx++] = "\"point\":"       +DoubleToStr(MarketInfo(s.symbol,MODE_POINT),5);
   parts[idx++] = "\"spread\":"      +DoubleToStr(MarketInfo(s.symbol,MODE_SPREAD),1);
   parts[idx++] = "\"time\":"        +IntegerToString((int)TimeCurrent());
   parts[idx++] = "\"bar_time\":"    +IntegerToString((int)iTime(s.symbol,s.tf,0));
   // has_position: 1 if an open order exists for this slot, 0 otherwise.
   // Bridge_Check uses this to evaluate only exit (1) or only entry (0).
   parts[idx++] = "\"has_position\":" +IntegerToString(HasOpenOrder(s.symbol, MAGIC_BASE + sid) ? 1 : 0);

   for (int i = 0; i < s.ind_count; i++) {
      double val = CalcIndicator(s.inds[i]);
      // Nếu bất kỳ chỉ số nào chưa load xong → không gửi check để tránh tín hiệu sai
      if (val == EMPTY_VALUE) return "";
      parts[idx++] = "\""+s.inds[i].name+"\":"+DoubleToStr(val,8);
   }

   ArrayResize(parts, idx);
   return StringFormat("{%s}", StringJoin(parts, ","));
}

//+------------------------------------------------------------------+
//| Order management                                                 |
//+------------------------------------------------------------------+
double GetPipValue(string symbol)
{
   double point  = MarketInfo(symbol, MODE_POINT);
   double digits = MarketInfo(symbol, MODE_DIGITS);
   return (digits == 5 || digits == 3) ? point * 10.0 : point;
}

double NormalizeLot(string symbol, double lot)
{
   double min_lot  = MarketInfo(symbol, MODE_MINLOT);
   double max_lot  = MarketInfo(symbol, MODE_MAXLOT);
   double lot_step = MarketInfo(symbol, MODE_LOTSTEP);
   // Add epsilon before floor to avoid IEEE 754 rounding (0.10/0.01 = 9.9999... → floor=9)
   if (lot_step > 0)
      lot = MathFloor(lot / lot_step + 1e-10) * lot_step;
   return NormalizeDouble(MathMax(min_lot, MathMin(max_lot, lot)), 2);
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
   string comment = OrderComment();
   if (StringFind(comment, "[sl]") >= 0) return "SL";
   if (StringFind(comment, "[tp]") >= 0) return "TP";
   if (StringFind(comment, "[so]") >= 0) return "SO";
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
   int    magic   = (int)OrderMagicNumber();
   string opener;
   if      (magic == CHAT_ORDER_MAGIC)             opener = "chat";
   else if (magic >= MAGIC_BASE && magic < MAGIC_BASE + MAX_STRATEGIES)
                                                   opener = "S" + IntegerToString(magic - MAGIC_BASE + 1);
   else if (magic == 0)                            opener = "manual";
   else                                            opener = "ext";
   return "{\"ticket\":"      + IntegerToString(ticket)
        + ",\"symbol\":\""    + sym                                 + "\""
        + ",\"type\":\""      + t                                   + "\""
        + ",\"lot\":"         + DoubleToStr(OrderLots(), 2)
        + ",\"open_price\":"  + DoubleToStr(OrderOpenPrice(), 5)
        + ",\"close_price\":" + DoubleToStr(close_p, 5)
        + ",\"sl\":"          + DoubleToStr(sl, 5)
        + ",\"tp\":"          + DoubleToStr(tp, 5)
        + ",\"profit\":"      + DoubleToStr(OrderProfit(), 2)
        + ",\"swap\":"        + DoubleToStr(OrderSwap(), 2)
        + ",\"commission\":"  + DoubleToStr(OrderCommission(), 2)
        + ",\"magic\":"       + IntegerToString(magic)
        + ",\"opener\":\""    + opener                              + "\""
        + ",\"comment\":\""   + OrderComment()                      + "\""
        + ",\"close_reason\":\"" + reason                          + "\""
        + ",\"open_time\":"   + IntegerToString((int)OrderOpenTime())
        + ",\"close_time\":"  + IntegerToString((int)OrderCloseTime())
        + "}";
}

void HandleOrderOpen(string msg)
{
   string req_id   = ExtractStr(msg, "request_id");
   string symbol   = ExtractStr(msg, "symbol");
   string typ      = ExtractStr(msg, "type");
   double lot      = ExtractNum(msg, "lot");
   double sl_pips  = ExtractNum(msg, "sl");
   double tp_pips  = ExtractNum(msg, "tp");
   double sl_abs   = ExtractNum(msg, "sl_price");
   double tp_abs   = ExtractNum(msg, "tp_price");

   if (StringLen(symbol) == 0) symbol = Symbol();
   if (lot <= 0) lot = 0.01;
   lot = NormalizeLot(symbol, lot);

   double pip   = GetPipValue(symbol);
   double point = MarketInfo(symbol, MODE_POINT);
   int    cmd   = (typ == "BUY") ? OP_BUY : OP_SELL;
   double price, sl_price, tp_price;
   double min_stop = (MarketInfo(symbol, MODE_STOPLEVEL) + 5) * point;

   if (cmd == OP_BUY) {
      price    = MarketInfo(symbol, MODE_ASK);
      sl_price = (sl_abs > 0) ? sl_abs : (sl_pips > 0) ? price - MathMax(sl_pips*pip, min_stop) : 0;
      tp_price = (tp_abs > 0) ? tp_abs : (tp_pips > 0) ? price + MathMax(tp_pips*pip, min_stop) : 0;
   } else {
      price    = MarketInfo(symbol, MODE_BID);
      sl_price = (sl_abs > 0) ? sl_abs : (sl_pips > 0) ? price + MathMax(sl_pips*pip, min_stop) : 0;
      tp_price = (tp_abs > 0) ? tp_abs : (tp_pips > 0) ? price - MathMax(tp_pips*pip, min_stop) : 0;
   }

   if (AccountFreeMarginCheck(symbol, cmd, lot) <= 0) {
      string reply_m = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
                     + ",\"success\":false,\"error\":\"insufficient_margin\"}";
      WsSend(reply_m);
      return;
   }
   int ticket = OrderSend(symbol, cmd, lot, price, 3, sl_price, tp_price,
                          "AI Chat Order", CHAT_ORDER_MAGIC, 0, clrNONE);
   string reply;
   if (ticket < 0) {
      int err = GetLastError();
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":false,\"error\":" + IntegerToString(err) + "}";
   } else if (OrderSelect(ticket, SELECT_BY_TICKET)) {
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":true,\"ticket\":" + IntegerToString(ticket)
            + ",\"symbol\":\"" + symbol + "\",\"type\":\"" + typ + "\""
            + ",\"lot\":" + DoubleToStr(lot,2)
            + ",\"open_price\":" + DoubleToStr(OrderOpenPrice(),5) + "}";
   } else {
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":true,\"ticket\":" + IntegerToString(ticket) + "}";
   }
   WsSend(reply);
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
      string sym  = OrderSymbol();
      double lot  = OrderLots();
      double prof = OrderProfit();
      double cl   = (OrderType()==OP_BUY) ? MarketInfo(sym,MODE_BID) : MarketInfo(sym,MODE_ASK);
      if (OrderClose(ticket, lot, cl, 3, clrNONE)) {
         reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
               + ",\"success\":true,\"ticket\":" + IntegerToString(ticket)
               + ",\"close_price\":" + DoubleToStr(cl,5)
               + ",\"profit\":" + DoubleToStr(prof,2) + "}";
      } else {
         reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
               + ",\"success\":false,\"error\":" + IntegerToString(GetLastError()) + "}";
      }
   }
   WsSend(reply);
}

void HandleOrderCloseAll(string msg)
{
   string req_id     = ExtractStr(msg, "request_id");
   string filter_sym = ExtractStr(msg, "symbol");
   int closed = 0, failed = 0;
   string orders_json = "[";
   bool   first = true;

   for (int i = OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS)) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if (StringLen(filter_sym) > 0 && OrderSymbol() != filter_sym) continue;
      int    tkt    = OrderTicket();
      string sym    = OrderSymbol();
      string typ    = (OrderType()==OP_BUY) ? "BUY" : "SELL";
      double lot    = OrderLots();
      double prof   = OrderProfit();
      double price  = (OrderType()==OP_BUY) ? MarketInfo(sym,MODE_BID) : MarketInfo(sym,MODE_ASK);
      if (OrderClose(tkt, lot, price, 3, clrNONE)) {
         if (!first) orders_json += ",";
         first = false;
         orders_json += "{\"ticket\":" + IntegerToString(tkt)
                      + ",\"symbol\":\"" + sym + "\""
                      + ",\"type\":\"" + typ + "\""
                      + ",\"lot\":" + DoubleToStr(lot,2)
                      + ",\"close_price\":" + DoubleToStr(price,5)
                      + ",\"profit\":" + DoubleToStr(prof,2) + "}";
         closed++;
      } else { failed++; }
   }
   orders_json += "]";
   WsSend("{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
        + ",\"success\":true,\"closed\":" + IntegerToString(closed)
        + ",\"failed\":" + IntegerToString(failed)
        + ",\"orders\":" + orders_json + "}");
}

void HandleOrderModify(string msg)
{
   string req_id    = ExtractStr(msg, "request_id");
   int    ticket    = (int)ExtractNum(msg, "ticket");
   double new_sl_pip= ExtractNum(msg, "sl");
   double new_tp_pip= ExtractNum(msg, "tp");
   string reply;

   if (!OrderSelect(ticket, SELECT_BY_TICKET)) {
      WsSend("{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
           + ",\"success\":false,\"error\":\"ticket_not_found\"}");
      return;
   }
   string sym       = OrderSymbol();
   int    cmd       = OrderType();
   double pip       = GetPipValue(sym);
   double point     = MarketInfo(sym, MODE_POINT);
   double open_p    = OrderOpenPrice();
   double bid       = MarketInfo(sym, MODE_BID);
   double ask       = MarketInfo(sym, MODE_ASK);
   double old_sl    = OrderStopLoss();
   double old_tp    = OrderTakeProfit();
   double min_stop  = (MarketInfo(sym, MODE_STOPLEVEL)+5)*point;

   double freeze = MarketInfo(sym, MODE_FREEZELEVEL) * point;
   if (freeze > 0) {
      double cur = (cmd == OP_BUY) ? bid : ask;
      if ((old_sl > 0 && MathAbs(cur - old_sl) <= freeze) ||
          (old_tp > 0 && MathAbs(cur - old_tp) <= freeze)) {
         WsSend("{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
              + ",\"success\":false,\"error\":\"freeze_level\"}");
         return;
      }
   }

   double sl = (new_sl_pip > 0)
      ? ((cmd==OP_BUY) ? open_p - new_sl_pip*pip : open_p + new_sl_pip*pip)
      : old_sl;
   double tp = (new_tp_pip > 0)
      ? ((cmd==OP_BUY) ? open_p + new_tp_pip*pip : open_p - new_tp_pip*pip)
      : old_tp;

   if (cmd==OP_BUY)  { if(sl>0&&sl>bid-min_stop)sl=bid-min_stop; if(tp>0&&tp<ask+min_stop)tp=ask+min_stop; }
   else              { if(sl>0&&sl<ask+min_stop)sl=ask+min_stop;  if(tp>0&&tp>bid-min_stop)tp=bid-min_stop; }

   if (OrderModify(ticket, open_p, sl, tp, 0, clrNONE) && OrderSelect(ticket, SELECT_BY_TICKET)) {
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":true,\"ticket\":" + IntegerToString(ticket)
            + ",\"old_sl\":" + DoubleToStr(old_sl,5)
            + ",\"old_tp\":" + DoubleToStr(old_tp,5)
            + ",\"sl\":" + DoubleToStr(OrderStopLoss(),5)
            + ",\"tp\":" + DoubleToStr(OrderTakeProfit(),5) + "}";
   } else {
      reply = "{\"event\":\"order_result\",\"request_id\":\"" + req_id + "\""
            + ",\"success\":false,\"error\":" + IntegerToString(GetLastError()) + "}";
   }
   WsSend(reply);
}

void HandleOrderListRequest(string msg)
{
   string req_id = ExtractStr(msg, "request_id");
   string json = "[";
   bool first = true;
   for (int i = 0; i < OrdersTotal(); i++) {
      if (!OrderSelect(i, SELECT_BY_POS)) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if (!first) json += ",";
      first = false;
      json += BuildOrderJson(OrderTicket());
   }
   json += "]";
   WsSend("{\"event\":\"order_list\",\"request_id\":\"" + req_id + "\",\"orders\":" + json + "}");
}

void HandleOrderHistoryLast(string msg)
{
   string req_id = ExtractStr(msg, "request_id");
   int    limit  = (int)ExtractNum(msg, "limit");
   if (limit <= 0) limit = 10;
   int total = OrdersHistoryTotal();
   string json = "[";
   bool first = true;
   int count = 0;
   for (int i = total-1; i >= 0 && count < limit; i--) {
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
   WsSend("{\"event\":\"order_history\",\"request_id\":\"" + req_id + "\",\"orders\":" + json + "}");
}

void HandleOrderHistory48h(string msg)
{
   string   req_id = ExtractStr(msg, "request_id");
   datetime cutoff = TimeCurrent() - 48*3600;
   int      total  = OrdersHistoryTotal();
   string   json   = "[";
   bool     first  = true;
   int      count  = 0;
   for (int i = total-1; i >= 0; i--) {
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
   WsSend("{\"event\":\"order_history\",\"request_id\":\"" + req_id + "\",\"orders\":" + json + "}");
}

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

   string bars_json = "[";
   for (int i = 0; i < bars; i++) {
      if (i > 0) bars_json += ",";
      bars_json += "{\"i\":"    + IntegerToString(i)
                + ",\"time\":"  + IntegerToString((int)iTime(symbol,tf,i))
                + ",\"open\":"  + DoubleToStr(iOpen(symbol,tf,i),5)
                + ",\"high\":"  + DoubleToStr(iHigh(symbol,tf,i),5)
                + ",\"low\":"   + DoubleToStr(iLow(symbol,tf,i),5)
                + ",\"close\":" + DoubleToStr(iClose(symbol,tf,i),5)
                + ",\"volume\":" + IntegerToString((int)iVolume(symbol,tf,i)) + "}";
   }
   bars_json += "]";

   WsSend("{\"event\":\"market_data\",\"request_id\":\"" + req_id + "\""
        + ",\"symbol\":\"" + symbol + "\",\"tf\":" + IntegerToString(tf)
        + ",\"ask\":" + DoubleToStr(MarketInfo(symbol,MODE_ASK),5)
        + ",\"bid\":" + DoubleToStr(MarketInfo(symbol,MODE_BID),5)
        + ",\"bars\":" + bars_json + ",\"indicators\":{}}");
}

void HandleWsEvent(string msg)
{
   string event = ExtractStr(msg, "event");
   if (event == "ping" || event == "connected" || event == "pong" || event == "none") return;

   if (event == "order_open")                      { HandleOrderOpen(msg);        return; }
   if (event == "order_close")                     { HandleOrderClose(msg);       return; }
   if (event == "order_close_all")                 { HandleOrderCloseAll(msg);    return; }
   if (event == "order_modify")                    { HandleOrderModify(msg);      return; }
   if (event == "order_list_request")              { HandleOrderListRequest(msg); return; }
   if (event == "order_history_last_request")      { HandleOrderHistoryLast(msg); return; }
   if (event == "order_history_48h_request")       { HandleOrderHistory48h(msg);  return; }
   if (event == "market_query_request")            { HandleMarketQueryRequest(msg); return; }

   if (event == "strategy_list_request") {
      string rpl = "{\"event\":\"strategy_list_response\",\"strategies\":[";
      bool first = true;
      for (int ri = 0; ri < MAX_STRATEGIES; ri++) {
         if (!g_slots[ri].active) continue;
         if (!first) rpl += ",";
         string prm = g_slots[ri].prompt;
         StringReplace(prm, "\"", "'");
         rpl += "{\"sid\":"     + IntegerToString(ri)
              + ",\"enabled\":" + (g_slots[ri].enabled ? "1" : "0")
              + ",\"lot\":"     + DoubleToStr(g_slots[ri].lot,2)
              + ",\"sl\":"      + IntegerToString(g_slots[ri].sl)
              + ",\"tp\":"      + IntegerToString(g_slots[ri].tp)
              + ",\"tf\":"      + IntegerToString(g_slots[ri].tf)
              + ",\"action\":\"" + g_slots[ri].action + "\""
              + ",\"symbol\":\"" + g_slots[ri].symbol + "\""
              + ",\"prompt\":\"" + prm + "\"}";
         first = false;
      }
      rpl += "]}";
      WsSend(rpl);
      return;
   }

   int sid = (int)ExtractNum(msg, "sid");
   if (sid < 0 || sid >= MAX_STRATEGIES) return;

   if (event == "strategy_sync" || event == "strategy_add") {
      Print("[AI Bridge] ", event, " S", sid);
      if (sid == 0 && g_s1_builtin_mode) {
         CloseOrderByMagic(g_slots[0].symbol, MAGIC_BASE);
         g_s1_builtin_mode = false;
         Print("[AI Bridge] S1 built-in mode ended — chuyển sang ai_bridge strategy");
      }
      bool was_inactive = !g_slots[sid].active;
      string np = ExtractStr(msg, "prompt"); double nl = ExtractNum(msg, "lot");
      int ns = (int)ExtractNum(msg, "sl");   int nt = (int)ExtractNum(msg, "tp");
      int ntf = (int)ExtractNum(msg, "tf");  string na = ExtractStr(msg, "action");
      string nsym = ExtractStr(msg, "symbol");

      if (StringLen(np) > 0) g_slots[sid].prompt = np;
      if (nl  > 0) g_slots[sid].lot    = nl;
      if (ns  > 0) g_slots[sid].sl     = ns;
      if (nt  > 0) g_slots[sid].tp     = nt;
      if (ntf > 0) g_slots[sid].tf     = ntf;
      if (StringLen(na)   > 0) g_slots[sid].action = na;
      if (StringLen(nsym) > 0) g_slots[sid].symbol = nsym;

      ParseIndList(sid, msg);
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

      // Mark for re-init: Bridge_Init phải được gọi để cập nhật condition tree trong exe
      g_pending_reinit[sid] = true;
      g_slots[sid].last_bar      = 0; // force check ngay sau khi re-init xong
      g_slots[sid].last_draw_bar = 0; // force redraw indicators với config mới
      g_last_signal_bar[sid]     = 0; // reset signal gate khi strategy thay đổi

      if (g_slots[sid].chart_id <= 0) {
         g_slots[sid].chart_id      = OpenStrategyChart(sid);
         g_slots[sid].chart_open_ms = GetTickCount();
      } else {
         if (ChartSymbol(g_slots[sid].chart_id) != g_slots[sid].symbol ||
             (int)ChartPeriod(g_slots[sid].chart_id) != g_slots[sid].tf) {
            // Chỉ đổi symbol/TF trên chart do EA tự mở — không can thiệp chart của user
            if (g_slots[sid].chart_id == ChartID() || !IsEaOpenedChart(g_slots[sid].chart_id)) {
               g_slots[sid].chart_id      = OpenStrategyChart(sid);
               g_slots[sid].chart_open_ms = GetTickCount();
            } else {
               ChartSetSymbolPeriod(g_slots[sid].chart_id, g_slots[sid].symbol, g_slots[sid].tf);
               ChartNavigate(g_slots[sid].chart_id, CHART_END, -500);
               ObjectsDeleteAll(g_slots[sid].chart_id, OBJ_PREFIX);
               g_slots[sid].chart_open_ms = GetTickCount();
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
      Print("[AI Bridge] strategy_update S", sid);
      string up = ExtractStr(msg, "prompt"); double ul = ExtractNum(msg, "lot");
      int us = (int)ExtractNum(msg, "sl");   int ut = (int)ExtractNum(msg, "tp");
      int utf = (int)ExtractNum(msg, "tf");
      if (StringLen(up) > 0) g_slots[sid].prompt = up;
      if (ul  > 0) g_slots[sid].lot = ul;
      if (us  > 0) g_slots[sid].sl  = us;
      if (ut  > 0) g_slots[sid].tp  = ut;
      if (utf > 0) {
         int old_tf = g_slots[sid].tf;
         g_slots[sid].tf = utf;
         for (int k = 0; k < g_slots[sid].ind_count; k++)
            if (g_slots[sid].inds[k].timeframe == old_tf)
               g_slots[sid].inds[k].timeframe = utf;
      }
      if (StringFind(msg, "\"enabled\"") >= 0)
         g_slots[sid].enabled = ((int)ExtractNum(msg, "enabled") != 0);

      if (g_slots[sid].chart_id > 0) {
         if (utf > 0) {
            // Chỉ đổi symbol/TF trên chart do EA tự mở — không can thiệp chart của user
            if (g_slots[sid].chart_id == ChartID() || !IsEaOpenedChart(g_slots[sid].chart_id)) {
               g_slots[sid].chart_id      = OpenStrategyChart(sid);
               g_slots[sid].chart_open_ms = GetTickCount();
            } else {
               ChartSetSymbolPeriod(g_slots[sid].chart_id, g_slots[sid].symbol, g_slots[sid].tf);
               ChartNavigate(g_slots[sid].chart_id, CHART_END, -500);
               ObjectsDeleteAll(g_slots[sid].chart_id, OBJ_PREFIX);
               g_slots[sid].chart_open_ms = GetTickCount();
            }
            DrawIndicators(sid, g_slots[sid].chart_id);
         }
         DrawStrategyInfo(sid, g_slots[sid].chart_id);
         ChartRedraw(g_slots[sid].chart_id);
      }
   }
   else if (event == "strategy_delete") {
      Print("[AI Bridge] strategy_delete S", sid, " active=", g_slots[sid].active);
      if (g_slots[sid].active) {
         SendNoWait("{\"action\":\"stop\",\"sid\":" + IntegerToString(sid) + "}");
         g_slots[sid].active  = false;
         g_pending_reinit[sid] = false;
         if (sid == 0) g_s1_builtin_mode = false;
         g_last_signal_bar[sid] = 0;
         g_active = MathMax(g_active-1, 0);
         long cid = g_slots[sid].chart_id;
         g_slots[sid].chart_id = 0;
         if (cid > 0 && cid != ChartID()) {
            // Chỉ đóng nếu không slot nào khác đang dùng chart này
            bool shared = false;
            for (int si2 = 0; si2 < MAX_STRATEGIES; si2++)
               if (si2 != sid && g_slots[si2].chart_id == cid) { shared = true; break; }
            if (!shared) {
               SafeCloseChart(cid);
            } else {
               // Shared chart: xóa objects của slot này (panel + indicators)
               string sid_sfx = "_S" + IntegerToString(sid);
               for (int oi = ObjectsTotal(cid)-1; oi >= 0; oi--) {
                  string oname = ObjectName(cid, oi);
                  if (StringFind(oname, OBJ_PREFIX) == 0 && StringFind(oname, sid_sfx) >= 0)
                     ObjectDelete(cid, oname);
               }
               ChartRedraw(cid);
            }
         } else if (cid == ChartID()) {
            string sid_sfx = "_S" + IntegerToString(sid);
            for (int oi = ObjectsTotal(cid)-1; oi >= 0; oi--) {
               string oname = ObjectName(cid, oi);
               if (StringFind(oname, OBJ_PREFIX) == 0 && StringFind(oname, sid_sfx) >= 0)
                  ObjectDelete(cid, oname);
            }
            ChartRedraw(cid);
         }
         Print("[AI Bridge] S", sid, " deleted. g_active=", g_active);
      }
   }
}

//+------------------------------------------------------------------+
//| Handle signal                                                    |
//+------------------------------------------------------------------+
void HandleSignal(int sid, string res)
{
   string action = ExtractStr(res, "action");
   if (action == "" || action == "NONE") return;
   if (!g_slots[sid].enabled) {
      LOG("S", sid+1, " signal skipped (disabled): ", action);
      return;
   }

   StrategySlot s   = g_slots[sid];
   string       sym = s.symbol;
   double       pt  = GetPipValue(sym);
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

   if (action == "EXIT") { CloseOrderByMagic(sym, magic); return; }
   if (HasOpenOrder(sym, magic)) {
      Print("[AI Bridge] S", sid, " signal ", action, " skipped — order already open");
      return;
   }

   string slot_tag = "AI-S" + IntegerToString(sid+1) + ": ";
   int max_entry   = 31 - StringLen(slot_tag) - 3;
   string entry_short = StringSubstr(s.prompt, 0, max_entry)
                      + (StringLen(s.prompt) > max_entry ? "..." : "");
   string order_comment = slot_tag + entry_short;

   double point    = MarketInfo(sym, MODE_POINT);
   double min_stop = (MarketInfo(sym, MODE_STOPLEVEL) + 5) * point;

   if (action == "BUY") {
      lot = NormalizeLot(sym, lot);
      double ask      = MarketInfo(sym, MODE_ASK);
      double sl_price = (sl_pip > 0) ? ask - sl_pip*pt : 0;
      double tp_price = (tp_pip > 0) ? ask + tp_pip*pt : 0;
      if (sl_price > 0 && sl_price > ask - min_stop) sl_price = ask - min_stop;
      if (tp_price > 0 && tp_price < ask + min_stop) tp_price = ask + min_stop;
      if (AccountFreeMarginCheck(sym, OP_BUY, lot) <= 0) {
         Print("[AI Bridge] S", sid, " BUY skipped — insufficient margin");
         NotifyOrderFail(sid, "BUY", sym, lot, 134);
         return;
      }
      int ticket = OrderSend(sym, OP_BUY, lot, ask, 3, sl_price, tp_price,
                             order_comment, magic, 0, clrBlue);
      if (ticket > 0) { Print("[AI Bridge] S", sid, " BUY opened ticket=", ticket); DrawSignalArrow(sid, "BUY", sym, s.tf); }
      else { int err = GetLastError(); Print("[AI Bridge] S", sid, " BUY FAILED err=", err, " lot=", lot, " sl=", sl_price, " tp=", tp_price); NotifyOrderFail(sid, "BUY", sym, lot, err); }
   }
   else if (action == "SELL") {
      lot = NormalizeLot(sym, lot);
      double bid      = MarketInfo(sym, MODE_BID);
      double sl_price = (sl_pip > 0) ? bid + sl_pip*pt : 0;
      double tp_price = (tp_pip > 0) ? bid - tp_pip*pt : 0;
      if (sl_price > 0 && sl_price < bid + min_stop) sl_price = bid + min_stop;
      if (tp_price > 0 && tp_price > bid - min_stop) tp_price = bid - min_stop;
      if (AccountFreeMarginCheck(sym, OP_SELL, lot) <= 0) {
         Print("[AI Bridge] S", sid, " SELL skipped — insufficient margin");
         NotifyOrderFail(sid, "SELL", sym, lot, 134);
         return;
      }
      int ticket = OrderSend(sym, OP_SELL, lot, bid, 3, sl_price, tp_price,
                             order_comment, magic, 0, clrRed);
      if (ticket > 0) { Print("[AI Bridge] S", sid, " SELL opened ticket=", ticket); DrawSignalArrow(sid, "SELL", sym, s.tf); }
      else { int err = GetLastError(); Print("[AI Bridge] S", sid, " SELL FAILED err=", err, " lot=", lot, " sl=", sl_price, " tp=", tp_price); NotifyOrderFail(sid, "SELL", sym, lot, err); }
   }
}

void NotifyOrderFail(int sid, string action, string sym, double lot, int err)
{
   WsSend("{\"event\":\"signal_order_fail\",\"sid\":" + IntegerToString(sid)
        + ",\"action\":\"" + action + "\""
        + ",\"symbol\":\"" + sym + "\""
        + ",\"lot\":" + DoubleToStr(lot,2)
        + ",\"err\":" + IntegerToString(err) + "}");
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
      int    tkt   = OrderTicket();
      double lot   = OrderLots();
      double price = (OrderType()==OP_BUY)
                     ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
      if (!OrderClose(tkt, lot, price, 3, clrYellow)) {
         int err = GetLastError();
         Print("[AI Bridge] EXIT CloseOrderByMagic FAILED ticket=", tkt,
               " sym=", sym, " err=", err);
         WsSend("{\"event\":\"exit_close_fail\",\"ticket\":" + IntegerToString(tkt)
              + ",\"symbol\":\"" + sym + "\",\"err\":" + IntegerToString(err) + "}");
      }
   }
}

//+------------------------------------------------------------------+
//| Built-in S1: MA20/MA50 crossover (standalone, no ai_bridge)     |
//+------------------------------------------------------------------+
void RunBuiltinS1()
{
   if (!g_slots[0].enabled) return;

   StrategySlot s     = g_slots[0];
   string       sym   = s.symbol;
   int          tf    = s.tf;
   int          magic = MAGIC_BASE;

   datetime cur_bar = iTime(sym, tf, 0);
   if (cur_bar == g_slots[0].last_bar) return;
   if (s.chart_open_ms > 0 && GetTickCount() - s.chart_open_ms < 8000) return;
   if (iBars(sym, tf) < 55) return;

   double ma20_1 = iMA(sym, tf, 20, 0, MODE_SMA, PRICE_CLOSE, 1);
   double ma50_1 = iMA(sym, tf, 50, 0, MODE_SMA, PRICE_CLOSE, 1);
   double ma20_2 = iMA(sym, tf, 20, 0, MODE_SMA, PRICE_CLOSE, 2);
   double ma50_2 = iMA(sym, tf, 50, 0, MODE_SMA, PRICE_CLOSE, 2);

   if (ma20_1 == EMPTY_VALUE || ma50_1 == EMPTY_VALUE ||
       ma20_2 == EMPTY_VALUE || ma50_2 == EMPTY_VALUE) return;

   g_slots[0].last_bar = cur_bar;

   bool has_buy = false, has_sell = false;
   for (int i = OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != sym || OrderMagicNumber() != magic) continue;
      if (OrderType() == OP_BUY)  has_buy  = true;
      if (OrderType() == OP_SELL) has_sell = true;
   }

   // Exit BUY: MA20 crosses below MA50
   if (has_buy && ma20_1 < ma50_1 && ma20_2 >= ma50_2) {
      CloseOrderByMagic(sym, magic);
      g_last_signal_bar[0] = cur_bar;
      return;
   }
   // Exit SELL: MA20 crosses above MA50
   if (has_sell && ma20_1 > ma50_1 && ma20_2 <= ma50_2) {
      CloseOrderByMagic(sym, magic);
      g_last_signal_bar[0] = cur_bar;
      return;
   }

   if (has_buy || has_sell) return;
   if (cur_bar == g_last_signal_bar[0]) return;

   double lot      = NormalizeLot(sym, s.lot);
   double pt       = GetPipValue(sym);
   double point    = MarketInfo(sym, MODE_POINT);
   double min_stop = (MarketInfo(sym, MODE_STOPLEVEL) + 5) * point;

   // Entry BUY: MA20 crosses above MA50
   if (ma20_1 > ma50_1 && ma20_2 <= ma50_2) {
      double ask      = MarketInfo(sym, MODE_ASK);
      double sl_price = (s.sl > 0) ? ask - s.sl * pt : 0;
      double tp_price = (s.tp > 0) ? ask + s.tp * pt : 0;
      if (sl_price > 0 && sl_price > ask - min_stop) sl_price = ask - min_stop;
      if (tp_price > 0 && tp_price < ask + min_stop) tp_price = ask + min_stop;
      if (AccountFreeMarginCheck(sym, OP_BUY, lot) <= 0) return;
      int ticket = OrderSend(sym, OP_BUY, lot, ask, 3, sl_price, tp_price,
                             "AI-S1: MA20xMA50", magic, 0, clrBlue);
      if (ticket > 0) { g_last_signal_bar[0] = cur_bar; DrawSignalArrow(0, "BUY", sym, tf); Print("[AI Bridge] Builtin S1 BUY ticket=", ticket); }
      else Print("[AI Bridge] Builtin S1 BUY FAILED err=", GetLastError());
   }
   // Entry SELL: MA20 crosses below MA50
   else if (ma20_1 < ma50_1 && ma20_2 >= ma50_2) {
      double bid      = MarketInfo(sym, MODE_BID);
      double sl_price = (s.sl > 0) ? bid + s.sl * pt : 0;
      double tp_price = (s.tp > 0) ? bid - s.tp * pt : 0;
      if (sl_price > 0 && sl_price < bid + min_stop) sl_price = bid + min_stop;
      if (tp_price > 0 && tp_price > bid - min_stop) tp_price = bid - min_stop;
      if (AccountFreeMarginCheck(sym, OP_SELL, lot) <= 0) return;
      int ticket = OrderSend(sym, OP_SELL, lot, bid, 3, sl_price, tp_price,
                             "AI-S1: MA20xMA50", magic, 0, clrRed);
      if (ticket > 0) { g_last_signal_bar[0] = cur_bar; DrawSignalArrow(0, "SELL", sym, tf); Print("[AI Bridge] Builtin S1 SELL ticket=", ticket); }
      else Print("[AI Bridge] Builtin S1 SELL FAILED err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Strategy loading                                                 |
//+------------------------------------------------------------------+
string ParseSymbolFromPrompt(string prompt)
{
   string syms[] = {
      "XAUUSD","XAGUSD","EURUSD","GBPUSD","USDJPY","USDCHF","USDCAD","AUDUSD","NZDUSD",
      "EURGBP","EURJPY","EURCHF","EURCAD","EURAUD","EURNZD","GBPJPY","GBPCHF","GBPCAD",
      "GBPAUD","GBPNZD","AUDJPY","AUDCHF","AUDCAD","AUDNZD","NZDJPY","NZDCHF","NZDCAD",
      "CADJPY","CADCHF","CHFJPY","BTCUSD","ETHUSD"
   };
   string upper = prompt;
   StringToUpper(upper);
   StringReplace(upper, "/", ""); StringReplace(upper, "-", "");
   StringReplace(upper, "_", ""); StringReplace(upper, " ", "");
   for (int i = 0; i < ArraySize(syms); i++)
      if (StringFind(upper, syms[i]) >= 0) return syms[i];
   return "";
}

void LoadSlots()
{
   string prompts[MAX_STRATEGIES];
   bool   enables[MAX_STRATEGIES];
   int    tfs[MAX_STRATEGIES];
   double lots[MAX_STRATEGIES];
   int    sls[MAX_STRATEGIES], tps[MAX_STRATEGIES];

   prompts[0]=S1_Prompt; prompts[1]=S2_Prompt; prompts[2]=S3_Prompt;
   prompts[3]=S4_Prompt; prompts[4]=S5_Prompt;
   enables[0]=S1_Enable; enables[1]=S2_Enable; enables[2]=S3_Enable;
   enables[3]=S4_Enable; enables[4]=S5_Enable;
   tfs[0]=S1_Default_TF; tfs[1]=S2_Default_TF; tfs[2]=S3_Default_TF;
   tfs[3]=S4_Default_TF; tfs[4]=S5_Default_TF;
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
      g_slots[i].symbol    = Symbol();
      g_slots[i].tf        = tfs[i];
      g_slots[i].lot       = lots[i];
      g_slots[i].sl        = sls[i];
      g_slots[i].tp        = tps[i];
      g_slots[i].last_bar       = 0;
      g_slots[i].last_draw_bar  = 0;
      g_slots[i].ind_count = 0;
      g_slots[i].ohlc_bars = 5;
      g_slots[i].chart_id  = 0;
      g_slots[i].action    = "";
      if (g_slots[i].active) {
         string det = ParseSymbolFromPrompt(prompts[i]);
         if (StringLen(det) > 0) g_slots[i].symbol = det;
         g_active++;
      }
   }
}

void ParseIndList(int sid, string json)
{
   g_slots[sid].ind_count = 0;
   g_slots[sid].ohlc_bars = 5;
   double bars_num = ExtractNum(json, "ohlc_bars");
   if (bars_num > 0)
      g_slots[sid].ohlc_bars = (int)MathMin(bars_num, MAX_OHLC_BARS);

   int pos = 0;
   while (g_slots[sid].ind_count < MAX_INDICATORS) {
      int s = StringFind(json, "{\"name\"", pos);
      if (s < 0) break;
      int depth = 0, e = s;
      for (int i = s; i < StringLen(json); i++) {
         ushort c = StringGetCharacter(json, i);
         if (c=='{') depth++;
         else if (c=='}') { depth--; if (depth==0) { e=i+1; break; } }
      }
      string block = StringSubstr(json, s, e-s);
      int idx = g_slots[sid].ind_count;

      g_slots[sid].inds[idx].name          = ExtractStr(block,"name");
      g_slots[sid].inds[idx].type          = ExtractStr(block,"type");
      g_slots[sid].inds[idx].symbol        = ExtractStr(block,"symbol");
      g_slots[sid].inds[idx].timeframe     = (int)ExtractNum(block,"timeframe");
      g_slots[sid].inds[idx].period        = (int)ExtractNum(block,"period");
      g_slots[sid].inds[idx].method        = (int)ExtractNum(block,"method");
      g_slots[sid].inds[idx].applied       = (int)ExtractNum(block,"applied");
      g_slots[sid].inds[idx].shift         = (int)ExtractNum(block,"shift");
      g_slots[sid].inds[idx].line          = (int)ExtractNum(block,"line");
      g_slots[sid].inds[idx].deviation     = ExtractNum(block,"deviation");
      g_slots[sid].inds[idx].ma_shift      = (int)ExtractNum(block,"ma_shift");
      g_slots[sid].inds[idx].fast_period   = (int)ExtractNum(block,"fast");
      g_slots[sid].inds[idx].slow_period   = (int)ExtractNum(block,"slow");
      g_slots[sid].inds[idx].signal_period = (int)ExtractNum(block,"signal");
      g_slots[sid].inds[idx].k_period      = (int)ExtractNum(block,"kperiod");
      g_slots[sid].inds[idx].d_period      = (int)ExtractNum(block,"dperiod");
      g_slots[sid].inds[idx].slowing       = (int)ExtractNum(block,"slowing");
      g_slots[sid].inds[idx].sar_step      = ExtractNum(block,"step");
      g_slots[sid].inds[idx].sar_max       = ExtractNum(block,"maximum");
      g_slots[sid].inds[idx].p1            = (int)ExtractNum(block,"p1");
      g_slots[sid].inds[idx].p2            = (int)ExtractNum(block,"p2");
      g_slots[sid].inds[idx].p3            = (int)ExtractNum(block,"p3");
      g_slots[sid].inds[idx].s1            = (int)ExtractNum(block,"s1");
      g_slots[sid].inds[idx].s2            = (int)ExtractNum(block,"s2");
      g_slots[sid].inds[idx].s3            = (int)ExtractNum(block,"s3");
      g_slots[sid].inds[idx].custom_name   = ExtractStr(block,"custom_name");
      g_slots[sid].inds[idx].buffer_index  = (int)ExtractNum(block,"buffer_index");

      if (g_slots[sid].inds[idx].deviation   == 0) g_slots[sid].inds[idx].deviation   = 2.0;
      if (g_slots[sid].inds[idx].sar_step    == 0) g_slots[sid].inds[idx].sar_step    = 0.02;
      if (g_slots[sid].inds[idx].sar_max     == 0) g_slots[sid].inds[idx].sar_max     = 0.2;
      if (g_slots[sid].inds[idx].fast_period == 0) g_slots[sid].inds[idx].fast_period = 12;
      if (g_slots[sid].inds[idx].slow_period == 0) g_slots[sid].inds[idx].slow_period = 26;
      if (g_slots[sid].inds[idx].signal_period==0) g_slots[sid].inds[idx].signal_period=9;
      if (g_slots[sid].inds[idx].k_period    == 0) g_slots[sid].inds[idx].k_period    = 5;
      if (g_slots[sid].inds[idx].d_period    == 0) g_slots[sid].inds[idx].d_period    = 3;
      if (g_slots[sid].inds[idx].slowing     == 0) g_slots[sid].inds[idx].slowing     = 3;

      // Skip duplicate indicator names (same name already in list)
      bool dup = false;
      string newName = g_slots[sid].inds[idx].name;
      for (int di = 0; di < idx; di++) {
         if (g_slots[sid].inds[di].name == newName) { dup = true; break; }
      }
      if (!dup) g_slots[sid].ind_count++;
      pos = e;
   }
}

// Số bars tối thiểu cần thiết để tính indicator này
int IndMinBars(IndConfig &c)
{
   int period = c.period;
   if      (c.type=="iMA"||c.type=="iDEMA"||c.type=="iTEMA"||
            c.type=="iFrAMA"||c.type=="iAMA"||c.type=="iStdDev")
      return period + c.ma_shift + c.shift + 2;
   else if (c.type=="iRSI"||c.type=="iCCI"||c.type=="iWPR"||
            c.type=="iMomentum"||c.type=="iATR"||c.type=="iMFI"||
            c.type=="iOBV"||c.type=="iForce")
      return period + c.shift + 2;
   else if (c.type=="iMACD")
      return c.slow_period + c.signal_period + c.shift + 2;
   else if (c.type=="iBands")
      return period + c.ma_shift + c.shift + 2;
   else if (c.type=="iStochastic")
      return c.k_period + c.d_period + c.slowing + c.shift + 2;
   else if (c.type=="iADX")
      return period * 2 + c.shift + 2;
   else if (c.type=="iSAR")
      return 50;
   else if (c.type=="iAlligator")
      return MathMax(c.p1+c.s1, MathMax(c.p2+c.s2, c.p3+c.s3)) + c.shift + 2;
   else if (c.type=="iIchimoku")
      return c.p3 + c.p2 + c.shift + 5;
   else if (c.type=="iHighest"||c.type=="iLowest")
      return period + c.shift + 2;
   else if (c.type=="iFractals")
      return c.shift + 5;
   // iClose/iOpen/iHigh/iLow/iVolume/Ask/Bid/iCustom
   return c.shift + 2;
}

double CalcIndicator(IndConfig &c)
{
   string sym = (c.symbol != "") ? c.symbol : Symbol();
   int    tf  = (c.timeframe > 0) ? c.timeframe : 0;
   int    sh  = c.shift;
   int    ap  = (c.applied > 0) ? c.applied : PRICE_CLOSE;

   // Nếu MT4 chưa load đủ bars lịch sử, request thêm và trả EMPTY_VALUE
   int needed = IndMinBars(c);
   if (needed > 1 && iBars(sym, tf) < needed) {
      iTime(sym, tf, needed);  // trigger MT4 async history load
      return EMPTY_VALUE;
   }

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
   return 0.0;
}

//── JSON helpers ──────────────────────────────────────────────────────
string ExtractStr(string json, string key)
{
   string s = "\""+key+"\":\"";
   int p = StringFind(json, s);
   if (p < 0) return "";
   p += StringLen(s);
   // Scan for closing quote, skipping escaped \"
   string result = "";
   for (int i = p; i < StringLen(json); i++) {
      ushort ch = StringGetCharacter(json, i);
      if (ch == '\\') { i++; result += StringSubstr(json, i, 1); continue; }
      if (ch == '"')  break;
      result += StringSubstr(json, i, 1);
   }
   return result;
}

double ExtractNum(string json, string key)
{
   string s = "\""+key+"\":";
   int p = StringFind(json, s);
   if (p < 0) return 0.0;
   p += StringLen(s);
   int e  = StringFind(json, ",", p);
   int e2 = StringFind(json, "}", p);
   int e3 = StringFind(json, "]", p);
   if (e < 0 || (e2 >= 0 && e2 < e)) e = e2;
   if (e < 0 || (e3 >= 0 && e3 < e)) e = e3;
   if (e < 0) return 0.0;
   return StringToDouble(StringSubstr(json, p, e-p));
}

string TFtoStr(int tf)
{
   switch(tf) {
      case 1: return "M1"; case 5: return "M5"; case 15: return "M15";
      case 30: return "M30"; case 60: return "H1"; case 240: return "H4";
      case 1440: return "D1"; case 10080: return "W1";
      default: return IntegerToString(tf)+"m";
   }
}

string StringJoin(string &arr[], string sep)
{
   string r = ""; int len = ArraySize(arr);
   for (int i = 0; i < len; i++) { r += arr[i]; if (i < len-1) r += sep; }
   return r;
}

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
void DrawSignalArrow(int sid, string action, string sym, int tf)
{
   long cid = g_slots[sid].chart_id;
   if (cid <= 0) { if (sym != Symbol()) return; cid = ChartID(); }
   datetime bar_time = iTime(sym, tf, 1);
   string obj_name = OBJ_PREFIX+"SIG_"+IntegerToString(sid)+"_"+IntegerToString((int)bar_time);
   ObjectDelete(cid, obj_name);
   if (action == "BUY") {
      double price = iLow(sym,tf,1) - MarketInfo(sym,MODE_POINT)*50;
      ObjectCreate(cid, obj_name, OBJ_ARROW, 0, bar_time, price);
      ObjectSetInteger(cid, obj_name, OBJPROP_ARROWCODE, 241);
      ObjectSetInteger(cid, obj_name, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(cid, obj_name, OBJPROP_WIDTH, 2);
   } else if (action == "SELL") {
      double price = iHigh(sym,tf,1) + MarketInfo(sym,MODE_POINT)*50;
      ObjectCreate(cid, obj_name, OBJ_ARROW, 0, bar_time, price);
      ObjectSetInteger(cid, obj_name, OBJPROP_ARROWCODE, 242);
      ObjectSetInteger(cid, obj_name, OBJPROP_COLOR, clrCrimson);
      ObjectSetInteger(cid, obj_name, OBJPROP_WIDTH, 2);
   }
   ChartRedraw(cid);
}

string FormatIndValue(IndConfig &c, bool loading = false)
{
   if (StringFind(c.name, "_prev") >= 0) return "";
   string ann = "";
   if      (c.type=="iMACD")       ann="("+IntegerToString(c.fast_period)+","+IntegerToString(c.slow_period)+")";
   else if (c.type=="iStochastic") ann="("+IntegerToString(c.k_period)+","+IntegerToString(c.d_period)+")";
   else if (c.type=="iAlligator")  ann="("+IntegerToString(c.p1)+","+IntegerToString(c.p2)+","+IntegerToString(c.p3)+")";
   else if (c.type=="iIchimoku")   ann="("+IntegerToString(c.p1)+","+IntegerToString(c.p2)+","+IntegerToString(c.p3)+")";
   else if (c.period > 0)          ann="("+IntegerToString(c.period)+")";
   string full_label = c.name + ann;
   while (StringLen(full_label) < 18) full_label += " ";
   // Chart vừa mở → data đang load, chưa đủ ổn định
   if (loading) return full_label + "...";
   double val = CalcIndicator(c);
   // CalcIndicator trả EMPTY_VALUE khi chưa đủ bars lịch sử
   if (val == EMPTY_VALUE) return full_label + "...";
   int dp = 5;
   if (c.type=="iRSI"||c.type=="iCCI"||c.type=="iWPR"||c.type=="iMomentum"||
       c.type=="iMACD"||c.type=="iStochastic"||c.type=="iADX") dp=2;
   string vs   = DoubleToStr(val, dp);
   string note = "";
   if      (c.type=="iRSI")        note=(val>70)?"  OB":(val<30)?"  OS":"";
   else if (c.type=="iCCI")        note=(val>100)?"  OB":(val<-100)?"  OS":"";
   else if (c.type=="iStochastic") note=(val>80)?"  OB":(val<20)?"  OS":"";
   else if (c.type=="iWPR")        note=(val>-20)?"  OB":(val<-80)?"  OS":"";
   return full_label + vs + note;
}

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

void UpdateOscPanelValues(int sid, long cid)
{
   if (cid <= 0 || !g_slots[sid].active) return;
   int ic = g_slots[sid].ind_count;
   if (ic == 0) return;
   int prompt_rows  = (StringLen(g_slots[sid].prompt) + 51) / 52;
   if (prompt_rows < 1) prompt_rows = 1;
   int ind_start_row = 3 + prompt_rows + 1;
   bool ind_loading = (g_slots[sid].chart_open_ms > 0 &&
                       GetTickCount() - g_slots[sid].chart_open_ms < 8000);
   int row = ind_start_row;
   for (int k = 0; k < ic; k++) {
      IndConfig c = g_slots[sid].inds[k];
      if (StringFind(c.name, "_prev") >= 0) continue;
      // Cập nhật TẤT CẢ chỉ số per tick (không chỉ oscillators)
      // → MA sẽ tự refresh sau khi warmup hết hạn
      string ln = OBJ_PREFIX+"INFO_L"+IntegerToString(row)+"_S"+IntegerToString(sid);
      if (ObjectFind(cid, ln) >= 0) {
         string txt = FormatIndValue(c, ind_loading);
         if (StringLen(txt) > 0) {
            ObjectSetString (cid, ln, OBJPROP_TEXT,  txt);
            ObjectSetInteger(cid, ln, OBJPROP_COLOR, (color)IndPanelColor(c));
         }
      }
      row++;
   }
   ChartRedraw(cid);
}

void DrawStrategyInfo(int sid, long cid)
{
   if (cid <= 0) return;
   string sym    = g_slots[sid].symbol;
   string tf_str = TFtoStr(g_slots[sid].tf);
   string action = (StringLen(g_slots[sid].action) > 0) ? g_slots[sid].action : "?";
   int    ic     = g_slots[sid].ind_count;

   #define MAX_PANEL_LINES 32
   string lines[MAX_PANEL_LINES];
   color  clrs [MAX_PANEL_LINES];
   int    fsz  [MAX_PANEL_LINES];
   int    n = 0;

   string en_tag = g_slots[sid].enabled ? "[ON]" : "[OFF]";
   lines[n]=">> STRATEGY "+IntegerToString(sid+1)+" "+en_tag; clrs[n]=clrGold; fsz[n]=10; n++;
   color en_clr = g_slots[sid].enabled ? clrAqua : clrOrange;
   lines[n]=sym+" "+tf_str+"   |   "+action; clrs[n]=en_clr; fsz[n]=9; n++;
   lines[n]="Lot "+DoubleToStr(g_slots[sid].lot,2)
           +"  SL "+IntegerToString(g_slots[sid].sl)+" pip"
           +"  TP "+IntegerToString(g_slots[sid].tp)+" pip"; clrs[n]=clrSilver; fsz[n]=8; n++;

   string prm = g_slots[sid].prompt;
   while (StringLen(prm) > 0 && n < MAX_PANEL_LINES-2) {
      lines[n]=StringSubstr(prm,0,52); clrs[n]=C'180,180,180'; fsz[n]=7; n++;
      prm = (StringLen(prm)>52) ? StringSubstr(prm,52) : "";
   }
   // Warmup 8 giây sau khi mở chart để H4/D1 data load xong
   bool ind_loading = (g_slots[sid].chart_open_ms > 0 &&
                       GetTickCount() - g_slots[sid].chart_open_ms < 8000);
   if (ic > 0) {
      lines[n]="─── Indicators ──────────────────"; clrs[n]=C'80,80,120'; fsz[n]=7; n++;
      for (int k = 0; k < ic && n < MAX_PANEL_LINES; k++) {
         string row = FormatIndValue(g_slots[sid].inds[k], ind_loading);
         if (StringLen(row) == 0) continue;
         lines[n]=row; clrs[n]=IndPanelColor(g_slots[sid].inds[k]); fsz[n]=8; n++;
      }
   }

   int x = 10, lh = 16;
   int dashboard_h = lh*(MAX_STRATEGIES+2)+20;
   int y = (cid==ChartID()) ? dashboard_h+10 : 10;
   string bg_n = OBJ_PREFIX+"INFO_BG_S"+IntegerToString(sid);
   if (ObjectFind(cid, bg_n) < 0)
      ObjectCreate(cid, bg_n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(cid, bg_n, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(cid, bg_n, OBJPROP_XDISTANCE, x-6);
   ObjectSetInteger(cid, bg_n, OBJPROP_YDISTANCE, y-4);
   ObjectSetInteger(cid, bg_n, OBJPROP_XSIZE,     280);
   ObjectSetInteger(cid, bg_n, OBJPROP_YSIZE,     lh*n+10);
   ObjectSetInteger(cid, bg_n, OBJPROP_BGCOLOR,   C'10,10,30');
   ObjectSetInteger(cid, bg_n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(cid, bg_n, OBJPROP_COLOR,     C'60,60,120');

   for (int j = 0; j < n; j++) {
      string ln = OBJ_PREFIX+"INFO_L"+IntegerToString(j)+"_S"+IntegerToString(sid);
      if (ObjectFind(cid, ln) < 0)
         ObjectCreate(cid, ln, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(cid, ln, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(cid, ln, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(cid, ln, OBJPROP_YDISTANCE, y+j*lh);
      ObjectSetInteger(cid, ln, OBJPROP_COLOR,     clrs[j]);
      ObjectSetInteger(cid, ln, OBJPROP_FONTSIZE,  fsz[j]);
      ObjectSetString (cid, ln, OBJPROP_TEXT,      lines[j]);
   }
   for (int j = n; j < MAX_PANEL_LINES; j++) {
      string ln = OBJ_PREFIX+"INFO_L"+IntegerToString(j)+"_S"+IntegerToString(sid);
      if (ObjectFind(cid, ln) >= 0) ObjectSetString(cid, ln, OBJPROP_TEXT, "");
   }
   #undef MAX_PANEL_LINES
   ChartRedraw(cid);
}

bool IsEaOpenedChart(long cid)
{
   for (int i = 0; i < g_ea_opened_chart_count; i++)
      if (g_ea_opened_charts[i] == cid) return true;
   return false;
}

// Chỉ close chart nếu EA tự mở nó — tránh đóng chart của user/EA khác
void SafeCloseChart(long cid)
{
   if (cid <= 0) return;
   for (int i = 0; i < g_ea_opened_chart_count; i++) {
      if (g_ea_opened_charts[i] == cid) {
         g_ea_opened_charts[i] = g_ea_opened_charts[--g_ea_opened_chart_count];
         ChartClose(cid);
         return;
      }
   }
   // Chart không do EA mở → chỉ xóa objects, không đóng
   ObjectsDeleteAll(cid, OBJ_PREFIX);
   ChartRedraw(cid);
}

long OpenStrategyChart(int sid)
{
   string sym = g_slots[sid].symbol;
   int    tf  = g_slots[sid].tf;
   if (sym == Symbol() && tf == Period()) return ChartID();
   long cid = ChartOpen(sym, tf);
   if (cid <= 0) return 0;
   // Đăng ký chart này để SafeCloseChart biết được phép đóng
   if (g_ea_opened_chart_count < ArraySize(g_ea_opened_charts))
      g_ea_opened_charts[g_ea_opened_chart_count++] = cid;
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
   // Request MT4 to load at least 500 bars of history up front
   ChartNavigate(cid, CHART_END, -500);
   ChartRedraw(cid);
   return cid;
}

void DrawIndicators(int sid, long cid)
{
   if (cid <= 0) return;
   int ic = g_slots[sid].ind_count;
   if (ic == 0) { ChartRedraw(cid); return; }
   RefreshRates();
   string sym = g_slots[sid].symbol;
   int    tf  = g_slots[sid].tf;
   int    BARS = 80;
   int    total_drawn = 0;
   int    osc_row     = 0;

   for (int k = 0; k < g_slots[sid].ind_count; k++) {
      IndConfig c  = g_slots[sid].inds[k];
      int       ap = (c.applied > 0) ? c.applied : PRICE_CLOSE;
      tf = (c.timeframe > 0) ? c.timeframe : g_slots[sid].tf;

      if (StringFind(c.name, "_prev") >= 0) continue;

      #define DRAW_TREND_LINE(pfx, v1_expr, v2_expr, clr_val, w_val) \
         { int _sd=0; \
           for (int _i=BARS;_i>=1;_i--) { \
              double _v1=(v1_expr), _v2=(v2_expr); \
              if(_v1==0||_v2==0) continue; \
              datetime _t1=iTime(sym,tf,_i),_t2=iTime(sym,tf,_i-1); \
              string _o=(pfx)+IntegerToString(_i); \
              ObjectDelete(cid,_o); \
              ObjectCreate(cid,_o,OBJ_TREND,0,_t1,_v1,_t2,_v2); \
              ObjectSetInteger(cid,_o,OBJPROP_COLOR,(clr_val)); \
              ObjectSetInteger(cid,_o,OBJPROP_WIDTH,(w_val)); \
              ObjectSetInteger(cid,_o,OBJPROP_RAY,false); \
              ObjectSetInteger(cid,_o,OBJPROP_SELECTABLE,false); \
              _sd++; } \
           total_drawn+=_sd; }

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

      if (c.type=="iMA"||c.type=="iDEMA"||c.type=="iTEMA"||c.type=="iFrAMA"||c.type=="iAMA") {
         color clr = (c.period<=10)?clrDeepSkyBlue:(c.period<=25)?clrDodgerBlue:
                     (c.period<=60)?clrOrangeRed:(c.period<=120)?clrGold:clrMagenta;
         string pfx = OBJ_PREFIX+"IND_"+c.name+"_S"+IntegerToString(sid)+"_";
         double test_v = iMA(sym,tf,c.period,c.ma_shift,c.method,ap,1);
         if (test_v == 0 || test_v == EMPTY_VALUE) continue;
         DRAW_TREND_LINE(pfx, iMA(sym,tf,c.period,c.ma_shift,c.method,ap,_i),
                              iMA(sym,tf,c.period,c.ma_shift,c.method,ap,_i-1), clr, 1)
      }
      else if (c.type=="iBands") {
         double test_band = iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,MODE_MAIN,1);
         if (test_band == 0 || test_band == EMPTY_VALUE) continue;
         string pfxU=OBJ_PREFIX+"IND_"+c.name+"_U_S"+IntegerToString(sid)+"_";
         string pfxL=OBJ_PREFIX+"IND_"+c.name+"_L_S"+IntegerToString(sid)+"_";
         string pfxM=OBJ_PREFIX+"IND_"+c.name+"_M_S"+IntegerToString(sid)+"_";
         DRAW_TREND_LINE(pfxU, iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,MODE_UPPER,_i),
                               iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,MODE_UPPER,_i-1), clrRoyalBlue, 1)
         DRAW_TREND_LINE(pfxL, iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,MODE_LOWER,_i),
                               iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,MODE_LOWER,_i-1), clrRoyalBlue, 1)
         DRAW_TREND_LINE(pfxM, iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,MODE_MAIN,_i),
                               iBands(sym,tf,c.period,c.deviation,c.ma_shift,ap,MODE_MAIN,_i-1), C'60,60,180', 1)
      }
      else if (c.type=="iSAR") {
         double test_sar = iSAR(sym,tf,c.sar_step,c.sar_max,1);
         if (test_sar == 0 || test_sar == EMPTY_VALUE) continue;
         string pfx=OBJ_PREFIX+"IND_"+c.name+"_S"+IntegerToString(sid)+"_";
         DRAW_TREND_LINE(pfx, iSAR(sym,tf,c.sar_step,c.sar_max,_i),
                              iSAR(sym,tf,c.sar_step,c.sar_max,_i-1), clrRoyalBlue, 1)
      }
      else if (c.type=="iRSI") {
         double v = iRSI(sym,tf,c.period,ap,0);
         if (v == EMPTY_VALUE) continue;
         color  clr = (v>70)?clrCrimson:(v<30)?clrLimeGreen:clrSilver;
         string lbl = OBJ_PREFIX+"OSC_"+c.name+"_S"+IntegerToString(sid);
         DRAW_OSC_LABEL(lbl, c.name+"("+IntegerToString(c.period)+"): "+DoubleToStr(v,1)
                            +((v>70)?" OB":(v<30)?" OS":""), clr)
      }
      else if (c.type=="iCCI") {
         double v = iCCI(sym,tf,c.period,ap,0);
         if (v == EMPTY_VALUE) continue;
         color  clr = (v>100)?clrCrimson:(v<-100)?clrLimeGreen:clrSilver;
         string lbl = OBJ_PREFIX+"OSC_"+c.name+"_S"+IntegerToString(sid);
         DRAW_OSC_LABEL(lbl, c.name+"("+IntegerToString(c.period)+"): "+DoubleToStr(v,1)
                            +((v>100)?" OB":(v<-100)?" OS":""), clr)
      }
      else if (c.type=="iWPR") {
         double v = iWPR(sym,tf,c.period,0);
         if (v == EMPTY_VALUE) continue;
         color  clr = (v>-20)?clrCrimson:(v<-80)?clrLimeGreen:clrSilver;
         string lbl = OBJ_PREFIX+"OSC_"+c.name+"_S"+IntegerToString(sid);
         DRAW_OSC_LABEL(lbl, c.name+"("+IntegerToString(c.period)+"): "+DoubleToStr(v,1), clr)
      }
      else if (c.type=="iMACD") {
         double v = iMACD(sym,tf,c.fast_period,c.slow_period,c.signal_period,ap,0,0);
         if (v == EMPTY_VALUE) continue;
         color  clr = (v>0)?clrLimeGreen:clrCrimson;
         string lbl = OBJ_PREFIX+"OSC_"+c.name+"_S"+IntegerToString(sid);
         DRAW_OSC_LABEL(lbl, "MACD("+IntegerToString(c.fast_period)+","+IntegerToString(c.slow_period)+"): "+DoubleToStr(v,5), clr)
      }
      else if (c.type=="iStochastic") {
         double v = iStochastic(sym,tf,c.k_period,c.d_period,c.slowing,c.method,0,c.line,0);
         if (v == EMPTY_VALUE) continue;
         color  clr = (v>80)?clrCrimson:(v<20)?clrLimeGreen:clrSilver;
         string lbl = OBJ_PREFIX+"OSC_"+c.name+"_S"+IntegerToString(sid);
         DRAW_OSC_LABEL(lbl, "STO("+IntegerToString(c.k_period)+"): "+DoubleToStr(v,1)
                            +((v>80)?" OB":(v<20)?" OS":""), clr)
      }
      else if (c.type=="iADX") {
         double v = iADX(sym,tf,c.period,ap,0,0);
         if (v == EMPTY_VALUE) continue;
         string lbl = OBJ_PREFIX+"OSC_"+c.name+"_S"+IntegerToString(sid);
         DRAW_OSC_LABEL(lbl, "ADX("+IntegerToString(c.period)+"): "+DoubleToStr(v,1), clrSilver)
      }

      #undef DRAW_TREND_LINE
      #undef DRAW_OSC_LABEL
   }
   ChartRedraw(cid);
}

void CleanObjects()
{
   long cid = ChartFirst();
   while (cid >= 0) {
      ObjectsDeleteAll(cid, OBJ_PREFIX);
      cid = ChartNext(cid);
   }
}
