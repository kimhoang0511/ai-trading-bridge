/**
 * file_bridge_mt5.cpp — AI Bridge File IPC server for MT4 + MT5
 *
 * Watches Common\Files for ai_bridge_req.json (MT4) and
 * ai_bridge_req_mt5.json (MT5) using 2 independent worker threads,
 * dispatches using AI_Bridge.cpp logic protected by a shared mutex,
 * writes responses to ai_bridge_resp.json / ai_bridge_resp_mt5.json.
 *
 * Build: build_exe_mt5.bat  (MSVC x64)
 */

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <objidl.h>
#include <gdiplus.h>
#pragma comment(lib, "gdiplus.lib")
#include <shellapi.h>
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#include <string>
#include <atomic>
#include <thread>
#include <mutex>
#include <fstream>
#include <queue>
#include <shlobj.h>
#pragma comment(lib, "shell32.lib")
#include "logo_data.h"

#define HEADER_H 55

#include "AI_Bridge.cpp"

// ── IPC Encryption (XOR stream + hex, prefix "ENC:") ─────────────────────────
static const uint8_t IPC_KEY[32] = {
    0x4A,0x1F,0xB3,0x7E,0x9C,0x52,0xD8,0x23,
    0xAE,0x67,0x3B,0xF4,0x81,0x0D,0xC9,0x56,
    0x74,0xEB,0x2A,0x98,0x3F,0xD1,0x6C,0x47,
    0xB2,0x85,0x1E,0xFA,0x39,0xC4,0x70,0x8B
};

static std::string IpcDecrypt(const std::string& data) {
    if (data.size() < 4 || data.substr(0, 4) != "ENC:") return data;
    const std::string hex = data.substr(4);
    std::string out;
    out.reserve(hex.size() / 2);
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        unsigned int bv = 0;
        sscanf_s(hex.c_str() + i, "%2x", &bv);
        out += (char)((uint8_t)bv ^ IPC_KEY[(i / 2) % 32]);
    }
    return out;
}

static std::string IpcEncrypt(const std::string& data) {
    std::string out = "ENC:";
    out.reserve(4 + data.size() * 2);
    for (size_t i = 0; i < data.size(); i++) {
        char hex[3];
        _snprintf_s(hex, sizeof(hex), _TRUNCATE, "%02x",
                    (uint8_t)((uint8_t)data[i] ^ IPC_KEY[i % 32]));
        out += hex;
    }
    return out;
}

// ── Control IDs ───────────────────────────────────────────────────────────────
#define IDC_BTN_START  101
#define IDC_BTN_STOP   102
#define IDC_BTN_CLEAR  103
#define IDC_EDIT_LOG   104
#define IDC_BTN_CHAT   105
#define IDC_BTN_QR     106
#define WM_APPEND_LOG    (WM_USER + 1)
#define WM_UPDATE_STATUS (WM_USER + 2)
#define WM_TOKEN_READY   (WM_USER + 3)
#define WM_QR_READY      (WM_USER + 4)
#define WM_TRAY_ICON     (WM_USER + 5)

// ── Globals ───────────────────────────────────────────────────────────────────
static HWND              g_hwnd          = nullptr;
static HWND              g_hwnd_log      = nullptr;
static HWND              g_hwnd_start    = nullptr;
static HWND              g_hwnd_stop     = nullptr;
static HWND              g_hwnd_stat     = nullptr;
static HWND              g_hwnd_ea_stat  = nullptr;
static HWND              g_hwnd_srv_stat = nullptr;
static std::atomic<bool> g_running       { false };
static std::thread       g_thread_read;
static std::thread       g_thread_write;
static ULONG_PTR         g_gdiplus_token = 0;
static Gdiplus::Image*   g_logo_img      = nullptr;
static HICON             g_icon_big      = nullptr;
static HICON             g_icon_small    = nullptr;

#define IDI_APPICON 1
static std::string       g_chat_url;
static std::mutex        g_chat_url_mutex;
static HWND              g_hwnd_chat_btn = nullptr;
static HWND              g_hwnd_qr_btn   = nullptr;
static bool              g_show_log      = true;   // debug: show log area
static HWND              g_hwnd_qr_dlg   = nullptr;
static Gdiplus::Image*   g_qr_img        = nullptr;
static NOTIFYICONDATAA   g_nid           = {};
static bool              g_tray_added    = false;
static bool              g_ea_was_connected = false;

static void LoadLogo() {
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, g_logo_png_size);
    if (!hMem) return;
    void* pMem = GlobalLock(hMem);
    memcpy(pMem, g_logo_png, g_logo_png_size);
    GlobalUnlock(hMem);
    IStream* pStream = nullptr;
    if (SUCCEEDED(CreateStreamOnHGlobal(hMem, TRUE, &pStream))) {
        g_logo_img = Gdiplus::Image::FromStream(pStream);
        pStream->Release();
    }
}

