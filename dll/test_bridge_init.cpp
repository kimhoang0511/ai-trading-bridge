/**
 * test_bridge_init.cpp
 *
 * Standalone test: loads AI_Bridge.dll dynamically, calls Bridge_Init with a
 * test prompt, then prints the full raw JSON response AND each parsed field
 * so you can verify everything is correct before running in MT4.
 *
 * Build (x86 MSVC, same env as build.bat):
 *   cl /nologo /MD /O2 /EHsc /W3 test_bridge_init.cpp /Fe:test_bridge_init.exe
 *
 * Run:
 *   test_bridge_init.exe
 * Or pass custom args:
 *   test_bridge_init.exe "EURUSD" "Buy when EMA8 crosses above EMA21 and RSI14 < 60" 60
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ── DLL function pointer types (must match AI_Bridge.def / __stdcall) ──────────
typedef int  (__stdcall *FnBridgeInit)(int sid, const char* prompt, const char* symbol,
                                       int tf, double lot, int sl, int tp, int account,
                                       char* out_buf, int buf_size);
typedef int  (__stdcall *FnBridgeVersion)(char* out_buf, int buf_size);

// ── Simple JSON field extractors (no external deps) ──────────────────────────

// Extract string value for key: "key":"VALUE"
static int extract_str(const char* json, const char* key, char* out, int out_sz)
{
    char needle[128];
    _snprintf_s(needle, sizeof(needle), _TRUNCATE, "\"%s\":\"", key);
    const char* p = strstr(json, needle);
    if (!p) { out[0]='\0'; return 0; }
    p += strlen(needle);
    int i = 0;
    while (*p && *p != '"' && i < out_sz-1) out[i++] = *p++;
    out[i] = '\0';
    return i;
}

// Extract numeric value for key: "key":NUMBER
static double extract_num(const char* json, const char* key)
{
    char needle[128];
    _snprintf_s(needle, sizeof(needle), _TRUNCATE, "\"%s\":", key);
    const char* p = strstr(json, needle);
    if (!p) return 0.0;
    p += strlen(needle);
    return atof(p);
}

// Count occurrences of substr in str
static int count_substr(const char* str, const char* sub)
{
    int count = 0;
    const char* p = str;
    while ((p = strstr(p, sub)) != NULL) { count++; p++; }
    return count;
}

// Print one indicator block from JSON
// Finds the Nth occurrence of {"name" in the string
static void print_indicator(const char* json, int n)
{
    const char* p = json;
    int found = 0;
    while ((p = strstr(p, "{\"name\"")) != NULL) {
        if (found == n) {
            // Find matching closing brace
            int depth = 0, i = 0;
            char block[512]; block[0]='\0';
            for (i = 0; p[i] && i < 511; i++) {
                block[i] = p[i];
                if (p[i]=='{') depth++;
                else if (p[i]=='}') { depth--; if (depth==0){ block[i+1]='\0'; break; } }
            }
            // Parse fields from block
            char name[64], type[32];
            extract_str(block, "name",   name, sizeof(name));
            extract_str(block, "type",   type, sizeof(type));
            int period  = (int)extract_num(block, "period");
            int method  = (int)extract_num(block, "method");
            int applied = (int)extract_num(block, "applied");
            int shift   = (int)extract_num(block, "shift");
            printf("  [%d] name=%-16s  type=%-12s  period=%3d  method=%d  applied=%d  shift=%d\n",
                   n, name, type, period, method, applied, shift);
            return;
        }
        found++;
        p++;
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, char* argv[])
{
    // Test parameters — override from command line if provided
    const char* symbol = (argc > 1) ? argv[1] : "EURUSD";
    const char* prompt = (argc > 2) ? argv[2]
        : "Buy EURUSD when MA20 crosses above MA50 and RSI14 is below 65. Lot 0.1, SL 50 pips, TP 100 pips.";
    int tf  = (argc > 3) ? atoi(argv[3]) : 60;
    double lot = 0.1;
    int sl = 50, tp = 100;

    printf("============================================================\n");
    printf(" AI Bridge — Bridge_Init Test\n");
    printf("============================================================\n");
    printf(" Symbol : %s\n", symbol);
    printf(" TF     : %d min\n", tf);
    printf(" Prompt : %s\n", prompt);
    printf("------------------------------------------------------------\n\n");

    // 1. Load DLL (look in current dir first, then Libraries)
    HMODULE hDll = LoadLibraryA("AI_Bridge.dll");
    if (!hDll) {
        // Try ..\dist\dll\ (build output location)
        hDll = LoadLibraryA("..\\dist\\dll\\AI_Bridge.dll");
    }
    if (!hDll) {
        printf("[ERROR] Cannot load AI_Bridge.dll  (err=%lu)\n", GetLastError());
        printf("        Place AI_Bridge.dll next to this exe, or in ..\\dist\\dll\\\n");
        printf("Press Enter to exit..."); getchar();
        return 1;
    }
    printf("[OK] AI_Bridge.dll loaded.\n\n");

    // 2. Get DLL version
    FnBridgeVersion fnVer = (FnBridgeVersion)GetProcAddress(hDll, "_Bridge_Version@8");
    if (!fnVer) fnVer = (FnBridgeVersion)GetProcAddress(hDll, "Bridge_Version");
    if (fnVer) {
        char vbuf[64] = {};
        fnVer(vbuf, sizeof(vbuf));
        printf("[INFO] DLL version: %s\n\n", vbuf);
    }

    // 3. Get Bridge_Init
    FnBridgeInit fnInit = (FnBridgeInit)GetProcAddress(hDll, "_Bridge_Init@36");
    if (!fnInit) fnInit = (FnBridgeInit)GetProcAddress(hDll, "Bridge_Init");
    if (!fnInit) {
        printf("[ERROR] Bridge_Init not found in DLL.\n");
        FreeLibrary(hDll);
        printf("Press Enter to exit..."); getchar();
        return 1;
    }

    // 4. Call Bridge_Init
    const int BUF = 65536;
    char* out = (char*)calloc(BUF, 1);
    if (!out) { printf("[ERROR] OOM\n"); return 1; }

    printf("[...] Calling Bridge_Init (this calls Claude API — may take 5-15s)...\n\n");
    int rc = fnInit(0, prompt, symbol, tf, lot, sl, tp, 12345, out, BUF);

    // 5. Print raw response
    printf("------------------------------------------------------------\n");
    printf(" RAW RESPONSE  (rc=%d)\n", rc);
    printf("------------------------------------------------------------\n");
    // Print full response, splitting at commas for readability
    int rlen = (int)strlen(out);
    printf(" Length: %d chars\n\n", rlen);

    // Print full JSON on one line first
    printf(" JSON: %s\n\n", out);

    // 6. Check status
    char status[32];
    extract_str(out, "status", status, sizeof(status));
    printf("------------------------------------------------------------\n");
    printf(" PARSED FIELDS\n");
    printf("------------------------------------------------------------\n");
    printf(" status   : %s\n", status);

    if (strcmp(status, "ok") != 0) {
        char msg[512];
        extract_str(out, "message", msg, sizeof(msg));
        printf(" message  : %s\n", msg);
        printf("\n[FAIL] Bridge_Init returned error. Check api_key.txt and prompt.\n");
        free(out);
        FreeLibrary(hDll);
        printf("\nPress Enter to exit..."); getchar();
        return 1;
    }

    // 7. Parse and print all fields
    char action[16], version[32];
    extract_str(out, "action",  action,  sizeof(action));
    extract_str(out, "version", version, sizeof(version));
    int    tf_out     = (int)extract_num(out, "tf");
    int    ohlc_bars  = (int)extract_num(out, "ohlc_bars");

    printf(" action   : %s\n", action);
    printf(" tf       : %d  (%s)\n", tf_out,
           tf_out==1?"M1":tf_out==5?"M5":tf_out==15?"M15":tf_out==30?"M30":
           tf_out==60?"H1":tf_out==240?"H4":tf_out==1440?"D1":"other");
    printf(" ohlc_bars: %d\n", ohlc_bars);
    printf(" version  : %s\n", version);

    // 8. Count and print indicators
    int ind_count = count_substr(out, "{\"name\"");
    printf("\n indicators_count: %d\n", ind_count);

    if (ind_count == 0) {
        // Check if indicators key exists but is empty array
        if (strstr(out, "\"indicators\":[]"))
            printf("  => \"indicators\":[] — Claude returned NO indicators (PA-only strategy)\n");
        else if (!strstr(out, "\"indicators\":"))
            printf("  => \"indicators\" key MISSING from response — DLL bug?\n");
        else
            printf("  => \"indicators\" present but could not parse any {\"name\" objects\n");
    } else {
        for (int i = 0; i < ind_count; i++)
            print_indicator(out, i);
    }

    // 9. Verify condition exists
    int has_condition = (strstr(out, "\"condition\"") != NULL) ? 1 : 0;
    // Note: condition is stored internally in DLL — not returned in out_buf
    // Check by looking at the "indicators" section only
    printf("\n------------------------------------------------------------\n");
    printf(" DIAGNOSIS\n");
    printf("------------------------------------------------------------\n");

    int ok = 1;
    if (strcmp(action, "BUY") != 0 && strcmp(action, "SELL") != 0) {
        printf(" [WARN] action is not BUY/SELL: '%s'\n", action); ok=0;
    } else {
        printf(" [OK] action = %s\n", action);
    }
    if (tf_out <= 0) {
        printf(" [WARN] tf = %d (should be > 0)\n", tf_out); ok=0;
    } else {
        printf(" [OK] tf = %d\n", tf_out);
    }
    if (ohlc_bars <= 0) {
        printf(" [WARN] ohlc_bars = %d (should be > 0)\n", ohlc_bars); ok=0;
    } else {
        printf(" [OK] ohlc_bars = %d\n", ohlc_bars);
    }
    if (ind_count == 0) {
        printf(" [WARN] No indicators — MA/RSI lines will NOT be drawn on chart\n");
        printf("        Check prompt mentions specific indicator names (MA20, RSI14, etc.)\n");
    } else {
        printf(" [OK] %d indicator(s) parsed\n", ind_count);
    }

    printf("\n%s\n",
           ok && ind_count > 0 ? " RESULT: PASS — DLL response looks correct"
                               : " RESULT: PARTIAL — see warnings above");
    printf("============================================================\n");

    free(out);
    FreeLibrary(hDll);
    printf("\nPress Enter to exit..."); getchar();
    return 0;
}
