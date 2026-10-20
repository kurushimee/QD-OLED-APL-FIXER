// DwmBoost tray host. Injects the hook DLL into dwm.exe, keeps it resident, and toggles the effect
// through a shared-memory flag. Hotkeys: Ctrl+Alt+Shift+End = on, Home = off. The kicker thread keeps
// DWM composing the Philips while the effect is still settling on a static desktop.
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <string>
#include <vector>
#include <atomic>

#include "../shared/ipc.h"

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "user32.lib")

namespace {

const wchar_t* kDllName = L"DwmBoostHook.dll";
const wchar_t* kWndClass = L"DwmBoostTray";
const wchar_t* kMutexName = L"Local\\DwmBoost_SingleInstance";
const wchar_t* kTaskName = L"DwmBoost";

const UINT WM_TRAY = WM_APP + 1;
const UINT HOTKEY_ON = 1;
const UINT HOTKEY_OFF = 2;
enum { CMD_ENABLE = 100, CMD_DISABLE, CMD_AUTOSTART, CMD_QUIT };

struct Target { int left = 0, top = 0; UINT width = 0, height = 0; bool hdr = false; double refreshMs = 1000.0 / 60.0; bool found = false; };

HWND g_hwnd = nullptr;
HANDLE g_configMap = nullptr;
DwmBoostConfig* g_config = nullptr;
HANDLE g_settleEvt = nullptr, g_contentEvt = nullptr, g_primeEvt = nullptr;
HANDLE g_kickThread = nullptr, g_kickStop = nullptr;
DWORD g_dwmPid = 0;
bool g_enabled = false;
Target g_target;
NOTIFYICONDATAW g_nid = {};

// -------- logging --------
void Logf(const wchar_t* fmt, ...)
{
    wchar_t buf[512];
    va_list ap; va_start(ap, fmt);
    _vsnwprintf_s(buf, _countof(buf), _TRUNCATE, fmt, ap);
    va_end(ap);
    OutputDebugStringW(buf); OutputDebugStringW(L"\n");
}

// -------- privilege / elevation --------

bool EnablePrivilege(const wchar_t* name)
{
    HANDLE tok;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok)) return false;
    LUID luid;
    bool ok = LookupPrivilegeValueW(nullptr, name, &luid) != 0;
    if (ok)
    {
        TOKEN_PRIVILEGES tp = {};
        tp.PrivilegeCount = 1; tp.Privileges[0].Luid = luid; tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
        ok = AdjustTokenPrivileges(tok, FALSE, &tp, sizeof(tp), nullptr, nullptr) != 0 && GetLastError() == ERROR_SUCCESS;
    }
    CloseHandle(tok);
    return ok;
}

std::vector<DWORD> FindPids(const wchar_t* exeName)
{
    std::vector<DWORD> pids;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return pids;
    PROCESSENTRY32W pe = {}; pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe))
        do { if (_wcsicmp(pe.szExeFile, exeName) == 0) pids.push_back(pe.th32ProcessID); } while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    return pids;
}

// Impersonate lsass.exe's SYSTEM token for this thread, so OpenProcess on dwm.exe succeeds.
bool ElevateToSystem()
{
    auto pids = FindPids(L"lsass.exe");
    if (pids.empty()) return false;
    HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pids[0]);
    if (!proc) return false;
    HANDLE tok = nullptr, dup = nullptr;
    bool ok = false;
    if (OpenProcessToken(proc, TOKEN_DUPLICATE | TOKEN_IMPERSONATE | TOKEN_QUERY, &tok))
    {
        if (DuplicateTokenEx(tok, TOKEN_ALL_ACCESS, nullptr, SecurityImpersonation, TokenImpersonation, &dup))
        {
            ok = SetThreadToken(nullptr, dup) != 0;
            CloseHandle(dup);
        }
        CloseHandle(tok);
    }
    CloseHandle(proc);
    return ok;
}

// -------- monitor discovery (QueryDisplayConfig) --------