static HICON IconFromGdiplus(Gdiplus::Image* img, int size) {
    if (!img) return nullptr;
    Gdiplus::Bitmap bmp(size, size, PixelFormat32bppARGB);
    Gdiplus::Graphics g(&bmp);
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.DrawImage(img, 0, 0, size, size);
    HICON hIcon = nullptr;
    bmp.GetHICON(&hIcon);
    return hIcon;
}

static std::atomic<bool>  g_srv_connected    { false };
static std::atomic<DWORD> g_last_ea_tick_mt4 { 0 };
static std::atomic<DWORD> g_last_ea_tick_mt5 { 0 };
static std::string        g_dir;             // Common\Files\ path

static std::string ResolveCommonDir() {
    char appdata[MAX_PATH] = {};
    if (SUCCEEDED(SHGetFolderPathA(nullptr, CSIDL_APPDATA, nullptr, 0, appdata))) {
        std::string d = std::string(appdata)
                      + "\\MetaQuotes\\Terminal\\Common\\Files\\";
        CreateDirectoryA(d.c_str(), nullptr);
        return d;
    }
    return ".\\";
}

// ── URL encoder ───────────────────────────────────────────────────────────────
static std::string UrlEncode(const std::string& s) {
    std::string out;
    for (unsigned char c : s) {
        if (isalnum(c) || c=='-' || c=='_' || c=='.' || c=='~') { out += c; }
        else { char b[4]; _snprintf_s(b,sizeof(b),_TRUNCATE,"%%%02X",c); out+=b; }
    }
    return out;
}

