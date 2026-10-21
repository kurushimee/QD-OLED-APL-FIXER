// Shared contract between the tray host and the injected hook DLL.
//
// Named objects live in the current session (dwm.exe and the host share it). The config mapping and
// the heartbeat use a null DACL so dwm.exe, running as SYSTEM, can open objects the host created.
#pragma once

#include <cstdint>

// DLL exports the host resolves by name and calls on remote threads.
#define DWMBOOST_INIT_EXPORT     "DwmBoostInit"
#define DWMBOOST_SHUTDOWN_EXPORT "DwmBoostShutdown"

// DwmBoostInit() return codes.
enum DwmBoostInitStatus
{
    DWMBOOST_INIT_OK = 0,
    DWMBOOST_INIT_NO_DWMCORE = 1,
    DWMBOOST_INIT_UNSUPPORTED_BUILD = 2,  // build number not a known pattern set
    DWMBOOST_INIT_PATTERN_MISSING = 3,    // a required pattern was absent or ambiguous
    DWMBOOST_INIT_FIELDS_MISSING = 4,     // the two registry fields could not be derived
    DWMBOOST_INIT_HOOK_FAILED = 5,        // MinHook init / create / enable failed
    DWMBOOST_INIT_SHARED_MEM_FAILED = 6,  // host config mapping not found
};

// Named objects.
#define DWMBOOST_CONFIG_NAME   L"Global\\DwmBoost_Config"
#define DWMBOOST_HEARTBEAT_NAME L"Global\\DwmBoost_Active"
#define DWMBOOST_SETTLE_FMT    L"Local\\DwmBoost_Settle_%d_%d"   // monitor left, top
#define DWMBOOST_CONTENT_FMT   L"Local\\DwmBoost_Content_%d_%d"  // monitor left, top
#define DWMBOOST_PRIME_NAME    L"Local\\DwmBoost_Prime"

// A dirty rect fully inside a KICK_ZONE box at any screen corner is the host's settle kick, not new
// content: it is copied into the clean copy and counts toward coverage, but does not re-arm settling.
#define DWMBOOST_KICK_PX      1
#define DWMBOOST_KICK_ZONE_PX 16

// Seqlock-versioned config: the host writes under an odd version and publishes an even one; a reader
// copies the body twice and retries while the version is odd or changed.
#pragma pack(push, 4)
struct DwmBoostConfig
{
    volatile uint32_t version;       // even = stable, odd = write in progress
    uint32_t enabled;                // 1 = boost on; 0 = pass through, patches reverted
    uint32_t resetGeneration;        // host bumps to force a history reset (enable, mode change)
    int32_t  monLeft;                // target monitor origin (desktop coords), for event names
    int32_t  monTop;
    uint32_t monWidth;               // back-buffer size the hook matches (the HDR monitor's desktop mode)
    uint32_t monHeight;
    uint32_t monHdr;                 // 1 = target monitor is in HDR
    float    monRefreshMs;           // target monitor refresh period, the smoothing step of one frame
    float    monLitFraction;         // share of the native panel the desktop lights after aspect-ratio scaling
    uint32_t hostPid;                // tray host PID; the DLL self-reverts if it dies
};
#pragma pack(pop)

static inline uint32_t DwmBoostReadConfig(const DwmBoostConfig* src, DwmBoostConfig* out)
{
    for (int tries = 0; tries < 16; ++tries)
    {
        uint32_t v0 = src->version;
        if (v0 & 1u) continue;
        *out = *src;
        uint32_t v1 = src->version;
        if (v0 == v1) return v0;
    }
    return 0;
}