Target FindPhilips()
{
    Target t;
    UINT32 nPath = 0, nMode = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &nPath, &nMode) != ERROR_SUCCESS) return t;
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(nPath);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(nMode);
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &nPath, paths.data(), &nMode, modes.data(), nullptr) != ERROR_SUCCESS)
        return t;
    paths.resize(nPath); modes.resize(nMode);

    for (const auto& p : paths)
    {
        if (p.sourceInfo.modeInfoIdx >= modes.size()) continue;
        const DISPLAYCONFIG_SOURCE_MODE& sm = modes[p.sourceInfo.modeInfoIdx].sourceMode;

        // HDR (advanced color enabled) for this target.
        DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO aci = {};
        aci.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
        aci.header.size = sizeof(aci);
        aci.header.adapterId = p.targetInfo.adapterId;
        aci.header.id = p.targetInfo.id;
        bool hdr = (DisplayConfigGetDeviceInfo(&aci.header) == ERROR_SUCCESS) && aci.advancedColorEnabled;

        if (sm.width == 2560 && sm.height == 1440)
        {
            t.left = sm.position.x; t.top = sm.position.y;
            t.width = sm.width; t.height = sm.height; t.hdr = hdr;
            if (p.targetInfo.refreshRate.Denominator && p.targetInfo.refreshRate.Numerator)
                t.refreshMs = 1000.0 * p.targetInfo.refreshRate.Denominator / p.targetInfo.refreshRate.Numerator;
            t.found = true;
            if (hdr) break;   // prefer the HDR 2560x1440 panel
        }
    }
    return t;
}

// -------- shared config + events (null DACL so SYSTEM dwm.exe can open them) --------

SECURITY_ATTRIBUTES* NullDaclSa()
{
    static SECURITY_DESCRIPTOR sd;
    static SECURITY_ATTRIBUTES sa;
    InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION);
    SetSecurityDescriptorDacl(&sd, TRUE, nullptr, FALSE);
    sa.nLength = sizeof(sa); sa.lpSecurityDescriptor = &sd; sa.bInheritHandle = FALSE;
    return &sa;
}

bool CreateConfig()
{
    g_configMap = CreateFileMappingW(INVALID_HANDLE_VALUE, NullDaclSa(), PAGE_READWRITE, 0, sizeof(DwmBoostConfig), DWMBOOST_CONFIG_NAME);
    if (!g_configMap) return false;
    g_config = (DwmBoostConfig*)MapViewOfFile(g_configMap, FILE_MAP_WRITE, 0, 0, sizeof(DwmBoostConfig));
    if (!g_config) return false;

    DwmBoostConfig init = {};
    init.version = 2;
    init.enabled = 0;
    init.resetGeneration = 1;
    init.monLeft = g_target.left; init.monTop = g_target.top;
    init.monWidth = g_target.width; init.monHeight = g_target.height;
    init.monHdr = g_target.hdr ? 1u : 0u;
    init.hostPid = GetCurrentProcessId();
    *g_config = init;
    return true;
}

void WriteEnabled(bool enabled)
{
    if (!g_config) return;
    uint32_t v = g_config->version;
    g_config->version = v | 1u;              // begin write (odd)
    MemoryBarrier();
    if (enabled && !g_config->enabled) g_config->resetGeneration++;   // fresh history on each enable
    g_config->enabled = enabled ? 1u : 0u;
    g_config->monLeft = g_target.left; g_config->monTop = g_target.top;
    g_config->monWidth = g_target.width; g_config->monHeight = g_target.height;
    g_config->monHdr = g_target.hdr ? 1u : 0u;
    g_config->hostPid = GetCurrentProcessId();
    MemoryBarrier();
    g_config->version = (v | 1u) + 1u;       // publish (even)
    g_enabled = enabled;
}

void CreateEvents()
{
    wchar_t name[96];
    swprintf_s(name, DWMBOOST_SETTLE_FMT, g_target.left, g_target.top);
    g_settleEvt = CreateEventW(NullDaclSa(), FALSE, FALSE, name);
    swprintf_s(name, DWMBOOST_CONTENT_FMT, g_target.left, g_target.top);
    g_contentEvt = CreateEventW(NullDaclSa(), FALSE, FALSE, name);
    g_primeEvt = CreateEventW(NullDaclSa(), FALSE, FALSE, DWMBOOST_PRIME_NAME);
}

// -------- injection --------

std::wstring ExeDir()
{
    wchar_t path[MAX_PATH]; GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring s(path);
    size_t p = s.find_last_of(L"\\/");
    return (p == std::wstring::npos) ? L"" : s.substr(0, p + 1);
}

std::wstring ExpandEnv(const wchar_t* s)
{
    wchar_t out[MAX_PATH]; DWORD n = ExpandEnvironmentStringsW(s, out, MAX_PATH);
    return (n && n <= MAX_PATH) ? std::wstring(out) : L"";
}

