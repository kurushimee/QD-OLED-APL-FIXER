# EOTF Boost for the Philips Evnia 27M2N6500

This ReShade shader offsets the automatic brightness limiter (ABL) of the **Philips Evnia 27M2N6500**, a 27-inch 1440p third-generation QD-OLED monitor, in **HDR Peak 1000** mode.

QD-OLED panels get dimmer when a large part of the screen is bright. On this panel, a small highlight reaches the full peak of about 1015 nits, but a full white screen reaches only about a quarter of it. The shader measures how much each frame loads the panel and raises the HDR signal by the amount the panel is expected to dim, so every level shows at its PQ target wherever the panel can reach it. Where it can't, the gain goes up only as far as the panel can deliver and the highlights roll off under the panel peak with their detail kept. It works much like the "EOTF Boost" option on some MSI QD-OLED monitors.

The shader is [`Shaders/EOTF_BoostMod3.1_27M2N6500.fx`](Shaders/EOTF_BoostMod3.1_27M2N6500.fx), EOTF Boost 3.1. It runs on a [panel model](#the-panel-model) fitted to the measurements in `abl_curve.csv`. [`DwmBoost/`](#desktop-wide-dwm-version) runs the same boost on the whole Windows desktop.

## Calibration target

The panel model matches this setup:

| Setting | Value |
|---|---|
| Monitor | Philips Evnia 27M2N6500 |
| Monitor HDR mode | HDR Peak 1000 |
| Burn-in protections in the monitor's OSD | All off |
| Windows HDR | On |
| Max luminance in the Windows HDR Calibration app | 1015 nits, the peak the measurement is scaled to |
| Max full-frame luminance in the Windows HDR Calibration app | 265 nits, the 100% white window |

Games that tone map read the two luminance values, so they keep their content inside what the panel shows. Other monitors and other HDR modes dim in a different way, so on them the shader boosts too much or too little. To use it with another display, see [Adapting to another monitor](#adapting-to-another-monitor).

## Requirements

- A game that outputs HDR as either HDR10 (PQ) or scRGB.
- ReShade with its standard shader package, which provides `ReShade.fxh`.
- A game that runs on DirectX 11, DirectX 12, or Vulkan. The shader uses compute shaders, which ReShade does not support on DirectX 9 or 10.

## Installation

1. Install ReShade for the game and include the standard effects package.
2. Copy `EOTF_BoostMod3.1_27M2N6500.fx` and `PanelModel_27M2N6500.fxh` from `Shaders/` into the game's `reshade-shaders\Shaders` folder.
3. Open the ReShade overlay and turn on **EOTF_Boost_3_1_27M2N6500**.
4. Move it to the bottom of the effect list, so it works on the final image that the monitor receives.

The shader reads HDR10 or scRGB, whichever ReShade reports, and its defaults match the calibration target.

### Using it

- Keep the shader last in the effect chain, since it measures the signal the panel receives.
- Keep DwmBoost off while the shader runs, or DWM boosts the frame again.
- Let the game fill the screen. Light outside the back buffer adds load that the shader can't see.
- Don't let a Windows color profile or another LUT change luminance after it.
- Keep every burn-in protection in the monitor's OSD off. Samsung's `QD_burn_in.c`, from related controller code for its TVs and monitors, gives PC modes no local protection with logo protection off, and its only other uniform cut follows the OSD's own state, which the signal can't show. So the shader compensates the power limit alone.

## How it works

1. **Measure the load.** Every frame, the shader builds a histogram of every pixel's brightest channel in linear BT.2020 and takes the load from it the way the panel model does.
2. **Solve full compensation.** Boosting the frame raises its load, so the shader finds the gain that equals the compensation at the load that gain causes, by bisection on the histogram within the frame.
3. **Pick the gain.** Full compensation shows every level at its target only when the frame fits under the ceiling, the signal peak divided by the gain. The shader scores 9 gains from 1 to full compensation by their predicted EOTF error, each histogram bin's shown level under the panel model against its target, in log2 and weighted by its pixels. It takes the vertex of the parabola through the best gain and its neighbors, so the gain moves smoothly as the frame changes. Gains whose mean error over the lit pixels differs by less than half a 10-bit code step look the same on the panel, so the highest of them wins, and full compensation is taken as is when it scores best. Black shows the same at every gain, so it counts toward neither the error nor that tolerance.
4. **Tone map the highlights.** Levels below the shoulder get exactly the gain. The shoulder starts at BT.2408's 203-nit reference white, or at BT.2390's knee where that's higher, and the histogram shares its range up to the ceiling out from the top down (Ward Larson, Rushmeier, and Piatko 1997), with no level stretched past its own contrast. A bend of up to a quarter octave joins the two. It is never wider than the frame's content rises past the ceiling, so a frame that fits under the ceiling keeps its source levels, and one just over it comes down only as far as it has to. The frame's brightest pixel lands on the ceiling, so its brightest channel is sent at most at 1007.93 nits, the brightest 10-bit PQ code at or under the 1015.24-nit peak, and nothing clips. All three channels of a pixel scale by the same factor, so hue and saturation stay.
5. **Smooth the gain.** The gain eases on its log with libplacebo's single-pole filter over a 20-frame period. The frame's mean PQ eases with the same filter, and a frame whose mean PQ sits 1% to 3% away from that eased mean counts as a scene change and goes through partly to fully.
6. **Dither HDR10.** Pixels the boost changed get triangular noise of one 10-bit code before quantization, so each code's mean lands on its target. Within half a code of the signal peak the noise is rectangular over half a code each way, since the clamp at the peak would cut off the triangular noise that rounds up.

Under the panel model, the mean EOTF error over a frame's pixels is under 0.001 stops on a dim frame and 0.01 stops on a game frame. It rises to 0.25 to 1.0 stops only on frames whose bright areas fill much of the screen, a bright sky or a snowfield, where the panel can't reach the target. The shader takes 0.76 ms per frame at 2560 by 1440 on an RTX 2070.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Enable EOTF Boost | On | Turns the compensation on or off. |
| Gain Smoothing Period (frames) | 20 | Sets the period of the gain's smoothing. 0 turns smoothing off. |
| Gain Pick | Lowest predicted EOTF error | **Brightness times kept detail** picks by the score of the upstream shader it started from instead. |
| Scene Change Low Threshold (% PQ) | 1 | Sets how far the frame's mean PQ sits from its eased mean where a scene change starts to bypass the smoothing. 0 on either threshold turns scene changes off. |
| Scene Change High Threshold (% PQ) | 3 | Sets the distance where it bypasses the smoothing fully. |
| Shoulder Start | Held at 203 nit reference white | **BT.2390 knee** starts the shoulder at BT.2390's knee alone, which falls lower on bright frames. |
| Shoulder Channel Blend | 0 | Blends each channel in the shoulder toward its own trip through the tone curve, as BT.2408 and libplacebo's film strength do. The brightest channel stays, so the load and the ceiling stay exact, but colors in the shoulder shift. |
| Dither HDR10 Output | On | Dithers the pixels the boost changed. |
| Show Stats | Off | Shows live numbers. |
| OSD Brightness | 0.5 | Sets the brightness of the stats display and the debug graph. It does not change the image. |

The stats display has these rows:

| Row | Meaning |
|---|---|
| RAW LOAD | Load of the game's frame. |
| OUT LOAD | Load the panel sees after the boost. |
| FULL | Full compensation for the frame. |
| GAIN | Gain the boost applies. |
| CEIL | Ceiling in source nits, the signal peak divided by the gain. |
| KNEE | Source level where the bend leaves the gain, in nits. |
| RAW NITS | Brightest channel of the brightest source pixel. |

### Preprocessor definitions

These options are set in the ReShade overlay, in the shader's preprocessor definitions.

| Definition | Default | What it does |
|---|---|---|
| `BOOST_COLOR_SPACE` | ReShade's `BUFFER_COLOR_SPACE` | Sets the back buffer's color space: 2 for scRGB, 3 for HDR10 PQ, and 1 for SDR or 4 for HLG, which pass through untouched. Set 3 for a game that sends HDR10 while ReShade reports SDR. |
| `APL_FULLFRAME_ROLLING_PHASES` | 0 | Above 0, refreshes the histogram in that many row phases, one per frame, which costs less GPU time but makes the load lag. |
| `PQHDRLUT_ENABLE` | 0 | 1 adds a 3D calibration LUT that runs after the boost. |
| `PQHDRLUT_SIZE` | 65 | Sets the edge size of the calibration LUT. |
| `ENABLE_APL_GRAPH` | 0 | 1 adds a debug graph of the boost curve. |
| `ENABLE_UI_TOOLTIPS` | 0 | 1 adds a tooltip to each setting. |

With `PQHDRLUT_ENABLE=1`, the shader loads `PQHDRLUT.cube` from ReShade's texture folders and adds an **Enable PQ HDR LUT** setting. The LUT takes and returns PQ-encoded Rec.2020 values and runs on the boosted signal, and the load counts what it sends.

With `ENABLE_APL_GRAPH=1`, the shader can draw a graph of input nits against output nits from the panel model: the identity line, the panel's unboosted output at the frame's load, the boosted signal, the predicted panel output, and an optional BT.2390-style reference curve. It is a tuning aid and does not change the image.

## Measured data

### abl_curve.csv

`abl_curve.csv` holds the measurement of the panel: white windows from 2% to 100% of the screen, gray windows at 100, 201, and 398 nits, red, green, blue, and yellow windows, and the black screen. Each row is one dogegen `window <size> <r> <g> <b>` pattern, with 10-bit PQ codes in BT.2020. The window size is a percentage of the screen area.

Every value is the luminance in the middle of the 2% window, the same spot on the screen in every pattern. It comes from RAW photos with locked camera settings, with the black screen subtracted, the camera's lens glare fitted and removed, and each reading divided by the 2% white peak at the time of the shot, which cancels the panel's slow drift. The 2% white counts as 1015.24 nits, the panel's EDID max luminance. The 2% grays land at 96.6, 199.3, and 391.8 nits for 100.2, 201.0, and 397.9 nits of signal, so the scale holds.

| Column | Meaning |
|---|---|
| `pattern`, `r`, `g`, `b` | Pattern name and its 10-bit PQ codes |
| `signal_nits` | What the brightest code asks for in PQ |
| `window_percent` | Window area as a percentage of the screen |
| `load_percent` | Window area times the brightest channel's linear signal level relative to the 1015.24-nit peak, capped at 1 |
| `luminance_load_percent` | Window area times the pattern's own 2% `relative`, the frame's mean luminance as a percentage of full white at peak |
| `relative` | Luminance relative to the 2% white peak |
| `nits` | `relative` times 1015.24 |
| `self_relative` | Luminance relative to the same pattern's 2% window, which is the panel's dimming alone. Compensation is its reciprocal |
| `relative_with_glare` | `relative` before the lens glare was removed |
| `x`, `y` | CIE 1931 chromaticity, with the 2% white taken as D65 |
| `camera_r`, `camera_g`, `camera_b` | Raw sensor values in the measuring spot, with the black screen subtracted, before glare removal and drift correction. The black row keeps them unsubtracted |

`self_relative` is reliable for every pattern. `relative`, `nits`, `x`, and `y` of colored windows rely on the phone's color matrix, which can't separate narrow QD primaries well, so they're rough, and red likely reads too bright. Chromaticity shifts between sizes of one pattern are real.

### The panel model

The panel dims a frame by the mean over all pixels of its brightest channel in linear light, relative to a load peak and capped at 1. A full red, green, blue, or yellow window dims like a white window of the same size, and a gray window dims like a white window whose area is its own area times its level. Gray 593 at 50% and gray 667 at 25% carry loads of 9.5% and 9.4% with very different codes and dim to 0.484 and 0.483, so the load is taken in linear light, not in code values.

[`Shaders/verify/fit_panel_model.py`](Shaders/verify/fit_panel_model.py) fits the compensation curve and the load peak to every row by least squares on the log of the dimming, and writes them into [`Shaders/PanelModel_27M2N6500.fxh`](Shaders/PanelModel_27M2N6500.fxh), which the shader, the null test, and DwmBoost include. Compensation is 1 up to a load of 3.16%, rises by 0.168 per percent up to a knee at 10.32%, and follows a power law with an exponent of 0.2366 above it, with the load peak at 1056.8 nits. It reaches 2.149 at 10%, 2.716 at 25%, 3.200 at 50%, and 3.770 at 100%. Its log slope against load peaks at 0.787 just under the knee, so the boost always pays for the load it adds and the gain that cancels the dimming exists and is unique.

How well each load model fits the 25 rows above 2%. The held out RMS predicts each row from a fit to the others:

| Load model | RMS error | Worst error | Held out RMS |
|---|---|---|---|
| Brightest channel, load peak fitted | 1.33% | 3.85% | 1.69% |
| Brightest channel, load peak at the EDID | 1.51% | 3.92% | 1.95% |
| Brightest channel with per-channel weights | 1.26% | 2.92% | 1.88% |
| A mix of mean and brightest channel, a pure primary at 0.75 of white | 2.70% | 4.64% | 3.18% |
| Channel sum | 13.46% | 23.62% | 15.63% |
| BT.2020 luminance | 25.28% | 63.12% | 25.98% |

Per-channel weights fit better but predict held out rows worse, so the model keeps the plain brightest channel. The worst row is the 100% blue window, which dims 3.9% less than predicted. Luminance can't explain the colors, since a 25% blue window carries 2.6% of full white's luminance and still dims like a 25% white window. The colored windows are pure BT.2020 primaries, which the panel shows at its own primaries, so the data can't tell whether the brightest channel should come from BT.2020 or from the panel's own primaries, and the model takes it in BT.2020.

## Verification

`Shaders/verify/` builds `RenderEffect.exe`, which runs a ReShade effect on a saved frame the way ReShade 6.8 runs it in a D3D11 game. From `Shaders/verify/`:

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
build/bin/Release/RenderEffect ../EOTF_BoostMod3.1_27M2N6500.fx hdr10 source.png out.png
```

`scrgb` in place of `hdr10` runs it on an FP16 scRGB back buffer. Frames are 16-bit PQ BT.2020 PNGs like ReShade's HDR screenshots.

[`Shaders/verify/eotf_check.py`](Shaders/verify/eotf_check.py) replays a boosted frame through the panel model and reports the shown error against the PQ target by level band. It fails if any pixel sends more than the signal peak or the curve falls anywhere. Run `python eotf_check.py source.png boosted.png`. `python fit_panel_model.py --check` confirms the panel model include matches a fresh fit of `abl_curve.csv`.

## Null test

[`Shaders/ABL_NullTest.fx`](Shaders/ABL_NullTest.fx) checks the compensation by eye, with no measuring gear. Copy it next to the shader and its panel model, turn on **ABL_NullTest**, and move it above **EOTF_Boost_3_1_27M2N6500** in the effect list so the boost analyzes the pattern. It writes the format ReShade reports, as the shader reads it. In the checks that run with the boost on, the boost eases over its smoothing period after each switch, so judge the patches a moment after the fill changes.

The pattern is a grid of nine gray patches inside a wide black gap. The rest of the screen switches once a second between state A, the first content in the test's name, and state B, the second. The middle patch keeps its level in both states. In state B the others change by 2% steps, starting one frame after the switch, when the panel's own dimming follows the load:

| | Left | Middle | Right |
|---|---:|---:|---:|
| **Top** | -7.6% | -5.8% | -3.9% |
| **Middle** | -2.0% | 0 | +2.0% |
| **Bottom** | +4.0% | +6.1% | +8.2% |

The panel dims all nine alike, so the patch that holds still shows how much more the panel dims state B than the model expects, and the middle one holds still when the model is right. Report the patch that holds still, or the two it falls between. A short blink that all nine share at a switch is no reading, so judge which patch keeps its level after it. Watch only the grid, through a paper tube or cupped hands so the rest of the screen is out of view. The eye judges a patch against its surroundings, so with the changing load in view the patches seem to change even when they do not. Keep the frame rate at or under the refresh rate, as G-Sync with a frame cap does, so each frame is one refresh.

| Test | Boost | What it checks |
|---|---|---|
| Gray vs window at the peak | Off | Whether a small window at the panel peak loads the panel the same as a dim fill with the same total light. |
| Gray vs red, green, or blue | Off | Whether a BT.2020 primary loads the panel as the panel model counts it. |
| Gray vs pastel red | Off | Whether a color halfway between BT.2020 red and white loads the panel as the model counts it, which covers how mixed colors fall between a primary and white. |
| Panel latency | Off | How many frames the panel's dimming lags behind a load change. |
| Out load 3% vs 6% through 50% vs 80% | On | How far the model's compensation is off at one load relative to the other. |
| Bright window, 150 nit patches | On | Whether a bright highlight coming into view leaves lower levels alone. |
| Bright window, 150 nit patches | Off | Whether a near-peak window loads the panel the same as a fill with the same light. |
| Shadow, 1 nit patches, out load 3% vs 50% | On | Whether the panel dims near-black as much as brighter levels, so shadows get the right gain. |
| Low end, load 1% vs 3% | Off | Whether the panel holds its peak up to the model's flat end at 3.16%. |

In the model checks with the boost off, both states carry a 5% load as the panel model counts it, each color with its brightest channel at the gray's level, and the RAW LOAD row of the stats display reads the same in both. A still patch away from the middle means the panel treats one content as a heavier or lighter load than the model counts. In the curve checks, the OUT LOAD row lands close to the named loads, and the patches sit below the shoulder at every gain, so they always get the full gain. The fill's 10-bit code moves the raw load slightly, and just under the model's knee the boost turns that into a few percent of out load, so the 10% load reads about 9.7%. The check reads true either way, since the boost follows the load it sees.

The bright window checks use 150-nit patches, and both states carry the same 8% raw load. In state B half of that light gathers into a 900-nit window left of the gap, as when a bright sky or lamp comes into view, and with the boost on the shoulder rolls the window off under the ceiling. With the boost off, both states load the panel the same under the model. If the middle patch holds still there, a reading away from the middle with the boost on comes from the curve between the two out loads. Otherwise the window loads the panel more or less than its light.

The shadow check uses 1-nit patches over the out loads 3% and 50%. The boost lifts near-black by the same gain as everything else, up to 3.77 times, while the model comes from bright windows. A still patch on the dimmer side means the panel dims near-black less than bright content, so shadows get too much gain.

The low end check runs with the boost off and switches between 1% and 3% load. The model is flat up to 3.16%, so a still patch on the brighter side means the panel already dims between 1% and 3%.

The panel latency check replaces the grid with a row of five in a black band across the middle, while the rest of the screen switches between 3% and 10% load. Each patch is brightened by the model's compensation for the load of a frame further back, from the left the current frame, then 1, 2, 3, and 4 frames earlier. The panel dims all of them alike, so the patch whose delay matches the frames the panel's dimming lags behind holds still through both switches, while every other patch blinks for as many frames as its delay is off. Compare the patches with each other instead of watching one through a tube.

## Adapting to another monitor

Measure the new panel with windows the way `abl_curve.csv` does, at least white windows from 2% to 100% plus grays and colors to check the load, and replace the csv. Then run `python fit_panel_model.py` in `Shaders/verify/`, which fits the model and rewrites `PanelModel_27M2N6500.fxh` for the shader, the null test, and DwmBoost. Set the peak and full-frame luminance in the Windows HDR Calibration app to the new panel's 2% and 100% white windows.

## Desktop-wide (DWM) version

The ReShade shader only reaches a game that has ReShade installed. [`DwmBoost/`](DwmBoost) runs the same compensation on the **whole Windows 11 desktop** by hooking the desktop compositor (`dwm.exe`) and boosting each composed frame, the way [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) and the `dwm_lut` family do for desktop color calibration. It is meant for non-game desktop use, and games keep using the ReShade shader. It runs the shader's scRGB path with the same panel model, and its output matches the shader at its default settings.

While the effect is on it forces DWM composition, which **disables variable refresh rate (VRR)**, so it is turned off for gaming. It applies to the first monitor with HDR on and leaves other monitors untouched. The target follows display changes, so after HDR is toggled, the resolution or refresh rate changes, or a monitor is plugged in or removed, the boost moves to the first monitor with HDR on within 2 seconds. With no HDR monitor left the boost turns off and VRR returns, and it comes back on when one returns if it was on before.

A tray app injects a hook into `dwm.exe` and keeps it resident. Toggling is instant and reversible:

- **Ctrl+Alt+Shift+End** turns the boost on.
- **Ctrl+Alt+Shift+Home** turns it off, which reverts the composition patches so VRR returns.
- The tray menu has **Enable**, **Disable**, **Install autostart task** (an elevated logon task, no per-launch prompt), and **Quit**. Quit ejects the hook cleanly.

DWM composes only when something changes, so the gain smoothing runs on time, the shader's 20 frames at the panel's 240 Hz. On a static desktop DWM stops composing, so the app nudges the monitor once per refresh with a 1 px corner window for one frame and then 0.48 seconds after the last change, then stops. Each frame solves its full compensation on its own, and the smoothing needs up to 0.48 seconds to ease in from any gain, so this lets the gain settle on the new content without a game running. Once the desktop has sat still, the gain has settled, so the first new frame after that eases by the one refresh it has been on screen instead of the whole wait.

The tool injects only into Windows 11 25H2 (build 26200 or later) and refuses to inject if any `dwmcore.dll` byte pattern it relies on is missing or ambiguous, which also guards against a future Windows update changing the compositor.

### Building

The build needs CMake, Ninja or Visual Studio 2022, the MSVC toolchain, and the Windows 10 SDK (for `fxc`). From `DwmBoost/`:

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

This produces `DwmBoost.exe` and `DwmBoostHook.dll` in `build/bin/Release`, plus `RenderFrame.exe` for verification. Keep the first two together. The build regenerates `hook/boost_bytecode.h` from [`hook/boost.hlsl`](DwmBoost/hook/boost.hlsl) with `fxc`. The executable and tray icons are rendered from [`app/icon.svg`](DwmBoost/app/icon.svg) into the committed `.ico` files. After editing the svg, run `python make_icons.py` in `app/` (needs `resvg-py` and Pillow). MinHook (BSD-2) is vendored under `DwmBoost/third_party/minhook/` with its license.

### Verification

[`DwmBoost/verify/parity_check.py`](DwmBoost/verify/parity_check.py) renders synthetic frames, from black and flat fields to windows, highlights, a PQ ramp, primaries, and saturated noise, through the hook's pipeline and through the shader on an scRGB back buffer the way ReShade runs it, and fails if any channel differs by a quarter of a 10-bit code and by half an FP16 step of its pixel. It also checks that bright fields and bright cyan gradients covering most of the screen keep full compensation, that frames needing no gain come out of the hook and of the shader in both formats untouched, that a window far past the ceiling reaches the signal peak, that the geometry in `pipeline.h` matches `boost.hlsl`, and that the settle time covers the slowest ease the smoothing allows. It needs `RenderFrame.exe` and `RenderEffect.exe` built. Run `python parity_check.py`.

[`DwmBoost/verify/render_frame.cpp`](DwmBoost/verify/render_frame.cpp) builds `RenderFrame.exe`, which runs the hook's own pipeline and shader on the GPU over a saved HDR frame until the gain settles and writes the boosted frame. Both are 16-bit PQ BT.2020 PNGs like ReShade's HDR screenshots. It prints the raw and out load, the gain, the full compensation, the knee, the ceiling, how long the gain took to settle at the primary display's refresh rate and how far it still moves after that, and the GPU time of the whole pipeline and of the solve alone. Run `RenderFrame source.png boosted.png`.

## Older versions

These stay in the repository for reference and aren't maintained:

- [`Shaders/EOTF_BoostMod2.0_27M2N6500.fx`](Shaders/EOTF_BoostMod2.0_27M2N6500.fx) is the earlier shader for this panel. It looks the compensation up in a table from an earlier white-only measurement and counts a pure primary at 0.75 of white's load, which misses colored content by 5% to 8%. Its documentation is in this README's history before EOTF Boost 3.1.
- [`Shaders/EOTF_BoostMod3.0.fx`](Shaders/EOTF_BoostMod3.0.fx) is shansolox's v8.18.7.15 shader with local tweaks, the code base 3.1 started from. It uses upstream's compensation table and a luma load, which don't match this panel.

## Credits

This shader builds on earlier work:

- [DespairArdor/QD-OLED-APL-FIXER](https://github.com/DespairArdor/QD-OLED-APL-FIXER) is the original APL compensation shader.
- [mspeedo/QD-OLED-APL-FIXER](https://github.com/mspeedo/QD-OLED-APL-FIXER) modeled it on measurements of the Samsung Odyssey OLED G8 (G85SB) in Peak 1000 mode and added the rolling full-frame histogram.
- [shansolox/QD-OLED-APL-FIXER](https://github.com/shansolox/QD-OLED-APL-FIXER) added the color-preserving boost and versions for the Aorus FO32U/2/2P and other TB400 QD-OLED monitors. EOTF Boost 3.1 starts from its v8.18.7.15 version.

The DWM hook under `DwmBoost/` is written from scratch to keep the MIT license. [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) (GPL-3.0) was read for facts and design, the compositor functions involved, the vtable walk, and the clean-copy and static-desktop settling approach, but none of its source is copied.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
