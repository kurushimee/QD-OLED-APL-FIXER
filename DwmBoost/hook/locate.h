// Resolve the dwmcore.dll functions and fields the hook needs, by byte-pattern scan and by registry
// value-name derivation. No PDB or symbol server: this machine has none, and the patterns are keyed
// to the build number. Every pattern must match exactly once; anything missing or ambiguous is a
// hard failure reported to the host, never a guess.
#pragma once

#include <windows.h>
#include "../shared/ipc.h"

typedef __int64(__fastcall* Present_t)(void*, void*, unsigned int, void*, unsigned int, void*, bool);

struct DwmLocations
{
    void* moduleBase = nullptr;
    size_t moduleSize = 0;

    Present_t present = nullptr;          // COverlayContext::Present
    void* isCandidateDirectFlip = nullptr; // COverlayContext::IsCandidateDirectFlipCompatible
    void* isDirectFlipOnTarget = nullptr;  // COverlayContext::IsDirectFlipSupportedOnTarget
    void* isAdvancedDirectFlip = nullptr;  // CGlobalCompositionSurfaceInfo::IsAdvancedDirectFlipCompatible
    unsigned char* overlaysEnabled = nullptr; // COverlayContext::OverlaysEnabled (inline-patched)

    int* overlayTestMode = nullptr;        // CCommonRegistryData::m_dwOverlayTestMode
    int* disableIndependentFlip = nullptr; // CCommonRegistryData::m_fDisableIndependentFlip
};

// Fills `out`; returns DWMBOOST_INIT_OK or the failure code. Supports Windows 11 25H2 (build >= 26200).
DwmBoostInitStatus LocateDwm(DwmLocations& out);
