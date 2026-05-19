/**
 * AI_Bridge.cpp — Pure C++ MT4 DLL v3
 *
 * Flow:
 *   Bridge_Init  → POST /init to backend → backend calls Claude → returns condition tree
 *   Bridge_Check → evaluates condition tree LOCALLY (no API call, fast)
 *
 * No external dependencies. Custom JSON parser included.
 *
 * Build (x86 MSVC):
 *   cl /nologo /LD /MD /EHsc /O2 /W3 AI_Bridge.cpp /link /OUT:AI_Bridge.dll /DEF:AI_Bridge.def winhttp.lib user32.lib
 */

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winhttp.h>

// WINHTTP_WEB_SOCKET_PING_PONG_BUFFER_TYPE was added in SDK 8.1.
// Cast the raw value so it compiles on both old (missing enum) and new (strongly-typed enum) SDKs.
#ifndef WINHTTP_WEB_SOCKET_PING_PONG_BUFFER_TYPE
#define WINHTTP_WEB_SOCKET_PING_PONG_BUFFER_TYPE static_cast<WINHTTP_WEB_SOCKET_BUFFER_TYPE>(9)
#endif
#include <string>
#include <map>
#include <vector>
#include <mutex>
#include <deque>
#include <thread>
#include <fstream>
#include <algorithm>
#include <cmath>
#include <cstdio>

#define BRIDGE_VERSION "3.0.0"

static HMODULE g_hmod = nullptr;

// ═══════════════════════════════════════════════════════════════════════════════
// §1  Minimal JSON parser
// ═══════════════════════════════════════════════════════════════════════════════

struct JVal {
    enum { NUL=0, BOOL, NUM, STR, ARR, OBJ } type = NUL;
    bool                          b   = false;
    double                        n   = 0;
    std::string                   s;
    std::vector<JVal>             a;
    std::map<std::string, JVal>   o;

    bool valid()  const { return type != NUL || !o.empty() || !a.empty(); }
    bool isObj()  const { return type == OBJ; }
    bool isArr()  const { return type == ARR; }
    bool isStr()  const { return type == STR; }
    bool isNum()  const { return type == NUM; }

    const JVal* get(const std::string& key) const {
        auto it = o.find(key); return it!=o.end() ? &it->second : nullptr;
    }
    std::string str(const std::string& key, const std::string& d="") const {
        auto* v=get(key); return (v&&v->isStr()) ? v->s : d;
    }
    double num(const std::string& key, double d=0) const {
        auto* v=get(key); return (v&&v->isNum()) ? v->n : d;
    }
    int    inum(const std::string& key, int d=0) const { return (int)num(key,d); }
    bool   has(const std::string& key) const { return o.count(key)>0; }
};

static void   jskip(const std::string& s, size_t& p) {
    while (p<s.size()&&(s[p]==' '||s[p]=='\t'||s[p]=='\n'||s[p]=='\r')) ++p;
}
static std::string jstr(const std::string& s, size_t& p) {
    ++p; std::string r; bool esc=false;
    while (p<s.size()) {
        char c=s[p++];
        if (esc) {
            if(c=='n')r+='\n'; else if(c=='r')r+='\r';
            else if(c=='t')r+='\t'; else r+=c;
            esc=false;
        } else if(c=='\\'){esc=true;} else if(c=='"'){break;} else{r+=c;}
    }
    return r;
}
static JVal jparse(const std::string& s, size_t& p);
static JVal jparse(const std::string& s, size_t& p) {
    jskip(s,p); JVal v;
    if (p>=s.size()) return v;
    char c=s[p];
    if (c=='"')   { v.type=JVal::STR; v.s=jstr(s,p); }
    else if (c=='[') {
        v.type=JVal::ARR; ++p; jskip(s,p);
        while (p<s.size()&&s[p]!=']') {
            v.a.push_back(jparse(s,p)); jskip(s,p);
            if(p<s.size()&&s[p]==',')++p; jskip(s,p);
        } if(p<s.size())++p;
    } else if (c=='{') {
        v.type=JVal::OBJ; ++p; jskip(s,p);
        while (p<s.size()&&s[p]!='}') {
            std::string key=jstr(s,p); jskip(s,p);
            if(p<s.size()&&s[p]==':')++p; jskip(s,p);
            v.o[key]=jparse(s,p); jskip(s,p);
            if(p<s.size()&&s[p]==',')++p; jskip(s,p);
        } if(p<s.size())++p;
    } else if (c=='t'){v.type=JVal::BOOL;v.b=true; p+=4;}
    else if (c=='f'){v.type=JVal::BOOL;v.b=false;p+=5;}
    else if (c=='n'){v.type=JVal::NUL; p+=4;}
    else {
        v.type=JVal::NUM; size_t st=p;
        if(c=='-')++p;
        while(p<s.size()&&(isdigit(s[p])||s[p]=='.'||s[p]=='e'||s[p]=='E'||s[p]=='+'||s[p]=='-'))++p;
        try { v.n=std::stod(s.substr(st,p-st)); } catch(...) { v.n=0; }
    }
    return v;
}
static JVal ParseJSON(const std::string& s) { size_t p=0; return jparse(s,p); }

// ═══════════════════════════════════════════════════════════════════════════════
// §2  Logging
// ═══════════════════════════════════════════════════════════════════════════════

// Last-call debug buffer — returned by Bridge_GetLastLog so MT4 can print it
static std::string g_last_debug;