// Null the DACL on a staged file so the SYSTEM dwm.exe can read it.
void ClearDacl(const std::wstring& path)
{
    SECURITY_DESCRIPTOR sd;
    InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION);
    SetSecurityDescriptorDacl(&sd, TRUE, nullptr, FALSE);
    HANDLE f = CreateFileW(path.c_str(), READ_CONTROL | WRITE_DAC, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f != INVALID_HANDLE_VALUE) { SetKernelObjectSecurity(f, DACL_SECURITY_INFORMATION, &sd); CloseHandle(f); }
}

HMODULE RemoteModuleBase(DWORD pid, const wchar_t* name)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE_VALUE) return nullptr;
    MODULEENTRY32W me = {}; me.dwSize = sizeof(me);
    HMODULE base = nullptr;
    if (Module32FirstW(snap, &me))
        do { if (_wcsicmp(me.szModule, name) == 0) { base = me.hModule; break; } } while (Module32NextW(snap, &me));
    CloseHandle(snap);
    return base;
}

// Run a one-arg function in the remote process and return its DWORD exit code (0xFFFFFFFF on failure).
DWORD RemoteCall(HANDLE proc, void* fn, void* arg)
{
    HANDLE th = CreateRemoteThread(proc, nullptr, 0, (LPTHREAD_START_ROUTINE)fn, arg, 0, nullptr);
    if (!th) return 0xFFFFFFFF;
    WaitForSingleObject(th, 15000);
    DWORD code = 0xFFFFFFFF;
    GetExitCodeThread(th, &code);
    CloseHandle(th);
    return code;
}

