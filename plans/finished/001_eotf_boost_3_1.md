---
id: 001
title: EOTF Boost 3.1
status: finished
created: 2026-10-28
updated: 2026-10-28
finished: 2026-10-28
---

# EOTF Boost 3.1

A new shader, `Shaders/EOTF_BoostMod3.1_27M2N6500.fx`, that makes the 27M2N6500 in HDR Peak 1000 mode track the PQ EOTF as closely as the panel physically allows. It starts as a copy of `EOTF_BoostMod3.0.fx`, which stays as it is, and runs on a panel model fitted to every row of `abl_curve.csv`. Where the csv doesn't cover something, the research below decides. DwmBoost moves to 3.1 in the same work

## Facts

### Goal

- Shown luminance matches the PQ target wherever the panel can reach it
- Where it can't, the gain goes up only as far as the panel can deliver, the shoulder rolls highlights off under the ceiling with their detail kept, and no highlight clips

### What abl_curve.csv holds

34 rows from RAW phone photos of dogegen windows: white at 2, 5, 10, 25, 50 and 100%, grays at 100, 201 and 398 nits at 2, 25, 50 and 100%, red, green and blue at 2, 25, 50 and 100%, yellow at 2, 50 and 100%, and the black screen. `self_relative` is reliable for every row, while the colored rows' `relative`, `x` and `y` go through the phone's color matrix and are rough. The camera gives ratios only, so the absolute scale rests on taking the 2% white as the EDID's 1015.24 nits

Compensation is a ratio between windows of one pattern, so it doesn't depend on the absolute scale. The scale matters for the load's normalization, which the fit finds as the load peak

### Panel model

From `Shaders/verify/fit_panel_model.py`, errors in dimming, measured over predicted, across the 25 rows above 2%:

| Load model | RMS | Worst | Held out RMS |
|---|---|---|---|
| Brightest channel, load peak fitted | 1.33% | 3.85% | 1.69% |
| Brightest channel, load peak at the EDID | 1.51% | 3.92% | 1.95% |
| Brightest channel weighted per channel | 1.26% | 2.92% | 1.88% |
| 2.0's mix of mean and brightest channel | 2.70% | 4.64% | 3.18% |
| Channel sum | 13.46% | 23.62% | 15.63% |
| BT.2020 luminance | 25.28% | 63.12% | 25.98% |

- The load is the frame mean of min(maxRGB in linear BT.2020, 1056.84) / 1056.84. Red, green, blue and yellow windows at full drive dim like white windows of the same size, so channels don't add
- Gray 593 at 50% and gray 667 at 25%, loads 9.5 and 9.4% with very different codes, dim to 0.484 and 0.483, so the load is taken in linear light
- Compensation is 1 up to 3.16%, rises by 0.168 per percent up to a knee at 10.32%, and follows a power law with exponent 0.2366 above it. It reads 2.149 at 10%, 2.716 at 25%, 3.200 at 50% and 3.770 at 100%
- The elasticity, the curve's log slope against load, peaks at 0.787 just under the knee. Below 1 the boost always pays for the load it adds, so full compensation exists and is unique
- Per-channel weights fit better but predict held out rows worse, so the model keeps the plain brightest channel
- Chromaticity moves at most 0.0013 u'v' for any pattern between its window sizes, so one gain for all channels keeps chromaticity
- The ceiling at full compensation never drops under 269 nits
- `PANEL_PEAK_NITS` 1015.24 sits at 10-bit PQ code 770.8, which rounds up to code 771 at 1017.0 nits. `PANEL_SIGNAL_PEAK_NITS` 1007.93, code 770, is the brightest code at or under the peak and the top of every boosted frame

### Research behind the design

#### Load and limiter

- CIC32 (DXOMARK) predicts an OLED's colorimetry from frame power summed over an RGB grid, and Dong, Choi and Zhong (DAC 2009) sum a per-channel power over pixels. Both sum over channels, which this panel's limiter doesn't
- LG Display's US 9607552 takes APL as the frame mean of max(R, G, B) every vblank, the metric the fit found, except this panel takes it in linear light
- tftcentral measured a QD-OLED at 1% APL with the RGB sum equal to the white peak, so colors add up to white in luminance even though this panel's limiter doesn't add them

#### Samsung controller

From version 22 of `QD_burn_in.c` in Samsung's QNxxS95DAFXZA open source release, related code, not this monitor's firmware

