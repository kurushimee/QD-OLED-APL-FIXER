#include "locate.h"
#include <psapi.h>
#include <cstdint>
#include <cstdlib>

namespace {

// A byte pattern: entries 0x00..0xFF match that byte, >= 0x100 is a wildcard.
struct Pattern
{
    const int* bytes;
    size_t len;
};

// 25H2 and 26H2 (build >= 26200) patterns, each verified to match exactly once on dwmcore
// 10.0.26100.9711 (25H2) and 10.0.26100.9818 (26H2).
// Present: the frame size and the registers that take this, the rect vector and arg 6 differ between
// builds, so those are wildcards. Both builds read only stack args 5 to 7, so Present_t still fits.
const int kPresent[] = {
    0x40, 0x55, 0x53, 0x56, 0x57, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57, 0x48, 0x8D, 0x6C,
    0x24, 0xF9, 0x48, 0x81, 0xEC, 0x100, 0x100, 0x00, 0x00, 0x48, 0x8B, 0x05,
    0x100, 0x100, 0x100, 0x100, 0x48, 0x33, 0xC4, 0x48, 0x89, 0x45, 0xEF, 0x4C, 0x8B, 0x100, 0x77,
    0x48, 0x8B, 0x100, 0x48, 0x8B, 0x09, 0x4D, 0x8B, 0x100, 0x48, 0x83, 0xC1, 0x08
};
const int kIsCandidateDirectFlip[] = {
    0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x08, 0x48, 0x89, 0x68, 0x10, 0x48, 0x89, 0x70, 0x18, 0x48,
    0x89, 0x78, 0x20, 0x41, 0x56, 0x48, 0x83, 0xEC, 0x20, 0x33, 0xDB
};
const int kOverlaysEnabled[] = {
    0x83, 0x3D, 0x100, 0x100, 0x100, 0x100, 0x05, 0x74, 0x09, 0x83, 0x79, 0x28, 0x01, 0x0F, 0x97, 0xC0, 0xC3
};
const int kIsDirectFlipOnTarget[] = {
    0x48, 0x89, 0x5C, 0x24, 0x20, 0x55, 0x56, 0x57, 0x48, 0x83, 0xEC, 0x60,
    0x48, 0x8B, 0x05, 0x100, 0x100, 0x100, 0x100, 0x48, 0x33, 0xC4, 0x48, 0x89, 0x44, 0x24, 0x50,
    0x48, 0x8B, 0x81, 0x100, 0x100, 0x100, 0x100, 0x49, 0x8B, 0xD8, 0x48, 0x8B, 0xF1
};
const int kIsAdvancedDirectFlip[] = {
    0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0x89,
    0x100, 0x100, 0x100, 0x100, 0x48, 0x85, 0xC9, 0x74, 0x100,
    0x48, 0x83, 0x64, 0x24, 0x30, 0x00
};

bool MatchAt(const unsigned char* p, const int* pat, size_t len)
{
    for (size_t k = 0; k < len; ++k)
        if (pat[k] < 0x100 && p[k] != (unsigned char)pat[k]) return false;
    return true;
}

// Returns the single match, or nullptr if the pattern matches zero or more than once.
unsigned char* FindUnique(const unsigned char* base, size_t size, const int* pat, size_t len)
{
    unsigned char* hit = nullptr;
    if (size < len) return nullptr;
    for (size_t i = 0; i + len <= size; ++i)
    {
        if (MatchAt(base + i, pat, len))
        {
            if (hit) return nullptr;   // ambiguous
            hit = (unsigned char*)base + i;
        }
    }
    return hit;
}

// Derive a CCommonRegistryData field by its registry value name: find the UTF-16 name, then a
//   lea r?, [rip+name]
// followed within 0x80 bytes by
//   mov dword [rip+field], eax
// Returns the field address, or nullptr.
int* DeriveField(const unsigned char* base, size_t size, const wchar_t* name)
{
    const size_t nameBytes = (wcslen(name) + 1) * sizeof(wchar_t);   // includes the wide NUL
    const unsigned char* str = nullptr;
    for (size_t i = 0; i + nameBytes <= size; ++i)
        if (memcmp(base + i, name, nameBytes) == 0) { str = base + i; break; }
    if (!str) return nullptr;

    const size_t window = 0x80;
    for (size_t i = 0; i + 7 <= size; ++i)
    {
        const unsigned char* p = base + i;
        if ((p[0] != 0x48 && p[0] != 0x4C) || p[1] != 0x8D || (p[2] & 0xC7) != 0x05) continue;
        if (p + 7 + *(const int*)(p + 3) != str) continue;

        const unsigned char* q = p + 7;
        const unsigned char* lim = q + window;
        if (lim > base + size - 6) lim = base + size - 6;
        for (; q < lim; ++q)
        {
            if (q[0] != 0x89 || (q[1] & 0xC7) != 0x05) continue;
            const unsigned char* tgt = q + 6 + *(const int*)(q + 2);
            if (tgt >= base && tgt + sizeof(int) <= base + size) return (int*)tgt;
            break;
        }
    }
    return nullptr;
}

bool IsBuild25H2OrLater()
{
    typedef LONG(WINAPI* RtlGetVersion_t)(PRTL_OSVERSIONINFOW);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    RtlGetVersion_t fn = ntdll ? (RtlGetVersion_t)GetProcAddress(ntdll, "RtlGetVersion") : nullptr;
    if (!fn) return false;
    RTL_OSVERSIONINFOW vi = {};
    vi.dwOSVersionInfoSize = sizeof(vi);
    if (fn(&vi) != 0) return false;
    return vi.dwBuildNumber >= 26200;
}

} // namespace

