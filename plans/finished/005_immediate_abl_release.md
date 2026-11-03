---
id: 005
title: Remove residual boost after a bright-to-dark cut
status: finished
created: 2026-11-03
updated: 2026-11-03
finished: 2026-11-03
---

# Immediate ABL release

The user sees a brief whole-screen brightness flash when switching a browser tab from white to black. The model
assumes a 10 ms undimming time constant without timing measurements. Its tests replayed the same assumption and
therefore did not detect overcompensation against a panel that releases ABL immediately.

## Reproduction

Switch a 203-nit page to black while retaining fixed 60- and 150-nit patches. Against immediate ABL release, the
staged shader sends those patches at 2.32 times their target on the first dark frame at 60 fps and 3.14 times at
240 fps. The second 60 fps frame is already correct, matching the reported one-frame flash. This is a simulated
fast-release case, not a physical timing measurement.

## Fix and verification

- [x] Reproduce residual boost independently of the assumed temporal model
- [x] Remove the unmeasured release delay; support zero response time without division by zero
- [x] Check the first dark frame through the shared ReShade core and the actual DWM pipeline
- [x] Keep the null test and documentation aligned with immediate release
- [x] Regenerate the model include and shader bytecode; build and run fit, temporal and parity checks

Zero is a compensation policy motivated by the observed flash. The 80 ms dimming assumption is unchanged. No new
physical response time is claimed; the rebuilt hook must be loaded before checking the result on the monitor.

## Verification results

- Release builds and regenerated shader bytecode succeed; the panel include still matches its fit with 0.48% mean error
- Immediate-release cases cover 203/1000-nit white pages, black/1-nit pages, 60/240 fps, unchanged toolbar patches and quick returns to the white tab
- All dark outputs match boost-disabled reference pixels exactly in HDR10 and scRGB; residual patch-code differences from requested luminance are only input/output rounding (at most 0.008 codes)
- The native DWM first-frame regression rejects all four cases with the old staged bytecode (gain 3.15 to 3.44 at the renderer's refresh rate), then passes all four with the rebuilt bytecode (gain 1.0; no changed pixels)
- DWM parity passes, including no-gain, peak, wide-buffer and first-frame checks
- Synthetic HDR-to-SDR previews of the old and new first dark frame were inspected; these are renderer outputs, not screen measurements

- Existing static and temporal checks pass in HDR10 and scRGB at 60 and 240 fps; worst temporal patch errors remain below the unchanged 0.25-code tolerance (0.116 HDR10, 0.103 scRGB)
- Both renderer formats produce first dark frames identical to boost-disabled output, including the whole 1-nit background, not only the two toolbar patches
- The updated DwmBoostHook.dll has been built. The user must quit the current tray app and launch the rebuilt app to load it; confirmation on the physical display is still pending
