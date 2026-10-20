#include "flip_disable.h"
#include "../third_party/minhook/include/MinHook.h"

namespace {

bool g_active = false;   // detours return false only while the effect is on

typedef bool(__fastcall* IsCandidateDF_t)(void*, void*, void*, void*, unsigned int, bool);
typedef bool(__fastcall* IsDFOnTarget_t)(void*, void*, void*);
typedef bool(__fastcall* IsAdvancedDF_t)(void*);

IsCandidateDF_t g_origIsCandidateDF = nullptr;
IsDFOnTarget_t  g_origIsDFOnTarget = nullptr;
IsAdvancedDF_t  g_origIsAdvancedDF = nullptr;

bool __fastcall HookIsCandidateDF(void* self, void* a2, void* a3, void* a4, unsigned int a5, bool a6)
{
    if (g_active) return false;
    return g_origIsCandidateDF(self, a2, a3, a4, a5, a6);
}

bool __fastcall HookIsDFOnTarget(void* self, void* a2, void* a3)
{
    if (g_active) return false;
    return g_origIsDFOnTarget(self, a2, a3);
}

bool __fastcall HookIsAdvancedDF(void* self)
{
    if (g_active) return false;
    return g_origIsAdvancedDF(self);
}

// Saved state for exact revert.
int  g_savedOverlayTestMode = 0;
int  g_savedDisableIndependentFlip = 0;
bool g_fieldsPatched = false;
unsigned char g_overlaysEnabledOrig[17] = {};
unsigned char* g_overlaysEnabledAddr = nullptr;

bool WriteField(int* field, int value, int* saved)
{
    MEMORY_BASIC_INFORMATION mbi = {};
    if (!VirtualQuery(field, &mbi, sizeof(mbi))) return false;
    DWORD prot = mbi.Protect;
    const DWORD writable = PAGE_READWRITE | PAGE_EXECUTE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_WRITECOPY;
    DWORD old = 0;
    bool reprotected = false;
    if (!(prot & writable))
    {
        if (!VirtualProtect(field, sizeof(int), PAGE_READWRITE, &old)) return false;
        reprotected = true;
    }
    bool ok = true;
    __try { *saved = *field; *field = value; }
    __except (EXCEPTION_EXECUTE_HANDLER) { ok = false; }
    if (reprotected) VirtualProtect(field, sizeof(int), old, &old);
    return ok;
}

void RestoreField(int* field, int value)
{
    __try { *field = value; }
    __except (EXCEPTION_EXECUTE_HANDLER) {}
}

} // namespace

bool FlipInstallHooks(const DwmLocations& loc)
{
    bool ok = true;
    ok &= MH_CreateHook(loc.isCandidateDirectFlip, (void*)HookIsCandidateDF, (void**)&g_origIsCandidateDF) == MH_OK;
    ok &= MH_CreateHook(loc.isDirectFlipOnTarget, (void*)HookIsDFOnTarget, (void**)&g_origIsDFOnTarget) == MH_OK;
    ok &= MH_CreateHook(loc.isAdvancedDirectFlip, (void*)HookIsAdvancedDF, (void**)&g_origIsAdvancedDF) == MH_OK;
    return ok;
}

void FlipEnable(const DwmLocations& loc)
{
    if (g_active) return;

    if (!g_fieldsPatched && loc.overlayTestMode && loc.disableIndependentFlip)
    {
        bool a = WriteField(loc.overlayTestMode, 5, &g_savedOverlayTestMode);
        bool b = WriteField(loc.disableIndependentFlip, 1, &g_savedDisableIndependentFlip);
        g_fieldsPatched = a && b;
    }

    // OverlaysEnabled: inline patch to "mov al,1; ret" (a MinHook trampoline crashes on this
    // dwmcore). Validate the known prologue first.
    if (!g_overlaysEnabledAddr && loc.overlaysEnabled)
    {
        unsigned char* f = loc.overlaysEnabled;
        if (f[0] == 0x83 && f[1] == 0x3D && f[6] == 0x05 && f[7] == 0x74 && f[8] == 0x09)
        {
            DWORD old = 0;
            if (VirtualProtect(f, 17, PAGE_EXECUTE_READWRITE, &old))
            {
                memcpy(g_overlaysEnabledOrig, f, 17);
                g_overlaysEnabledAddr = f;
                f[0] = 0xB0; f[1] = 0x01; f[2] = 0xC3;        // mov al,1; ret
                for (int i = 3; i < 17; ++i) f[i] = 0xCC;     // int3 padding
                VirtualProtect(f, 17, old, &old);
                FlushInstructionCache(GetCurrentProcess(), f, 17);
            }
        }
    }

    g_active = true;
    MH_EnableHook(loc.isCandidateDirectFlip);
    MH_EnableHook(loc.isDirectFlipOnTarget);
    MH_EnableHook(loc.isAdvancedDirectFlip);
}

void FlipDisable(const DwmLocations& loc)
{
    if (!g_active && !g_fieldsPatched && !g_overlaysEnabledAddr) return;

    g_active = false;
    MH_DisableHook(loc.isCandidateDirectFlip);
    MH_DisableHook(loc.isDirectFlipOnTarget);
    MH_DisableHook(loc.isAdvancedDirectFlip);

    if (g_overlaysEnabledAddr)
    {
        DWORD old = 0;
        if (VirtualProtect(g_overlaysEnabledAddr, 17, PAGE_EXECUTE_READWRITE, &old))
        {
            memcpy(g_overlaysEnabledAddr, g_overlaysEnabledOrig, 17);
            VirtualProtect(g_overlaysEnabledAddr, 17, old, &old);
            FlushInstructionCache(GetCurrentProcess(), g_overlaysEnabledAddr, 17);
        }
        g_overlaysEnabledAddr = nullptr;
    }

    if (g_fieldsPatched)
    {
        if (loc.overlayTestMode) RestoreField(loc.overlayTestMode, g_savedOverlayTestMode);
        if (loc.disableIndependentFlip) RestoreField(loc.disableIndependentFlip, g_savedDisableIndependentFlip);
        g_fieldsPatched = false;
    }
}

void FlipRemoveHooks(const DwmLocations& loc)
{
    MH_RemoveHook(loc.isCandidateDirectFlip);
    MH_RemoveHook(loc.isDirectFlipOnTarget);
    MH_RemoveHook(loc.isAdvancedDirectFlip);
}