DwmBoostInitStatus LocateDwm(DwmLocations& out)
{
    HMODULE dwmcore = GetModuleHandleW(L"dwmcore.dll");
    if (!dwmcore) return DWMBOOST_INIT_NO_DWMCORE;

    MODULEINFO mi = {};
    if (!GetModuleInformation(GetCurrentProcess(), dwmcore, &mi, sizeof(mi)))
        return DWMBOOST_INIT_NO_DWMCORE;

    if (!IsBuild25H2OrLater())
        return DWMBOOST_INIT_UNSUPPORTED_BUILD;

    const unsigned char* base = (const unsigned char*)dwmcore;
    const size_t size = mi.SizeOfImage;
    out.moduleBase = dwmcore;
    out.moduleSize = size;

    out.present = (Present_t)FindUnique(base, size, kPresent, _countof(kPresent));
    out.isCandidateDirectFlip = FindUnique(base, size, kIsCandidateDirectFlip, _countof(kIsCandidateDirectFlip));
    out.isDirectFlipOnTarget = FindUnique(base, size, kIsDirectFlipOnTarget, _countof(kIsDirectFlipOnTarget));
    out.isAdvancedDirectFlip = FindUnique(base, size, kIsAdvancedDirectFlip, _countof(kIsAdvancedDirectFlip));
    out.overlaysEnabled = FindUnique(base, size, kOverlaysEnabled, _countof(kOverlaysEnabled));

    if (!out.present || !out.isCandidateDirectFlip || !out.isDirectFlipOnTarget ||
        !out.isAdvancedDirectFlip || !out.overlaysEnabled)
        return DWMBOOST_INIT_PATTERN_MISSING;

    // The field the OverlaysEnabled compare reads: cmp dword [rip+disp], 5  (83 3D disp32 imm8).
    int* otmFromCmp = (int*)(out.overlaysEnabled + 7 + *(const int*)(out.overlaysEnabled + 2));
    if ((unsigned char*)otmFromCmp < base || (unsigned char*)otmFromCmp + sizeof(int) > base + size)
        return DWMBOOST_INIT_FIELDS_MISSING;

    // Cross-check: deriving m_dwOverlayTestMode by name must land on the same address. Two methods
    // agreeing is what licenses applying the same derivation to the sibling field.
    int* otmByName = DeriveField(base, size, L"OverlayTestMode");
    if (otmByName != otmFromCmp)
        return DWMBOOST_INIT_FIELDS_MISSING;
    out.overlayTestMode = otmFromCmp;

    int* dif = DeriveField(base, size, L"DisableIndependentFlip");
    if (!dif) return DWMBOOST_INIT_FIELDS_MISSING;

    // Plausibility: same registry-data struct and DWORD-aligned.
    INT_PTR delta = (unsigned char*)dif - (unsigned char*)out.overlayTestMode;
    if (delta < 0) delta = -delta;
    if (delta > 0x200 || ((ULONG_PTR)dif & 3) != 0)
        return DWMBOOST_INIT_FIELDS_MISSING;
    out.disableIndependentFlip = dif;

    return DWMBOOST_INIT_OK;
}
