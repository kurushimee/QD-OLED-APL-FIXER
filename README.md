# EOTF Boost for the Philips Evnia 27M2N6500

This ReShade shader offsets the automatic brightness limiter (ABL) of the **Philips Evnia 27M2N6500**, a 27-inch 1440p third-generation QD-OLED monitor, in **HDR Peak 1000** mode.

QD-OLED panels get dimmer when a large part of the screen is bright. On this panel, a small highlight reaches the full peak of about 1000 nits, but a full white screen reaches only about a quarter of it. The shader measures how bright each frame is and raises the HDR signal by the amount the panel is expected to dim, so bright scenes keep their intended brightness. It works much like the "EOTF Boost" option on some MSI QD-OLED monitors.

The shader file is [`Shaders/EOTF_BoostMod2.0_27M2N6500.fx`](Shaders/EOTF_BoostMod2.0_27M2N6500.fx). [EOTF Boost 3.1](#eotf-boost-31) is a newer version calibrated from `abl_curve.csv` that aims to show every level at its PQ target, and the null test and the desktop-wide version follow it.

## Calibration target

The built-in data matches this setup:

| Setting | Value |
|---|---|
| Monitor | Philips Evnia 27M2N6500 |
| Monitor HDR mode | HDR Peak 1000 |
| Windows HDR | On |
| Peak luminance in the Windows HDR color profile | 1060 nits, the measured peak at 3% APL |

Other monitors and other HDR modes dim in a different way, so on them the shader boosts too much or too little. To use it with another display, replace the measured data as described in [Adapting to another monitor](#adapting-to-another-monitor).

## Requirements

- A game that outputs HDR as either HDR10 (PQ) or scRGB.
- ReShade with its standard shader package, which provides `ReShade.fxh`.
- A game that runs on DirectX 11, DirectX 12, or Vulkan. The shader uses compute shaders, which ReShade does not support on DirectX 9 or 10.
- G-Sync or another VRR mode with a frame cap at or under the refresh rate, and no frame generation. The panel dims each refresh for the load of the refresh before it, and the shader can only follow the frames it processed, so each refresh has to show exactly one of them.

## Installation

1. Install ReShade for the game and include the standard effects package.
2. Copy `EOTF_BoostMod2.0_27M2N6500.fx` into the game's `reshade-shaders\Shaders` folder.
3. Open the ReShade overlay and turn on **EOTF_Boost_1D_APL_LUT**.
4. Move it to the bottom of the effect list, so it works on the final image that the monitor receives.

The default settings match the calibration target, so most setups need no changes.

## How it works

1. **Measure the scene.** The shader builds a brightness histogram of the full frame, every frame, and finds the average picture level (APL) from it. Each pixel counts toward the APL the way it loads the panel, from the panel's own red, green, and blue: partly by its brightest subpixel and partly by the mean of all three, so a pure primary loads the panel 0.75 as much as white at the same channel level and gray loads it at its luma.
2. **Look up the compensation.** A measured table tells how much the panel dims at each APL. For example, at 25% APL the panel reaches only about 37% of its peak, so the scene needs about 2.72 times more signal.
3. **Account for its own boost.** Boosting the image raises the APL, and a higher APL makes the panel dim even more. The shader measures each frame's APL with the boost applied, which is the APL the panel actually sees.
4. **Cancel the dimming the panel applies.** The panel dims each frame for the APL of the frame before it, the last one it has fully received. With **APL Smoothing Time** at 0, the full gain for each frame is the compensation for that APL, so every frame is compensated for exactly the dimming it gets, including the first frame after a cut, except the first frame after a lower gain lets go (step 6). When the boost changes the APL, the gain settles over the next few frames while each of those frames still gets the right brightness. Above 0, that loop keeps running on its own without being shown, and the shown gain eases toward the gain the loop settles on, including the lower gain of step 6. The ease runs on the log of the gain, so its gap shrinks by about two thirds each smoothing time whether brightness goes up or down. Brightness changes then come in gradually and move one way, and frames during a change get somewhat more or less than the dimming calls for.
5. **Apply the boost.** Levels at full gain show as bright as they do at 3% APL. The panel cannot show more than its peak divided by the gain, the ceiling, so the boost tonemaps the whole frame into the panel's range. Nothing goes past the panel peak and nothing clips. Every frame the boost curve is fitted to that frame's histogram, which is ready before the boost runs, so the fit adds no delay. The brightest pixel on screen lands on the panel peak. Content the panel can show keeps the full gain where the room allows, and content above the ceiling keeps at most a quarter of its PQ contrast. Each level weighs the detail its pixels would lose if it were flattened against the pixels above it that keeping it would shift down, counting both their shift and the contrast it costs them against the rest of the frame. So the room comes from empty and sparse levels first, from the top down. A small highlight gives up mostly its own contrast, a large one also dims what sits under it, and a few stray pixels move nothing else. A fixed shoulder that depends only on the gain eases from a knee to a quarter of the PQ contrast and lands a 10000-nit signal on the panel peak. Its knee runs from 419 nits at a gain of 1 down to 73 nits at the highest gain of 3.77. The fitted curve never goes under the fixed shoulder or flatter than it, so no two levels ever merge, even across levels nothing on screen uses. Below the knee, nothing ever moves. Above it, levels follow what is on screen. They are exact when nothing needs the room, and they go down to the fixed shoulder's values, never further, when big bright content fills it.
6. **Lower the gain when the frame cannot fit.** When bright content fills most of the screen, most of the picture sits above the ceiling and would keep only a quarter of its contrast. So every frame the boost also fits the curve at lower gains and works out what each costs the frame. Each pixel pays for how far it lands under its exact level, for how far its contrast against every other pixel is off, and for the fine detail it loses. Gains whose costs differ by less than half a 10-bit code look the same, so the boost takes their average, each gain weighed down by e for every further half code it costs, and a small change on screen moves the gain only a little. A frame that fits keeps the full gain, short of up to 1% near full white, and a frame like a sunlit snowfield shows dimmer than the full gain everywhere and keeps its shading. When the content stops needing the lower gain, the loop starts again from the gain it showed, so a smoothed change heads straight for the new gain. Without smoothing, that first frame keeps the lower gain and shows dimmer than the panel's dimming calls for.

Luma drives the boost, and all three color channels scale by the same amount, so colors keep their hue. The brightest color channel follows the same curve, which keeps it under the panel peak.

The analysis runs only while the boost or the stats display is on.

## Measured data

The table holds the peak the panel reaches with a full-signal window at each size from 3% to 100% of the screen, where the window size equals the APL. The compensation for each APL equals the 1060-nit peak at 3% APL divided by the peak at that APL.

| APL | Measured peak (nits) | Compensation |
|---:|---:|---:|
| 3% | 1060.0 | 1.000 |
| 4% | 923.6 | 1.148 |
| 5% | 812.0 | 1.305 |
| 6% | 719.1 | 1.474 |
| 7% | 643.4 | 1.647 |
| 8% | 583.7 | 1.816 |
| 9% | 534.4 | 1.984 |
| 10% | 493.0 | 2.150 |
| 11% | 478.8 | 2.214 |
| 12% | 469.8 | 2.256 |
| 13% | 459.8 | 2.305 |
| 14% | 451.7 | 2.347 |
| 15% | 442.4 | 2.396 |
| 17% | 430.6 | 2.462 |
| 20% | 412.3 | 2.571 |
| 22% | 404.0 | 2.624 |
| 25% | 389.8 | 2.719 |
| 27% | 381.5 | 2.779 |
| 30% | 373.2 | 2.840 |
| 35% | 361.7 | 2.931 |
| 40% | 348.1 | 3.045 |
| 50% | 328.6 | 3.226 |
| 75% | 299.2 | 3.543 |
| 100% | 281.2 | 3.770 |

Below 3% APL the gain is 1, and the curve only makes room for content brighter than the panel peak. Between the points, it interpolates the logarithm of the peak against the logarithm of the APL, so the peak follows a power law from one point to the next.

This table comes from an earlier measurement of white windows only. 2.0 doesn't use `abl_curve.csv`, and 3.1 takes its panel model from it.

### abl_curve.csv

`abl_curve.csv` holds the latest measurement of the panel: white windows from 2% to 100% of the screen, gray windows at 100, 201, and 398 nits, red, green, blue, and yellow windows, and the black screen. Each row is one dogegen `window <size> <r> <g> <b>` pattern, with 10-bit PQ codes in BT.2020. The window size is a percentage of the screen area.

Every value is the luminance in the middle of the 2% window, the same spot on the screen in every pattern. It comes from RAW photos with locked camera settings, with the black screen subtracted, the camera's lens glare fitted and removed, and each reading divided by the 2% white peak at the time of the shot, which cancels the panel's slow drift. The 2% white counts as 1015.24 nits, the panel's EDID max luminance. The 2% grays land at 96.6, 199.3, and 391.8 nits for 100.2, 201.0, and 397.9 nits of signal, so the scale holds.

| Column | Meaning |
|---|---|
| `pattern`, `r`, `g`, `b` | Pattern name and its 10-bit PQ codes |
| `signal_nits` | What the brightest code asks for in PQ |
| `window_percent` | Window area as a percentage of the screen |
| `load_percent` | Window area times the brightest channel's linear signal level relative to the 1015.24-nit peak, capped at 1. This is the load the panel dims by, see below |
| `luminance_load_percent` | Window area times the pattern's own 2% `relative`, the frame's mean luminance as a percentage of full white at peak |
| `relative` | Luminance relative to the 2% white peak |
| `nits` | `relative` times 1015.24 |
| `self_relative` | Luminance relative to the same pattern's 2% window, which is the panel's dimming alone. Compensation is its reciprocal |
| `relative_with_glare` | `relative` before the lens glare was removed |
| `x`, `y` | CIE 1931 chromaticity, with the 2% white taken as D65 |
| `camera_r`, `camera_g`, `camera_b` | Raw sensor values in the measuring spot, with the black screen subtracted, before glare removal and drift correction. The black row keeps them unsubtracted |

`self_relative` is reliable for every pattern. `relative`, `nits`, `x`, and `y` of colored windows rely on the phone's color matrix, which can't separate narrow QD primaries well, so they're rough, and red likely reads too bright. Chromaticity shifts between sizes of one pattern are real.

#### The panel model

The panel dims a frame by the mean over all pixels of its brightest channel in linear light, relative to a load peak and capped at 1. A full red, green, blue, or yellow window dims like a white window of the same size, and a gray window dims like a white window whose area is its own area times its level. Gray 593 at 50% and gray 667 at 25% carry loads of 9.5% and 9.4% with very different codes and dim to 0.484 and 0.483, so the load is taken in linear light, not in code values.

[`Shaders/verify/fit_panel_model.py`](Shaders/verify/fit_panel_model.py) fits the compensation curve and the load peak to every row by least squares on the log of the dimming, and writes them into [`Shaders/PanelModel_27M2N6500.fxh`](Shaders/PanelModel_27M2N6500.fxh), which 3.1 and the null test include. Compensation is 1 up to a load of 3.16%, rises by 0.168 per percent up to a knee at 10.32%, and follows a power law with an exponent of 0.2366 above it, with the load peak at 1056.8 nits. It reaches 2.149 at 10%, 2.716 at 25%, 3.200 at 50%, and 3.770 at 100%. Its log slope against load peaks at 0.787 just under the knee, so the boost always pays for the load it adds and the gain that cancels the dimming exists and is unique. Run `python fit_panel_model.py --check` in `Shaders/verify/` to confirm the include matches a fresh fit.

How well each load model fits the 25 rows above 2%. The held out RMS predicts each row from a fit to the others:

| Load model | RMS error | Worst error | Held out RMS |
|---|---|---|---|
| Brightest channel, load peak fitted | 1.33% | 3.85% | 1.69% |
| Brightest channel, load peak at the EDID | 1.51% | 3.92% | 1.95% |
| Brightest channel with per-channel weights | 1.26% | 2.92% | 1.88% |
| 2.0's mix, a pure primary at 0.75 of white | 2.70% | 4.64% | 3.18% |
| Channel sum | 13.46% | 23.62% | 15.63% |
| BT.2020 luminance | 25.28% | 63.12% | 25.98% |

Per-channel weights fit better but predict held out rows worse, so the model keeps the plain brightest channel. The worst row is the 100% blue window, which dims 3.9% less than predicted. Luminance can't explain the colors, since a 25% blue window carries 2.6% of full white's luminance and still dims like a 25% white window. The colored windows are pure BT.2020 primaries, which the panel shows at its own primaries, so the data can't tell whether the brightest channel should come from BT.2020 or from the panel's own primaries, and the model takes it in BT.2020.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Enable EOTF Boost | On | Turns the brightness compensation on or off. |
| Input Signal | Auto | Picks how to read the game's HDR output: **Auto**, **PQ (HDR10)**, or **scRGB**. Auto follows the format that ReShade reports and falls back to PQ. |
| APL Reference White (nits) | 1060 | Sets the brightness that counts as 100% APL. Keep it at the calibrated peak. A higher value makes scenes read darker, which lowers the boost. |
| Panel Peak (nits) | 1060 | Sets the peak signal the boost tonemaps into. Nothing is shown above it, and brighter content is compressed under it instead of clipped. 0 turns highlight protection off. |
| APL Smoothing Time (s) | 0.5 | Eases the gain toward a new scene's over this time instead of following it exactly from the next frame. 0 turns smoothing off. |
| scRGB Signal Reference (nits) | 80 | Sets the brightness of scRGB value 1.0. It only matters for scRGB games. |
| Show APL Stats | Off | Shows live numbers in the top right corner. |
| Show Compression | Off | While the boost is on, shows the image in gray and tints each pixel that shows dimmer than the full gain would show it, from yellow for a slight cut to red for the deepest. |
| OSD Brightness | 0.5 | Sets the brightness of the stats display and the debug graph. It does not change the image. |

The stats display has three rows:

| Row | Meaning |
|---|---|
| RAW APL | APL of the game's image before the boost. |
| OUT APL | APL that the panel sees after the boost. |
| KNEE NIT | Output level where the curve first leaves the full gain, in nits. It turns orange while that level sits under the panel peak, so some levels the panel could show come out dimmer than the full gain. It reads 0 while the boost holds the whole frame under the full gain. Otherwise it shows the panel peak in gray. |

## Preprocessor definitions

These options are set in the ReShade overlay, in the shader's preprocessor definitions.

| Definition | Default | What it does |
|---|---|---|
| `PQHDRLUT_ENABLE` | 0 | 1 adds a 3D calibration LUT that runs after the boost. |
| `PQHDRLUT_SIZE` | 65 | Sets the edge size of the calibration LUT. |
| `ENABLE_APL_GRAPH` | 0 | 1 adds a debug graph of the boost curve. |
| `ENABLE_UI_TOOLTIPS` | 0 | 1 adds a tooltip to each setting. |

### Calibration LUT

With `PQHDRLUT_ENABLE=1`, the shader loads `PQHDRLUT.cube` from ReShade's texture folders and adds an **Enable PQ HDR LUT** setting. The LUT takes and returns PQ-encoded Rec.2020 values. It runs on the boosted signal, or on the plain signal when the boost is off. For scRGB games, the shader converts the image to PQ Rec.2020 before the LUT and back after it.

### Debug graph

With `ENABLE_APL_GRAPH=1`, the shader can draw a graph of input nits against output nits. It shows the identity line, the measured panel response, the boosted signal, the predicted panel output, and an optional BT.2390-style reference curve. The graph can use either a fixed APL or a measured window size of 100%, 50%, 25%, 15%, or 10%. It is a tuning aid and does not change the image.

The graph's 2D compensation table and window curves come from earlier measurements of the Samsung Odyssey OLED G8 (G85SB), not of the 27M2N6500. The live boost does not use them.

## EOTF Boost 3.1

[`Shaders/EOTF_BoostMod3.1_27M2N6500.fx`](Shaders/EOTF_BoostMod3.1_27M2N6500.fx) shows every level at its PQ target wherever the panel can reach it. Where it can't, the gain goes up only as far as the panel can deliver and the highlights roll off under the panel peak with their detail kept. It starts from shansolox's v8.18.7.15 shader, `Shaders/EOTF_BoostMod3.0.fx` here, and runs on the [panel model](#the-panel-model) fitted to `abl_curve.csv`.

Copy `EOTF_BoostMod3.1_27M2N6500.fx` and `PanelModel_27M2N6500.fxh` into the game's `reshade-shaders\Shaders` folder, turn on **EOTF_Boost_3_1_27M2N6500**, and move it to the bottom of the effect list. It reads HDR10 or scRGB, whichever ReShade reports.

### How 3.1 works

1. **Measure the load.** Every frame, the shader builds a histogram of every pixel's brightest channel in linear BT.2020 and takes the load from it the way the panel model does.
2. **Solve full compensation.** Boosting the frame raises its load, so the shader finds the gain that equals the compensation at the load that gain causes, by bisection on the histogram within the frame.
3. **Pick the gain.** Full compensation shows every level at its target only when the frame fits under the ceiling, the signal peak divided by the gain. The shader scores 9 gains from 1 to full compensation by their predicted EOTF error, each histogram bin's shown level under the panel model against its target, in log2 and weighted by its pixels. It takes the vertex of the parabola through the best gain and its neighbors, so the gain moves smoothly as the frame changes, and takes full compensation as is when it scores best.
4. **Tone map the highlights.** Levels below the shoulder get exactly the gain. The shoulder starts at BT.2408's 203-nit reference white, or at BT.2390's knee where that's higher, and the histogram shares its range up to the ceiling out from the top down (Ward Larson, Rushmeier, and Piatko 1997), with no level stretched past its own contrast. A bend of a quarter octave joins the two. The brightest channel lands at most on 1007.93 nits, the brightest 10-bit PQ code at or under the 1015.24-nit peak, so nothing clips. All three channels of a pixel scale by the same factor, so hue and saturation stay.
5. **Smooth the gain.** The gain eases on its log with libplacebo's single-pole filter over a 20-frame period. A change of 1% to 3% in the frame's mean PQ counts as a scene change and goes through partly to fully.
6. **Dither HDR10.** Pixels the boost changed get triangular noise of one 10-bit code before quantization, so each code's mean lands on its target.

Under the panel model, the mean EOTF error over a frame's pixels is 0.0001 stops on a dim frame and 0.01 stops on a game frame. It rises to 0.25 to 1.0 stops only on frames whose bright areas fill much of the screen, a bright sky or a snowfield, where the panel can't reach the target. The pipeline takes 0.76 ms per frame at 2560 by 1440 on an RTX 2070.

### 3.1 settings

| Setting | Default | What it does |
|---|---|---|
| Enable EOTF Boost | On | Turns the compensation on or off. |
| Gain Smoothing Period (frames) | 20 | Sets the period of the gain's smoothing. 0 turns smoothing off. |
| Gain Pick | Lowest predicted EOTF error | **Brightness times kept detail** picks by 3.0's score instead. |
| Scene Change Low Threshold (% PQ) | 1 | Sets the change in the frame's mean PQ where a scene change starts to bypass the smoothing. |
| Scene Change High Threshold (% PQ) | 3 | Sets the change where it bypasses the smoothing fully. |
| Shoulder Start | Held at 203 nit reference white | **BT.2390 knee** starts the shoulder at BT.2390's knee alone, which falls lower on bright frames. |
| Shoulder Channel Blend | 0 | Blends each channel in the shoulder toward its own trip through the tone curve, as BT.2408 and libplacebo's film strength do. The brightest channel stays, so the load and the ceiling stay exact, but colors in the shoulder shift. |
| Dither HDR10 Output | On | Dithers the pixels the boost changed. |
| Show Stats | Off | Shows live numbers. |
| OSD Brightness | 0.5 | Sets the brightness of the stats display and the debug graph. |

| Stats row | Meaning |
|---|---|
| RAW LOAD | Load of the game's frame. |
| OUT LOAD | Load the panel sees after the boost. |
| FULL | Full compensation for the frame. |
| GAIN | Gain the boost applies. |
| CEIL | Ceiling in source nits, the signal peak divided by the gain. |
| KNEE | Source level where the bend leaves the gain, in nits. |
| RAW NITS | Brightest channel of the brightest source pixel. |

3.1 has the same preprocessor definitions as 2.0. The calibration LUT runs after the boost, and the load counts what it sends. The debug graph draws from the panel model. `APL_FULLFRAME_ROLLING_PHASES` above 0 refreshes the histogram in that many row phases, one per frame, which costs less GPU time but makes the load lag.

### Using 3.1

- In the Windows HDR Calibration app, set the max luminance to 1015 nits, the peak the measurement is scaled to, and the max full-frame luminance to 265 nits, the 100% white window. Games that tone map read these values.
- Keep 3.1 last in the effect chain, since it measures the signal the panel receives.
- Keep DwmBoost off while 3.1 runs, or DWM boosts the frame again.
- Let the game fill the screen. Light outside the back buffer adds load that 3.1 can't see.
- Don't let a Windows color profile or another LUT change luminance after it.
- Turn off every burn-in protection the monitor's OSD offers. Samsung's `QD_burn_in.c`, from related controller code for its TVs and monitors, gives PC modes no local protection with logo protection off, and its only other uniform cut follows the OSD's own state, which the signal can't show. So 3.1 compensates the power limit alone.

### 3.1 verification

`Shaders/verify/` builds `RenderEffect.exe`, which runs a ReShade effect on a saved frame the way ReShade 6.8 runs it in a D3D11 game, see CLAUDE.md. [`Shaders/verify/eotf_check.py`](Shaders/verify/eotf_check.py) replays a boosted frame through the panel model and reports the shown error against the PQ target by level band. It fails if any pixel sends more than the signal peak or the curve falls anywhere. Run `python eotf_check.py source.png boosted.png`.

## Null test

[`Shaders/ABL_NullTest.fx`](Shaders/ABL_NullTest.fx) checks 3.1's compensation by eye, with no measuring gear. Copy it next to 3.1 and its panel model, turn on **ABL_NullTest**, and move it above **EOTF_Boost_3_1_27M2N6500** in the effect list so the boost analyzes the pattern. It writes the format ReShade reports, as 3.1 reads it. In the checks that run with the boost on, the boost eases over its smoothing period after each switch, so judge the patches a moment after the fill changes.

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

2.0's boost depends on the `APL_ANCHORS` table in the shader. In ascending APL order, each entry holds the base-2 logarithm of an APL in percent and the base-2 logarithm of the compensation at that APL.

To retune 2.0 for another monitor:

1. Measure the panel's peak brightness at each APL, starting with a window small enough to reach the full peak.
2. Divide the full peak by each measurement to get the compensation values. The first value should be 1.0.
3. Fill the table with log2 of each APL and log2 of its compensation, and set `APL_ANCHOR_COUNT` to the number of entries.
4. Set **APL Reference White** and **Panel Peak** to the panel's peak, and use the same peak in the Windows HDR color profile.

To retune 3.1, measure windows the way `abl_curve.csv` does and run `fit_panel_model.py`, which rewrites the panel model for 3.1, the null test, and DwmBoost.

## Desktop-wide (DWM) version

The ReShade shader only reaches a game that has ReShade installed. [`DwmBoost/`](DwmBoost) runs the same compensation on the **whole Windows 11 desktop** by hooking the desktop compositor (`dwm.exe`) and boosting each composed frame, the way [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) and the `dwm_lut` family do for desktop color calibration. It is meant for non-game desktop use, and games keep using the ReShade shader. It runs EOTF Boost 3.1's scRGB path and includes the same panel model, and its output matches 3.1 at its default settings.

While the effect is on it forces DWM composition, which **disables variable refresh rate (VRR)**, so it is turned off for gaming. It applies only to the Philips 27M2N6500 (the 2560×1440 HDR monitor); other monitors are left untouched.

A tray app injects a hook into `dwm.exe` and keeps it resident. Toggling is instant and reversible:

- **Ctrl+Alt+Shift+End** turns the boost on.
- **Ctrl+Alt+Shift+Home** turns it off, which reverts the composition patches so VRR returns.
- The tray menu has **Enable**, **Disable**, **Install autostart task** (an elevated logon task, no per-launch prompt), and **Quit**. Quit ejects the hook cleanly.

DWM composes only when something changes, so the gain smoothing runs on time, 3.1's 20 frames at the panel's 240 Hz. On a static desktop DWM stops composing, so the app nudges the monitor once per refresh with a 1 px corner window for one frame and then 0.48 seconds after the last change, then stops. Each frame solves its full compensation on its own, and the smoothing needs up to 0.48 seconds to ease in from any gain, so this lets the gain settle on the new content without a game running.

The target panel and its build are pinned: the tool injects only into Windows 11 25H2 (build 26200 or later) and refuses to inject if any `dwmcore.dll` byte pattern it relies on is missing or ambiguous, which also guards against a future Windows update changing the compositor.

### Building

The build needs CMake, Ninja or Visual Studio 2022, the MSVC toolchain, and the Windows 10 SDK (for `fxc`). From `DwmBoost/`:

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

This produces `DwmBoost.exe` and `DwmBoostHook.dll` in `build/bin`, plus `RenderFrame.exe` for verification. Keep the first two together. The build regenerates `hook/boost_bytecode.h` from [`hook/boost.hlsl`](DwmBoost/hook/boost.hlsl) with `fxc`. The executable and tray icons are rendered from [`app/icon.svg`](DwmBoost/app/icon.svg) into the committed `.ico` files; after editing the svg, run `python make_icons.py` in `app/` (needs `resvg-py` and Pillow). MinHook (BSD-2) is vendored under `DwmBoost/third_party/minhook/` with its license.

### Verification

[`DwmBoost/verify/parity_check.py`](DwmBoost/verify/parity_check.py) renders synthetic frames, from black and flat fields to windows, highlights, a PQ ramp, primaries, and saturated noise, through the hook's pipeline and through 3.1 on an scRGB back buffer the way ReShade runs it, and fails if any channel differs by a quarter of a 10-bit code and by half an FP16 step of its pixel. It also checks that the geometry in `pipeline.h` matches `boost.hlsl` and that the settle time covers the slowest ease the smoothing allows. It needs `RenderFrame.exe` and the ReShade effect renderer in `Shaders/verify/` built. Run `python parity_check.py`.

[`DwmBoost/verify/render_frame.cpp`](DwmBoost/verify/render_frame.cpp) builds `RenderFrame.exe`, which runs the hook's own pipeline and shader on the GPU over a saved HDR frame until the gain settles and writes the boosted frame. Both are 16-bit PQ BT.2020 PNGs like ReShade's HDR screenshots. It prints the raw and out load, the gain, the full compensation, the knee, the ceiling, how long the gain took to settle at the primary display's refresh rate and how far it still moves after that, and the GPU time of the whole pipeline and of the solve alone. Run `RenderFrame source.png boosted.png`.

## Credits

This shader builds on earlier work:

- [DespairArdor/QD-OLED-APL-FIXER](https://github.com/DespairArdor/QD-OLED-APL-FIXER) is the original APL compensation shader.
- [mspeedo/QD-OLED-APL-FIXER](https://github.com/mspeedo/QD-OLED-APL-FIXER) modeled it on measurements of the Samsung Odyssey OLED G8 (G85SB) in Peak 1000 mode and added the rolling full-frame histogram.
- [shansolox/QD-OLED-APL-FIXER](https://github.com/shansolox/QD-OLED-APL-FIXER) added the color-preserving boost and versions for the Aorus FO32U/2/2P and other TB400 QD-OLED monitors. This shader starts from its v8.18.7.14F version.

The DWM hook under `DwmBoost/` is written from scratch to keep the MIT license. [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) (GPL-3.0) was read for facts and design — the compositor functions involved, the vtable walk, the clean-copy and static-desktop settling approach — but none of its source is copied.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
