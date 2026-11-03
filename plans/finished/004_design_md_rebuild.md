---
id: 004
title: EOTF Boost 3.1 rebuilt on DESIGN.md
status: finished
created: 2026-11-02
updated: 2026-11-03
finished: 2026-11-03
---

# EOTF Boost 3.1 rebuilt on DESIGN.md

3.1 is brighter than TB400, but every APL change flashes the whole picture's brightness, so the boost feels as aggressive as plain Peak 1000. This plan carries out every part of `DESIGN.md` in the shader, DwmBoost and the checks, plus the extra defects a full review of 3.1 found. No settings that trade accuracy, no lowered peak, no new measurements. The data is `abl_curve.csv` plus the 24 row dense white table at `bc0684f^:abl_curve.csv`

## Facts

### Panel model, recomputed from the csv

| Model | mean abs error | RMS | worst |
|---|---|---|---|
| 3.1's fit, brightest BT.2020 channel, load peak fitted at 1056.8 | | 1.33% | 3.85% |
| DESIGN.md's model, loads from the signal level | 1.06% | 1.50% | 4.39% |
| DESIGN.md's model, gray loads from the level the panel shows at 2% | 0.74% | 1.00% | 2.55% |
| DESIGN.md's model on the 19 extra dense white rows | 0.38% | | 1.07% |

- DESIGN.md's under 0.5% mean over 52 rows needs gray loads from the level the panel shows without dimming. At 2% the panel shows a 100 nit gray at 0.9642 of its signal, 201 nits at 0.9914, 398 nits at 0.9848 and peak white at 1, so the model carries that static tracking factor in its load
- DESIGN.md's curve peaks at elasticity 0.756 at 9.3% load, against 0.787 in 3.1, and has no kink

### 3.1's smoothing against a panel that dims on the same frame

Simulated from the panel model, error time is how long the error stays above 2%

| Scenario | 60 fps | 240 fps |
|---|---|---|
| 900 nit 5% window appears on 30 nits | 0.61 stops worst, 1050 ms | 262 ms |
| The same window leaves | 0.47 stops worst, 1150 ms | 288 ms |
| 50 ms muzzle flash | 0.12 stops worst, 500 ms | 146 ms |
| Bright area grows over 1 s | 0.09 stops for the whole move | |

### Where DESIGN.md's text differs from the code

The work follows the intent of each part

- Root cause 1: the fit already fits `self_relative`. The problem is the fitted 1056.8 nit load peak with gray loads from the signal level. The fix is DESIGN.md's, load peak at the EDID and loads from the shown level
- Root cause 2.2: the tail is already a power law. The change is DESIGN.md's C2 smooth corners, its fit and the dense white rows
- `PanelCompensation` becomes `EvaluatePanelCompensation`. DwmBoost's entry points are `CS_Setup`, `CS_Build`, `CS_Reduce`, `CS_Solve`, `VS_Boost` and `PS_Boost`. DESIGN.md's line numbers are stale
- Layer 4.1 assumes bins of uniform PQ width. 3.1's bins are quarter octaves, so span and room use each bin's real PQ edges
- Layer 5 keeps the brightest BT.2020 channel exact, but Layer 1's load is in native panel RGB, so the solve folds the roll-off into each bin's load ratio
- Layer 3.1's `PanelResponseSeconds` slider becomes the constant `PANEL_RESPONSE_SECONDS = 0.08` in the include. The repo holds no timing data, so the value is DESIGN.md's

### Root causes

From DESIGN.md
1. The fitted 1056.8 nit load peak with gray loads from the signal level under-compensates 5 to 10% white windows by about 3%
2. Only 6 white points out of 24 dense ones, and a kink at 10.32% load where gain sensitivity drops 12 times
3. Load counted in BT.2020 instead of the panel's native P3 RGB, with no green and blue weights
4. Gain smoothing counted in frames and run outside the solve, and mean PQ scene-change bypasses of 1 to 3% that jump the gain in one frame
5. `APL_PickLogGain` dims all midtones whenever highlights appear, and its tie rule jumps by 12.5% of the log gain
6. The tone curve's top follows the single brightest pixel
7. The histogram shoulder has no slope floor and no smoothing across bins, so highlights breathe

From the review
8. The OSD draws in raw signal values, up to 10000 nits in HDR10, and adds load the solve never saw
9. The bend starts half its width below the knee, so levels under the shoulder start get bent
10. Rolling histogram phases make the load lag
11. The null test hard-codes a one frame panel lag
12. Settings that trade accuracy: gain pick, shoulder start, shoulder blend, dither toggle, smoothing and scene change sliders, rolling phases
13. Dead and duplicated code: unused `FrameTime`, two sets of digit and PQ functions, the LUT's XYZ round trip, empty wrappers, texture names that don't say what they hold

## 1. Baseline

Done when the review baseline and final verification results are recorded

- [x] Record the review baseline and final GPU checks in phase 6 (supersedes the original pre-rebuild baseline task)
  - Historical pre-review timings at 2560 by 1440: 0.76 ms before the rebuild, 0.69 ms after it; final synthetic-frame timings are in phase 6

## 2. Panel model

Done when the mean error over 52 rows is under 0.5%, the curve is C2 and the elasticity is under 0.95