static void Log(const std::string& msg) {
    char ad[MAX_PATH]={};
    ExpandEnvironmentStringsA("%APPDATA%", ad, MAX_PATH);
    std::string dir=std::string(ad)+"\\AI_Bridge";
    CreateDirectoryA(dir.c_str(), nullptr);
    // Append to rolling log
    HANDLE h=CreateFileA((dir+"\\bridge.log").c_str(), FILE_APPEND_DATA,
                         FILE_SHARE_READ, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if(h!=INVALID_HANDLE_VALUE){
        SYSTEMTIME t; GetLocalTime(&t);
        char line[8192];
        _snprintf_s(line,sizeof(line),_TRUNCATE,"[%02d:%02d:%02d] %s\r\n",
                    t.wHour,t.wMinute,t.wSecond,msg.c_str());
        DWORD n; WriteFile(h,line,(DWORD)strlen(line),&n,nullptr);
        CloseHandle(h);
    }
    // Also accumulate into g_last_debug (reset at start of each Bridge_Init call)
    g_last_debug += msg + "\n";
}

// Reset debug buffer at start of each Bridge_Init call
static void LogReset() { g_last_debug.clear(); }

// ═══════════════════════════════════════════════════════════════════════════════
// §3  (removed — api_key.txt no longer needed; Claude is called via backend)
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════════
// §4b  Backend HTTP POST (to license server)
// ═══════════════════════════════════════════════════════════════════════════════

#define BACKEND_HOST "192.168.21.1"
#define BACKEND_PORT 8000

// Persistent session + connection handles (reused across calls — 30s timeouts)
static HINTERNET  g_http_hS  = nullptr;
static HINTERNET  g_http_hC  = nullptr;
static std::mutex g_http_mtx;

static bool BackendEnsureHandles() {
    if (g_http_hS && g_http_hC) return true;

    if (g_http_hS) { WinHttpCloseHandle(g_http_hS); g_http_hS = nullptr; }

    g_http_hS = WinHttpOpen(L"AI_Bridge/3.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                             WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!g_http_hS) { Log("BackendPost: WinHttpOpen failed"); return false; }

    // 30-second send/receive timeouts
    DWORD t30 = 30000;
    WinHttpSetOption(g_http_hS, WINHTTP_OPTION_CONNECT_TIMEOUT,    &t30, sizeof(t30));
    WinHttpSetOption(g_http_hS, WINHTTP_OPTION_SEND_TIMEOUT,       &t30, sizeof(t30));
    WinHttpSetOption(g_http_hS, WINHTTP_OPTION_RECEIVE_TIMEOUT,    &t30, sizeof(t30));

    std::wstring whost(std::string(BACKEND_HOST).begin(), std::string(BACKEND_HOST).end());
    g_http_hC = WinHttpConnect(g_http_hS, whost.c_str(), (INTERNET_PORT)BACKEND_PORT, 0);
    if (!g_http_hC) {
        WinHttpCloseHandle(g_http_hS); g_http_hS = nullptr;
        Log("BackendPost: WinHttpConnect failed");
        return false;
    }
    return true;
}

static std::string BackendPost(const std::string& path, const std::string& body) {
    std::lock_guard<std::mutex> lk(g_http_mtx);

    for (int attempt = 0; attempt < 2; ++attempt) {
        if (!BackendEnsureHandles()) return {};

        std::wstring wpath(path.begin(), path.end());
        HINTERNET hR = WinHttpOpenRequest(g_http_hC, L"POST", wpath.c_str(), nullptr,
                                          WINHTTP_NO_REFERER,
                                          WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
        if (!hR) {
            // Connection handle stale — invalidate and retry once
            WinHttpCloseHandle(g_http_hC); g_http_hC = nullptr;
            WinHttpCloseHandle(g_http_hS); g_http_hS = nullptr;
            Log("BackendPost: OpenRequest failed, retrying");
            continue;
        }

        WinHttpAddRequestHeaders(hR, L"Content-Type: application/json\r\n",
                                 (DWORD)-1, WINHTTP_ADDREQ_FLAG_ADD);

        BOOL ok = WinHttpSendRequest(hR, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                     (LPVOID)body.data(), (DWORD)body.size(),
                                     (DWORD)body.size(), 0);
        std::string resp;
        if (ok && WinHttpReceiveResponse(hR, nullptr)) {
            DWORD av = 0;
            while (WinHttpQueryDataAvailable(hR, &av) && av) {
                std::string chunk(av, '\0'); DWORD got = 0;
                WinHttpReadData(hR, &chunk[0], av, &got);
                resp.append(chunk.data(), got);
            }
            WinHttpCloseHandle(hR);
            return resp;
        } else {
            DWORD err = GetLastError();
            Log("BackendPost: send/recv failed err=" + std::to_string(err));
            WinHttpCloseHandle(hR);
            // Stale connection — drop handles and retry once
            WinHttpCloseHandle(g_http_hC); g_http_hC = nullptr;
            WinHttpCloseHandle(g_http_hS); g_http_hS = nullptr;
        }
    }
    return {};
}

// ═══════════════════════════════════════════════════════════════════════════════
// §4c  MQL4 string conversion (MQL4 passes string as wchar_t* / UTF-16)
// ═══════════════════════════════════════════════════════════════════════════════

// Convert wchar_t* (from MQL4) to std::string (UTF-8 / CP_ACP)
static std::string W2S(const wchar_t* w) {
    if (!w || !*w) return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 1) return {};
    std::string s(len - 1, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], len, nullptr, nullptr);
    return s;
}

// ═══════════════════════════════════════════════════════════════════════════════
// §5  JSON string builder helpers
// ═══════════════════════════════════════════════════════════════════════════════

static std::string JE(const std::string& s) {
    std::string o; o.reserve(s.size()+8);
    for(unsigned char c:s){
        if(c=='"')o+="\\\""; else if(c=='\\')o+="\\\\";
        else if(c=='\n')o+="\\n"; else if(c=='\r')o+="\\r";
        else if(c=='\t')o+="\\t";
        else if(c<0x20){char b[8];_snprintf_s(b,8,_TRUNCATE,"\\u%04x",c);o+=b;}
        else o+=(char)c;
    }
    return o;
}

// ═══════════════════════════════════════════════════════════════════════════════
// §6  Market values accessor (maps to Python v dict)
// ═══════════════════════════════════════════════════════════════════════════════

struct V {
    std::map<std::string,double> d;
    double get(const std::string& k, double def=0.0) const {
        auto it=d.find(k); return it!=d.end()?it->second:def;
    }
    double O(int i=0)   const { return get("open_"  +std::to_string(i)); }
    double H(int i=0)   const { return get("high_"  +std::to_string(i)); }
    double L(int i=0)   const { return get("low_"   +std::to_string(i)); }
    double C(int i=0)   const { return get("close_" +std::to_string(i)); }
    double Vol(int i=0) const { return get("volume_"+std::to_string(i)); }
    double point()      const { return get("point",0.00001); }
    // Returns how many OHLCV bars are actually present in the value map.
    int avail_bars()    const {
        int n=0;
        while(d.count("high_"+std::to_string(n))) n++;
        return n;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// §7  PA Helper functions  (maps 1-to-1 with pa_helpers.py)
// ═══════════════════════════════════════════════════════════════════════════════

static double body(const V& v,int i=0)       { return std::abs(v.C(i)-v.O(i)); }
static double upper_wick(const V& v,int i=0) { return v.H(i)-std::max(v.O(i),v.C(i)); }
static double lower_wick(const V& v,int i=0) { return std::min(v.O(i),v.C(i))-v.L(i); }
static double candle_range(const V& v,int i=0){ return v.H(i)-v.L(i); }
static bool   is_bull(const V& v,int i=0)    { return v.C(i)>v.O(i); }
static bool   is_bear(const V& v,int i=0)    { return v.C(i)<v.O(i); }
static double body_ratio(const V& v,int i=0) { double r=candle_range(v,i); return r>0?body(v,i)/r:0.0; }
static double body_mid(const V& v,int i=0)   { return (v.O(i)+v.C(i))/2.0; }

// Single candle patterns
static bool is_doji(const V& v,int i=0,double th=0.1){ return body_ratio(v,i)<th; }
static bool is_marubozu(const V& v,int i=0)          { return body_ratio(v,i)>=0.95; }
static bool is_hammer(const V& v,int i=0){
    double b=body(v,i),lw=lower_wick(v,i),uw=upper_wick(v,i);
    return b>0 && lw>=b*2.0 && uw<=b*0.3;
}
static bool is_inverted_hammer(const V& v,int i=0){
    double b=body(v,i),uw=upper_wick(v,i),lw=lower_wick(v,i);
    return b>0 && uw>=b*2.0 && lw<=b*0.3;
}
static bool is_shooting_star(const V& v,int i=0)  { return is_inverted_hammer(v,i)&&is_bear(v,i); }
static bool is_hanging_man(const V& v,int i=0)    { return is_hammer(v,i)&&is_bear(v,i); }
static bool is_pin_bar_bull(const V& v,int i=0){
    double lw=lower_wick(v,i),b=body(v,i),uw=upper_wick(v,i),r=candle_range(v,i);
    return r>0 && lw>=r*0.6 && b<=r*0.25 && uw<=r*0.15;
}
static bool is_pin_bar_bear(const V& v,int i=0){
    double uw=upper_wick(v,i),b=body(v,i),lw=lower_wick(v,i),r=candle_range(v,i);
    return r>0 && uw>=r*0.6 && b<=r*0.25 && lw<=r*0.15;
}
static bool is_pin_bar(const V& v,int i=0){ return is_pin_bar_bull(v,i)||is_pin_bar_bear(v,i); }
static bool is_spinning_top(const V& v,int i=0){
    double b=body_ratio(v,i),uw=upper_wick(v,i),lw=lower_wick(v,i),r=candle_range(v,i);
    return r>0 && b>0.1&&b<0.35 && uw/r>0.2 && lw/r>0.2;
}

// Two-candle patterns
static bool is_bull_engulfing(const V& v){
    return is_bear(v,1)&&is_bull(v,0)&&body(v,0)>body(v,1)&&v.H(0)>=v.H(1)&&v.L(0)<=v.L(1);
}
static bool is_bear_engulfing(const V& v){
    return is_bull(v,1)&&is_bear(v,0)&&body(v,0)>body(v,1)&&v.H(0)>=v.H(1)&&v.L(0)<=v.L(1);
}
static bool is_bull_harami(const V& v){
    return is_bear(v,1)&&is_bull(v,0)&&v.O(0)>v.C(1)&&v.C(0)<v.O(1)&&body(v,0)<body(v,1);
}
static bool is_bear_harami(const V& v){
    return is_bull(v,1)&&is_bear(v,0)&&v.O(0)<v.C(1)&&v.C(0)>v.O(1)&&body(v,0)<body(v,1);
}
static bool is_piercing(const V& v){
    return is_bear(v,1)&&is_bull(v,0)&&v.O(0)<v.L(1)&&v.C(0)>body_mid(v,1)&&v.C(0)<v.O(1);
}
static bool is_dark_cloud(const V& v){
    return is_bull(v,1)&&is_bear(v,0)&&v.O(0)>v.H(1)&&v.C(0)<body_mid(v,1)&&v.C(0)>v.C(1);
}
static bool is_tweezer_top(const V& v){
    return is_bull(v,1)&&is_bear(v,0)&&std::abs(v.H(0)-v.H(1))<=v.point()*3;
}
static bool is_tweezer_bottom(const V& v){
    return is_bear(v,1)&&is_bull(v,0)&&std::abs(v.L(0)-v.L(1))<=v.point()*3;
}

// Three-candle patterns
static bool is_morning_star(const V& v){
    return is_bear(v,2)&&body_ratio(v,2)>0.6&&body_ratio(v,1)<0.3&&is_bull(v,0)&&body_ratio(v,0)>0.6
        &&std::max(v.O(1),v.C(1))<v.C(2)&&v.C(0)>body_mid(v,2);
}
static bool is_evening_star(const V& v){
    return is_bull(v,2)&&body_ratio(v,2)>0.6&&body_ratio(v,1)<0.3&&is_bear(v,0)&&body_ratio(v,0)>0.6
        &&std::min(v.O(1),v.C(1))>v.C(2)&&v.C(0)<body_mid(v,2);
}
static bool is_three_white_soldiers(const V& v){
    return is_bull(v,2)&&is_bull(v,1)&&is_bull(v,0)
        &&v.C(1)>v.C(2)&&v.C(0)>v.C(1)&&v.O(1)>v.O(2)&&v.O(0)>v.O(1)
        &&body_ratio(v,2)>0.5&&body_ratio(v,1)>0.5&&body_ratio(v,0)>0.5;
}
static bool is_three_black_crows(const V& v){
    return is_bear(v,2)&&is_bear(v,1)&&is_bear(v,0)
        &&v.C(1)<v.C(2)&&v.C(0)<v.C(1)&&v.O(1)<v.O(2)&&v.O(0)<v.O(1)
        &&body_ratio(v,2)>0.5&&body_ratio(v,1)>0.5&&body_ratio(v,0)>0.5;
}
static bool is_three_inside_up(const V& v)  { return is_bear_harami(v)&&is_bull(v,0)&&v.C(0)>v.O(2); }
static bool is_three_inside_down(const V& v){ return is_bull_harami(v)&&is_bear(v,0)&&v.C(0)<v.O(2); }

// Market structure
static bool is_higher_high(const V& v,int n=3){
    int ab=v.avail_bars(); if(ab<2)return false; if(n>ab)n=ab;
    for(int i=0;i<n-1;i++) if(v.H(i)<=v.H(i+1)) return false; return true;
}
static bool is_lower_low(const V& v,int n=3){
    int ab=v.avail_bars(); if(ab<2)return false; if(n>ab)n=ab;
    for(int i=0;i<n-1;i++) if(v.L(i)>=v.L(i+1)) return false; return true;
}
static bool is_higher_low(const V& v,int n=3){
    int ab=v.avail_bars(); if(ab<2)return false; if(n>ab)n=ab;
    for(int i=0;i<n-1;i++) if(v.L(i)<=v.L(i+1)) return false; return true;
}
static bool is_lower_high(const V& v,int n=3){
    int ab=v.avail_bars(); if(ab<2)return false; if(n>ab)n=ab;
    for(int i=0;i<n-1;i++) if(v.H(i)>=v.H(i+1)) return false; return true;
}
static bool is_uptrend(const V& v,int n=4){
    int h=std::max(n/2,2); return is_higher_high(v,h)&&is_higher_low(v,h);
}
static bool is_downtrend(const V& v,int n=4){
    int h=std::max(n/2,2); return is_lower_high(v,h)&&is_lower_low(v,h);
}
static bool is_consolidating(const V& v,int n=5){
    int ab=v.avail_bars(); if(ab<1)return false; if(n>ab)n=ab;
    double hi=v.H(0),lo=v.L(0),ab_body=0;
    for(int i=0;i<n;i++){hi=std::max(hi,v.H(i));lo=std::min(lo,v.L(i));ab_body+=body(v,i);}
    ab_body/=n; return ab_body>0 && (hi-lo)<ab_body*n*0.5;
}
static bool is_bull_breakout(const V& v,int n=20){
    // lookback uses bars 1..n; bar 0 is current close
    int avail=v.avail_bars()-1; if(avail<1)return false; if(n>avail)n=avail;
    double hi=v.H(1);
    for(int i=1;i<=n;i++) hi=std::max(hi,v.H(i));
    return v.C(0)>hi && is_bull(v,0);
}
static bool is_bear_breakout(const V& v,int n=20){
    int avail=v.avail_bars()-1; if(avail<1)return false; if(n>avail)n=avail;
    double lo=v.L(1);
    for(int i=1;i<=n;i++) lo=std::min(lo,v.L(i));
    return v.C(0)<lo && is_bear(v,0);
}
static bool is_high_volume(const V& v,int n=5,double mult=1.5){
    int avail=v.avail_bars()-1; if(avail<1)return false; if(n>avail)n=avail;
    double avg=0; for(int i=1;i<=n;i++) avg+=v.Vol(i); avg/=n;
    return avg>0 && v.Vol(0)>avg*mult;
}
static bool is_accelerating_up(const V& v,int n=3){
    // needs C(0)..C(n): total n+1 bars
    int avail=v.avail_bars()-1; if(avail<1)return false; if(n>avail)n=avail;
    for(int i=0;i<n;i++) if(v.C(i)<=v.C(i+1)) return false; return true;
}
static bool is_accelerating_down(const V& v,int n=3){
    int avail=v.avail_bars()-1; if(avail<1)return false; if(n>avail)n=avail;
    for(int i=0;i<n;i++) if(v.C(i)>=v.C(i+1)) return false; return true;
}
static bool near_round_number(const V& v,int pip_range=10){
    double price=v.C(0),pt=v.point(),step=pt*1000;
    double nearest=std::round(price/step)*step;
    return std::abs(price-nearest)<pt*pip_range;
}

// ═══════════════════════════════════════════════════════════════════════════════
// §7b  SEQ state  (forward-declared here so EvalCond can use it)
// ═══════════════════════════════════════════════════════════════════════════════

struct SeqState {
    bool   active      = false;
    double bar_time    = 0;
    int    bars_waited = 0;
};

// ═══════════════════════════════════════════════════════════════════════════════
// §8  Condition evaluator  (maps to sandbox_run in Python)
// ═══════════════════════════════════════════════════════════════════════════════

static double GetVal(const JVal& node, const V& vals) {
    if(node.isNum()) return node.n;
    if(node.isStr()) return vals.get(node.s);
    // EXPR node — arithmetic on indicator values or literals
    // {"type":"EXPR","op":"+|-|*|/|abs","left":{...},"right":{...}}
    if(node.str("type") == "EXPR") {
        std::string op = node.str("op");
        auto* lp = node.get("left");
        double lv = lp ? GetVal(*lp, vals) : 0.0;
        if(op == "abs") return std::abs(lv);            // unary
        auto* rp = node.get("right");
        double rv = rp ? GetVal(*rp, vals) : 0.0;
        if(op == "+") return lv + rv;
        if(op == "-") return lv - rv;
        if(op == "*") return lv * rv;
        if(op == "/") return rv != 0.0 ? lv / rv : 0.0;
        Log("Unknown EXPR op: " + op);
    }
    return 0.0;
}

static bool EvalCond(const JVal& node, const V& vals, SeqState* seq = nullptr) {
    std::string type=node.str("type");

    if(type=="AND"){
        auto* args=node.get("args"); if(!args||!args->isArr()) return false;
        for(auto& a:args->a) if(!EvalCond(a,vals,seq)) return false;
        return true;
    }
    if(type=="OR"){
        auto* args=node.get("args"); if(!args||!args->isArr()) return false;
        for(auto& a:args->a) if(EvalCond(a,vals,seq)) return true;
        return false;
    }
    if(type=="NOT"){
        auto* arg=node.get("arg"); return arg ? !EvalCond(*arg,vals,seq) : false;
    }
    if(type=="CMP"){
        auto* lp=node.get("left"); auto* rp=node.get("right");
        if(!lp||!rp) return false;
        double lv=GetVal(*lp,vals), rv=GetVal(*rp,vals);
        std::string op=node.str("op");
        if(op==">") return lv>rv; if(op=="<") return lv<rv;
        if(op==">=")return lv>=rv;if(op=="<=")return lv<=rv;
        if(op=="==")return std::abs(lv-rv)<1e-9;
        if(op=="!=")return std::abs(lv-rv)>=1e-9;
        return false;
    }
    // TIME node — broker server time filter (uses "time" from vals)
    // {"type":"TIME","from":900,"to":1700}  (HHMM integer, 24h)
    if(type=="TIME"){
        int from = node.inum("from", 0);
        int to   = node.inum("to",   2400);
        long ts  = (long)vals.get("time");
        int hhmm = ((ts / 3600) % 24) * 100 + (ts / 60) % 60;
        return (from <= to) ? (hhmm >= from && hhmm < to)
                            : (hhmm >= from || hhmm < to); // crosses midnight
    }
    // SEQ node — 2-step sequencer: step1 fires, then step2 must fire on a later bar
    // {"type":"SEQ","step1":{...},"step2":{...},"bars":3}
    // bars = max bars to wait for step2 (default 3, 0 = unlimited)
    if(type=="SEQ"){
        if(!seq) return false;
        auto* s1 = node.get("step1");
        auto* s2 = node.get("step2");
        if(!s1 || !s2) return false;
        int  max_bars  = node.inum("bars", 3);
        double cur_bar = vals.get("bar_time");

        if(!seq->active) {
            if(EvalCond(*s1, vals, seq)) {
                seq->active      = true;
                seq->bar_time    = cur_bar;
                seq->bars_waited = 0;
                Log("SEQ step1 triggered — waiting for step2");
            }
            return false;
        } else {
            // step1 already triggered — wait for new bar
            if(cur_bar > seq->bar_time) {
                seq->bar_time = cur_bar;
                seq->bars_waited++;
                if(EvalCond(*s2, vals, seq)) {
                    seq->active = false;
                    Log("SEQ step2 confirmed — SIGNAL");
                    return true;
                }
                if(max_bars > 0 && seq->bars_waited >= max_bars) {
                    Log("SEQ expired after " + std::to_string(seq->bars_waited) + " bars — reset");
                    seq->active = false;
                }
            }
            return false;
        }
    }
    if(type=="FN"){
        std::string name=node.str("name");
        auto* pm=node.get("params");
        int  pi = pm?pm->inum("i",0):0;
        int  pn = pm?pm->inum("n",3):3;

        // single-candle (take i param)
        if(name=="is_bull")            return is_bull(vals,pi);
        if(name=="is_bear")            return is_bear(vals,pi);
        if(name=="is_doji")            return is_doji(vals,pi);
        if(name=="is_marubozu")        return is_marubozu(vals,pi);
        if(name=="is_hammer")          return is_hammer(vals,pi);
        if(name=="is_inverted_hammer") return is_inverted_hammer(vals,pi);
        if(name=="is_shooting_star")   return is_shooting_star(vals,pi);
        if(name=="is_hanging_man")     return is_hanging_man(vals,pi);
        if(name=="is_pin_bar_bull")    return is_pin_bar_bull(vals,pi);
        if(name=="is_pin_bar_bear")    return is_pin_bar_bear(vals,pi);
        if(name=="is_pin_bar")         return is_pin_bar(vals,pi);
        if(name=="is_spinning_top")    return is_spinning_top(vals,pi);
        // two-candle
        if(name=="is_bull_engulfing")  return is_bull_engulfing(vals);
        if(name=="is_bear_engulfing")  return is_bear_engulfing(vals);
        if(name=="is_bull_harami")     return is_bull_harami(vals);
        if(name=="is_bear_harami")     return is_bear_harami(vals);
        if(name=="is_piercing")        return is_piercing(vals);
        if(name=="is_dark_cloud")      return is_dark_cloud(vals);
        if(name=="is_tweezer_top")     return is_tweezer_top(vals);
        if(name=="is_tweezer_bottom")  return is_tweezer_bottom(vals);
        // three-candle
        if(name=="is_morning_star")        return is_morning_star(vals);
        if(name=="is_evening_star")        return is_evening_star(vals);
        if(name=="is_three_white_soldiers")return is_three_white_soldiers(vals);
        if(name=="is_three_black_crows")   return is_three_black_crows(vals);
        if(name=="is_three_inside_up")     return is_three_inside_up(vals);
        if(name=="is_three_inside_down")   return is_three_inside_down(vals);
        // market structure (take n param)
        if(name=="is_higher_high")      return is_higher_high(vals,pn);
        if(name=="is_lower_low")        return is_lower_low(vals,pn);
        if(name=="is_higher_low")       return is_higher_low(vals,pn);
        if(name=="is_lower_high")       return is_lower_high(vals,pn);
        if(name=="is_uptrend")          return is_uptrend(vals,pn);
        if(name=="is_downtrend")        return is_downtrend(vals,pn);
        if(name=="is_consolidating")    return is_consolidating(vals,pn);
        if(name=="is_bull_breakout")    return is_bull_breakout(vals,pn);
        if(name=="is_bear_breakout")    return is_bear_breakout(vals,pn);
        if(name=="is_high_volume")      return is_high_volume(vals,pn);
        if(name=="is_accelerating_up")  return is_accelerating_up(vals,pn);
        if(name=="is_accelerating_down")return is_accelerating_down(vals,pn);
        if(name=="near_round_number")   return near_round_number(vals);
        Log("Unknown FN: "+name);
        return false;
    }
    Log("Unknown condition type: "+type);
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// §9  (removed — system prompt moved to backend/main.py)
// ═══════════════════════════════════════════════════════════════════════════════

/* REMOVED: static const char* INIT_SYSTEM_PROMPT — now lives in backend/main.py
   Bridge_Init posts to POST /init on backend which calls Claude and returns config.

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

INDICATOR TYPES and REQUIRED FIELDS (only include fields listed, omit others):
- iMA:         {"name":"ma20","type":"iMA","period":20,"method":1,"applied":0,"shift":0}
               method: 0=SMA, 1=EMA, 2=SMMA, 3=LWMA | applied: 0=Close,1=Open,2=High,3=Low
- iRSI:        {"name":"rsi14","type":"iRSI","period":14,"applied":0,"shift":0}
- iCCI:        {"name":"cci14","type":"iCCI","period":14,"applied":0,"shift":0}
- iWPR:        {"name":"wpr14","type":"iWPR","period":14,"shift":0}
- iMomentum:   {"name":"mom14","type":"iMomentum","period":14,"applied":0,"shift":0}
- iATR:        {"name":"atr14","type":"iATR","period":14,"shift":0}
- iADX:        {"name":"adx14","type":"iADX","period":14,"applied":0,"line":0,"shift":0}
               line: 0=ADX, 1=+DI, 2=-DI
- iMACD:       {"name":"macd_main","type":"iMACD","fast":12,"slow":26,"signal":9,"applied":0,"line":0,"shift":0}
               line: 0=main, 1=signal — ALWAYS set "line"
- iBands:      {"name":"bb20_upper","type":"iBands","period":20,"deviation":2.0,"method":0,"applied":0,"line":1,"shift":0}
               line: 0=middle, 1=upper, 2=lower — ALWAYS set "line"
- iStochastic: {"name":"sto_k","type":"iStochastic","kperiod":5,"dperiod":3,"slowing":3,"method":0,"line":0,"shift":0}
               line: 0=%K, 1=%D — ALWAYS set "line"
- iSAR:        {"name":"sar","type":"iSAR","step":0.02,"maximum":0.2,"shift":0}
- iAlligator:  {"name":"alli_jaw","type":"iAlligator","p1":13,"s1":8,"p2":8,"s2":5,"p3":5,"s3":3,"method":1,"applied":4,"line":1,"shift":0}
               line: 1=Jaw, 2=Teeth, 3=Lips — ALWAYS set "line"
- iIchimoku:   {"name":"ichi_tenkan","type":"iIchimoku","p1":9,"p2":26,"p3":52,"line":1,"shift":0}
               line: 1=Tenkan, 2=Kijun, 3=Senkou A, 4=Senkou B, 5=Chikou — ALWAYS set "line"

CONDITION TYPES:
- {"type":"AND","args":[...]}
- {"type":"OR","args":[...]}
- {"type":"NOT","arg":{...}}
- {"type":"CMP","left":"var_name"|number,"op":">/</>=/<=/==/!=","right":"var_name"|number}
- {"type":"FN","name":"fn_name","params":{"i":0,"n":3}}

PA FUNCTIONS (use only when instruction mentions candle patterns, no indicator needed):
is_bull(i), is_bear(i), is_doji(i), is_hammer(i), is_shooting_star(i), is_pin_bar(i),
is_bull_engulfing(), is_bear_engulfing(), is_morning_star(), is_evening_star(),
is_uptrend(n), is_downtrend(n), is_bull_breakout(n), is_bear_breakout(n)

CROSSOVER RULE: "X crosses above Y" requires BOTH current and _prev variants:
  indicators: X (shift=0), X_prev (shift=1), Y (shift=0), Y_prev (shift=1)
  condition: CMP(X > Y) AND CMP(X_prev < Y_prev)

CRITICAL RULES:
1. MANDATORY: If instruction mentions ANY indicator (MA, EMA, RSI, MACD, Bollinger, ATR, ADX, etc.)
   you MUST add it to "indicators" array AND reference its name in "condition".
   NEVER return "indicators":[] when the instruction names specific indicators.
2. Each indicator name used in condition MUST appear in the indicators array.
3. Each indicator in the array MUST be referenced in the condition.
4. action: BUY or SELL only
5. symbol: ALWAYS extract the trading instrument from the instruction (e.g. "GBPUSD", "XAUUSD").
   Normalize to standard MT4 format (no slash, uppercase). If not mentioned, use "EURUSD".
   Examples: "gold" → "XAUUSD", "cable" → "GBPUSD", "GBP/USD" → "GBPUSD", "gbp usd" → "GBPUSD"
6. tf: minutes (1,5,15,30,60,240,1440); 0 if not specified
7. sl_pip and tp_pip must be > 0; tp_pip >= sl_pip * 0.5
8. lot: 0 < lot <= 100
*/

// ═══════════════════════════════════════════════════════════════════════════════
// §10  Session  (maps to strategies[] dict in strategy.py)
// ═══════════════════════════════════════════════════════════════════════════════

struct Session {
    std::string action;
    double      lot=0.1, sl_pip=50, tp_pip=100;
    int         ohlc_bars=3, tf=0;
    std::string symbol;
    std::string prompt;
    JVal        condition;       // entry condition tree
    JVal        exit_condition;  // exit condition tree (empty = rely on SL/TP)
    SeqState    seq_entry;       // SEQ state for entry condition
    SeqState    seq_exit;        // SEQ state for exit condition
};

static std::map<int,Session> g_sessions;
static std::mutex            g_mutex;

// ═══════════════════════════════════════════════════════════════════════════════
// §11  Helpers
// ═══════════════════════════════════════════════════════════════════════════════

static void FillBuf(const std::string& src, char* buf, int sz) {
    if(!buf||sz<=0) return;
    int n=(int)src.size(); if(n>=sz)n=sz-1;
    memcpy(buf,src.c_str(),n); buf[n]='\0';
}
static std::string BuildOk(const Session& s) {
    // Build indicators JSON from condition — EA needs them to know what to send
    // For simplicity we return the session's tf and ohlc_bars
    char buf[256];
    _snprintf_s(buf,sizeof(buf),_TRUNCATE,
        "{\"status\":\"ok\",\"tf\":%d,\"ohlc_bars\":%d,\"version\":\"" BRIDGE_VERSION "\"}",
        s.tf, s.ohlc_bars);
    return buf;
}

// Parse values_json string → V struct
static V ParseValues(const char* json_str) {
    V vals;
    if(!json_str||!*json_str) return vals;
    JVal j=ParseJSON(json_str);
    if(!j.isObj()) return vals;
    for(auto& kv:j.o) {
        if(kv.second.isNum()) vals.d[kv.first]=kv.second.n;
    }
    return vals;
}

// Dry-run condition with dummy values to validate (maps to sandbox dry-run)
static bool DryRunCondition(const JVal& cond, int ohlc_bars) {
    V dummy;
    for(int i=0;i<ohlc_bars+2;i++){
        dummy.d["open_"  +std::to_string(i)]=1.0800+i*0.0001;
        dummy.d["close_" +std::to_string(i)]=1.0810+i*0.0001;
        dummy.d["high_"  +std::to_string(i)]=1.0820+i*0.0001;
        dummy.d["low_"   +std::to_string(i)]=1.0790+i*0.0001;
        dummy.d["volume_"+std::to_string(i)]=1000;
    }
    dummy.d["point"]=0.00001;
    dummy.d["ask"]=1.0811; dummy.d["bid"]=1.0810;
    // Set any referenced indicator vars to 1.0 (will be overwritten by real data)
    try { EvalCond(cond,dummy); return true; }
    catch(...) { return false; }
}

// ═══════════════════════════════════════════════════════════════════════════════
// §12  DLL entry
// ═══════════════════════════════════════════════════════════════════════════════

// Safe early log — only WinAPI, no CRT, callable before global C++ objects init.
static void DllStartupLog(const char* msg) {
    char dir[MAX_PATH] = {}, path[MAX_PATH] = {};
    ExpandEnvironmentStringsA("%APPDATA%", dir, MAX_PATH);
    // Build path manually (no snprintf — CRT may not be ready)
    lstrcatA(dir, "\\AI_Bridge");
    CreateDirectoryA(dir, nullptr);
    lstrcpyA(path, dir);
    lstrcatA(path, "\\startup.log");
    HANDLE h = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME t; GetLocalTime(&t);
    char line[512] = {};
    // wsprintf is safe before CRT init
    wsprintfA(line, "[%02d:%02d:%02d] %s\r\n",
              t.wHour, t.wMinute, t.wSecond, msg);
    DWORD n;
    WriteFile(h, line, (DWORD)lstrlenA(line), &n, nullptr);
    CloseHandle(h);
}

BOOL APIENTRY DllMain(HMODULE hmod, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_hmod = hmod;
        DisableThreadLibraryCalls(hmod);
        try {
            DllStartupLog("=== AI_Bridge.dll ATTACH begin (v" BRIDGE_VERSION ")");
            // Smoke-test globals declared before DllMain (g_ws_queue is declared later)
            (void)g_sessions.size();
            (void)g_last_debug.size();
            DllStartupLog("=== AI_Bridge.dll ATTACH ok — globals init OK");
        } catch (const std::exception& e) {
            std::string m = "EXCEPTION in ATTACH: ";
            m += e.what();
            DllStartupLog(m.c_str());
            return FALSE;
        } catch (...) {
            DllStartupLog("UNKNOWN EXCEPTION in ATTACH");
            return FALSE;
        }
    } else if (reason == DLL_PROCESS_DETACH) {
        DllStartupLog("=== AI_Bridge.dll DETACH");
    }
    return TRUE;
}

// ═══════════════════════════════════════════════════════════════════════════════
// §12b  Forward declarations for WS helpers used in Bridge_Init / Bridge_Stop
// ═══════════════════════════════════════════════════════════════════════════════
static bool        WsSend(const std::string& msg);
static std::string BuildStrategyHello();

// ═══════════════════════════════════════════════════════════════════════════════
// §13  Exported functions
// ═══════════════════════════════════════════════════════════════════════════════
extern "C" {

// Maps to: handle_init() in strategy.py
__declspec(dllexport) int __stdcall
Bridge_Init(int sid, const wchar_t* prompt, const wchar_t* symbol,
            int tf, double lot, int sl, int tp, int account,
            const wchar_t* token,
            char* out_buf, int buf_size)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    LogReset();
    // Convert MQL4 wchar_t* strings to std::string
    std::string sym = W2S(symbol);
    std::string prm = W2S(prompt);
    std::string tok = W2S(token);
    if (sym.empty()) sym = "EURUSD";
    Log("=== Bridge_Init sid="+std::to_string(sid)+" symbol="+sym
        +" tf="+std::to_string(tf)+" sl="+std::to_string(sl)+" tp="+std::to_string(tp));

    // 1. POST /init to backend — token authenticates account+server
    std::string req_body =
        "{\"sid\":"      + std::to_string(sid)     +
        ",\"token\":\"" + JE(tok)                  + "\"" +
        ",\"prompt\":\"" + JE(prm)                 + "\"" +
        ",\"symbol\":\"" + JE(sym)                 + "\"" +
        ",\"tf\":"       + std::to_string(tf)       +
        ",\"lot\":"      + std::to_string(lot)      +
        ",\"sl\":"       + std::to_string(sl)       +
        ",\"tp\":"       + std::to_string(tp)       +
        ",\"account\":"  + std::to_string(account)  + "}";
    std::string raw = BackendPost("/init", req_body);
    if (raw.empty()) {
        FillBuf("{\"status\":\"error\",\"message\":\"Backend /init unavailable\"}", out_buf, buf_size);
        Log("ERROR: Backend /init no response (offline?)"); return -1;
    }

    // 2. Parse backend response
    JVal resp = ParseJSON(raw);
    if (!resp.isObj()) {
        std::string err = "{\"status\":\"error\",\"message\":\"Non-JSON from backend: "
                          + JE(raw.substr(0, 120)) + "\"}";
        FillBuf(err, out_buf, buf_size);
        Log("ERROR: backend /init non-JSON: " + raw.substr(0, 300)); return -1;
    }
    if (resp.str("status") != "ok") {
        // FastAPI errors use "detail", our errors use "message"
        std::string msg = resp.str("message", "");
        if (msg.empty()) msg = resp.str("detail", "");
        if (msg.empty()) msg = "Backend error (raw: " + raw.substr(0, 120) + ")";
        std::string err = "{\"status\":\"error\",\"message\":\"" + JE(msg) + "\"}";
        FillBuf(err, out_buf, buf_size);
        Log("ERROR: backend /init: " + msg); return -1;
    }
    auto* cfg_node_outer = resp.get("config");
    if (!cfg_node_outer || !cfg_node_outer->isObj()) {
        FillBuf("{\"status\":\"error\",\"message\":\"No config in backend response\"}", out_buf, buf_size);
        Log("ERROR: config missing from backend response"); return -1;
    }
    JVal cfg = *cfg_node_outer;

    // 3. Validate condition tree exists
    auto* cond_check = cfg.get("condition");
    if (!cond_check || !cond_check->isObj()) {
        FillBuf("{\"status\":\"error\",\"message\":\"No condition in config\"}", out_buf, buf_size);
        Log("ERROR: condition missing from backend config"); return -1;
    }

    // (continue into existing parse + validate + session store below)
    auto* cond_node=cfg.get("condition"); // already validated above

    // 7. Build session
    Session s;
    s.prompt   = prm;
    s.action   = cfg.str("action","BUY");
    s.lot      = cfg.num("lot",   lot);
    s.sl_pip   = cfg.num("sl_pip",sl);
    s.tp_pip   = cfg.num("tp_pip",tp);
    s.ohlc_bars= cfg.inum("ohlc_bars",5);
    s.condition= *cond_node;
    // Store exit_condition if provided (must have a "type" key to be non-empty)
    {
        auto* ec = cfg.get("exit_condition");
        if (ec && ec->isObj() && ec->get("type"))
            s.exit_condition = *ec;
    }
    // Use Claude-detected symbol if provided, else fallback to EA-passed symbol
    std::string claude_sym = cfg.str("symbol","");
    s.symbol = claude_sym.empty() ? sym : claude_sym;
    if(!claude_sym.empty() && claude_sym!=sym)
        Log("SYMBOL overridden by Claude: "+sym+" → "+claude_sym);

    // TF: prefer Claude's value, fallback to EA default (same as Python)
    int tf_claude=cfg.inum("tf",0);
    s.tf = tf_claude>0 ? tf_claude : tf;

    // 8. Validate params (maps to validate_output checks in Python)

    // Check 1: action must be BUY or SELL
    if (s.action != "BUY" && s.action != "SELL") {
        char dbg[128];
        _snprintf_s(dbg, sizeof(dbg), _TRUNCATE,
            "FAIL action=\"%s\" — must be BUY or SELL", s.action.c_str());
        Log(dbg);
        FillBuf("{\"status\":\"error\",\"message\":\"Invalid action\"}",out_buf,buf_size);
        return -1;
    }

    // Check 2: lot must be in (0, 100]
    if (s.lot <= 0 || s.lot > 100) {
        char dbg[128];
        _snprintf_s(dbg, sizeof(dbg), _TRUNCATE,
            "FAIL lot=%.4f — must satisfy 0 < lot <= 100", s.lot);
        Log(dbg);
        FillBuf("{\"status\":\"error\",\"message\":\"Invalid lot size\"}",out_buf,buf_size);
        return -1;
    }

    // Check 3: sl_pip and tp_pip must both be > 0
    if (s.sl_pip <= 0 || s.tp_pip <= 0) {
        char dbg[128];
        _snprintf_s(dbg, sizeof(dbg), _TRUNCATE,
            "FAIL sl_pip=%.1f tp_pip=%.1f — both must be > 0", s.sl_pip, s.tp_pip);
        Log(dbg);
        FillBuf("{\"status\":\"error\",\"message\":\"SL/TP must be > 0\"}",out_buf,buf_size);
        return -1;
    }

    // Check 4: tp_pip >= sl_pip * 0.5  (MIN_TP_SL_RATIO = 0.5)
    if (s.tp_pip < s.sl_pip * 0.5) {
        char dbg[160];
        _snprintf_s(dbg, sizeof(dbg), _TRUNCATE,
            "FAIL tp_pip=%.1f < sl_pip*0.5=%.1f — TP/SL ratio %.3f < 0.5",
            s.tp_pip, s.sl_pip * 0.5, s.tp_pip / (s.sl_pip > 0 ? s.sl_pip : 1.0));
        Log(dbg);
        FillBuf("{\"status\":\"error\",\"message\":\"TP/SL ratio too low\"}",out_buf,buf_size);
        return -1;
    }

    // 9. Dry-run condition with dummy values (maps to sandbox dry-run in Python)
    if (!DryRunCondition(s.condition, s.ohlc_bars)) {
        FillBuf("{\"status\":\"error\",\"message\":\"Condition dry-run failed\"}",out_buf,buf_size);
        Log("ERROR: condition dry-run FAILED — condition tree may reference unknown variables"); return -1;
    }

    // 10. Store session
    g_sessions[sid]=s;

    // Build indicators JSON for EA — include ALL fields so EA handles every type
    std::string ind_json="[]";
    auto* inds=cfg.get("indicators");
    if(inds&&inds->isArr()&&!inds->a.empty()){
        ind_json="[";
        for(size_t i=0;i<inds->a.size();i++){
            auto& ind=inds->a[i];
            if(i>0) ind_json+=",";

            // Helper lambda: double → string with 6 decimal places
            auto D=[](double v)->std::string{
                char b[32]; _snprintf_s(b,sizeof(b),_TRUNCATE,"%.6f",v); return b;
            };
            auto I=[](int v)->std::string{ return std::to_string(v); };

            std::string o="{";
            o+="\"name\":\""        +JE(ind.str("name"))                    +"\",";
            o+="\"type\":\""        +JE(ind.str("type","iMA"))              +"\",";
            o+="\"timeframe\":"     +I(ind.inum("timeframe",0))             +",";
            o+="\"period\":"        +I(ind.inum("period",14))               +",";
            o+="\"method\":"        +I(ind.inum("method",0))                +",";
            o+="\"applied\":"       +I(ind.inum("applied",0))               +",";
            o+="\"shift\":"         +I(ind.inum("shift",0))                 +",";
            o+="\"ma_shift\":"      +I(ind.inum("ma_shift",0))              +",";
            o+="\"line\":"          +I(ind.inum("line",0))                  +",";
            o+="\"deviation\":"     +D(ind.num("deviation",0.0))            +",";
            // MACD
            o+="\"fast\":"          +I(ind.inum("fast",0))                  +",";
            o+="\"slow\":"          +I(ind.inum("slow",0))                  +",";
            o+="\"signal\":"        +I(ind.inum("signal",0))                +",";
            // Stochastic
            o+="\"kperiod\":"       +I(ind.inum("kperiod",0))               +",";
            o+="\"dperiod\":"       +I(ind.inum("dperiod",0))               +",";
            o+="\"slowing\":"       +I(ind.inum("slowing",0))               +",";
            // SAR
            o+="\"step\":"          +D(ind.num("step",0.0))                 +",";
            o+="\"maximum\":"       +D(ind.num("maximum",0.0))              +",";
            // Alligator (jaw/teeth/lips periods + shifts)
            o+="\"p1\":"            +I(ind.inum("p1",0))                    +",";
            o+="\"s1\":"            +I(ind.inum("s1",0))                    +",";
            o+="\"p2\":"            +I(ind.inum("p2",0))                    +",";
            o+="\"s2\":"            +I(ind.inum("s2",0))                    +",";
            o+="\"p3\":"            +I(ind.inum("p3",0))                    +",";
            o+="\"s3\":"            +I(ind.inum("s3",0))                    +",";
            // Custom indicator
            o+="\"custom_name\":\"" +JE(ind.str("custom_name"))             +"\",";
            o+="\"buffer_index\":"  +I(ind.inum("buffer_index",0));
            o+="}";
            ind_json+=o;
        }
        ind_json+="]";
    }

    // Use std::string to avoid fixed-size buffer overflow on many/complex indicators
    std::string ok_str=
        std::string("{\"status\":\"ok\",\"action\":\"") + s.action + "\","
        +"\"symbol\":\""  +JE(s.symbol)                +"\","
        +"\"tf\":"        +std::to_string(s.tf)        +","
        +"\"ohlc_bars\":" +std::to_string(s.ohlc_bars) +","
        +"\"indicators\":" +ind_json                   +","
        +"\"version\":\""  +BRIDGE_VERSION             +"\"}";
    FillBuf(ok_str, out_buf, buf_size);
    Log("=== Bridge_Init OK action="+s.action+" tf="+std::to_string(s.tf)+" ohlc_bars="+std::to_string(s.ohlc_bars));

    // Notify backend so it can forward to frontend chat clients
    std::string upd =
        "{\"event\":\"strategy_update\""
        ",\"sid\":"     + std::to_string(sid)
        + ",\"prompt\":\"" + JE(s.prompt)  + "\""
        + ",\"action\":\"" + JE(s.action)  + "\""
        + ",\"symbol\":\"" + JE(s.symbol)  + "\""
        + ",\"lot\":"    + std::to_string(s.lot)
        + ",\"sl\":"     + std::to_string(s.sl_pip)
        + ",\"tp\":"     + std::to_string(s.tp_pip)
        + ",\"tf\":"     + std::to_string(s.tf)
        + "}";
    WsSend(upd);

    return 0;
}

// Maps to: handle_check() + sandbox_run() + validate_output() in Python
__declspec(dllexport) int __stdcall
Bridge_Check(int sid, const wchar_t* values_json, int account,
             char* out_buf, int buf_size)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it=g_sessions.find(sid);
    if(it==g_sessions.end()){
        FillBuf("{\"action\":\"NONE\"}",out_buf,buf_size); return -1;
    }
    Session& s=it->second;

    // Convert MQL4 wchar_t* → std::string then parse market values
    std::string vals_str = W2S(values_json);
    V vals=ParseValues(vals_str.c_str());

    // Exit condition evaluated first (higher priority than entry)
    if (s.exit_condition.get("type")) {
        bool should_exit = false;
        try { should_exit = EvalCond(s.exit_condition, vals, &s.seq_exit); }
        catch(const std::exception& e){
            Log(std::string("EvalCond(exit) exception: ")+e.what());
        }
        if (should_exit) {
            FillBuf("{\"action\":\"EXIT\"}",out_buf,buf_size);
            Log("EXIT signal → "+s.symbol);
            return 0;
        }
    }

    // Entry condition
    bool signal=false;
    try { signal=EvalCond(s.condition, vals, &s.seq_entry); }
    catch(const std::exception& e){
        Log(std::string("EvalCond exception: ")+e.what());
        FillBuf("{\"action\":\"NONE\"}",out_buf,buf_size); return 0;
    }

    if(!signal){
        FillBuf("{\"action\":\"NONE\"}",out_buf,buf_size); return 0;
    }

    char res[256];
    _snprintf_s(res,sizeof(res),_TRUNCATE,
        "{\"action\":\"%s\",\"lot\":%.2f,\"sl\":%.1f,\"tp\":%.1f}",
        s.action.c_str(), s.lot, s.sl_pip, s.tp_pip);
    FillBuf(res,out_buf,buf_size);
    Log("SIGNAL → "+s.action+" "+s.symbol+" lot="+std::to_string(s.lot));
    return 0;
}

// Maps to: handle_stop() in strategy.py
__declspec(dllexport) void __stdcall
Bridge_Stop(int sid) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it=g_sessions.find(sid);
    if(it!=g_sessions.end()){
        Log("Bridge_Stop sid="+std::to_string(sid)+" symbol="+it->second.symbol);
        g_sessions.erase(it);
        WsSend("{\"event\":\"strategy_delete\",\"sid\":" + std::to_string(sid) + "}");
    }
}

__declspec(dllexport) int __stdcall
Bridge_Version(char* out_buf, int buf_size) {
    FillBuf(BRIDGE_VERSION, out_buf, buf_size); return 0;
}

// Returns the full debug log of the last Bridge_Init call.
// MT4 can call this right after Bridge_Init to print everything.
__declspec(dllexport) int __stdcall
Bridge_GetLastLog(char* out_buf, int buf_size) {
    std::lock_guard<std::mutex> lock(g_mutex);
    FillBuf(g_last_debug, out_buf, buf_size);
    return (int)g_last_debug.size();
}

} // extern "C"  — closes Bridge_Init/Check/Stop/Version/GetLastLog

