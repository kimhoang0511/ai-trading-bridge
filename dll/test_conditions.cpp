/**
 * test_conditions.cpp — Standalone test for PA helpers + EvalCond
 * Compile: cl /nologo /MD /O2 /EHsc /DTEST_MODE test_conditions.cpp
 * Run:     test_conditions.exe
 */

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <map>
#include <vector>
#include <cmath>
#include <algorithm>
#include <cstdio>
#include <cassert>

// ── Paste V struct + PA helpers + EvalCond từ AI_Bridge.cpp ──────────────────
// (copy §6, §7, §8 từ AI_Bridge.cpp vào đây — hoặc #include "AI_Bridge.cpp")
// Để đơn giản, copy inline:

struct JVal {
    enum { NUL=0, BOOL, NUM, STR, ARR, OBJ } type = NUL;
    bool b=false; double n=0; std::string s;
    std::vector<JVal> a; std::map<std::string,JVal> o;
    bool isObj() const{return type==OBJ;} bool isArr()const{return type==ARR;}
    bool isStr() const{return type==STR;} bool isNum()const{return type==NUM;}
    const JVal* get(const std::string& k)const{auto it=o.find(k);return it!=o.end()?&it->second:nullptr;}
    std::string str(const std::string& k,const std::string& d="")const{auto*v=get(k);return(v&&v->isStr())?v->s:d;}
    double num(const std::string& k,double d=0)const{auto*v=get(k);return(v&&v->isNum())?v->n:d;}
    int inum(const std::string& k,int d=0)const{return(int)num(k,d);}
    bool has(const std::string& k)const{return o.count(k)>0;}
};
static void jskip(const std::string&s,size_t&p){while(p<s.size()&&(s[p]==' '||s[p]=='\t'||s[p]=='\n'||s[p]=='\r'))++p;}
static std::string jstr(const std::string&s,size_t&p){++p;std::string r;bool esc=false;while(p<s.size()){char c=s[p++];if(esc){if(c=='n')r+='\n';else if(c=='r')r+='\r';else if(c=='t')r+='\t';else r+=c;esc=false;}else if(c=='\\'){esc=true;}else if(c=='"'){break;}else{r+=c;}}return r;}
static JVal jparse(const std::string&s,size_t&p);
static JVal jparse(const std::string&s,size_t&p){jskip(s,p);JVal v;if(p>=s.size())return v;char c=s[p];if(c=='"'){v.type=JVal::STR;v.s=jstr(s,p);}else if(c=='['){v.type=JVal::ARR;++p;jskip(s,p);while(p<s.size()&&s[p]!=']'){v.a.push_back(jparse(s,p));jskip(s,p);if(p<s.size()&&s[p]==',')++p;jskip(s,p);}if(p<s.size())++p;}else if(c=='{'){v.type=JVal::OBJ;++p;jskip(s,p);while(p<s.size()&&s[p]!='}'){std::string key=jstr(s,p);jskip(s,p);if(p<s.size()&&s[p]==':')++p;jskip(s,p);v.o[key]=jparse(s,p);jskip(s,p);if(p<s.size()&&s[p]==',')++p;jskip(s,p);}if(p<s.size())++p;}else if(c=='t'){v.type=JVal::BOOL;v.b=true;p+=4;}else if(c=='f'){v.type=JVal::BOOL;v.b=false;p+=5;}else if(c=='n'){v.type=JVal::NUL;p+=4;}else{v.type=JVal::NUM;size_t st=p;if(c=='-')++p;while(p<s.size()&&(isdigit(s[p])||s[p]=='.'||s[p]=='e'||s[p]=='E'||s[p]=='+'||s[p]=='-'))++p;try{v.n=std::stod(s.substr(st,p-st));}catch(...){v.n=0;}}return v;}
static JVal ParseJSON(const std::string&s){size_t p=0;return jparse(s,p);}