- [x] Fit DESIGN.md's C2 curve, green and blue weights and load peak at the EDID to the csv and the dense rows, with the static tracking factor in the load
- [x] Write the include with the matrices, weights, tracking points and response time
- [x] Extend `--check` with the mean error and C2 rules
- Results: mean error 0.48% over 52 windows, worst 2.61% (100% blue), RMS 0.74%, held out RMS 1.03%, weights 0.9307 and 0.9123, peak elasticity about 0.80, curvature step 0.004. The flat end uses a quintic that leaves 0 with a zero second derivative, since a smooth max leaks a small gain below it and touched frames needing none

## 3. Shader

Done when `eotf_check.py --suite` passes in HDR10 and scRGB

- [x] Native panel load with a per-bin load ratio in the histogram
- [x] Robust content top
- [x] Panel load filter inside the solve, midtone lock and softmin whiteout pick
- [x] Smoothed bin density, slope floor and content top attack and release
- [x] Highlight chroma roll-off
- [x] Remove accuracy settings and rolling phases, OSD in nits, bend start fix, clean code pass
- The algorithm lives in `Shaders/EOTF_BoostCore_27M2N6500.fxh`, included by both the shader and `boost.hlsl`, so the two can't drift
- The filter and the content top land exactly on their target once within 0.001% of load and 1e-5 PQ, or a held frame never stops moving in the last bits

## 4. DwmBoost

Done when `parity_check.py` passes

- [x] Mirror into `boost.hlsl`, pipeline, present hook settle time and RenderFrame
- [x] Update `parity_check.py`
- Final settle time is 4.0 s, including load feedback and the PQ release. Parity passes on every frame and on widths up to 16384 pixels, worst 0.70 of the tolerance on the noise frame

## 5. Checks, null test and docs

Done when they describe the code as it is

- [x] `RenderEffect` `--frame-ms`, `--from` and `--frames` with `--then`, and `eotf_check.py --suite`
- [x] Null test on the new model
- [x] README and CLAUDE.md

## 6. Staged review fixes

Done when all eight review findings have regression coverage and the renderers, fit, EOTF suite and parity pass.

- [x] Use sub-bin averages for the content top, with no raw-maximum shortcut
- [x] Deposit density continuously between PQ centers before smoothing
- [x] Snap the panel filter to the target based on its remaining gap
- [x] Bound DWM settling separately in load and PQ, including gain feedback
- [x] Add the shared core to the DWM shader build dependencies
- [x] Balance every null-test pattern in tracked native-panel load
- [x] Compare HDR10 patches with quantized input targets
- [x] Scale histogram fixed point for wide buffers without losing native-resolution precision
- [x] Regenerate bytecode and run targeted checks, both full EOTF suites and DWM parity

The review reproduced 10.5-code single-pixel highlight changes, a 5.57-code jump at 640 nits, a 0.281-code persistent filter error at 240 Hz, and an 8K red frame losing compensation through int32 overflow. The previous settle bound mixed log-luminance and PQ units and omitted load feedback. The corrected load bound is about 3.47 seconds and the content-top bound is 1.85 seconds; DWM holds composition for 4 seconds to leave room for discrete refresh steps.

The density fix also retains slope values just outside the active span: interpolation already reads those centers before the content top reaches them. Activating those slopes at an edge was a separate source of highlight jumps. The breathing check compares neighboring steps rather than a global median that included the lamp's long clamped plateau; independent one-nit probes at 384, 448, 512, 640 and 768 nits still reject the original discontinuities.

Once the load correctly lands on its target, a held HDR10 peak-window frame exposed a last-bit gain cycle. The output now holds the previous gain within one bisection interval while the load continues to its true target. This is below a small fraction of a PQ code and lets fixed dithering settle without freezing a biased load.

## Final verification, 2026-11-03

- MSVC Release builds of both renderers, the hook and the app pass; editing only the shared core triggers bytecode regeneration
- The panel include still matches its fit, mean error 0.48% over 52 measured windows
- The full EOTF suite passes in HDR10 and scRGB. Worst temporal patch errors are 0.116 and 0.103 codes respectively, under the unchanged 0.25-code tolerance
- A single pixel in the same populated level bin moves other HDR10 levels by 0.041 codes, and in the same sub-bin by 0.004; both changes round to zero in scRGB
- The 639-to-640-nit probe moves the fixed lamp by 0.172 codes in scRGB, down from 5.57 before the fixes; HDR10's one-nit probe is unchanged after input quantization
- The 240 Hz load transition ends 0.015 codes from target in HDR10 and 0.050 in scRGB; both content-top checks match settled output at the 4-second DWM deadline
- Native-width, 8K and 16384-pixel-wide saturated frames match, and every null-test state stays within 0.5% of its requested load
- DWM parity passes, including the wide-buffer cases
- The full suite used a temporary bytecode-caching copy of RenderEffect; its output was checked pixel-for-pixel against the normal renderer in both formats. The committed renderer is unchanged by that acceleration
- Rendered gradients and color bars were inspected through SDR previews. Numerical checks use the original HDR values; no new physical panel measurements were taken
- Informational GPU timings on the synthetic game frame at 2560 by 1440: 0.507 ms for RenderEffect's scRGB effect and 0.319 ms for RenderFrame's pipeline