// Returns DwmBoostInit's status, or a negative host error.
int InjectAndInit(DWORD pid, std::wstring& err)
{
    std::wstring sysTemp = ExpandEnv(L"%SYSTEMROOT%\\Temp\\");
    if (sysTemp.empty()) { err = L"cannot expand %SYSTEMROOT%"; return -1; }
    std::wstring dllSrc = ExeDir() + kDllName;
    std::wstring dllDst = sysTemp + kDllName;

    if (GetFileAttributesW(dllSrc.c_str()) == INVALID_FILE_ATTRIBUTES) { err = L"DwmBoostHook.dll not found next to the exe"; return -1; }
    if (!CopyFileW(dllSrc.c_str(), dllDst.c_str(), FALSE)) { err = L"failed to stage the DLL into %SYSTEMROOT%\\Temp"; return -1; }
    ClearDacl(dllDst);

    HANDLE proc = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);
    if (!proc) { err = L"OpenProcess(dwm.exe) failed; run elevated"; return -1; }

    int result = -1;
    size_t bytes = (dllDst.size() + 1) * sizeof(wchar_t);
    void* remote = VirtualAllocEx(proc, nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (remote && WriteProcessMemory(proc, remote, dllDst.c_str(), bytes, nullptr))
    {
        void* loadLib = (void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
        if (loadLib && RemoteCall(proc, loadLib, remote) != 0xFFFFFFFF)
        {
            HMODULE remoteBase = RemoteModuleBase(pid, kDllName);
            HMODULE local = LoadLibraryExW(dllDst.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
            if (remoteBase && local)
            {
                FARPROC localInit = GetProcAddress(local, DWMBOOST_INIT_EXPORT);
                if (localInit)
                {
                    void* remoteInit = (char*)remoteBase + ((char*)localInit - (char*)local);
                    DWORD st = RemoteCall(proc, remoteInit, nullptr);
                    result = (st == 0xFFFFFFFF) ? -1 : (int)st;
                    if (result != DWMBOOST_INIT_OK) err = L"DwmBoostInit reported a failure code";
                }
                else err = L"DwmBoostInit export not found";
            }
            else err = L"could not resolve the remote DLL base";
            if (local) FreeLibrary(local);
        }
        else err = L"remote LoadLibraryW failed";
    }
    else err = L"VirtualAllocEx/WriteProcessMemory failed";

    if (remote) VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
    CloseHandle(proc);
    return result;
}

void ShutdownAndEject(DWORD pid)
{
    HANDLE proc = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);
    if (!proc) return;
    HMODULE remoteBase = RemoteModuleBase(pid, kDllName);
    std::wstring dllDst = ExpandEnv(L"%SYSTEMROOT%\\Temp\\") + kDllName;
    HMODULE local = LoadLibraryExW(dllDst.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
    if (remoteBase && local)
    {
        FARPROC localShut = GetProcAddress(local, DWMBOOST_SHUTDOWN_EXPORT);
        if (localShut)
        {
            void* remoteShut = (char*)remoteBase + ((char*)localShut - (char*)local);
            RemoteCall(proc, remoteShut, nullptr);
        }
        void* freeLib = (void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "FreeLibrary");
        if (freeLib) RemoteCall(proc, freeLib, remoteBase);   // detach is already clean; this unloads
    }
    if (local) FreeLibrary(local);
    CloseHandle(proc);
}

bool HeartbeatAlive()
{
    HANDLE h = OpenEventW(SYNCHRONIZE, FALSE, DWMBOOST_HEARTBEAT_NAME);
    if (!h) return false;
    CloseHandle(h);
    return true;
}

// -------- kicker + prime thread --------

HWND MakeLayeredWindow(HINSTANCE inst, const wchar_t* cls, int x, int y, int w, int h)
{
    return CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                           cls, L"", WS_POPUP, x, y, w, h, nullptr, nullptr, inst, nullptr);
}

void PaintLayered(HWND w, int x, int y, int cw, int ch, BYTE alpha, HDC screen, HDC mem, DWORD* bits)
{
    POINT src = { 0, 0 }, pos = { x, y };
    SIZE sz = { cw, ch };
    BLENDFUNCTION bf = { AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    if (bits) { *bits = (DWORD)alpha << 24; GdiFlush(); }
    UpdateLayeredWindow(w, screen, &pos, &sz, mem, &src, 0, &bf, ULW_ALPHA);
}

DWORD WINAPI KickThread(LPVOID)
{
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HINSTANCE inst = GetModuleHandleW(nullptr);
    WNDCLASSW wc = {}; wc.lpfnWndProc = DefWindowProcW; wc.hInstance = inst; wc.lpszClassName = L"DwmBoostKick";
    RegisterClassW(&wc);

    HDC screen = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bi = {}; bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = 1; bi.bmiHeader.biHeight = 1; bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
    void* kbits = nullptr;
    HBITMAP kbmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &kbits, nullptr, 0);
    HGDIOBJ oldBmp = kbmp ? SelectObject(mem, kbmp) : nullptr;

    // A 1x1 prime DIB stretched over the monitor forces a full recomposition.
    HDC primeMem = CreateCompatibleDC(screen);
    void* pbits = nullptr;
    HBITMAP pbmp = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &pbits, nullptr, 0);
    HGDIOBJ oldPrime = pbmp ? SelectObject(primeMem, pbmp) : nullptr;

    HWND kickWnd = MakeLayeredWindow(inst, wc.lpszClassName, g_target.left, g_target.top, DWMBOOST_KICK_PX, DWMBOOST_KICK_PX);
    HWND primeWnd = MakeLayeredWindow(inst, wc.lpszClassName, g_target.left, g_target.top, (int)g_target.width, (int)g_target.height);

    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (!timer) timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);

    const ULONGLONG QUIET_MS = 100;
    ULONGLONG lastSettleMs = 0, primeUntilMs = 0;
    BYTE alpha = 1;
    bool kickShown = false, primeShown = false;

    for (;;)
    {
        ULONGLONG now = GetTickCount64();
        bool kicking = lastSettleMs && (now - lastSettleMs < QUIET_MS);

        if (!kicking && primeUntilMs == 0)
        {
            HANDLE waits[3] = { g_kickStop, g_settleEvt, g_primeEvt };
            DWORD w = WaitForMultipleObjects(3, waits, FALSE, 1000);
            if (w == WAIT_OBJECT_0) break;
            if (w == WAIT_OBJECT_0 + 1) lastSettleMs = GetTickCount64();
            else if (w == WAIT_OBJECT_0 + 2) primeUntilMs = GetTickCount64() + 100;
            continue;
        }

        // Active: pace at the Philips refresh period.
        LARGE_INTEGER due; due.QuadPart = -(LONGLONG)(g_target.refreshMs * 10000.0);
        if (timer) { SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE); HANDLE w2[2] = { g_kickStop, timer }; WaitForMultipleObjects(2, w2, FALSE, 100); }
        else WaitForSingleObject(g_kickStop, (DWORD)(g_target.refreshMs + 0.5));
        if (WaitForSingleObject(g_kickStop, 0) == WAIT_OBJECT_0) break;

        now = GetTickCount64();
        if (WaitForSingleObject(g_settleEvt, 0) == WAIT_OBJECT_0) lastSettleMs = now;
        if (WaitForSingleObject(g_primeEvt, 0) == WAIT_OBJECT_0) primeUntilMs = now + 100;
        bool contentArrived = (WaitForSingleObject(g_contentEvt, 0) == WAIT_OBJECT_0);
        kicking = lastSettleMs && (now - lastSettleMs < QUIET_MS);

        // Prime window: full-monitor, alpha 1/255, shown briefly to force a recomposition.
        if (primeUntilMs && now < primeUntilMs)
        {
            PaintLayered(primeWnd, g_target.left, g_target.top, (int)g_target.width, (int)g_target.height, 1, screen, primeMem, (DWORD*)pbits);
            if (!primeShown) { SetWindowPos(primeWnd, HWND_TOPMOST, g_target.left, g_target.top, (int)g_target.width, (int)g_target.height, SWP_NOACTIVATE | SWP_SHOWWINDOW); primeShown = true; }
        }
        else if (primeShown) { ShowWindow(primeWnd, SW_HIDE); primeShown = false; primeUntilMs = 0; }

        // Kick window: only while settling and no content arrived this tick.
        if (kicking && !contentArrived)
        {
            alpha = (BYTE)(3 - alpha);   // 1 <-> 2
            PaintLayered(kickWnd, g_target.left, g_target.top, DWMBOOST_KICK_PX, DWMBOOST_KICK_PX, alpha, screen, mem, (DWORD*)kbits);
            if (!kickShown) { SetWindowPos(kickWnd, HWND_TOPMOST, g_target.left, g_target.top, DWMBOOST_KICK_PX, DWMBOOST_KICK_PX, SWP_NOACTIVATE | SWP_SHOWWINDOW); kickShown = true; }
        }
        else if (kickShown) { ShowWindow(kickWnd, SW_HIDE); kickShown = false; }
    }

    if (kickShown) ShowWindow(kickWnd, SW_HIDE);
    if (primeShown) ShowWindow(primeWnd, SW_HIDE);
    DestroyWindow(kickWnd); DestroyWindow(primeWnd);
    if (timer) CloseHandle(timer);
    if (oldBmp) SelectObject(mem, oldBmp); if (kbmp) DeleteObject(kbmp); DeleteDC(mem);
    if (oldPrime) SelectObject(primeMem, oldPrime); if (pbmp) DeleteObject(pbmp); DeleteDC(primeMem);
    ReleaseDC(nullptr, screen);
    return 0;
}

