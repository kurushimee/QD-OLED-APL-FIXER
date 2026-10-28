---
id: 002
title: Review fixes for 3.1 and DwmBoost
status: finished
created: 2026-10-28
updated: 2026-10-28
finished: 2026-10-28
---

# Review fixes for 3.1 and DwmBoost

A review of `EOTF_BoostMod3.1_27M2N6500.fx`, `boost.hlsl` and the DwmBoost code around them as of e0527a1, and fixes for what it found

## Facts

### Found by running the renderers

- At gain exactly 1 the bend width is 0, so the knee mismatch is 0 for every knee under the crossing, and the bisection only moves up on a mismatch under 0. The knee falls to 0, the lookup takes over every pixel, and on a frame that needs no gain up to 25% of the pixels come out changed and dithered in HDR10. A 0.6% load frame scored 0.0041 stops of error where it should score 0
- The tone curve's top is the upper edge of the highest histogram sub-bin holding pixels, up to a sixteenth of an octave over the brightest pixel. A 4000 nit window landed on code 768 instead of 770, so the brightest highlights sit up to 2 codes under the signal peak
- The scRGB lookup clamps each entry to the ceiling, so between the entry under the top and the clamped one over it the interpolation sits under the ceiling, up to a quarter code
- fxc and ReShade's compiler fold `NitsToPQ(PANEL_SIGNAL_PEAK_NITS)` a few ulps under the ceiling the GPU computes at gain 1, so the headroom left for the bend came out negative and kept the knee collapsing after the bisection fix. The headroom is clamped at 0
- Hardware bilinear filtering weighs the lookup's two entries in 8 bits, so 3.1 now reads both entries and interpolates them itself, the same way the hook does

### Found by reading

- libplacebo eases the frame's mean PQ with the same IIR as the peak and measures the scene change against that eased mean, `delta = |avg_pq - obj->peak.avg_pq|` right after the IIR step, and skips the scene change when either threshold is 0. 3.1 and the hook compare against the previous frame's raw mean, so a slow fade never counts as a scene change, and thresholds at 0 bypass every frame
- The tie tolerance is half a code step per pixel over every pixel, black included. Black shows no error at any gain, so on a mostly black frame the tolerance over the lit pixels grows by the black share, 10 times on a frame that's 90% black
- The dither clamps at the signal peak, so a pixel on the top code loses its upward half and its mean drops by an eighth of a code
- An SDR or HLG back buffer gets decoded as PQ and boosted. ReShade adds `BUFFER_COLOR_SPACE` before the preset's definitions and never overrides a macro, so a game that sends HDR10 through its own API while ReShade reports SDR can't fix it from the preset
- DwmBoost eases toward new content by the time since the last run, so after the desktop sat still the first frame of new content gets the whole gap and the gain jumps instead of easing
- A frame that fits under the ceiling still gets its top darkened by the bend, since the bend stays a quarter octave wide around the ceiling. A 350 nit window under a 358 nit ceiling kept 0.997 of its level, and a 360 nit window that only had to come down to 0.993 came down to 0.976
- The null test's window check rounds the window's side, which can push the window past the signal peak
- DwmBoost targets the first monitor with HDR on. Every third generation QD-OLED TB400 panel in its 1000 nit mode measures close to `abl_curve.csv`, so the target stays any HDR monitor and isn't matched by name

### Results

- The panel model check and the parity check pass. Every parity frame now matches the shader exactly except the noise frame, whose worst pixel went from 84 codes to 21.5, at 0.66 of the tolerance
- Frames that need no gain come out of the hook and of the shader in both formats with 0% of their pixels changed
- A 4000 nit window lands on code 770 in HDR10 without dither, and at 1007.45 nits in scRGB and in the hook, within the 0.62 nit FP16 step of the peak. With dither its mean is 769.94, from the GPU's `pow` precision
- Windows that fit under the ceiling keep 0.9994 of their level, limited by FP16, and the 360 nit window keeps 0.992 where it needs 0.993
- The shader's GPU time stayed about 0.5 ms in the test renderer

Mean EOTF error under the panel model, in stops:

| Frame | Before | After |
|---|---|---|
| Dim | 0.0041 | 0.0001 |
| Game | 0.0087 | 0.0087 |
| Saturated | 0.8205 | 0.8186 |
| Bright | 0.7159 | 0.7136 |
| Sky | 1.0043 | 0.9991 |
| Snow | 1.4590 | 1.4496 |

The dim frame's output is bit-identical to its source, and its remaining 0.0001 comes from the checker reading a 16-bit PNG

### Left open

- The host finds its target monitor only at startup and doesn't follow display changes
- The hook matches the target's swapchain only by its size, its FP16 format and the host's HDR flag
- DwmBoost wasn't run live inside `dwm.exe` for this review, only through `RenderFrame`

## 1. Shader and hook

Done when 3.1 and `boost.hlsl` carry every fix and the parity check passes

- [x] Let the knee bisection move up on a mismatch of 0
- [x] Track the frame's exact brightest level every frame and top the curve there
- [x] Leave the lookup unclamped at the top and clamp after interpolating
- [x] Keep the bend no wider than the content rises past the ceiling
- [x] Ease the mean PQ and measure scene changes against it, and turn them off at a threshold of 0
- [x] Count only lit pixels in the tie tolerance
- [x] Dither within half a code of the peak with rectangular noise
- [x] Pass SDR and HLG back buffers through, with `BOOST_COLOR_SPACE` to override
- [x] Regenerate `boost_bytecode.h`

## 2. DwmBoost host and hook

Done when DwmBoost builds

- [x] Ease new content by one refresh after a still desktop

## 3. Null test and checks

Done when every check passes and the before and after scores are in the facts

- [x] Keep the null test's peak window under the signal peak
- [x] Add parity checks that a frame needing no gain passes through untouched and that the brightest level lands on the signal peak
- [x] Rerun the panel model check, the parity check and the test frames

## 4. Docs

Done when the README and CLAUDE.md describe the fixed behavior

- [x] Update the README's how it works, settings, preprocessor definitions, DwmBoost and verification sections