struct V {
    std::map<std::string,double> d;
    double get(const std::string&k,double def=0.0)const{auto it=d.find(k);return it!=d.end()?it->second:def;}
    double O(int i=0)const{return get("open_"+std::to_string(i));}
    double H(int i=0)const{return get("high_"+std::to_string(i));}
    double L(int i=0)const{return get("low_"+std::to_string(i));}
    double C(int i=0)const{return get("close_"+std::to_string(i));}
    double Vol(int i=0)const{return get("volume_"+std::to_string(i));}
    double point()const{return get("point",0.00001);}
};

// PA helpers (copy từ AI_Bridge.cpp §7)
static double body(const V&v,int i=0){return std::abs(v.C(i)-v.O(i));}
static double upper_wick(const V&v,int i=0){return v.H(i)-std::max(v.O(i),v.C(i));}
static double lower_wick(const V&v,int i=0){return std::min(v.O(i),v.C(i))-v.L(i);}
static double candle_range(const V&v,int i=0){return v.H(i)-v.L(i);}
static bool is_bull(const V&v,int i=0){return v.C(i)>v.O(i);}
static bool is_bear(const V&v,int i=0){return v.C(i)<v.O(i);}
static double body_ratio(const V&v,int i=0){double r=candle_range(v,i);return r>0?body(v,i)/r:0.0;}
static double body_mid(const V&v,int i=0){return(v.O(i)+v.C(i))/2.0;}
static bool is_doji(const V&v,int i=0,double th=0.1){return body_ratio(v,i)<th;}
static bool is_marubozu(const V&v,int i=0){return body_ratio(v,i)>=0.95;}
static bool is_hammer(const V&v,int i=0){double b=body(v,i),lw=lower_wick(v,i),uw=upper_wick(v,i);return b>0&&lw>=b*2.0&&uw<=b*0.3;}
static bool is_inverted_hammer(const V&v,int i=0){double b=body(v,i),uw=upper_wick(v,i),lw=lower_wick(v,i);return b>0&&uw>=b*2.0&&lw<=b*0.3;}
static bool is_shooting_star(const V&v,int i=0){return is_inverted_hammer(v,i)&&is_bear(v,i);}
static bool is_hanging_man(const V&v,int i=0){return is_hammer(v,i)&&is_bear(v,i);}
static bool is_pin_bar_bull(const V&v,int i=0){double lw=lower_wick(v,i),b=body(v,i),uw=upper_wick(v,i),r=candle_range(v,i);return r>0&&lw>=r*0.6&&b<=r*0.25&&uw<=r*0.15;}
static bool is_pin_bar_bear(const V&v,int i=0){double uw=upper_wick(v,i),b=body(v,i),lw=lower_wick(v,i),r=candle_range(v,i);return r>0&&uw>=r*0.6&&b<=r*0.25&&lw<=r*0.15;}
static bool is_pin_bar(const V&v,int i=0){return is_pin_bar_bull(v,i)||is_pin_bar_bear(v,i);}
static bool is_spinning_top(const V&v,int i=0){double b=body_ratio(v,i),uw=upper_wick(v,i),lw=lower_wick(v,i),r=candle_range(v,i);return r>0&&b>0.1&&b<0.35&&uw/r>0.2&&lw/r>0.2;}
static bool is_bull_engulfing(const V&v){return is_bear(v,1)&&is_bull(v,0)&&body(v,0)>body(v,1)&&v.H(0)>=v.H(1)&&v.L(0)<=v.L(1);}
static bool is_bear_engulfing(const V&v){return is_bull(v,1)&&is_bear(v,0)&&body(v,0)>body(v,1)&&v.H(0)>=v.H(1)&&v.L(0)<=v.L(1);}
static bool is_bull_harami(const V&v){return is_bear(v,1)&&is_bull(v,0)&&v.O(0)>v.C(1)&&v.C(0)<v.O(1)&&body(v,0)<body(v,1);}
static bool is_bear_harami(const V&v){return is_bull(v,1)&&is_bear(v,0)&&v.O(0)<v.C(1)&&v.C(0)>v.O(1)&&body(v,0)<body(v,1);}
static bool is_piercing(const V&v){return is_bear(v,1)&&is_bull(v,0)&&v.O(0)<v.L(1)&&v.C(0)>body_mid(v,1)&&v.C(0)<v.O(1);}
static bool is_dark_cloud(const V&v){return is_bull(v,1)&&is_bear(v,0)&&v.O(0)>v.H(1)&&v.C(0)<body_mid(v,1)&&v.C(0)>v.C(1);}
static bool is_tweezer_top(const V&v){return is_bull(v,1)&&is_bear(v,0)&&std::abs(v.H(0)-v.H(1))<=v.point()*3;}
static bool is_tweezer_bottom(const V&v){return is_bear(v,1)&&is_bull(v,0)&&std::abs(v.L(0)-v.L(1))<=v.point()*3;}
static bool is_morning_star(const V&v){return is_bear(v,2)&&body_ratio(v,2)>0.6&&body_ratio(v,1)<0.3&&is_bull(v,0)&&body_ratio(v,0)>0.6&&std::max(v.O(1),v.C(1))<v.C(2)&&v.C(0)>body_mid(v,2);}
static bool is_evening_star(const V&v){return is_bull(v,2)&&body_ratio(v,2)>0.6&&body_ratio(v,1)<0.3&&is_bear(v,0)&&body_ratio(v,0)>0.6&&std::min(v.O(1),v.C(1))>v.C(2)&&v.C(0)<body_mid(v,2);}
static bool is_three_white_soldiers(const V&v){return is_bull(v,2)&&is_bull(v,1)&&is_bull(v,0)&&v.C(1)>v.C(2)&&v.C(0)>v.C(1)&&v.O(1)>v.O(2)&&v.O(0)>v.O(1)&&body_ratio(v,2)>0.5&&body_ratio(v,1)>0.5&&body_ratio(v,0)>0.5;}
static bool is_three_black_crows(const V&v){return is_bear(v,2)&&is_bear(v,1)&&is_bear(v,0)&&v.C(1)<v.C(2)&&v.C(0)<v.C(1)&&v.O(1)<v.O(2)&&v.O(0)<v.O(1)&&body_ratio(v,2)>0.5&&body_ratio(v,1)>0.5&&body_ratio(v,0)>0.5;}
static bool is_three_inside_up(const V&v){return is_bear_harami(v)&&is_bull(v,0)&&v.C(0)>v.O(2);}
static bool is_three_inside_down(const V&v){return is_bull_harami(v)&&is_bear(v,0)&&v.C(0)<v.O(2);}
static bool is_higher_high(const V&v,int n=3){for(int i=0;i<n-1;i++)if(v.H(i)<=v.H(i+1))return false;return true;}
static bool is_lower_low(const V&v,int n=3){for(int i=0;i<n-1;i++)if(v.L(i)>=v.L(i+1))return false;return true;}
static bool is_higher_low(const V&v,int n=3){for(int i=0;i<n-1;i++)if(v.L(i)<=v.L(i+1))return false;return true;}
static bool is_lower_high(const V&v,int n=3){for(int i=0;i<n-1;i++)if(v.H(i)>=v.H(i+1))return false;return true;}
static bool is_uptrend(const V&v,int n=4){int h=std::max(n/2,2);return is_higher_high(v,h)&&is_higher_low(v,h);}
static bool is_downtrend(const V&v,int n=4){int h=std::max(n/2,2);return is_lower_high(v,h)&&is_lower_low(v,h);}
static bool is_consolidating(const V&v,int n=5){double hi=v.H(0),lo=v.L(0),ab=0;for(int i=0;i<n;i++){hi=std::max(hi,v.H(i));lo=std::min(lo,v.L(i));ab+=body(v,i);}ab/=n;return ab>0&&(hi-lo)<ab*n*0.5;}
static bool is_bull_breakout(const V&v,int n=20){double hi=v.H(1);for(int i=1;i<=n;i++)hi=std::max(hi,v.H(i));return v.C(0)>hi&&is_bull(v,0);}
static bool is_bear_breakout(const V&v,int n=20){double lo=v.L(1);for(int i=1;i<=n;i++)lo=std::min(lo,v.L(i));return v.C(0)<lo&&is_bear(v,0);}
static bool is_high_volume(const V&v,int n=5,double mult=1.5){if(n<1)return false;double avg=0;for(int i=1;i<=n;i++)avg+=v.Vol(i);avg/=n;return avg>0&&v.Vol(0)>avg*mult;}
static bool is_accelerating_up(const V&v,int n=3){for(int i=0;i<n;i++)if(v.C(i)<=v.C(i+1))return false;return true;}
static bool is_accelerating_down(const V&v,int n=3){for(int i=0;i<n;i++)if(v.C(i)>=v.C(i+1))return false;return true;}
static bool near_round_number(const V&v,int pip_range=10){double price=v.C(0),pt=v.point(),step=pt*1000;double nearest=std::round(price/step)*step;return std::abs(price-nearest)<pt*pip_range;}