void StartKicker()
{
    if (g_kickThread) return;
    g_kickStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_kickThread = CreateThread(nullptr, 0, KickThread, nullptr, 0, nullptr);
}

void StopKicker()
{
    if (!g_kickThread) return;
    SetEvent(g_kickStop);
    WaitForSingleObject(g_kickThread, 3000);
    CloseHandle(g_kickThread); g_kickThread = nullptr;
    CloseHandle(g_kickStop); g_kickStop = nullptr;
}

// -------- autostart --------

void InstallAutostart()
{
    wchar_t exe[MAX_PATH]; GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring cmd = L"/c schtasks /create /tn \"" + std::wstring(kTaskName) +
        L"\" /tr \"\\\"" + exe + L"\\\"\" /sc onlogon /rl highest /f";
    SHELLEXECUTEINFOW se = { sizeof(se) };
    se.lpVerb = L"open"; se.lpFile = L"cmd.exe"; se.lpParameters = cmd.c_str();
    se.nShow = SW_HIDE; se.fMask = SEE_MASK_NOCLOSEPROCESS;
    if (ShellExecuteExW(&se) && se.hProcess) { WaitForSingleObject(se.hProcess, 5000); CloseHandle(se.hProcess); }
    MessageBoxW(g_hwnd, L"Autostart task installed (runs elevated at logon).", L"DwmBoost", MB_OK | MB_ICONINFORMATION);
}

// -------- tray --------

void SetTray(HWND hwnd, bool create)
{
    g_nid.cbSize = sizeof(g_nid); g_nid.hWnd = hwnd; g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;
    g_nid.hIcon = LoadIconW(nullptr, g_enabled ? IDI_WINLOGO : IDI_APPLICATION);
    wcscpy_s(g_nid.szTip, g_enabled ? L"DwmBoost: on" : L"DwmBoost: off");
    Shell_NotifyIconW(create ? NIM_ADD : NIM_MODIFY, &g_nid);
}

void Toggle(bool on)
{
    WriteEnabled(on);
    if (on) StartKicker();
    SetTray(g_hwnd, false);
}