// ── WinHTTP GET → raw bytes (for QR image) ────────────────────────────────────
static std::vector<uint8_t> HttpGetBytes(const wchar_t* host, const wchar_t* path) {
    std::vector<uint8_t> result;
    HINTERNET hS = WinHttpOpen(L"AI_Bridge_QR/1.0",
                               WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                               WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hS) return result;
    HINTERNET hC = WinHttpConnect(hS, host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!hC) { WinHttpCloseHandle(hS); return result; }
    HINTERNET hR = WinHttpOpenRequest(hC, L"GET", path, nullptr,
                                      WINHTTP_NO_REFERER,
                                      WINHTTP_DEFAULT_ACCEPT_TYPES,
                                      WINHTTP_FLAG_SECURE);
    if (hR && WinHttpSendRequest(hR, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                  WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
           && WinHttpReceiveResponse(hR, nullptr)) {
        DWORD av = 0;
        while (WinHttpQueryDataAvailable(hR, &av) && av) {
            size_t old = result.size(); result.resize(old + av);
            DWORD got = 0;
            WinHttpReadData(hR, result.data() + old, av, &got);
            result.resize(old + got);
        }
    }
    if (hR) WinHttpCloseHandle(hR);
    WinHttpCloseHandle(hC);
    WinHttpCloseHandle(hS);
    return result;
}

static Gdiplus::Image* ImageFromBytes(const std::vector<uint8_t>& bytes) {
    if (bytes.empty()) return nullptr;
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (!hMem) return nullptr;
    void* p = GlobalLock(hMem);
    memcpy(p, bytes.data(), bytes.size());
    GlobalUnlock(hMem);
    IStream* pStream = nullptr;
    if (FAILED(CreateStreamOnHGlobal(hMem, TRUE, &pStream))) return nullptr;
    Gdiplus::Image* img = Gdiplus::Image::FromStream(pStream);
    pStream->Release();
    return img;
}

// ── QR dialog ────────────────────────────────────────────────────────────────
static LRESULT CALLBACK QrWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_QR_READY:
        InvalidateRect(hwnd, nullptr, TRUE);
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC hdc = BeginPaint(hwnd, &ps);
        RECT rc; GetClientRect(hwnd, &rc);
        HBRUSH bg = CreateSolidBrush(RGB(255,255,255));
        FillRect(hdc, &rc, bg); DeleteObject(bg);
        if (g_qr_img && g_qr_img->GetLastStatus() == Gdiplus::Ok) {
            Gdiplus::Graphics g(hdc);
            g.SetInterpolationMode(Gdiplus::InterpolationModeNearestNeighbor);
            g.DrawImage(g_qr_img, 20, 20, 280, 280);
        } else {
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, RGB(100,100,100));
            RECT tr = {20,120,300,160};
            DrawTextA(hdc, "Loading QR...", -1, &tr,
                      DT_CENTER | DT_SINGLELINE | DT_VCENTER);
        }
        {
          std::string url_snap; { std::lock_guard<std::mutex> lk(g_chat_url_mutex); url_snap = g_chat_url; }
          if (!url_snap.empty()) {
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, RGB(60, 90, 180));
            HFONT hf = CreateFontA(11,0,0,0,FW_NORMAL,FALSE,TRUE,FALSE,
                DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,
                CLEARTYPE_QUALITY,DEFAULT_PITCH|FF_SWISS,"Segoe UI");
            HFONT ho = (HFONT)SelectObject(hdc, hf);
            RECT ur = {10, 308, 310, 328};
            DrawTextA(hdc, url_snap.c_str(), -1, &ur,
                      DT_CENTER | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
            SelectObject(hdc, ho); DeleteObject(hf);
          }
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_CLOSE:
        g_hwnd_qr_dlg = nullptr;
        delete g_qr_img; g_qr_img = nullptr;
        DestroyWindow(hwnd);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void ShowQrDialog(HINSTANCE hInst) {
    std::string url;
    { std::lock_guard<std::mutex> lk(g_chat_url_mutex); url = g_chat_url; }
    if (url.empty()) return;
    if (g_hwnd_qr_dlg) { SetForegroundWindow(g_hwnd_qr_dlg); return; }
    static bool registered = false;
    if (!registered) {
        WNDCLASSA wc = {};
        wc.lpfnWndProc   = QrWndProc;
        wc.hInstance     = hInst;
        wc.lpszClassName = "AIBridgeMT5QR";
        wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
        wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
        RegisterClassA(&wc);
        registered = true;
    }
    g_hwnd_qr_dlg = CreateWindowA("AIBridgeMT5QR", "QR Code | Scan to Chat",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
        CW_USEDEFAULT, CW_USEDEFAULT, 328, 360,
        g_hwnd, nullptr, hInst, nullptr);
    ShowWindow(g_hwnd_qr_dlg, SW_SHOW);
    std::thread([url]() {
        std::string path = "/v1/create-qr-code/?size=280x280&margin=2&data="
                         + UrlEncode(url);
        std::wstring wpath(path.begin(), path.end());
        auto bytes = HttpGetBytes(L"api.qrserver.com", wpath.c_str());
        delete g_qr_img;
        g_qr_img = ImageFromBytes(bytes);
        if (g_hwnd_qr_dlg)
            PostMessage(g_hwnd_qr_dlg, WM_QR_READY, 0, 0);
    }).detach();
}

// ── Helpers ───────────────────────────────────────────────────────────────────
static std::string TimeNow() {
    SYSTEMTIME t; GetLocalTime(&t);
    char s[12];
    _snprintf_s(s, sizeof(s), _TRUNCATE, "%02d:%02d:%02d",
                t.wHour, t.wMinute, t.wSecond);
    return s;
}

static void UILog(const std::string& msg) {
    if (!g_hwnd || !g_show_log) return;
    char* p = _strdup(("[" + TimeNow() + "] " + msg).c_str());
    PostMessage(g_hwnd, WM_APPEND_LOG, (WPARAM)p, 0);
}

static void PostStatusUpdate() {
    if (g_hwnd) PostMessage(g_hwnd, WM_UPDATE_STATUS, 0, 0);
}

static void ShowTrayNotification(const char* title, const char* msg) {
    if (!g_tray_added) return;
    g_nid.uFlags      = NIF_ICON | NIF_TIP | NIF_INFO;
    g_nid.dwInfoFlags = NIIF_WARNING;
    strncpy_s(g_nid.szInfoTitle, sizeof(g_nid.szInfoTitle), title, _TRUNCATE);
    strncpy_s(g_nid.szInfo,      sizeof(g_nid.szInfo),      msg,   _TRUNCATE);
    Shell_NotifyIconA(NIM_MODIFY, &g_nid);
}

// ── Request dispatcher ────────────────────────────────────────────────────────
static std::string Dispatch(const std::string& json) {
    JVal req = ParseJSON(json);
    if (!req.isObj()) return "{\"status\":\"error\",\"message\":\"invalid JSON\"}";

    std::string action = req.str("action");
    char out[65536] = {};

    auto W = [](const std::string& s) -> std::wstring {
        return std::wstring(s.begin(), s.end());
    };

    if (action == "ping") {
        return "{\"status\":\"ok\",\"pong\":true}";
    }
    else if (action == "register") {
        Bridge_Register(req.inum("account"),
                        W(req.str("server_broker")).c_str(),
                        req.inum("license_type", 0),
                        out, sizeof(out));
        {
            JVal rv = ParseJSON(std::string(out));
            std::string tok = rv.str("token");
            if (!tok.empty()) {
                std::lock_guard<std::mutex> lk(g_chat_url_mutex);
                if (g_chat_url.empty()) {
                    g_chat_url = "http://aitraiding.up.railway.app/chat?token=" + tok;
                    if (g_hwnd) PostMessage(g_hwnd, WM_TOKEN_READY, 0, 0);
                }
            }
        }
    }
    else if (action == "init") {
        {
            std::string tok = req.str("token");
            if (!tok.empty()) {
                std::lock_guard<std::mutex> lk(g_chat_url_mutex);
                if (g_chat_url.empty()) {
                    g_chat_url = "http://aitraiding.up.railway.app/chat?token=" + tok;
                    if (g_hwnd) PostMessage(g_hwnd, WM_TOKEN_READY, 0, 0);
                }
            }
        }
        Bridge_Init(req.inum("sid"),
                    W(req.str("prompt")).c_str(),
                    W(req.str("symbol", "EURUSD")).c_str(),
                    req.inum("tf", 60), req.num("lot", 0.1),
                    req.inum("sl", 50), req.inum("tp", 100),
                    req.inum("account"),
                    W(req.str("token")).c_str(),
                    out, sizeof(out));
    }
    else if (action == "check") {
        Bridge_Check(req.inum("sid"),
                     W(req.str("values_json")).c_str(),
                     req.inum("account"),
                     out, sizeof(out));
    }
    else if (action == "stop") {
        Bridge_Stop(req.inum("sid"));
        return "{\"status\":\"ok\"}";
    }
    else if (action == "ws_connect") {
        Bridge_WsConnect(W(req.str("account")).c_str(),
                         W(req.str("token")).c_str(),
                         out, sizeof(out));
        std::string r(out);
        g_srv_connected = (r.find("\"status\":\"ok\"") != std::string::npos ||
                          r.find("\"connected\":true") != std::string::npos);
        PostStatusUpdate();
    }
    else if (action == "ws_disconnect") {
        Bridge_WsDisconnect();
        g_srv_connected = false;
        PostStatusUpdate();
        return "{\"status\":\"ok\"}";
    }
    else if (action == "ws_poll") {
        Bridge_WsPoll(out, sizeof(out));
        return std::string(out);
    }
    else if (action == "ws_send") {
        std::string msg = req.str("msg");
        UILog("[DBG ws_send] " + msg.substr(0, 200));
        Bridge_WsSend(W(msg).c_str());
        return "{\"status\":\"ok\"}";
    }
    else {
        _snprintf_s(out, sizeof(out), _TRUNCATE,
                    "{\"status\":\"error\",\"message\":\"unknown action: %s\"}",
                    action.c_str());
    }
    return std::string(out);
}

// ── File IPC — Producer / Consumer ───────────────────────────────────────────
//
//  Read Thread  : polls file system, reads req files, pushes to g_req_queue
//  Write Thread : pops from queue, dispatches (mutex), writes resp file
//
struct ReqItem {
    std::string content;   // decrypted JSON
    std::string resp_path; // where to write the response
    std::string tag;       // "[MT4]" or "[MT5]"
    std::atomic<DWORD>* last_tick;
};

static std::mutex              g_dispatch_mutex;
static std::mutex              g_queue_mutex;
static std::condition_variable g_queue_cv;
static std::queue<ReqItem>     g_req_queue;

// Read thread — watches MT4 fixed file + MT5 wildcard ai_bridge_req_mt5_*.json.
// Each MT5 EA instance uses a unique filename (ChartID suffix) so multiple
// charts running the same EA don't collide.
static void ReadThread(const std::string& mt4_req)
{
    UILog("[Read] thread started.");
    const std::string mt5_req_prefix  = "ai_bridge_req_mt5_";
    const std::string mt5_resp_prefix = "ai_bridge_resp_mt5_";

    while (g_running) {
        // ── MT4: single fixed file ─────────────────────────────────────────
        if (GetFileAttributesA(mt4_req.c_str()) != INVALID_FILE_ATTRIBUTES) {
            Sleep(20);
            std::string raw;
            { std::ifstream f(mt4_req); if (f) raw.assign(std::istreambuf_iterator<char>(f), {}); }
            if (!raw.empty()) {
                DeleteFileA(mt4_req.c_str());
                ReqItem item{ IpcDecrypt(raw),
                              g_dir + "ai_bridge_resp.json",
                              "[MT4]", &g_last_ea_tick_mt4 };
                std::lock_guard<std::mutex> lk(g_queue_mutex);
                g_req_queue.push(std::move(item));
                g_queue_cv.notify_one();
            }
        }

        // ── MT5: scan ai_bridge_req_mt5_*.json (one file per EA instance) ──
        {
            WIN32_FIND_DATAA ffd = {};
            HANDLE hFind = FindFirstFileA((g_dir + mt5_req_prefix + "*.json").c_str(), &ffd);
            if (hFind != INVALID_HANDLE_VALUE) {
                do {
                    std::string req_path  = g_dir + ffd.cFileName;
                    // "ai_bridge_req_mt5_12345.json" → suffix = "12345.json"
                    std::string suffix    = std::string(ffd.cFileName).substr(mt5_req_prefix.size());
                    std::string resp_path = g_dir + mt5_resp_prefix + suffix;

                    Sleep(20);
                    std::string raw;
                    { std::ifstream f(req_path); if (f) raw.assign(std::istreambuf_iterator<char>(f), {}); }
                    if (!raw.empty()) {
                        DeleteFileA(req_path.c_str());
                        ReqItem item{ IpcDecrypt(raw), resp_path, "[MT5]", &g_last_ea_tick_mt5 };
                        std::lock_guard<std::mutex> lk(g_queue_mutex);
                        g_req_queue.push(std::move(item));
                        g_queue_cv.notify_one();
                    }
                } while (FindNextFileA(hFind, &ffd));
                FindClose(hFind);
            }
        }

        Sleep(50);
    }
    g_queue_cv.notify_all(); // wake write thread to exit
    UILog("[Read] thread stopped.");
}

// Write thread — pops from queue, dispatches, writes response file.
static void WriteThread()
{
    UILog("[Write] thread started.");
    while (true) {
        ReqItem item;
        {
            std::unique_lock<std::mutex> lk(g_queue_mutex);
            g_queue_cv.wait(lk, []{ return !g_req_queue.empty() || !g_running; });
            if (g_req_queue.empty()) break; // g_running == false and queue empty
            item = std::move(g_req_queue.front());
            g_req_queue.pop();
        }

        bool is_poll = (item.content.find("\"ws_poll\"") != std::string::npos);
        if (!is_poll) UILog(item.tag + " >> " + item.content.substr(0, 120));

        std::string resp;
        {
            std::lock_guard<std::mutex> lk(g_dispatch_mutex);
            resp = Dispatch(item.content);
        }

        *item.last_tick = GetTickCount();
        PostStatusUpdate();

        if (!is_poll) {
            UILog(item.tag + " << " + resp.substr(0, 120));
        } else {
            bool is_noise = (resp.find("\"event\":\"none\"")      != std::string::npos ||
                             resp.find("\"event\":\"ping\"")      != std::string::npos ||
                             resp.find("\"event\":\"pong\"")      != std::string::npos ||
                             resp.find("\"event\":\"connected\"") != std::string::npos);
            if (!is_noise) UILog(item.tag + " [WS] " + resp.substr(0, 200));
        }

        std::ofstream rf(item.resp_path, std::ios::trunc);
        if (rf) rf << IpcEncrypt(resp);
    }
    UILog("[Write] thread stopped.");
}

// ── Window procedure ──────────────────────────────────────────────────────────
static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {

    case WM_CREATE: {
        g_hwnd_stat = CreateWindowA("STATIC", "Status: Stopped",
            WS_CHILD | WS_VISIBLE | SS_LEFT,
            10, HEADER_H+12, 200, 20, hwnd, nullptr, nullptr, nullptr);

        g_hwnd_ea_stat = CreateWindowA("STATIC", "EA: --",
            WS_CHILD | WS_VISIBLE | SS_LEFT,
            220, HEADER_H+12, 180, 20, hwnd, nullptr, nullptr, nullptr);

        g_hwnd_srv_stat = CreateWindowA("STATIC", "Server: --",
            WS_CHILD | WS_VISIBLE | SS_LEFT,
            410, HEADER_H+12, 210, 20, hwnd, nullptr, nullptr, nullptr);

        CreateWindowA("STATIC", "",
            WS_CHILD | WS_VISIBLE | SS_ETCHEDHORZ,
            10, HEADER_H+36, 610, 2, hwnd, nullptr, nullptr, nullptr);

        g_hwnd_start = CreateWindowA("BUTTON", "Start",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
            10, HEADER_H+44, 100, 30, hwnd, (HMENU)IDC_BTN_START, nullptr, nullptr);

        g_hwnd_stop = CreateWindowA("BUTTON", "Stop",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_DISABLED,
            120, HEADER_H+44, 100, 30, hwnd, (HMENU)IDC_BTN_STOP, nullptr, nullptr);

        if (g_show_log)
            CreateWindowA("BUTTON", "Clear Log",
                WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                230, HEADER_H+44, 100, 30, hwnd, (HMENU)IDC_BTN_CLEAR, nullptr, nullptr);

        g_hwnd_chat_btn = CreateWindowA("BUTTON", "Open Chat",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_DISABLED,
            345, HEADER_H+44, 120, 30, hwnd, (HMENU)IDC_BTN_CHAT, nullptr, nullptr);

        g_hwnd_qr_btn = CreateWindowA("BUTTON", "Chat on mobile",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON | WS_DISABLED,
            475, HEADER_H+44, 120, 30, hwnd, (HMENU)IDC_BTN_QR, nullptr, nullptr);

        g_hwnd_log = CreateWindowExA(WS_EX_CLIENTEDGE, "EDIT", "",
            WS_CHILD | (g_show_log ? WS_VISIBLE : 0) | WS_VSCROLL |
            ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
            10, HEADER_H+84, 610, 374, hwnd, (HMENU)IDC_EDIT_LOG, nullptr, nullptr);

        HFONT hf = CreateFontA(13, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            DEFAULT_QUALITY, FIXED_PITCH | FF_MODERN, "Consolas");
        if (hf) SendMessage(g_hwnd_log, WM_SETFONT, (WPARAM)hf, TRUE);

        return 0;
    }

    case WM_ERASEBKGND:
        return 1;

    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);

        RECT cli; GetClientRect(hwnd, &cli);
        HDC     memDC  = CreateCompatibleDC(hdc);
        HBITMAP memBmp = CreateCompatibleBitmap(hdc, cli.right, cli.bottom);
        HBITMAP oldBmp = (HBITMAP)SelectObject(memDC, memBmp);

        HBRUSH hBgBr = GetSysColorBrush(COLOR_BTNFACE);
        FillRect(memDC, &cli, hBgBr);

        RECT hdr = { 0, 0, cli.right, HEADER_H };
        HBRUSH hbr = CreateSolidBrush(RGB(20, 24, 40));
        FillRect(memDC, &hdr, hbr);
        DeleteObject(hbr);

        HPEN hpen = CreatePen(PS_SOLID, 1, RGB(60, 70, 120));
        HPEN hOldPen = (HPEN)SelectObject(memDC, hpen);
        MoveToEx(memDC, 0, HEADER_H - 1, nullptr);
        LineTo(memDC, cli.right, HEADER_H - 1);
        SelectObject(memDC, hOldPen);
        DeleteObject(hpen);

        if (g_logo_img && g_logo_img->GetLastStatus() == Gdiplus::Ok) {
            Gdiplus::Graphics g(memDC);
            g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
            g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            g.DrawImage(g_logo_img, 10, 7, 40, 40);
        }

        SetBkMode(memDC, TRANSPARENT);
        SetTextColor(memDC, RGB(220, 225, 255));
        HFONT hTitle = CreateFontA(17, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, "Segoe UI");
        HFONT hOldFont = (HFONT)SelectObject(memDC, hTitle);
        RECT tr = { 58, 9, 640, 32 };
        DrawTextA(memDC, "AI Chat Bot Trade Builder", -1, &tr, DT_LEFT | DT_SINGLELINE);

        SetTextColor(memDC, RGB(120, 130, 180));
        HFONT hSub = CreateFontA(12, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, "Segoe UI");
        SelectObject(memDC, hSub);
        RECT sr = { 58, 32, 640, 50 };
        DrawTextA(memDC, "MT4 + MT5 File IPC Bridge", -1, &sr, DT_LEFT | DT_SINGLELINE);

        SelectObject(memDC, hOldFont);
        DeleteObject(hTitle);
        DeleteObject(hSub);

        {
            bool running = g_running.load();
            DWORD now_t  = GetTickCount();
            bool ea_ok   = running && ((g_last_ea_tick_mt4.load() > 0 &&
                                        now_t - g_last_ea_tick_mt4.load() < 5000) ||
                                       (g_last_ea_tick_mt5.load() > 0 &&
                                        now_t - g_last_ea_tick_mt5.load() < 5000));
            bool srv_ok  = running && g_srv_connected.load();

            COLORREF dot_clr;
            const char* dot_label;
            if (!running) {
                dot_clr   = RGB(120, 120, 120); dot_label = "Stopped";
            } else if (ea_ok && srv_ok) {
                dot_clr   = RGB(50, 210, 90);   dot_label = "Connected";
            } else if (!srv_ok && running) {
                dot_clr   = RGB(220, 55, 55);   dot_label = "No Server";
            } else {
                dot_clr   = RGB(240, 160, 30);  dot_label = "Waiting EA";
            }

            Gdiplus::Graphics gfx(memDC);
            gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
            Gdiplus::Color gc;
            gc.SetFromCOLORREF(dot_clr);
            Gdiplus::Color halo(60, gc.GetR(), gc.GetG(), gc.GetB());
            Gdiplus::SolidBrush haloBrush(halo);
            gfx.FillEllipse(&haloBrush, 598, 14, 20, 20);
            Gdiplus::SolidBrush dotBrush(Gdiplus::Color(255, gc.GetR(), gc.GetG(), gc.GetB()));
            gfx.FillEllipse(&dotBrush, 602, 18, 12, 12);

            SetBkMode(memDC, TRANSPARENT);
            SetTextColor(memDC, dot_clr);
            HFONT hDotFont = CreateFontA(11, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, "Segoe UI");
            HFONT hOldDot = (HFONT)SelectObject(memDC, hDotFont);
            RECT dr = { 480, 20, 598, 38 };
            DrawTextA(memDC, dot_label, -1, &dr, DT_RIGHT | DT_SINGLELINE | DT_VCENTER);
            SelectObject(memDC, hOldDot);
            DeleteObject(hDotFont);
        }

        BitBlt(hdc, 0, 0, cli.right, cli.bottom, memDC, 0, 0, SRCCOPY);
        SelectObject(memDC, oldBmp);
        DeleteObject(memBmp);
        DeleteDC(memDC);

        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_UPDATE_STATUS: {
        if (!g_running) {
            SetWindowTextA(g_hwnd_ea_stat,  "MT4: --");
            SetWindowTextA(g_hwnd_srv_stat, "MT5: --");
            g_ea_was_connected = false;
        } else {
            DWORD now = GetTickCount();
            bool mt4_ok = (g_last_ea_tick_mt4.load() > 0 &&
                           now - g_last_ea_tick_mt4.load() < 5000);
            bool mt5_ok = (g_last_ea_tick_mt5.load() > 0 &&
                           now - g_last_ea_tick_mt5.load() < 5000);
            SetWindowTextA(g_hwnd_ea_stat,  mt4_ok ? "MT4: Connected" : "MT4: No signal");
            SetWindowTextA(g_hwnd_srv_stat, mt5_ok ? "MT5: Connected" : "MT5: No signal");

            bool any_ok = mt4_ok || mt5_ok;
            if (g_ea_was_connected && !any_ok)
                ShowTrayNotification("AI Bridge | EA Disconnected",
                    "Both MT4 and MT5 EAs lost connection.");
            g_ea_was_connected = any_ok;
        }
        RECT hdr = { 0, 0, 650, HEADER_H };
        InvalidateRect(hwnd, &hdr, FALSE);
        return 0;
    }

    case WM_TOKEN_READY:
        EnableWindow(g_hwnd_chat_btn, TRUE);
        EnableWindow(g_hwnd_qr_btn,   TRUE);
        return 0;

    case WM_COMMAND: {
        WORD id = LOWORD(wp);

        if (id == IDC_BTN_CHAT) {
            std::string url; { std::lock_guard<std::mutex> lk(g_chat_url_mutex); url = g_chat_url; }
            if (!url.empty()) ShellExecuteA(nullptr, "open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
            return 0;
        }
        if (id == IDC_BTN_QR) {
            HINSTANCE hInst = (HINSTANCE)GetWindowLongPtrA(hwnd, GWLP_HINSTANCE);
            ShowQrDialog(hInst);
            return 0;
        }

        if (id == 0 && HIWORD(wp) == 0xFFFF) {
            EnableWindow(g_hwnd_start, TRUE);
            EnableWindow(g_hwnd_stop,  FALSE);
            SetWindowTextA(g_hwnd_stat, "Status: Stopped");
            return 0;
        }

        if (id == IDC_BTN_START && !g_running) {
            if (g_dir.empty()) g_dir = ResolveCommonDir();
            g_running          = true;
            g_last_ea_tick_mt4 = 0;
            g_last_ea_tick_mt5 = 0;
            { std::lock_guard<std::mutex> lk(g_queue_mutex);
              while (!g_req_queue.empty()) g_req_queue.pop(); }
            g_thread_read  = std::thread(ReadThread,
                g_dir + "ai_bridge_req.json");
            g_thread_write = std::thread(WriteThread);
            EnableWindow(g_hwnd_start, FALSE);
            EnableWindow(g_hwnd_stop,  TRUE);
            SetWindowTextA(g_hwnd_stat, "Status: Running");
            UILog("Watching: " + g_dir);
            InvalidateRect(hwnd, nullptr, FALSE);
        }
        else if (id == IDC_BTN_STOP && g_running) {
            SetWindowTextA(g_hwnd_stat, "Status: Stopping...");
            EnableWindow(g_hwnd_stop, FALSE);
            g_running = false;
            g_queue_cv.notify_all();
            Bridge_WsDisconnect();
            if (g_thread_read.joinable())  g_thread_read.join();
            if (g_thread_write.joinable()) g_thread_write.join();
            EnableWindow(g_hwnd_start, TRUE);
            SetWindowTextA(g_hwnd_stat, "Status: Stopped");
            InvalidateRect(hwnd, nullptr, FALSE);
            PostMessage(hwnd, WM_COMMAND, MAKEWPARAM(0, 0xFFFF), 0);
        }
        else if (id == IDC_BTN_CLEAR) {
            SetWindowTextA(g_hwnd_log, "");
        }
        return 0;
    }

    case WM_APPEND_LOG: {
        char* p = (char*)wp;
        if (p) {
            if (g_show_log && g_hwnd_log) {
                int len = GetWindowTextLengthA(g_hwnd_log);
                SendMessage(g_hwnd_log, EM_SETSEL,     (WPARAM)len, (LPARAM)len);
                SendMessage(g_hwnd_log, EM_REPLACESEL, 0,
                            (LPARAM)(std::string(p) + "\r\n").c_str());
            }
            free(p);
        }
        return 0;
    }

    case WM_CTLCOLORSTATIC: {
        HDC hdcCtrl = (HDC)wp;
        HWND hCtrl  = (HWND)lp;
        char buf[64] = {};
        GetWindowTextA(hCtrl, buf, sizeof(buf));
        std::string txt(buf);

        COLORREF clr = RGB(160, 160, 160);
        if (hCtrl == g_hwnd_stat) {
            if (txt.find("Running")  != std::string::npos) clr = RGB(50,  210, 90);
            if (txt.find("Stopping") != std::string::npos) clr = RGB(240, 160, 30);
        } else if (hCtrl == g_hwnd_ea_stat) {
            if (txt.find("Connected") != std::string::npos) clr = RGB(50,  210, 90);
            if (txt.find("No signal") != std::string::npos) clr = RGB(240, 160, 30);
        } else if (hCtrl == g_hwnd_srv_stat) {
            if (txt.find("Connected")    != std::string::npos) clr = RGB(50,  210, 90);
            if (txt.find("Disconnected") != std::string::npos) clr = RGB(220, 55,  55);
        } else {
            return DefWindowProcA(hwnd, msg, wp, lp);
        }

        SetBkMode(hdcCtrl, TRANSPARENT);
        SetTextColor(hdcCtrl, clr);
        return (LRESULT)GetSysColorBrush(COLOR_BTNFACE);
    }

    case WM_TRAY_ICON:
        if (LOWORD(lp) == WM_LBUTTONUP) {
            ShowWindow(hwnd, SW_RESTORE);
            SetForegroundWindow(hwnd);
        }
        return 0;

    case WM_DESTROY:
        if (g_tray_added) { Shell_NotifyIconA(NIM_DELETE, &g_nid); g_tray_added = false; }
        g_running = false;
        g_queue_cv.notify_all();
        Bridge_WsDisconnect();
        if (g_thread_read.joinable())  g_thread_read.detach();
        if (g_thread_write.joinable()) g_thread_write.detach();
        g_hwnd = nullptr;
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

// ── WinMain ───────────────────────────────────────────────────────────────────
int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int nShow) {
    Gdiplus::GdiplusStartupInput gdipInput;
    Gdiplus::GdiplusStartup(&g_gdiplus_token, &gdipInput, nullptr);
    LoadLogo();

    g_icon_big   = IconFromGdiplus(g_logo_img, 32);
    g_icon_small = IconFromGdiplus(g_logo_img, 16);
    HICON hIconRes = LoadIconA(hInst, MAKEINTRESOURCEA(IDI_APPICON));
    if (!hIconRes) hIconRes = g_icon_big;

    WNDCLASSEXA wc   = {};
    wc.cbSize        = sizeof(WNDCLASSEXA);
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = "AIBridgeMT5Proxy";
    wc.hCursor       = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.hIcon         = hIconRes;
    wc.hIconSm       = g_icon_small;
    RegisterClassExA(&wc);

    int win_h = g_show_log ? (502 + HEADER_H) : (HEADER_H + 130);
    g_hwnd = CreateWindowA("AIBridgeMT5Proxy", "AI Chat Bot Trade Builder (MT5)",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 648, win_h,
        nullptr, nullptr, hInst, nullptr);

    SendMessage(g_hwnd, WM_SETICON, ICON_BIG,   (LPARAM)(hIconRes ? hIconRes : g_icon_big));
    SendMessage(g_hwnd, WM_SETICON, ICON_SMALL,  (LPARAM)g_icon_small);

    ShowWindow(g_hwnd, nShow);
    UpdateWindow(g_hwnd);

    g_nid.cbSize           = sizeof(NOTIFYICONDATAA);
    g_nid.hWnd             = g_hwnd;
    g_nid.uID              = 1;
    g_nid.uFlags           = NIF_ICON | NIF_TIP | NIF_MESSAGE;
    g_nid.uCallbackMessage = WM_TRAY_ICON;
    g_nid.hIcon            = g_icon_small ? g_icon_small : LoadIconA(nullptr, IDI_APPLICATION);
    strncpy_s(g_nid.szTip, sizeof(g_nid.szTip), "AI Chat Bot Trade Builder (MT5)", _TRUNCATE);
    g_tray_added = (Shell_NotifyIconA(NIM_ADD, &g_nid) == TRUE);

    MSG m = {};
    while (GetMessage(&m, nullptr, 0, 0)) {
        TranslateMessage(&m);
        DispatchMessage(&m);
    }

    delete g_logo_img;
    if (g_icon_big)   DestroyIcon(g_icon_big);
    if (g_icon_small) DestroyIcon(g_icon_small);
    Gdiplus::GdiplusShutdown(g_gdiplus_token);
    return (int)m.wParam;
}