// EvalCond (copy từ AI_Bridge.cpp §8)
static double GetVal(const JVal&node,const V&vals){if(node.isNum())return node.n;if(node.isStr())return vals.get(node.s);return 0.0;}
static bool EvalCond(const JVal&node,const V&vals);
static bool CallFn(const std::string&name,const JVal*pm,const V&v){
    int pi=pm?pm->inum("i",0):0,pn=pm?pm->inum("n",3):3;
    if(name=="is_bull")return is_bull(v,pi);if(name=="is_bear")return is_bear(v,pi);
    if(name=="is_doji")return is_doji(v,pi);if(name=="is_marubozu")return is_marubozu(v,pi);
    if(name=="is_hammer")return is_hammer(v,pi);if(name=="is_inverted_hammer")return is_inverted_hammer(v,pi);
    if(name=="is_shooting_star")return is_shooting_star(v,pi);if(name=="is_hanging_man")return is_hanging_man(v,pi);
    if(name=="is_pin_bar_bull")return is_pin_bar_bull(v,pi);if(name=="is_pin_bar_bear")return is_pin_bar_bear(v,pi);
    if(name=="is_pin_bar")return is_pin_bar(v,pi);if(name=="is_spinning_top")return is_spinning_top(v,pi);
    if(name=="is_bull_engulfing")return is_bull_engulfing(v);if(name=="is_bear_engulfing")return is_bear_engulfing(v);
    if(name=="is_bull_harami")return is_bull_harami(v);if(name=="is_bear_harami")return is_bear_harami(v);
    if(name=="is_piercing")return is_piercing(v);if(name=="is_dark_cloud")return is_dark_cloud(v);
    if(name=="is_tweezer_top")return is_tweezer_top(v);if(name=="is_tweezer_bottom")return is_tweezer_bottom(v);
    if(name=="is_morning_star")return is_morning_star(v);if(name=="is_evening_star")return is_evening_star(v);
    if(name=="is_three_white_soldiers")return is_three_white_soldiers(v);if(name=="is_three_black_crows")return is_three_black_crows(v);
    if(name=="is_three_inside_up")return is_three_inside_up(v);if(name=="is_three_inside_down")return is_three_inside_down(v);
    if(name=="is_higher_high")return is_higher_high(v,pn);if(name=="is_lower_low")return is_lower_low(v,pn);
    if(name=="is_higher_low")return is_higher_low(v,pn);if(name=="is_lower_high")return is_lower_high(v,pn);
    if(name=="is_uptrend")return is_uptrend(v,pn);if(name=="is_downtrend")return is_downtrend(v,pn);
    if(name=="is_consolidating")return is_consolidating(v,pn);
    if(name=="is_bull_breakout")return is_bull_breakout(v,pn);if(name=="is_bear_breakout")return is_bear_breakout(v,pn);
    if(name=="is_high_volume")return is_high_volume(v,pn);
    if(name=="is_accelerating_up")return is_accelerating_up(v,pn);if(name=="is_accelerating_down")return is_accelerating_down(v,pn);
    if(name=="near_round_number")return near_round_number(v);
    return false;
}
static bool EvalCond(const JVal&node,const V&vals){
    std::string type=node.str("type");
    if(type=="AND"){auto*a=node.get("args");if(!a||!a->isArr())return false;for(auto&x:a->a)if(!EvalCond(x,vals))return false;return true;}
    if(type=="OR") {auto*a=node.get("args");if(!a||!a->isArr())return false;for(auto&x:a->a)if(EvalCond(x,vals))return true;return false;}
    if(type=="NOT"){auto*a=node.get("arg");return a?!EvalCond(*a,vals):false;}
    if(type=="CMP"){auto*lp=node.get("left");auto*rp=node.get("right");if(!lp||!rp)return false;double lv=GetVal(*lp,vals),rv=GetVal(*rp,vals);std::string op=node.str("op");if(op==">")return lv>rv;if(op=="<")return lv<rv;if(op==">=")return lv>=rv;if(op=="<=")return lv<=rv;if(op=="==")return std::abs(lv-rv)<1e-9;if(op=="!=")return std::abs(lv-rv)>=1e-9;return false;}
    if(type=="FN"){return CallFn(node.str("name"),node.get("params"),vals);}
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST FRAMEWORK
// ═══════════════════════════════════════════════════════════════════════════════

static int g_pass=0, g_fail=0;

static void CHECK(const char* name, bool result, bool expected) {
    bool ok = (result == expected);
    printf("  [%s] %-35s got=%s  expected=%s\n",
           ok?"PASS":"FAIL", name,
           result?"true":"false", expected?"true":"false");
    ok ? g_pass++ : g_fail++;
}

// Helper: build V từ OHLC array  {O,H,L,C} mỗi candle, index 0=newest
static V makeV(std::initializer_list<std::initializer_list<double>> candles,
               std::map<std::string,double> extra={}) {
    V v; int i=0;
    for(auto& c:candles){
        auto it=c.begin();
        double o=*it++;double h=*it++;double l=*it++;double cl=*it;
        v.d["open_"+std::to_string(i)] =o;
        v.d["high_"+std::to_string(i)] =h;
        v.d["low_"+std::to_string(i)]  =l;
        v.d["close_"+std::to_string(i)]=cl;
        v.d["volume_"+std::to_string(i)]=1000;
        ++i;
    }
    v.d["point"]=0.00001;
    v.d["ask"]=v.C(0)+0.00010;
    v.d["bid"]=v.C(0);
    for(auto& kv:extra) v.d[kv.first]=kv.second;
    return v;
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST CASES
// ═══════════════════════════════════════════════════════════════════════════════

void test_single_candle() {
    printf("\n[Single Candle Patterns]\n");

    // Bullish candle: O<C
    V bull = makeV({{1.0800,1.0850,1.0790,1.0840}});
    CHECK("is_bull",          is_bull(bull),   true);
    CHECK("is_bear (expect false)", is_bear(bull),   false);

    // Bearish candle: O>C
    V bear = makeV({{1.0840,1.0860,1.0790,1.0800}});
    CHECK("is_bear",          is_bear(bear),   true);

    // Doji: tiny body
    V doji = makeV({{1.0820,1.0850,1.0790,1.0821}});
    CHECK("is_doji",          is_doji(doji),   true);

    // Hammer: long lower wick, small body, small upper wick
    // body=5pip, lower_wick=20pip, upper_wick=1pip
    V hammer = makeV({{1.0820,1.0826,1.0800,1.0825}});
    CHECK("is_hammer",        is_hammer(hammer), true);

    // Shooting star: long upper wick, small body, NO lower wick (L=C)
    V star = makeV({{1.0820,1.0845,1.0818,1.0818}});
    CHECK("is_shooting_star", is_shooting_star(star), true);

    // Pin bar bull: lower wick >= 60% range
    V pinbull = makeV({{1.0820,1.0825,1.0790,1.0822}});
    CHECK("is_pin_bar_bull",  is_pin_bar_bull(pinbull), true);

    // Pin bar bear: upper wick >= 60% range
    V pinbear = makeV({{1.0820,1.0855,1.0818,1.0822}});
    CHECK("is_pin_bar_bear",  is_pin_bar_bear(pinbear), true);

    // Marubozu: almost no wicks
    V maru = makeV({{1.0800,1.0851,1.0799,1.0850}});
    CHECK("is_marubozu",      is_marubozu(maru), true);
}

void test_two_candle() {
    printf("\n[Two Candle Patterns]\n");

    // Bull Engulfing: nến 1 là bear, nến 0 là bull lớn hơn bao trùm
    // Candle 1 (prev): O=1.0830 H=1.0835 L=1.0810 C=1.0815  (bear)
    // Candle 0 (curr): O=1.0808 H=1.0840 L=1.0805 C=1.0838  (bull, engulfs)
    V bull_eng = makeV({
        {1.0808,1.0840,1.0805,1.0838},  // i=0 current bull
        {1.0830,1.0835,1.0810,1.0815},  // i=1 prev bear
    });
    CHECK("is_bull_engulfing",  is_bull_engulfing(bull_eng),  true);
    CHECK("is_bear_engulfing (expect false)", is_bear_engulfing(bull_eng), false);

    // Bear Engulfing
    V bear_eng = makeV({
        {1.0830,1.0835,1.0805,1.0808},  // i=0 current bear, engulfs
        {1.0810,1.0832,1.0808,1.0828},  // i=1 prev bull
    });
    CHECK("is_bear_engulfing",  is_bear_engulfing(bear_eng),  true);

    // Tweezer Bottom: same lows, bear→bull
    V tweezer_bot = makeV({
        {1.0810,1.0830,1.0800,1.0825},  // i=0 bull
        {1.0830,1.0835,1.0800,1.0812},  // i=1 bear, same low
    });
    CHECK("is_tweezer_bottom", is_tweezer_bottom(tweezer_bot), true);

    // Piercing line: bear candle then bull opens below low, closes above midpoint
    V piercing = makeV({
        {1.0790,1.0825,1.0788,1.0820},  // i=0 bull, opens below prev low
        {1.0830,1.0835,1.0795,1.0800},  // i=1 bear
    });
    CHECK("is_piercing",       is_piercing(piercing), true);
}

void test_three_candle() {
    printf("\n[Three Candle Patterns]\n");

    // Morning Star: big bear | small body | big bull confirm
    // i=2 big bear, i=1 small doji, i=0 big bull
    V morning = makeV({
        {1.0790,1.0830,1.0788,1.0828},  // i=0 big bull (close > midpoint of i=2)
        {1.0772,1.0778,1.0768,1.0774},  // i=1 small doji (gaps below i=2 close)
        {1.0830,1.0835,1.0795,1.0800},  // i=2 big bear
    });
    CHECK("is_morning_star",   is_morning_star(morning), true);

    // Evening Star: big bull | small body | big bear confirm
    V evening = makeV({
        {1.0850,1.0852,1.0810,1.0815},  // i=0 big bear
        {1.0870,1.0876,1.0868,1.0872},  // i=1 small doji (gaps above i=2 close)
        {1.0820,1.0865,1.0818,1.0860},  // i=2 big bull
    });
    CHECK("is_evening_star",   is_evening_star(evening), true);

    // Three White Soldiers
    V soldiers = makeV({
        {1.0840,1.0860,1.0838,1.0858},  // i=0
        {1.0820,1.0842,1.0818,1.0840},  // i=1
        {1.0800,1.0822,1.0798,1.0820},  // i=2
    });
    CHECK("is_three_white_soldiers", is_three_white_soldiers(soldiers), true);

    // Three Black Crows
    V crows = makeV({
        {1.0840,1.0842,1.0820,1.0822},  // i=0
        {1.0860,1.0862,1.0840,1.0842},  // i=1
        {1.0880,1.0882,1.0860,1.0862},  // i=2
    });
    CHECK("is_three_black_crows", is_three_black_crows(crows), true);
}

void test_market_structure() {
    printf("\n[Market Structure]\n");

    // Uptrend: higher highs AND higher lows
    V uptrend = makeV({
        {1.0840,1.0870,1.0838,1.0860},  // i=0 highest
        {1.0820,1.0850,1.0818,1.0840},  // i=1
        {1.0800,1.0830,1.0798,1.0820},  // i=2
        {1.0780,1.0810,1.0778,1.0800},  // i=3
    });
    CHECK("is_uptrend",   is_uptrend(uptrend,4),   true);
    CHECK("is_downtrend (expect false)", is_downtrend(uptrend,4), false);

    // Downtrend: lower highs AND lower lows
    V downtrend = makeV({
        {1.0800,1.0810,1.0778,1.0780},  // i=0 lowest
        {1.0820,1.0830,1.0798,1.0800},  // i=1
        {1.0840,1.0850,1.0818,1.0820},  // i=2
        {1.0860,1.0870,1.0838,1.0840},  // i=3
    });
    CHECK("is_downtrend",  is_downtrend(downtrend,4), true);

    // Accelerating up: each close higher than previous
    V accel = makeV({
        {1.0840,1.0850,1.0838,1.0848},  // i=0 highest close
        {1.0820,1.0840,1.0818,1.0835},  // i=1
        {1.0800,1.0825,1.0798,1.0820},  // i=2
        {1.0780,1.0805,1.0778,1.0800},  // i=3
    });
    CHECK("is_accelerating_up", is_accelerating_up(accel,3), true);
}

void test_indicator_comparison() {
    printf("\n[Indicator Comparison (CMP)]\n");

    // RSI > 50
    V v1; v1.d["rsi14"]=62.5; v1.d["point"]=0.00001;
    JVal cond1=ParseJSON(R"({"type":"CMP","left":"rsi14","op":">","right":50})");
    CHECK("rsi14 > 50 (62.5)", EvalCond(cond1,v1), true);

    // RSI < 30 (oversold)
    V v2; v2.d["rsi14"]=28.3; v2.d["point"]=0.00001;
    JVal cond2=ParseJSON(R"({"type":"CMP","left":"rsi14","op":"<","right":30})");
    CHECK("rsi14 < 30 (28.3)", EvalCond(cond2,v2), true);

    // MA crossover: ma20 > ma50 AND ma20_prev < ma50_prev
    V v3; v3.d["ma20"]=1.0820; v3.d["ma50"]=1.0815;
          v3.d["ma20_prev"]=1.0810; v3.d["ma50_prev"]=1.0812; v3.d["point"]=0.00001;
    JVal cross=ParseJSON(R"({
        "type":"AND","args":[
            {"type":"CMP","left":"ma20","op":">","right":"ma50"},
            {"type":"CMP","left":"ma20_prev","op":"<","right":"ma50_prev"}
        ]
    })");
    CHECK("MA20 crosses above MA50", EvalCond(cross,v3), true);

    // MA no crossover (both ma20 > ma50)
    V v4; v4.d["ma20"]=1.0820; v4.d["ma50"]=1.0815;
          v4.d["ma20_prev"]=1.0818; v4.d["ma50_prev"]=1.0812; v4.d["point"]=0.00001;
    CHECK("MA20 no crossover (expect false)", EvalCond(cross,v4), false);
}

void test_composite_strategies() {
    printf("\n[Composite Strategies]\n");

    // Strategy 1: Bull Engulfing + RSI oversold + Uptrend
    V s1 = makeV({
        {1.0808,1.0840,1.0805,1.0838},  // i=0 bull engulfs
        {1.0830,1.0835,1.0810,1.0815},  // i=1 bear
        {1.0800,1.0825,1.0798,1.0820},  // i=2 for uptrend
        {1.0780,1.0805,1.0778,1.0800},  // i=3
    }, {{"rsi14",42.0}});

    // Note: is_bull_engulfing requires L[0]<=L[1], which conflicts with
    // is_higher_low (L[0]>L[1]) — use is_higher_high instead as trend filter.
    JVal strat1=ParseJSON(R"({
        "type":"AND","args":[
            {"type":"FN","name":"is_bull_engulfing"},
            {"type":"CMP","left":"rsi14","op":"<","right":50},
            {"type":"FN","name":"is_higher_high","params":{"n":3}}
        ]
    })");
    CHECK("BullEngulfing+RSI<50+HH(3)", EvalCond(strat1,s1), true);

    // Strategy 2: Pin Bar Bear + RSI overbought
    V s2 = makeV({
        {1.0820,1.0855,1.0818,1.0822},  // i=0 pin bar bear
    }, {{"rsi14",72.0}});

    JVal strat2=ParseJSON(R"({
        "type":"AND","args":[
            {"type":"FN","name":"is_pin_bar_bear"},
            {"type":"CMP","left":"rsi14","op":">","right":70}
        ]
    })");
    CHECK("PinBarBear+RSI>70", EvalCond(strat2,s2), true);

    // Strategy 3: Morning Star + confirm
    V s3 = makeV({
        {1.0790,1.0830,1.0788,1.0828},  // i=0 big bull
        {1.0772,1.0778,1.0768,1.0774},  // i=1 doji
        {1.0830,1.0835,1.0795,1.0800},  // i=2 big bear
    }, {{"rsi14",35.0}});

    JVal strat3=ParseJSON(R"({
        "type":"AND","args":[
            {"type":"FN","name":"is_morning_star"},
            {"type":"CMP","left":"rsi14","op":"<","right":40}
        ]
    })");
    CHECK("MorningStar+RSI<40", EvalCond(strat3,s3), true);

    // Strategy 4: NOT condition
    V s4 = makeV({{1.0800,1.0850,1.0795,1.0840}});
    s4.d["rsi14"]=80.0;
    JVal strat4=ParseJSON(R"({
        "type":"AND","args":[
            {"type":"FN","name":"is_bull"},
            {"type":"NOT","arg":{"type":"CMP","left":"rsi14","op":">","right":75}}
        ]
    })");
    CHECK("Bull + NOT(RSI>75) → false", EvalCond(strat4,s4), false);

    // Strategy 5: OR condition
    V s5=makeV({{1.0808,1.0840,1.0805,1.0838},{1.0830,1.0835,1.0810,1.0815}});
    s5.d["rsi14"]=55.0;
    JVal strat5=ParseJSON(R"({
        "type":"OR","args":[
            {"type":"FN","name":"is_bull_engulfing"},
            {"type":"CMP","left":"rsi14","op":">","right":70}
        ]
    })");
    CHECK("BullEngulfing OR RSI>70", EvalCond(strat5,s5), true);
}