// ═══════════════════════════════════════════════════════════════════════════════
// §WS  WebSocket helpers — OUTSIDE extern "C" so std::string return is valid
//      Requires Windows 8+ (WinHttpWebSocketCompleteUpgrade)
// ═══════════════════════════════════════════════════════════════════════════════

static std::deque<std::string> g_ws_queue;   // incoming event strings for MQL4
static std::mutex              g_ws_qmutex;
static HANDLE                  g_ws_thread      = nullptr;
static volatile bool           g_ws_running     = false;
static volatile bool           g_ws_connected   = false;   // true once handshake succeeds
static volatile int            g_ws_reconnect_cnt = 0;     // total successful connects
static HINTERNET               g_ws_hS          = nullptr;
static HINTERNET               g_ws_hC          = nullptr;
static HINTERNET               g_ws_hWs         = nullptr;
static std::mutex              g_ws_connmtx;               // guards g_ws_hWs + g_ws_last_error
static std::string             g_ws_account;
static std::string             g_ws_token;
static std::string             g_ws_last_error;            // last WsDoConnect failure reason
static HANDLE                  g_ws_connect_evt = nullptr; // auto-reset, signaled after connect attempt

// Apply a fully-parsed config JVal into g_sessions[sid]
static void WsApplyConfig(int sid, const JVal& cfg) {
    auto* cond = cfg.get("condition");
    if (!cond || !cond->isObj()) {
        Log("WS: ApplyConfig sid=" + std::to_string(sid) + " missing condition — skip");
        return;
    }
    Session s;
    s.prompt    = cfg.str("prompt",   "");
    s.action    = cfg.str("action",   "BUY");
    s.symbol    = cfg.str("symbol",   "EURUSD");
    s.tf        = cfg.inum("tf",      60);
    s.lot       = cfg.num ("lot",     0.1);
    // Accept both "sl_pip" (preferred) and "sl" (fallback sent by some backend paths)
    s.sl_pip    = cfg.num("sl_pip", -1.0) >= 0 ? cfg.num("sl_pip", 50) : cfg.num("sl", 50);
    s.tp_pip    = cfg.num("tp_pip", -1.0) >= 0 ? cfg.num("tp_pip", 100) : cfg.num("tp", 100);
    s.ohlc_bars = cfg.inum("ohlc_bars", 3);
    s.condition = *cond;
    auto* exit_cond = cfg.get("exit_condition");
    if (exit_cond && exit_cond->isObj() && exit_cond->get("type"))
        s.exit_condition = *exit_cond;
    if (!DryRunCondition(s.condition, s.ohlc_bars)) {
        Log("WS: DryRun failed sid=" + std::to_string(sid) + " — skip");
        return;
    }
    std::lock_guard<std::mutex> lk(g_mutex);
    g_sessions[sid] = s;
    Log("WS: Session[" + std::to_string(sid) + "] applied action=" + s.action
        + " symbol=" + s.symbol + " sl=" + std::to_string(s.sl_pip)
        + " tp=" + std::to_string(s.tp_pip));
}

