// Injected into dwm.exe. DllMain does almost nothing (no DWM work under the loader lock); the host
// calls the exported DwmBoostInit on a remote thread, which installs the hooks and starts the
// watcher, and DwmBoostShutdown to revert everything before the host unloads the DLL.
#include <windows.h>
#include <tlhelp32.h>
#include <atomic>

#include "locate.h"
#include "flip_disable.h"
#include "present_hook.h"
#include "../shared/ipc.h"
#include "../third_party/minhook/include/MinHook.h"

namespace {

DwmLocations g_loc;
bool g_located = false;

HANDLE g_configMap = nullptr;
const DwmBoostConfig* g_config = nullptr;
HANDLE g_heartbeat = nullptr;

HANDLE g_watcherThread = nullptr;
HANDLE g_watcherStop = nullptr;
std::atomic<bool> g_flipOn{false};

bool ProcessAlive(DWORD pid)
{
    if (pid == 0) return true;   // unknown: do not self-revert
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return true;
    PROCESSENTRY32W pe = {}; pe.dwSize = sizeof(pe);
    bool found = false;
    if (Process32FirstW(snap, &pe))
        do { if (pe.th32ProcessID == pid) { found = true; break; } } while (Process32NextW(snap, &pe));
    CloseHandle(snap);
    return found;
}

void ApplyConfig(const DwmBoostConfig& c)
{
    bool wantOn = (c.enabled != 0);
    PresentSetTarget(wantOn, c.monLeft, c.monTop, c.monWidth, c.monHeight, c.monHdr != 0);

    if (wantOn && !g_flipOn.load())
    {
        FlipEnable(g_loc);
        g_flipOn.store(true);
    }
    else if (!wantOn && g_flipOn.load())
    {
        FlipDisable(g_loc);
        PresentReleaseResources();
        g_flipOn.store(false);
    }
}

DWORD WINAPI WatcherThread(LPVOID)
{
    for (;;)
    {
        if (WaitForSingleObject(g_watcherStop, 50) == WAIT_OBJECT_0) break;

        DwmBoostConfig c;
        if (g_config && DwmBoostReadConfig(g_config, &c))
        {
            if (!ProcessAlive(c.hostPid))
            {
                // Host gone without Shutdown: revert so VRR returns, then go inert.
                if (g_flipOn.load()) { FlipDisable(g_loc); PresentReleaseResources(); g_flipOn.store(false); }
                break;
            }
            ApplyConfig(c);
        }
    }
    return 0;
}

} // namespace

extern "C" __declspec(dllexport) int DwmBoostInit()
{
    DwmBoostInitStatus st = LocateDwm(g_loc);
    if (st != DWMBOOST_INIT_OK) return st;
    g_located = true;

    if (MH_Initialize() != MH_OK) return DWMBOOST_INIT_HOOK_FAILED;

    Present_t orig = nullptr;
    if (MH_CreateHook(g_loc.present, (void*)PresentGetDetour(), (void**)&orig) != MH_OK)
    {
        MH_Uninitialize();
        return DWMBOOST_INIT_HOOK_FAILED;
    }
    PresentSetOrig(orig);

    if (!FlipInstallHooks(g_loc))
    {
        MH_Uninitialize();
        return DWMBOOST_INIT_HOOK_FAILED;
    }

    // Present stays enabled while resident; the detour passes through unless the config enables it.
    if (MH_EnableHook(g_loc.present) != MH_OK)
    {
        MH_Uninitialize();
        return DWMBOOST_INIT_HOOK_FAILED;
    }

    g_configMap = OpenFileMappingW(FILE_MAP_READ, FALSE, DWMBOOST_CONFIG_NAME);
    if (g_configMap)
        g_config = (const DwmBoostConfig*)MapViewOfFile(g_configMap, FILE_MAP_READ, 0, 0, sizeof(DwmBoostConfig));
    if (!g_config)
    {
        MH_DisableHook(MH_ALL_HOOKS);
        MH_Uninitialize();
        return DWMBOOST_INIT_SHARED_MEM_FAILED;
    }

    // Heartbeat: a null-DACL manual-reset event the host polls; it vanishes if dwm.exe restarts.
    {
        SECURITY_DESCRIPTOR sd;
        InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION);
        SetSecurityDescriptorDacl(&sd, TRUE, nullptr, FALSE);
        SECURITY_ATTRIBUTES sa = { sizeof(sa), &sd, FALSE };
        g_heartbeat = CreateEventW(&sa, TRUE, TRUE, DWMBOOST_HEARTBEAT_NAME);
    }

    // Apply the initial config, then watch for changes off the present path.
    {
        DwmBoostConfig c;
        if (DwmBoostReadConfig(g_config, &c)) ApplyConfig(c);
    }
    g_watcherStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_watcherThread = CreateThread(nullptr, 0, WatcherThread, nullptr, 0, nullptr);

    return DWMBOOST_INIT_OK;
}

extern "C" __declspec(dllexport) int DwmBoostShutdown()
{
    if (g_watcherThread)
    {
        if (g_watcherStop) SetEvent(g_watcherStop);
        WaitForSingleObject(g_watcherThread, 2000);
        CloseHandle(g_watcherThread);
        g_watcherThread = nullptr;
    }
    if (g_watcherStop) { CloseHandle(g_watcherStop); g_watcherStop = nullptr; }

    if (g_located)
    {
        FlipDisable(g_loc);
        g_flipOn.store(false);
    }

    PresentReleaseResources();   // waits for the in-flight count to reach zero

    MH_DisableHook(MH_ALL_HOOKS);
    PresentWaitIdle();
    if (g_located) FlipRemoveHooks(g_loc);
    MH_Uninitialize();

    if (g_config) { UnmapViewOfFile(g_config); g_config = nullptr; }
    if (g_configMap) { CloseHandle(g_configMap); g_configMap = nullptr; }
    if (g_heartbeat) { CloseHandle(g_heartbeat); g_heartbeat = nullptr; }

    return 0;
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH)
        DisableThreadLibraryCalls(hModule);
    return TRUE;
}