- With logo protection off, it applies one uniform cut from the 4 most dimmed cells instead of the regional map, and PC and movie modes get no local protection at all
- With both an app and the OSD on screen, a counter lowers a uniform ceiling to 75%. That follows OSD state the signal can't show
- A peak exposure accumulator writes to a hardware register whose effect the file doesn't show, and the retention classifier is commented out in this release
- tftcentral separates ABL, the power budget that can't be turned off, from ASBL or TPC, minutes-scale static dimming, and GSR, local logo dimming

So with the OSD's protections off, the power limit is the only behavior left to compensate, and 3.1 compensates it alone

#### Timing

- libplacebo's peak detection smooths with a single-pole IIR, coefficient `1 - exp(-1/period)` with a 20 frame period, and lets scene changes through with a smoothstep between 1 and 3 units of 1% PQ. A single-pole IIR approaches its target monotonically, so a held frame settles without overshoot

#### Tone mapping

- BT.2390's EETF knee is 1.5 times the target maximum minus 0.5 in PQ. BT.2408 puts reference white at 203 nits and suggests blending RGB with maxRGB to control the desaturation of bright colors
- Burke, Smith and Zink (SMPTE 2020) found maxRGB the only variant that keeps the output inside the RGB volume with zero u'v' shift
- libplacebo blends a maxRGB gain with per-channel tone mapping at a film strength, weighted in as the shoulder compresses
- Ward Larson, Rushmeier and Piatko (1997) share a tone curve's range by the histogram

#### Windows

- scRGB 1.0 is 80 nits. Apps read the display's MaxLuminance and MaxFullFrameLuminance from the EDID or the HDR calibration profile, so the calibrated values decide what games tone map to
- dwm_lut hooks DWM in HDR and disables DirectFlip and MPO on monitors it runs on

### Decisions

- The panel model is the brightest channel load in linear BT.2020 with the knee model's compensation, fitted by one script to every row and written into the generated `Shaders/PanelModel_27M2N6500.fxh`. 3.1, ABL_NullTest and DwmBoost include it
- The histogram covers every pixel every frame. Six rolling phases stay as an option, `APL_FULLFRAME_ROLLING_PHASES`
- Full compensation is solved within the frame by bisection on the histogram, so a frame needs no settle frames
- The gain pick scores 9 gains from 1 to full compensation by the predicted EOTF error, pixel-weighted log2 error of each bin's shown level against its target under the model, and takes the parabola vertex around the best. Full compensation scoring best is taken as is. 3.0's score stays as an option
- The shoulder stays a top-down histogram shoulder in maxRGB, starting at 203 nit reference white or BT.2390's knee where that's higher. The BT.2390 knee alone stays as an option. An optional per-channel blend, off by default, keeps the brightest channel so the load and ceiling stay exact
- The boosted frame tops out at `PANEL_SIGNAL_PEAK_NITS`, so no 10-bit code passes the peak
- Timing is libplacebo's IIR on log gain with its scene-change bypass and defaults, since the csv has no timing data. DwmBoost runs the same filter on time, 20 frames at 240 Hz, since DWM composes only when something changes
- HDR10 output is dithered by one code of triangular noise, the same on all channels, only on pixels the boost changed. The calibration LUT runs after the boost, and the load counts what it sends
- Nothing beyond the power limit is compensated, from the Samsung controller research

### Results

EOTF score in log2, pixel-weighted, under the panel model on HDR10 test frames:

| Frame | 203 knee | BT.2390 knee | 3.0's score, BT.2390 knee |
|---|---|---|---|
| Dim | 0.0006 | 0.0006 | 0.0006 |
| Game | 0.0101 | 0.0101 | 0.0101 |
| Saturated | 0.246 | 0.247 | 0.247 |
| Bright | 0.301 | 0.326 | 0.457 |
| Sky | 0.414 | 0.439 | 0.972 |
| Snow | 1.002 | 1.085 | 1.389 |

The 203 knee wins or ties on every frame, so it's the default. The EOTF score beats 3.0's on every frame where they differ. Every frame passes `eotf_check.py` in HDR10 and scRGB: nothing sends past 1007.93 nits and the curve rises everywhere

GPU time per frame at 2560 by 1440 on an RTX 2070, against 4.2 ms per frame at 240 Hz:

| Run | ms |
|---|---|
| 3.1, full histogram | 0.761 |
| 3.1, 6 rolling phases | 0.371 |
| 3.1, shoulder blend 0.5 | 0.601 |
| DwmBoost pipeline | 0.47 |