// Process one received message, update g_sessions, push to queue for MQL4
static void WsOnMessage(const std::string& msg) {
    JVal j = ParseJSON(msg);
    if (!j.isObj()) { Log("WS: non-JSON message"); return; }

    std::string ev = j.str("event");

    if (ev == "strategy_add" || ev == "strategy_update") {
        int sid = j.inum("sid", -1);
        if (sid < 0 || sid >= 5) {
            Log("WS: " + ev + " bad sid=" + std::to_string(sid));
        } else {
            auto* cfg = j.get("config");
            if (cfg && cfg->isObj()) {
                // Full replace — new condition tree included
                WsApplyConfig(sid, *cfg);
            } else {
                // Partial update (chatbot update op: only lot/sl/tp/tf changed, no new condition)
                std::lock_guard<std::mutex> lk(g_mutex);
                auto it = g_sessions.find(sid);
                if (it != g_sessions.end()) {
                    auto* v_lot = j.get("lot"); if (v_lot && v_lot->isNum()) it->second.lot    = v_lot->n;
                    auto* v_sl  = j.get("sl");  if (v_sl  && v_sl->isNum())  it->second.sl_pip = v_sl->n;
                    auto* v_tp  = j.get("tp");  if (v_tp  && v_tp->isNum())  it->second.tp_pip = v_tp->n;
                    auto* v_tf  = j.get("tf");  if (v_tf  && v_tf->isNum())  it->second.tf     = (int)v_tf->n;
                    Log("WS: Session[" + std::to_string(sid) + "] partial update"
                        " lot=" + std::to_string(it->second.lot)
                        + " sl=" + std::to_string(it->second.sl_pip)
                        + " tp=" + std::to_string(it->second.tp_pip));
                } else {
                    Log("WS: strategy_update sid=" + std::to_string(sid) + " — no session to update");
                }
            }
        }

    } else if (ev == "strategy_delete") {
        int sid = j.inum("sid", -1);
        if (sid >= 0 && sid < 5) {
            std::lock_guard<std::mutex> lk(g_mutex);
            g_sessions.erase(sid);
            Log("WS: Session[" + std::to_string(sid) + "] deleted");
        }

    } else if (ev == "strategy_sync") {
        auto* strats = j.get("strategies");
        if (strats && strats->isArr()) {
            for (auto& item : strats->a) {
                int sid = item.inum("sid", -1);
                auto* cfg = item.get("config");
                if (sid >= 0 && sid < 5 && cfg && cfg->isObj())
                    WsApplyConfig(sid, *cfg);
            }
        }
    }
    // Push event string to queue for MQL4 polling
    std::lock_guard<std::mutex> lk(g_ws_qmutex);
    if (g_ws_queue.size() >= 50) g_ws_queue.pop_front(); // cap
    g_ws_queue.push_back(msg);
}

