// The 25H2 composition-forcing set: stop apps bypassing DWM composition (MPO, DirectFlip, independent
// flip) so the boost reaches every frame. This is what breaks VRR, so it is applied only while the
// effect is on and reverted exactly when it is toggled off and on Shutdown.
#pragma once

#include "locate.h"

// Create the three DirectFlip MinHook detours (disabled). Call once after MH_Initialize.
bool FlipInstallHooks(const DwmLocations& loc);

// Enable: write OverlayTestMode=5 and DisableIndependentFlip=1, inline-patch OverlaysEnabled to
// return true, and enable the three detours. Idempotent.
void FlipEnable(const DwmLocations& loc);

// Disable: restore the two fields and the OverlaysEnabled bytes, and disable the three detours.
// Idempotent; safe to call when already disabled.
void FlipDisable(const DwmLocations& loc);

// Remove the three detours. Call once before MH_Uninitialize at Shutdown.
void FlipRemoveHooks(const DwmLocations& loc);
