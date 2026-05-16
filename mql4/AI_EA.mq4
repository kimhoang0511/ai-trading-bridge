//+------------------------------------------------------------------+
//| AI_EA.mq4                                                        |
//| AI Trading Bridge — Expert Advisor                               |
//| Connects to Python Bridge via Named Pipe                         |
//| Supports up to 5 simultaneous strategies (S1–S5)                 |
//+------------------------------------------------------------------+
#property strict
#property description "AI Trading Bridge EA"
#property description "Enter your strategies in S1_Prompt .. S5_Prompt"
#property description "Leave prompt empty to disable that strategy slot"

//── Strategy 1 ──────────────────────────────────────────────────────
extern string S1_Prompt = "Buy EURUSD when MA20 crosses above MA50 and RSI14 < 65";
extern string S1_Symbol = "EURUSD";
extern int    S1_TF     = 60;     // 1=M1 5=M5 15=M15 60=H1 240=H4 1440=D1
extern double S1_Lot    = 0.10;
extern int    S1_SL     = 50;     // Stop Loss in pips
extern int    S1_TP     = 100;    // Take Profit in pips

//── Strategy 2 ──────────────────────────────────────────────────────
extern string S2_Prompt = "";     // leave empty to disable
extern string S2_Symbol = "GBPUSD";
extern int    S2_TF     = 240;
extern double S2_Lot    = 0.05;
extern int    S2_SL     = 40;
extern int    S2_TP     = 80;

//── Strategy 3 ──────────────────────────────────────────────────────
extern string S3_Prompt = "";
extern string S3_Symbol = "XAUUSD";
extern int    S3_TF     = 1440;
extern double S3_Lot    = 0.01;
extern int    S3_SL     = 200;
extern int    S3_TP     = 400;

//── Strategy 4 ──────────────────────────────────────────────────────
extern string S4_Prompt = "";
extern string S4_Symbol = "EURUSD";
extern int    S4_TF     = 60;
extern double S4_Lot    = 0.10;
extern int    S4_SL     = 50;
extern int    S4_TP     = 100;

//── Strategy 5 ──────────────────────────────────────────────────────
extern string S5_Prompt = "";
extern string S5_Symbol = "EURUSD";
extern int    S5_TF     = 60;
extern double S5_Lot    = 0.10;
extern int    S5_SL     = 50;
extern int    S5_TP     = 100;

//── Internal constants ───────────────────────────────────────────────
#define MAX_STRATEGIES 5
#define MAX_INDICATORS 50
#define MAX_OHLC_BARS  50
#define MAGIC_BASE     88800    // magic = MAGIC_BASE + sid

//── Indicator config struct ──────────────────────────────────────────
struct IndConfig {
   string name;
   string type;
   string symbol;
   int    timeframe;
   int    period;
   int    method;
   int    applied;
   int    shift;
   int    line;
   double deviation;
   int    ma_shift;
   int    fast_period;
   int    slow_period;
   int    signal_period;
   int    k_period;
   int    d_period;
   int    slowing;
   double sar_step;
   double sar_max;
   int    p1; int p2; int p3;
   int    s1; int s2; int s3;
   string custom_name;
   int    buffer_index;
   double custom_p[6];
};

//── Strategy slot struct ─────────────────────────────────────────────
struct StrategySlot {
   bool      active;
   string    prompt;
   string    symbol;
   int       tf;
   double    lot;
   int       sl;
   int       tp;
   IndConfig inds[MAX_INDICATORS];
   int       ind_count;
   int       ohlc_bars;
   datetime  last_bar;
};

StrategySlot g_slots[MAX_STRATEGIES];
int g_active = 0;

