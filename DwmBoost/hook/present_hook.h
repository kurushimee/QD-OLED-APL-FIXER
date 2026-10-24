// The COverlayContext::Present hook: acquire the FP16 scRGB back buffer, keep a per-monitor clean
// copy fed from dirty rects, run the EOTF Boost passes on it, and draw the boosted frame back. Runs
// on the target monitor (FP16 + configured size + host HDR flag) only; every other context and any
// non-FP16 back buffer passes straight through. No CPU-side wait, blocking Map, or shared-memory
// poll in the present path — the host config is mirrored into atomics by the DLL's watcher thread.
#pragma once

#include "locate.h"

// Give the detour its trampoline (the real Present), once, after MH_CreateHook.
void PresentSetOrig(Present_t orig);

// The detour address, to pass to MH_CreateHook.
Present_t PresentGetDetour();

// Mirror of the host config, pushed by the watcher thread (never read from shared memory in the
// present path).
void PresentSetTarget(bool enabled, int monLeft, int monTop, unsigned int monWidth, unsigned int monHeight, bool monHdr);

// Release all GPU resources and close the settle/content/prime events. Called when the effect is
// toggled off and at Shutdown. Safe to call repeatedly and when nothing was created.
void PresentReleaseResources();

// Wait until no DWM thread is inside the detour (an in-flight counter reached zero), so Shutdown can
// release resources and the host can unload the DLL safely.
void PresentWaitIdle();