void ShowMenu(HWND hwnd)
{
    POINT pt; GetCursorPos(&pt);
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING | (g_enabled ? MF_CHECKED : 0), CMD_ENABLE, L"Enable");
    AppendMenuW(m, MF_STRING | (!g_enabled ? MF_CHECKED : 0), CMD_DISABLE, L"Disable");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, CMD_AUTOSTART, L"Install autostart task");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, CMD_QUIT, L"Quit");
    SetForegroundWindow(hwnd);
    TrackPopupMenu(m, TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, nullptr);
    DestroyMenu(m);
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_HOTKEY:
        if (wp == HOTKEY_ON) Toggle(true);
        else if (wp == HOTKEY_OFF) Toggle(false);
        return 0;
    case WM_TRAY:
        if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_CONTEXTMENU) ShowMenu(hwnd);
        else if (LOWORD(lp) == WM_LBUTTONDBLCLK) Toggle(!g_enabled);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp))
        {
        case CMD_ENABLE: Toggle(true); break;
        case CMD_DISABLE: Toggle(false); break;
        case CMD_AUTOSTART: InstallAutostart(); break;
        case CMD_QUIT: DestroyWindow(hwnd); break;
        }
        return 0;
    case WM_TIMER:
        // Heartbeat watch: if the hook vanished (DWM restart / fault), mark off and do not reinject.
        if (!HeartbeatAlive() && g_enabled) { g_enabled = false; StopKicker(); if (g_config) g_config->enabled = 0; SetTray(hwnd, false); }
        return 0;
    case WM_DESTROY:
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

} // namespace

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, LPWSTR, int)
{
    HANDLE mutex = CreateMutexW(nullptr, TRUE, kMutexName);
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    EnablePrivilege(SE_DEBUG_NAME);

    g_target = FindPhilips();
    if (!g_target.found)
    {
        MessageBoxW(nullptr, L"No 2560x1440 monitor found. DwmBoost targets the Philips 27M2N6500.", L"DwmBoost", MB_OK | MB_ICONERROR);
        return 1;
    }

    if (!CreateConfig())
    {
        MessageBoxW(nullptr, L"Failed to create the shared config mapping.", L"DwmBoost", MB_OK | MB_ICONERROR);
        return 1;
    }
    CreateEvents();

    auto dwmPids = FindPids(L"dwm.exe");
    if (dwmPids.empty()) { MessageBoxW(nullptr, L"dwm.exe not found.", L"DwmBoost", MB_OK | MB_ICONERROR); return 1; }
    g_dwmPid = dwmPids[0];

    // Inject under a SYSTEM token so OpenProcess on dwm.exe succeeds.
    int st;
    std::wstring err;
    {
        if (!ElevateToSystem())
        {
            MessageBoxW(nullptr, L"Could not elevate to SYSTEM (needed to inject into dwm.exe).", L"DwmBoost", MB_OK | MB_ICONERROR);
            return 1;
        }
        st = InjectAndInit(g_dwmPid, err);
        RevertToSelf();
    }
    if (st != DWMBOOST_INIT_OK)
    {
        std::wstring msg = L"Injection failed: " + (err.empty() ? L"unknown" : err) + L" (code " + std::to_wstring(st) + L")";
        MessageBoxW(nullptr, msg.c_str(), L"DwmBoost", MB_OK | MB_ICONERROR);
        return 1;
    }

    WNDCLASSW wc = {}; wc.lpfnWndProc = WndProc; wc.hInstance = inst; wc.lpszClassName = kWndClass;
    RegisterClassW(&wc);
    g_hwnd = CreateWindowExW(0, kWndClass, L"DwmBoost", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, inst, nullptr);

    RegisterHotKey(g_hwnd, HOTKEY_ON, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, VK_END);
    RegisterHotKey(g_hwnd, HOTKEY_OFF, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, VK_HOME);
    SetTray(g_hwnd, true);
    SetTimer(g_hwnd, 1, 2000, nullptr);   // heartbeat watch

    MSG m;
    while (GetMessageW(&m, nullptr, 0, 0))
    {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }

    StopKicker();
    WriteEnabled(false);
    {
        if (ElevateToSystem()) { ShutdownAndEject(g_dwmPid); RevertToSelf(); }
    }
    if (g_config) UnmapViewOfFile(g_config);
    if (g_configMap) CloseHandle(g_configMap);
    if (g_settleEvt) CloseHandle(g_settleEvt);
    if (g_contentEvt) CloseHandle(g_contentEvt);
    if (g_primeEvt) CloseHandle(g_primeEvt);
    if (mutex) { ReleaseMutex(mutex); CloseHandle(mutex); }
    return 0;
}