int g_pipeIn  = INVALID_HANDLE;
int g_pipeOut = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   LoadSlots();

   if (g_active == 0) {
      Alert("No strategy configured. Set at least S1_Prompt.");
      return INIT_FAILED;
   }

   // Open pipe connection to Bridge
   g_pipeOut = FileOpen("\\\\.\\pipe\\ea_to_bridge", FILE_WRITE | FILE_BIN);
   g_pipeIn  = FileOpen("\\\\.\\pipe\\bridge_to_ea", FILE_READ  | FILE_BIN);

   if (g_pipeOut == INVALID_HANDLE || g_pipeIn == INVALID_HANDLE) {
      Alert("Cannot connect to Python Bridge!\n"
            "Make sure bridge/main.py is running.");
      return INIT_FAILED;
   }

   // Init each active strategy
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;

      string msg = StringFormat(
         "{\"cmd\":\"init\",\"sid\":%d,\"prompt\":\"%s\","
         "\"symbol\":\"%s\",\"tf\":%d,\"lot\":%.2f,\"sl\":%d,\"tp\":%d}",
         i,
         EscapeJSON(g_slots[i].prompt),
         g_slots[i].symbol,
         g_slots[i].tf,
         g_slots[i].lot,
         g_slots[i].sl,
         g_slots[i].tp
      );

      PipeSend(msg);
      string res = PipeRecv();

      if (StringFind(res, "\"status\":\"ok\"") < 0) {
         string err = ExtractStr(res, "message");
         Print("Strategy ", i, " init failed: ", err);
         g_slots[i].active = false;
         g_active--;
         continue;
      }

      ParseIndList(i, res);
      Print("Strategy ", i, " (", g_slots[i].symbol, " ",
            TFtoStr(g_slots[i].tf), "): ", StringSubstr(g_slots[i].prompt, 0, 50));
   }

   Print(g_active, " strategies active. EA running.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;

      // Only process on new candle for this strategy's timeframe
      datetime bar = iTime(g_slots[i].symbol, g_slots[i].tf, 0);
      if (bar == g_slots[i].last_bar) continue;
      g_slots[i].last_bar = bar;

      // Build and send values
      string json = BuildValues(i);
      PipeSend(json);
      string res = PipeRecv();

      if (res != "") HandleSignal(i, res);
   }
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Notify Bridge that all strategies are stopping
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      if (!g_slots[i].active) continue;
      string msg = StringFormat("{\"cmd\":\"stop\",\"sid\":%d}", i);
      PipeSend(msg);
   }
   FileClose(g_pipeIn);
   FileClose(g_pipeOut);
   Print("EA stopped.");
}

//+------------------------------------------------------------------+
//| Build JSON payload for one strategy                              |
//+------------------------------------------------------------------+
string BuildValues(int sid)
{
   StrategySlot s = g_slots[sid];
   string parts[];
   int    n = s.ohlc_bars * 5 + s.ind_count + 5;
   ArrayResize(parts, n);
   int idx = 0;

   // OHLC data
   for (int i = 0; i < s.ohlc_bars; i++) {
      parts[idx++] = "\"open_"  +i+"\":"+DoubleToStr(iOpen (s.symbol,s.tf,i),5);
      parts[idx++] = "\"high_"  +i+"\":"+DoubleToStr(iHigh (s.symbol,s.tf,i),5);
      parts[idx++] = "\"low_"   +i+"\":"+DoubleToStr(iLow  (s.symbol,s.tf,i),5);
      parts[idx++] = "\"close_" +i+"\":"+DoubleToStr(iClose(s.symbol,s.tf,i),5);
      parts[idx++] = "\"volume_"+i+"\":"+DoubleToStr((double)iVolume(s.symbol,s.tf,i),0);
   }

   // Market info
   parts[idx++] = "\"ask\":"   +DoubleToStr(MarketInfo(s.symbol,MODE_ASK),5);
   parts[idx++] = "\"bid\":"   +DoubleToStr(MarketInfo(s.symbol,MODE_BID),5);
   parts[idx++] = "\"point\":"+DoubleToStr(MarketInfo(s.symbol,MODE_POINT),5);
   parts[idx++] = "\"spread\":"+DoubleToStr(MarketInfo(s.symbol,MODE_SPREAD),1);
   parts[idx++] = "\"time\":"  +IntegerToString((int)TimeCurrent());

   // Indicators
   for (int i = 0; i < s.ind_count; i++) {
      double val = CalcIndicator(s.inds[i]);
      parts[idx++] = "\""+s.inds[i].name+"\":"+DoubleToStr(val,8);
   }

   ArrayResize(parts, idx);
   return StringFormat(
      "{\"cmd\":\"check\",\"sid\":%d,\"values\":{%s}}",
      sid, StringJoin(parts, ",")
   );
}