void test_no_signal() {
    printf("\n[No Signal cases]\n");

    // Bull engulfing condition but data doesn't match
    V v = makeV({
        {1.0800,1.0840,1.0798,1.0810},  // i=0 bull but small
        {1.0790,1.0830,1.0788,1.0820},  // i=1 also bull (not bear→bull)
    });
    JVal cond=ParseJSON(R"({"type":"FN","name":"is_bull_engulfing"})");
    CHECK("Bull engulfing fails (prev=bull)", EvalCond(cond,v), false);

    // RSI condition not met
    V v2; v2.d["rsi14"]=45.0; v2.d["point"]=0.00001;
    JVal cond2=ParseJSON(R"({"type":"CMP","left":"rsi14","op":">","right":50})");
    CHECK("RSI<50 fails >50 check", EvalCond(cond2,v2), false);
}

// ═══════════════════════════════════════════════════════════════════════════════
int main() {
    printf("==========================================================\n");
    printf("  AI Bridge — Condition Engine Test Suite\n");
    printf("==========================================================\n");

    test_single_candle();
    test_two_candle();
    test_three_candle();
    test_market_structure();
    test_indicator_comparison();
    test_composite_strategies();
    test_no_signal();

    printf("\n==========================================================\n");
    printf("  RESULT: %d passed,  %d failed  (total %d)\n",
           g_pass, g_fail, g_pass+g_fail);
    printf("==========================================================\n");
    return g_fail > 0 ? 1 : 0;
}