// Helper: record failure reason, signal event, return false
#define WS_FAIL(msg) \
    do { \
        DWORD _e = GetLastError(); \
        std::string _m = std::string(msg) + " (err=" + std::to_string(_e) + ")"; \
        { std::lock_guard<std::mutex> _lk(g_ws_connmtx); g_ws_last_error = _m; } \
        Log("WS: " + _m); \
        if (g_ws_connect_evt) SetEvent(g_ws_connect_evt); \
        return false; \
    } while(0)

static bool WsDoConnect() {
    g_ws_connected = false;
    { std::lock_guard<std::mutex> lk(g_ws_connmtx); g_ws_last_error.clear(); }

    // Close stale handles
    if (g_ws_hWs) {
        WinHttpWebSocketClose(g_ws_hWs,
            WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, nullptr, 0);
        WinHttpCloseHandle(g_ws_hWs); g_ws_hWs = nullptr;
    }
    if (g_ws_hC) { WinHttpCloseHandle(g_ws_hC); g_ws_hC = nullptr; }
    if (g_ws_hS) { WinHttpCloseHandle(g_ws_hS); g_ws_hS = nullptr; }

    Log("WS: connecting → " + std::string(BACKEND_HOST) + ":"
        + std::to_string(BACKEND_PORT) + "/ws/ea/" + g_ws_account);

    g_ws_hS = WinHttpOpen(L"AI_Bridge/3.0",
                          WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                          WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!g_ws_hS) WS_FAIL("WinHttpOpen failed");

    std::wstring whost(BACKEND_HOST, BACKEND_HOST + strlen(BACKEND_HOST));
    g_ws_hC = WinHttpConnect(g_ws_hS, whost.c_str(), BACKEND_PORT, 0);
    if (!g_ws_hC) {
        WinHttpCloseHandle(g_ws_hS); g_ws_hS = nullptr;
        WS_FAIL("WinHttpConnect failed");
    }

    std::string path_s = "/ws/ea/" + g_ws_account + "?token=" + g_ws_token;
    std::wstring wpath(path_s.begin(), path_s.end());
    HINTERNET hReq = WinHttpOpenRequest(g_ws_hC, L"GET", wpath.c_str(), nullptr,
                                        WINHTTP_NO_REFERER,
                                        WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
    if (!hReq) {
        WinHttpCloseHandle(g_ws_hC); g_ws_hC = nullptr;
        WinHttpCloseHandle(g_ws_hS); g_ws_hS = nullptr;
        WS_FAIL("WinHttpOpenRequest failed");
    }

    WinHttpSetOption(hReq, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0);

    BOOL ok = WinHttpSendRequest(hReq,
                                 WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                 nullptr, 0, 0, 0);
    if (!ok || !WinHttpReceiveResponse(hReq, nullptr)) {
        WinHttpCloseHandle(hReq);
        WS_FAIL("HTTP upgrade handshake failed — backend reachable?");
    }

    g_ws_hWs = WinHttpWebSocketCompleteUpgrade(hReq, 0);
    WinHttpCloseHandle(hReq);
    if (!g_ws_hWs) WS_FAIL("WinHttpWebSocketCompleteUpgrade failed");

    // Heartbeat: receive timeout 30s so WsThreadProc wakes up to send a ping
    // and detects silent disconnects (firewall/NAT state loss, no TCP RST)
    DWORD recvTimeout = 30000;
    WinHttpSetOption(g_ws_hWs, WINHTTP_OPTION_RECEIVE_TIMEOUT,
                     &recvTimeout, sizeof(recvTimeout));

    // SUCCESS
    g_ws_connected = true;
    g_ws_reconnect_cnt++;
    Log("WS: Connected → /ws/ea/" + g_ws_account
        + "  (connect #" + std::to_string(g_ws_reconnect_cnt) + ")");
    if (g_ws_connect_evt) SetEvent(g_ws_connect_evt);
    return true;
}
#undef WS_FAIL

// Send a UTF-8 JSON string to backend over the open WS connection
static bool WsSend(const std::string& msg) {
    std::lock_guard<std::mutex> lk(g_ws_connmtx);
    if (!g_ws_hWs) return false;
    DWORD ret = WinHttpWebSocketSend(
        g_ws_hWs,
        WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
        (PVOID)msg.c_str(), (DWORD)msg.size());
    if (ret != ERROR_SUCCESS)
        Log("WsSend error=" + std::to_string(ret));
    return ret == ERROR_SUCCESS;
}

// Send a WebSocket ping frame to verify the connection is still alive
static bool WsPing() {
    std::lock_guard<std::mutex> lk(g_ws_connmtx);
    if (!g_ws_hWs) return false;
    DWORD ret = WinHttpWebSocketSend(
        g_ws_hWs, WINHTTP_WEB_SOCKET_PING_PONG_BUFFER_TYPE, nullptr, 0);
    return ret == ERROR_SUCCESS;
}

// Build strategy_hello payload from all active sessions
static std::string BuildStrategyHello() {
    std::lock_guard<std::mutex> lk(g_mutex);
    std::string arr = "[";
    bool first = true;
    for (auto& kv : g_sessions) {
        int sid         = kv.first;
        const Session& s = kv.second;
        if (!first) arr += ",";
        first = false;
        arr += "{\"sid\":"    + std::to_string(sid)
             + ",\"prompt\":\"" + JE(s.prompt)   + "\""
             + ",\"action\":\"" + JE(s.action)   + "\""
             + ",\"symbol\":\"" + JE(s.symbol)   + "\""
             + ",\"lot\":"    + std::to_string(s.lot)
             + ",\"sl\":"     + std::to_string(s.sl_pip)
             + ",\"tp\":"     + std::to_string(s.tp_pip)
             + ",\"tf\":"     + std::to_string(s.tf)
             + "}";
    }
    arr += "]";
    return "{\"event\":\"strategy_hello\",\"strategies\":" + arr + "}";
}

static DWORD WINAPI WsThreadProc(LPVOID) {
    Log("WS: thread started account=" + g_ws_account);
    while (g_ws_running) {
        if (!g_ws_hWs) {
            Log("WS: connecting...");
            if (!WsDoConnect()) { Sleep(5000); continue; }
            // Immediately push all active sessions so backend is in sync
            std::string hello = BuildStrategyHello();
            WsSend(hello);
            Log("WS: strategy_hello sent (" + std::to_string(g_sessions.size()) + " sessions)");
        }

        BYTE  buf[65536] = {};
        DWORD got  = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE btype;
        DWORD ret = WinHttpWebSocketReceive(g_ws_hWs, buf, sizeof(buf), &got, &btype);

        if (!g_ws_running) break;

        if (ret == ERROR_WINHTTP_TIMEOUT) {
            // Receive timeout (30s) — send ping to detect silent disconnects
            if (WsPing()) continue;   // connection alive, keep receiving
            // Ping failed → silent disconnect (NAT/firewall dropped the session)
            g_ws_connected = false;
            { std::lock_guard<std::mutex> lk(g_ws_connmtx); g_ws_last_error = "ping failed — silent disconnect"; }
            Log("WS: ping failed — silent disconnect, reconnecting in 3s");
            WinHttpCloseHandle(g_ws_hWs); g_ws_hWs = nullptr;
            Sleep(3000);
            continue;
        }

        if (ret != ERROR_SUCCESS) {
            g_ws_connected = false;
            std::string recv_err = "Receive err=" + std::to_string(ret);
            { std::lock_guard<std::mutex> lk(g_ws_connmtx); g_ws_last_error = recv_err; }
            Log("WS: " + recv_err + " — reconnecting in 3s");
            WinHttpCloseHandle(g_ws_hWs); g_ws_hWs = nullptr;
            Sleep(3000);
            continue;
        }
        if (btype == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE && got > 0)
            WsOnMessage(std::string(reinterpret_cast<char*>(buf), got));
    }
    Log("WS: thread stopped");
    return 0;
}

// ── Exported WS functions ─────────────────────────────────────────────────────
extern "C" {

// Call after Bridge_Register — starts background WS thread and waits up to 3s for result.
// account_str: MQL4 string (wchar_t*) containing the account number, e.g. "11997690"
// Returns: 0=ok/connected, 1=ok/still-connecting(timeout), -1=error
__declspec(dllexport) int __stdcall
Bridge_WsConnect(const wchar_t* account_str, const wchar_t* token,
                 char* out_buf, int buf_size)
{
    // Init state under lock — release before blocking wait
    {
        std::lock_guard<std::mutex> lk(g_ws_connmtx);
        if (g_ws_running) {
            char tmp[256];
            _snprintf_s(tmp, sizeof(tmp), _TRUNCATE,
                "{\"status\":\"ok\",\"connected\":%s,"
                "\"message\":\"already running\",\"reconnect_count\":%d}",
                g_ws_connected ? "true" : "false", (int)g_ws_reconnect_cnt);
            FillBuf(tmp, out_buf, buf_size);
            return g_ws_connected ? 0 : 1;
        }
        g_ws_account   = W2S(account_str);   // FIX: was std::to_string(int) → wrong value
        g_ws_token     = W2S(token);
        g_ws_running   = true;
        g_ws_connected = false;

        if (g_ws_connect_evt) { CloseHandle(g_ws_connect_evt); g_ws_connect_evt = nullptr; }
        g_ws_connect_evt = CreateEventA(nullptr, FALSE, FALSE, nullptr); // auto-reset
    }

    g_ws_thread = CreateThread(nullptr, 0, WsThreadProc, nullptr, 0, nullptr);
    if (!g_ws_thread) {
        std::lock_guard<std::mutex> lk(g_ws_connmtx);
        g_ws_running = false;
        FillBuf("{\"status\":\"error\",\"message\":\"CreateThread failed\"}", out_buf, buf_size);
        Log("WS: CreateThread failed err=" + std::to_string(GetLastError()));
        return -1;
    }
    Log("WS: thread launched account=" + g_ws_account);

    // Wait up to 3s for first connect attempt to complete
    if (g_ws_connect_evt) {
        DWORD wr = WaitForSingleObject(g_ws_connect_evt, 3000);
        if (wr == WAIT_TIMEOUT) {
            Log("WS: connect wait timed out (3s) — thread still running in background");
            FillBuf("{\"status\":\"ok\",\"connected\":false,"
                    "\"message\":\"connecting in background — check bridge.log\"}",
                    out_buf, buf_size);
            return 1;
        }
    }

    if (g_ws_connected) {
        char tmp[256];
        _snprintf_s(tmp, sizeof(tmp), _TRUNCATE,
            "{\"status\":\"ok\",\"connected\":true,\"account\":\"%s\","
            "\"reconnect_count\":%d}",
            g_ws_account.c_str(), (int)g_ws_reconnect_cnt);
        FillBuf(tmp, out_buf, buf_size);
        Log("WS: Bridge_WsConnect → OK account=" + g_ws_account);
        return 0;
    } else {
        std::string last_err;
        { std::lock_guard<std::mutex> lk(g_ws_connmtx); last_err = g_ws_last_error; }
        char tmp[512];
        _snprintf_s(tmp, sizeof(tmp), _TRUNCATE,
            "{\"status\":\"error\",\"connected\":false,\"message\":\"%s\"}",
            JE(last_err).c_str());
        FillBuf(tmp, out_buf, buf_size);
        Log("WS: Bridge_WsConnect → FAILED: " + last_err);
        return -1;
    }
}

// Poll next event from queue — returns 0 if none, 1 if event returned
__declspec(dllexport) int __stdcall
Bridge_WsPoll(char* out_buf, int buf_size)
{
    std::lock_guard<std::mutex> lk(g_ws_qmutex);
    if (g_ws_queue.empty()) {
        FillBuf("{\"event\":\"none\"}", out_buf, buf_size);
        return 0;
    }
    FillBuf(g_ws_queue.front(), out_buf, buf_size);
    g_ws_queue.pop_front();
    return 1;
}

// Returns JSON snapshot of current WS connection state — call any time for diagnostics.
// Return value: 1=connected, 0=disconnected
__declspec(dllexport) int __stdcall
Bridge_WsGetStatus(char* out_buf, int buf_size)
{
    int q_size;
    std::string last_err;
    {
        std::lock_guard<std::mutex> lk(g_ws_qmutex);
        q_size = (int)g_ws_queue.size();
    }
    {
        std::lock_guard<std::mutex> lk(g_ws_connmtx);
        last_err = g_ws_last_error;
    }
    char tmp[512];
    _snprintf_s(tmp, sizeof(tmp), _TRUNCATE,
        "{\"connected\":%s,\"account\":\"%s\","
        "\"reconnect_count\":%d,\"queue_size\":%d,"
        "\"last_error\":\"%s\"}",
        g_ws_connected ? "true" : "false",
        g_ws_account.c_str(),
        (int)g_ws_reconnect_cnt,
        q_size,
        JE(last_err).c_str());
    FillBuf(tmp, out_buf, buf_size);
    return g_ws_connected ? 1 : 0;
}

// Call in OnDeinit — stops thread and closes handles
__declspec(dllexport) void __stdcall
Bridge_WsDisconnect()
{
    {
        std::lock_guard<std::mutex> lk(g_ws_connmtx);
        g_ws_running   = false;
        g_ws_connected = false;
        if (g_ws_connect_evt) { CloseHandle(g_ws_connect_evt); g_ws_connect_evt = nullptr; }
    }
    if (g_ws_hWs) {
        WinHttpWebSocketClose(g_ws_hWs,
            WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, nullptr, 0);
        WinHttpCloseHandle(g_ws_hWs); g_ws_hWs = nullptr;
    }
    if (g_ws_hC)  { WinHttpCloseHandle(g_ws_hC);  g_ws_hC  = nullptr; }
    if (g_ws_hS)  { WinHttpCloseHandle(g_ws_hS);  g_ws_hS  = nullptr; }
    if (g_ws_thread) {
        WaitForSingleObject(g_ws_thread, 5000);
        CloseHandle(g_ws_thread); g_ws_thread = nullptr;
    }
    Log("WS: Disconnected");
}

// ─────────────────────────────────────────────────────────────────────────────
// Bridge_Register — kiểm tra license và đăng ký với backend server
//
// license_type: giá trị từ MQL4 MQLInfoInteger(MQL_LICENSE_TYPE)
//   0 = LICENSE_FREE  → từ chối ngay, không gọi backend
//   1 = LICENSE_DEMO
//   2 = LICENSE_FULL
//   3 = LICENSE_TIME
//
// out_buf: JSON response {"status":"ok","token":"...","license_type":"..."}
//                     or {"status":"error","message":"..."}
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
__declspec(dllexport) int __stdcall
Bridge_Register(int account, const wchar_t* server_broker, int license_type,
                char* out_buf, int buf_size)
{
    std::lock_guard<std::mutex> lock(g_mutex);
    LogReset();
    Log("=== Bridge_Register account="+std::to_string(account)
        +" lic="+std::to_string(license_type));

    // Map license int → string
    static const char* lic_names[] = {"FREE","DEMO","FULL","TIME"};
    std::string lic_str = (license_type>=0&&license_type<=3)
                          ? lic_names[license_type] : "UNKNOWN";

    std::string acc_str = std::to_string(account);
    std::string srv_str = W2S(server_broker);

    // Build JSON body
    std::string body =
        "{\"account_number\":\"" + JE(acc_str) + "\","
        "\"server_broker\":\""   + JE(srv_str) + "\","
        "\"license_type\":\""    + lic_str      + "\"}";

    Log("REGISTER_BODY: "+body);

    // POST /register to backend
    std::string resp = BackendPost("/register", body);
    Log("REGISTER_RESP: "+resp);

    if (resp.empty()) {
        FillBuf("{\"status\":\"error\","
                "\"message\":\"Cannot connect to license server. Check backend_url.txt.\"}",
                out_buf, buf_size);
        return -1;
    }

    FillBuf(resp, out_buf, buf_size);

    JVal rv = ParseJSON(resp);
    if (!rv.isObj() || rv.str("status") != "ok") {
        Log("Bridge_Register FAILED: "+rv.str("message"));
        return -1;
    }

    Log("=== Bridge_Register OK token="+rv.str("token").substr(0,30)+"...");
    return 0;
}

// Simple alive-check — call in OnInit to confirm DLL loaded without crashing.
// Returns 0 and fills out_buf with version JSON.
__declspec(dllexport) int __stdcall
Bridge_Ping(char* out_buf, int buf_size)
{
    try {
        std::string r = "{\"status\":\"ok\",\"version\":\"" BRIDGE_VERSION "\","
                        "\"sessions\":" + std::to_string(g_sessions.size()) +
                        ",\"ws_connected\":" + (g_ws_connected ? "true" : "false") + "}";
        FillBuf(r, out_buf, buf_size);
        Log("Bridge_Ping OK");
        return 0;
    } catch (const std::exception& e) {
        FillBuf((std::string("{\"status\":\"error\",\"message\":\"") + e.what() + "\"}").c_str(),
                out_buf, buf_size);
        return -1;
    } catch (...) {
        FillBuf("{\"status\":\"error\",\"message\":\"unknown exception in Bridge_Ping\"}",
                out_buf, buf_size);
        return -1;
    }
}

// Send an arbitrary UTF-8 JSON string from MQL4 EA back to backend over WS.
// Used by order handlers in the EA to report order_result / order_list.
__declspec(dllexport) int __stdcall
Bridge_WsSend(const wchar_t* msg_w)
{
    std::string msg = W2S(msg_w);
    bool ok = WsSend(msg);
    if (!ok) Log("Bridge_WsSend(" + std::to_string(msg.size()) + " bytes) failed");
    return ok ? 0 : -1;
}

} // extern "C"