//+------------------------------------------------------------------+
//| Handle signal from Bridge                                        |
//+------------------------------------------------------------------+
void HandleSignal(int sid, string res)
{
   string action = ExtractStr(res, "action");
   if (action == "" || action == "NONE") return;

   StrategySlot s = g_slots[sid];
   string sym = s.symbol;
   double lot = s.lot;
   double pt  = MarketInfo(sym, MODE_POINT) * 10;  // pip value
   int    magic = MAGIC_BASE + sid;

   double overrideLot = ExtractNum(res, "lot");
   double overrideSL  = ExtractNum(res, "sl");
   double overrideTP  = ExtractNum(res, "tp");
   if (overrideLot > 0) lot = overrideLot;
   double sl_pip = (overrideSL > 0) ? overrideSL : s.sl;
   double tp_pip = (overrideTP > 0) ? overrideTP : s.tp;

   // Check if already in position for this strategy
   if (HasOpenOrder(sym, magic)) {
      return;  // one trade per strategy at a time
   }

   if (action == "BUY") {
      double ask = MarketInfo(sym, MODE_ASK);
      int ticket = OrderSend(sym, OP_BUY, lot, ask, 3,
                             ask - sl_pip * pt,
                             ask + tp_pip * pt,
                             "AI-S" + IntegerToString(sid),
                             magic, 0, clrBlue);
      if (ticket > 0)
         Print("S", sid, " BUY ", sym, " lot=", lot,
               " sl=", sl_pip, " tp=", tp_pip);
      else
         Print("S", sid, " BUY failed: error ", GetLastError());
   }
   else if (action == "SELL") {
      double bid = MarketInfo(sym, MODE_BID);
      int ticket = OrderSend(sym, OP_SELL, lot, bid, 3,
                             bid + sl_pip * pt,
                             bid - tp_pip * pt,
                             "AI-S" + IntegerToString(sid),
                             magic, 0, clrRed);
      if (ticket > 0)
         Print("S", sid, " SELL ", sym, " lot=", lot,
               " sl=", sl_pip, " tp=", tp_pip);
      else
         Print("S", sid, " SELL failed: error ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Universal indicator calculator                                   |
//+------------------------------------------------------------------+
double CalcIndicator(IndConfig &c)
{
   string sym = (c.symbol != "") ? c.symbol : Symbol();
   int    tf  = (c.timeframe > 0) ? c.timeframe : 0;
   int    sh  = c.shift;
   int    ap  = (c.applied > 0) ? c.applied : PRICE_CLOSE;

   if (c.type == "iClose")    return iClose(sym, tf, sh);
   if (c.type == "iOpen")     return iOpen(sym, tf, sh);
   if (c.type == "iHigh")     return iHigh(sym, tf, sh);
   if (c.type == "iLow")      return iLow(sym, tf, sh);
   if (c.type == "iVolume")   return (double)iVolume(sym, tf, sh);
   if (c.type == "Ask")       return MarketInfo(sym, MODE_ASK);
   if (c.type == "Bid")       return MarketInfo(sym, MODE_BID);
   if (c.type == "Spread")    return MarketInfo(sym, MODE_SPREAD);

   if (c.type == "iHighest")  return iHigh(sym, tf, iHighest(sym, tf, MODE_HIGH, c.period, sh));
   if (c.type == "iLowest")   return iLow(sym, tf,  iLowest(sym, tf,  MODE_LOW,  c.period, sh));

   if (c.type == "iMA")       return iMA(sym, tf, c.period, c.ma_shift, c.method, ap, sh);
   if (c.type == "iDEMA")     return iDEMA(sym, tf, c.period, c.ma_shift, ap, sh);
   if (c.type == "iTEMA")     return iTEMA(sym, tf, c.period, c.ma_shift, ap, sh);
   if (c.type == "iFrAMA")    return iFrAMA(sym, tf, c.period, c.ma_shift, ap, sh);
   if (c.type == "iStdDev")   return iStdDev(sym, tf, c.period, c.ma_shift, c.method, ap, sh);
   if (c.type == "iAMA")      return iAMA(sym, tf, c.period, c.fast_period, c.slow_period, c.ma_shift, ap, sh);

   if (c.type == "iRSI")      return iRSI(sym, tf, c.period, ap, sh);
   if (c.type == "iCCI")      return iCCI(sym, tf, c.period, ap, sh);
   if (c.type == "iWPR")      return iWPR(sym, tf, c.period, sh);
   if (c.type == "iMomentum") return iMomentum(sym, tf, c.period, ap, sh);
   if (c.type == "iDeMarker") return iDeMarker(sym, tf, c.period, sh);
   if (c.type == "iAO")       return iAO(sym, tf, sh);
   if (c.type == "iAC")       return iAC(sym, tf, sh);
   if (c.type == "iBearsPower") return iBearsPower(sym, tf, c.period, ap, sh);
   if (c.type == "iBullsPower") return iBullsPower(sym, tf, c.period, ap, sh);
   if (c.type == "iRVI")      return iRVI(sym, tf, c.period, c.line, sh);

   if (c.type == "iMACD")     return iMACD(sym, tf, c.fast_period, c.slow_period, c.signal_period, ap, c.line, sh);
   if (c.type == "iOsMA")     return iOsMA(sym, tf, c.fast_period, c.slow_period, c.signal_period, ap, sh);

   if (c.type == "iBands")    return iBands(sym, tf, c.period, c.deviation, c.ma_shift, ap, c.line, sh);
   if (c.type == "iEnvelopes") return iEnvelopes(sym, tf, c.period, c.method, c.ma_shift, ap, c.deviation, c.line, sh);

   if (c.type == "iStochastic") return iStochastic(sym, tf, c.k_period, c.d_period, c.slowing, c.method, 0, c.line, sh);

   if (c.type == "iADX")      return iADX(sym, tf, c.period, ap, c.line, sh);
   if (c.type == "iSAR")      return iSAR(sym, tf, c.sar_step, c.sar_max, sh);

   if (c.type == "iAlligator") return iAlligator(sym, tf, c.p1, c.s1, c.p2, c.s2, c.p3, c.s3, c.method, ap, c.line, sh);
   if (c.type == "iIchimoku")  return iIchimoku(sym, tf, c.p1, c.p2, c.p3, c.line, sh);

   if (c.type == "iMFI")      return iMFI(sym, tf, c.period, sh);
   if (c.type == "iOBV")      return iOBV(sym, tf, ap, sh);
   if (c.type == "iForce")    return iForce(sym, tf, c.period, c.method, ap, sh);
   if (c.type == "iChaikin")  return iChaikin(sym, tf, c.fast_period, c.slow_period, c.method, ap, sh);
   if (c.type == "iBWMFI")    return iBWMFI(sym, tf, sh);

   if (c.type == "iATR")      return iATR(sym, tf, c.period, sh);
   if (c.type == "iFractals") return iFractals(sym, tf, c.line, sh);

   if (c.type == "iCustom")
      return iCustom(sym, tf, c.custom_name,
                     c.custom_p[0], c.custom_p[1], c.custom_p[2],
                     c.custom_p[3], c.custom_p[4], c.custom_p[5],
                     c.buffer_index, sh);

   Print("Unknown indicator type: ", c.type);
   return 0.0;
}

//+------------------------------------------------------------------+
//| Parse Bridge init response — extract indicator list              |
//+------------------------------------------------------------------+
void ParseIndList(int sid, string json)
{
   g_slots[sid].ind_count  = 0;
   g_slots[sid].ohlc_bars  = 5;  // default

   // Extract ohlc_bars
   string bars_str = ExtractStr(json, "ohlc_bars");
   if (bars_str != "")
      g_slots[sid].ohlc_bars = (int)MathMin(StringToInteger(bars_str), MAX_OHLC_BARS);

   // Parse indicator blocks
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

      g_slots[sid].inds[idx].name         = ExtractStr(block, "name");
      g_slots[sid].inds[idx].type         = ExtractStr(block, "type");
      g_slots[sid].inds[idx].symbol       = ExtractStr(block, "symbol");
      g_slots[sid].inds[idx].timeframe    = (int)ExtractNum(block, "timeframe");
      g_slots[sid].inds[idx].period       = (int)ExtractNum(block, "period");
      g_slots[sid].inds[idx].method       = (int)ExtractNum(block, "method");
      g_slots[sid].inds[idx].applied      = (int)ExtractNum(block, "applied");
      g_slots[sid].inds[idx].shift        = (int)ExtractNum(block, "shift");
      g_slots[sid].inds[idx].line         = (int)ExtractNum(block, "line");
      g_slots[sid].inds[idx].deviation    = ExtractNum(block, "deviation");
      g_slots[sid].inds[idx].ma_shift     = (int)ExtractNum(block, "ma_shift");
      g_slots[sid].inds[idx].fast_period  = (int)ExtractNum(block, "fast");
      g_slots[sid].inds[idx].slow_period  = (int)ExtractNum(block, "slow");
      g_slots[sid].inds[idx].signal_period= (int)ExtractNum(block, "signal");
      g_slots[sid].inds[idx].k_period     = (int)ExtractNum(block, "kperiod");
      g_slots[sid].inds[idx].d_period     = (int)ExtractNum(block, "dperiod");
      g_slots[sid].inds[idx].slowing      = (int)ExtractNum(block, "slowing");
      g_slots[sid].inds[idx].sar_step     = ExtractNum(block, "step");
      g_slots[sid].inds[idx].sar_max      = ExtractNum(block, "maximum");
      g_slots[sid].inds[idx].p1           = (int)ExtractNum(block, "p1");
      g_slots[sid].inds[idx].p2           = (int)ExtractNum(block, "p2");
      g_slots[sid].inds[idx].p3           = (int)ExtractNum(block, "p3");
      g_slots[sid].inds[idx].s1           = (int)ExtractNum(block, "s1");
      g_slots[sid].inds[idx].s2           = (int)ExtractNum(block, "s2");
      g_slots[sid].inds[idx].s3           = (int)ExtractNum(block, "s3");
      g_slots[sid].inds[idx].custom_name  = ExtractStr(block, "custom_name");
      g_slots[sid].inds[idx].buffer_index = (int)ExtractNum(block, "buffer_index");

      // Apply defaults
      if (g_slots[sid].inds[idx].deviation == 0)   g_slots[sid].inds[idx].deviation = 2.0;
      if (g_slots[sid].inds[idx].sar_step  == 0)   g_slots[sid].inds[idx].sar_step  = 0.02;
      if (g_slots[sid].inds[idx].sar_max   == 0)   g_slots[sid].inds[idx].sar_max   = 0.2;
      if (g_slots[sid].inds[idx].fast_period == 0) g_slots[sid].inds[idx].fast_period = 12;
      if (g_slots[sid].inds[idx].slow_period == 0) g_slots[sid].inds[idx].slow_period = 26;
      if (g_slots[sid].inds[idx].signal_period== 0)g_slots[sid].inds[idx].signal_period = 9;
      if (g_slots[sid].inds[idx].k_period   == 0)  g_slots[sid].inds[idx].k_period   = 5;
      if (g_slots[sid].inds[idx].d_period   == 0)  g_slots[sid].inds[idx].d_period   = 3;
      if (g_slots[sid].inds[idx].slowing    == 0)  g_slots[sid].inds[idx].slowing    = 3;

      g_slots[sid].ind_count++;
      pos = e;
   }
}

//+------------------------------------------------------------------+
//| Load strategy slots from extern params                           |
//+------------------------------------------------------------------+
void LoadSlots()
{
   string prompts[MAX_STRATEGIES] = {S1_Prompt, S2_Prompt, S3_Prompt, S4_Prompt, S5_Prompt};
   string symbols[MAX_STRATEGIES] = {S1_Symbol, S2_Symbol, S3_Symbol, S4_Symbol, S5_Symbol};
   int    tfs[MAX_STRATEGIES]     = {S1_TF,     S2_TF,     S3_TF,     S4_TF,     S5_TF};
   double lots[MAX_STRATEGIES]    = {S1_Lot,    S2_Lot,    S3_Lot,    S4_Lot,    S5_Lot};
   int    sls[MAX_STRATEGIES]     = {S1_SL,     S2_SL,     S3_SL,     S4_SL,     S5_SL};
   int    tps[MAX_STRATEGIES]     = {S1_TP,     S2_TP,     S3_TP,     S4_TP,     S5_TP};

   g_active = 0;
   for (int i = 0; i < MAX_STRATEGIES; i++) {
      g_slots[i].active   = (StringLen(prompts[i]) > 0);
      g_slots[i].prompt   = prompts[i];
      g_slots[i].symbol   = symbols[i];
      g_slots[i].tf       = tfs[i];
      g_slots[i].lot      = lots[i];
      g_slots[i].sl       = sls[i];
      g_slots[i].tp       = tps[i];
      g_slots[i].last_bar = 0;
      g_slots[i].ind_count = 0;
      g_slots[i].ohlc_bars = 5;
      if (g_slots[i].active) g_active++;
   }
}

//+------------------------------------------------------------------+
//| Check if strategy already has an open order                     |
//+------------------------------------------------------------------+
bool HasOpenOrder(string sym, int magic)
{
   for (int i = OrdersTotal()-1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() == sym && OrderMagicNumber() == magic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Pipe helpers                                                     |
//+------------------------------------------------------------------+
bool PipeSend(string msg)
{
   uchar data[];
   StringToCharArray(msg, data, 0, StringLen(msg));
   uint written = FileWriteArray(g_pipeOut, data);
   FileFlush(g_pipeOut);
   return (written > 0);
}

string PipeRecv()
{
   uchar buf[];
   uint read = FileReadArray(g_pipeIn, buf, 0, 65536);
   if (read == 0) return "";
   return CharArrayToString(buf, 0, read);
}

//+------------------------------------------------------------------+
//| JSON helpers                                                     |
//+------------------------------------------------------------------+
string ExtractStr(string json, string key)
{
   string search = "\"" + key + "\":\"";
   int p = StringFind(json, search);
   if (p < 0) return "";
   p += StringLen(search);
   int e = StringFind(json, "\"", p);
   if (e < 0) return "";
   return StringSubstr(json, p, e - p);
}

double ExtractNum(string json, string key)
{
   string search = "\"" + key + "\":";
   int p = StringFind(json, search);
   if (p < 0) return 0.0;
   p += StringLen(search);
   int e  = StringFind(json, ",", p);
   int e2 = StringFind(json, "}", p);
   if (e < 0 || (e2 >= 0 && e2 < e)) e = e2;
   if (e < 0) return 0.0;
   return StringToDouble(StringSubstr(json, p, e - p));
}

string EscapeJSON(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\t", "\\t");
   return s;
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
      default:   return IntegerToString(tf) + "m";
   }
}

string StringJoin(string &arr[], string sep)
{
   string result = "";
   int len = ArraySize(arr);
   for (int i = 0; i < len; i++) {
      result += arr[i];
      if (i < len - 1) result += sep;
   }
   return result;
}