- The null test's curve checks land at out loads of 3.0, 6.0, 8.0, 9.7, 25.0 and 50.2%. The fill's 10-bit code moves the raw load slightly, and the elasticity near the knee turns that into the 9.7%. The check stays valid since the boost follows the load it sees
- DwmBoost matches 3.1 on scRGB within 0.11 of a 10-bit code, apart from channels near black on saturated colors, where the two compilers' rounding flips an FP16 value by one step. Those stay under 0.37 of one FP16 step of their pixel
- The rolling and blend timings come from before the solve's extra syncs and the content top, which added about 0.27 ms to the full histogram
- The solve's frame sums once returned before every warp had read them, so a fast warp could overwrite a total that slower warps then scored their bins with. On frames with a wide spread of bright levels, like a bright out of focus cyan background, the pick fell to gain 1 and the boost faded out and back as the content moved. A sync after each read fixed it, and `parity_check.py` now checks that bright fields and cyan gradients over most of the screen keep full compensation
- The tone curve's top sits at the brightest level the frame's pixels can hold, the upper edge of the highest sub-bin with pixels, so the brightest content lands on the ceiling instead of up to a bin below it. The top-down curve never rises past the source
- Gains whose mean predicted error differs by less than half a 10-bit code step, 0.0065 in log2, count as tied and the higher one wins. A frame whose solve never needs gain gets exactly 1, so its pixels skip the boost and the dither
- DwmBoost settles in 0.48 s, the time the smoothing takes to close a log gain gap of log2(3.770) to half the smallest 10-bit code step under the signal peak

## 1. Panel model from abl_curve.csv

Done when the fit script reproduces the facts from abl_curve.csv, writes the include, and its check passes

- [x] Write `Shaders/verify/fit_panel_model.py`, fitting the knee model and the load peak by least squares on log dimming, with residuals, RMS, worst row, held out RMS, the glare-kept shift and the elasticity
- [x] Compare the load models in the facts table
- [x] Write `Shaders/PanelModel_27M2N6500.fxh`, marked as generated, with the signal peak
- [x] Add a `--check` mode that fails on a stale include or elasticity of 0.95
- [x] Add the include and the script to CLAUDE.md

## 2. Build 3.1 on 3.0's code

Done when 3.1 runs in RenderEffect on HDR10 and scRGB frames with the panel model and the checks pass

- [x] Copy 3.0 to `EOTF_BoostMod3.1_27M2N6500.fx` with its own technique name
- [x] Include the panel model and drop 3.0's table, its luma load and its G8 graph data
- [x] Bin the histogram by the brightest channel over every pixel every frame, with rolling phases as an option
- [x] Time it on the GPU at 2560 by 1440
- [x] Solve full compensation within the frame
- [x] Pick the gain by predicted EOTF error, with 3.0's score as an option
- [x] Start the shoulder at reference white or BT.2390's knee, top it out at the signal peak, and add the optional per-channel blend
- [x] Dither the HDR10 output
- [x] Show the loads, full compensation, gain, ceiling, knee and brightest source level on the OSD
- [x] Rebuild the debug graph from the panel model
- [x] Count the calibration LUT's output in the load
- [x] Smooth with libplacebo's IIR and scene-change bypass

## 3. Checks

Done when every check passes on the test frames

- [x] Write `Shaders/verify/eotf_check.py`, which replays boosted frames through the panel model, reports the shown error by level band, and fails on a send past the signal peak or a falling curve
- [x] Compare the knee and pick options on bright, dim, saturated, game, sky and snow frames
- [x] Move ABL_NullTest to 3.1 and the panel model, and check every test compiles and renders in HDR10 and scRGB

## 4. DwmBoost

Done when the hook matches 3.1 at its defaults and the parity check passes

- [x] Rewrite `boost.hlsl` as 3.1's scRGB path with its defaults baked and the tone curve lookup built in the solve pass
- [x] Update `pipeline.h` and `pipeline.cpp` to the new textures, one settle run and the settle time
- [x] Update `RenderFrame` to the new state
- [x] Rewrite `parity_check.py` to render frames through the hook and 3.1 and compare them, and to check the geometry and the settle time

## 5. Docs

Done when CLAUDE.md and the README describe 3.1 and DwmBoost as they are

- [x] Add 3.1, the panel model and its checks to CLAUDE.md, with what stays in sync
- [x] Document the fit in the README's abl_curve.csv section
- [x] Give 3.1 its own README section with how it works, settings, stats, preprocessor options and verification
- [x] Document the Windows HDR calibration values, 1015 nits peak and 265 nits full frame
- [x] Warn that 3.1 goes last, DwmBoost stays off while it runs, the game fills the screen and no profile changes luminance after it
- [x] Document that the OSD's burn-in protections stay off and only the power limit is compensated
- [x] Move the README's null test and DwmBoost sections to 3.1
