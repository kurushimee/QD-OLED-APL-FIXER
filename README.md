# EOTF Boost for the Philips Evnia 27M2N6500

This ReShade shader offsets the automatic brightness limiter (ABL) of the **Philips Evnia 27M2N6500**, a 27-inch 1440p third-generation QD-OLED monitor, in **HDR Peak 1000** mode.

QD-OLED panels get dimmer when a large part of the screen is bright. On this panel, a small highlight reaches the full peak of about 1000 nits, but a full white screen reaches only about a quarter of it. The shader measures how bright each frame is and raises the HDR signal by the amount the panel is expected to dim, so bright scenes keep their intended brightness. It works much like the "EOTF Boost" option on some MSI QD-OLED monitors.

The shader file is [`Shaders/EOTF_BoostMod2.0_27M2N6500.fx`](Shaders/EOTF_BoostMod2.0_27M2N6500.fx).

## Calibration target

The built-in data matches this setup:

| Setting | Value |
|---|---|
| Monitor | Philips Evnia 27M2N6500 |
| Monitor HDR mode | HDR Peak 1000 |
| Windows HDR | On |
| Peak luminance in the Windows HDR color profile | 1060 nits, the measured peak at 2% APL |

Other monitors and other HDR modes dim in a different way, so on them the shader boosts too much or too little. To use it with another display, replace the measured data as described in [Adapting to another monitor](#adapting-to-another-monitor).

## Requirements

- A game that outputs HDR as either HDR10 (PQ) or scRGB.
- ReShade with its standard shader package, which provides `ReShade.fxh`.
- A game that runs on DirectX 11, DirectX 12, or Vulkan. The shader uses compute shaders, which ReShade does not support on DirectX 9 or 10.

## Installation

1. Install ReShade for the game and include the standard effects package.
2. Copy `EOTF_BoostMod2.0_27M2N6500.fx` into the game's `reshade-shaders\Shaders` folder.
3. Open the ReShade overlay and turn on **EOTF_Boost_1D_APL_LUT**.
4. Move it to the bottom of the effect list, so it works on the final image that the monitor receives.

The default settings match the calibration target, so most setups need no changes.

## How it works

1. **Measure the scene.** The shader builds a brightness histogram of the full frame. To save GPU time, it refreshes one of six groups of rows each frame and keeps the rest from earlier frames. From the histogram, it finds the average picture level (APL) and the scene's highlight peak. The highlight peak is the level that only the brightest 1/256 of the frame's light sits above.
2. **Look up the compensation.** A measured table tells how much the panel dims at each APL. For example, at 25% APL the panel reaches only about 36% of its peak, so the scene needs about 2.80 times more signal.
3. **Account for its own boost.** Boosting the image raises the APL, and a higher APL makes the panel dim even more. The shader solves for the APL that the panel will actually see after the boost and picks the gain from that.
4. **Smooth the change.** The APL and the highlight peak change gradually over time, so the brightness does not jump between frames.
5. **Apply the boost.** Shadows and midtones get the full gain. Near the top, the gain eases out in PQ space through two soft shoulders. The first shoulder leads up to the scene's highlight peak and keeps part of its contrast, set by **Highlight Contrast**. The second shoulder handles rarer, brighter content and any color channel that nears the panel peak, so they compress instead of clipping.

Luma drives the boost, and all three color channels scale by the same amount, so colors keep their hue. The shader never makes any part of the image darker than the source.

The analysis runs only while the boost or the stats display is on.

## Measured data

The table comes from [TFTCentral's review of the Dell Alienware AW2725DF](https://tftcentral.co.uk/reviews/dell-alienware-aw2725df), measured in its HDR Peak 1000 mode on firmware M2B102. That monitor uses the same third-generation 27-inch 1440p QD-OLED panel, and each window size equals the APL. TFTCentral's [MSI MPG 271QRX measurements](https://tftcentral.co.uk/articles/testing-hdr400-true-black-and-peak-1000-mode-brightness-on-new-oled-monitors) on this panel match it within 2 nits from 5% to 100%.

The compensation for each APL equals the 1060-nit peak at 2% APL divided by the peak at that APL.

| APL | Measured peak (nits) | Compensation |
|---:|---:|---:|
| 1% | 1001 | – |
| 2% | 1060 | 1.000 |
| 5% | 778 | 1.362 |
| 10% | 478 | 2.218 |
| 25% | 379 | 2.797 |
| 50% | 319 | 3.323 |
| 75% | 288 | 3.681 |
| 100% | 270 | 3.926 |

The 1% window reads lower than the 2% window. ABL only dims the panel more as the APL grows, so the shader treats this dip as a separate limit on very small windows and gives no boost below 2% APL. Between the points, the shader interpolates in a straight line. Above the **Compensation Freeze APL %**, it keeps the value at that APL.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Enable EOTF Boost | On | Turns the brightness compensation on or off. |
| Input Signal | Auto | Picks how to read the game's HDR output: **Auto**, **PQ (HDR10)**, or **scRGB**. Auto follows the format that ReShade reports and falls back to PQ. |
| APL Reference White (nits) | 1060 | Sets the brightness that counts as 100% APL. Keep it at the calibrated peak. A higher value makes scenes read darker, which lowers the boost. |
| Compensation Freeze APL % | 50 | Holds the compensation at its value for this APL in all brighter scenes. Lower values limit the boost in bright scenes. 0 turns the hold off, so the boost follows the measured table up to 100% APL. |
| Panel Peak (nits) | 1060 | Sets the peak signal that the boost eases into. Boosted content never goes past it, and content already above it passes through unchanged. 0 turns highlight protection off. |
| Highlight Contrast | 0.40 | Sets how much contrast the scene's highlights keep while the boost fades out. Lower values brighten bright midtones more, and higher values keep more separation between highlights. |
| APL Smoothing Time (s) | 0.25 | Sets how long the shader takes to follow a change in scene brightness. Raise it if the brightness looks jumpy. 0 turns smoothing off. |
| scRGB Signal Reference (nits) | 80 | Sets the brightness of scRGB value 1.0. It only matters for scRGB games. |
| Show APL Stats | Off | Shows live numbers in the top right corner. |
| OSD Brightness | 0.5 | Sets the brightness of the stats display and the debug graph. It does not change the image. |

The stats display has three rows:

| Row | Meaning |
|---|---|
| RAW APL | APL of the game's image before the boost. |
| OUT APL | APL that the panel sees after the boost, as solved and smoothed by the shader. |
| RAW NITS | Highest luma in the game's image, in nits. The shader tracks it only while the stats display is on. |

## Preprocessor definitions

These options are set in the ReShade overlay, in the shader's preprocessor definitions.

| Definition | Default | What it does |
|---|---|---|
| `APL_FULLFRAME_ROLLING_PHASES` | 6 | Splits the histogram rows into this many groups and refreshes one group per frame. 0 refreshes every row each frame, which costs more GPU time. |
| `PQHDRLUT_ENABLE` | 0 | 1 adds a 3D calibration LUT that runs after the boost. |
| `PQHDRLUT_SIZE` | 65 | Sets the edge size of the calibration LUT. |
| `ENABLE_APL_GRAPH` | 0 | 1 adds a debug graph of the boost curve. |
| `ENABLE_UI_TOOLTIPS` | 0 | 1 adds a tooltip to each setting. |

### Calibration LUT

With `PQHDRLUT_ENABLE=1`, the shader loads `PQHDRLUT.cube` from ReShade's texture folders and adds an **Enable PQ HDR LUT** setting. The LUT takes and returns PQ-encoded Rec.2020 values. It runs on the boosted signal, or on the plain signal when the boost is off. For scRGB games, the shader converts the image to PQ Rec.2020 before the LUT and back after it.

### Debug graph

With `ENABLE_APL_GRAPH=1`, the shader can draw a graph of input nits against output nits. It shows the identity line, the measured panel response, the boosted signal, the predicted panel output, and an optional BT.2390-style reference curve. The graph can use either a fixed APL or a measured window size of 100%, 50%, 25%, 15%, or 10%. It is a tuning aid and does not change the image.

The graph's 2D compensation table and window curves come from earlier measurements of the Samsung Odyssey OLED G8 (G85SB), not of the 27M2N6500. The live boost does not use them.

## Adapting to another monitor

The live boost depends on two arrays in the shader:

- `APL_ANCHOR_POINTS` lists the APL values in percent, in ascending order.
- `COMP_APL_1D` lists the compensation for each of those APL values.

To retune the shader for another monitor:

1. Measure the panel's peak brightness at each APL, starting with a window small enough to reach the full peak.
2. Divide the full peak by each measurement to get the compensation values. The first value should be 1.0.
3. Replace both arrays. They must have the same number of entries, which `APL_ANCHOR_COUNT` sets.
4. Set **APL Reference White** and **Panel Peak** to the panel's peak, and use the same peak in the Windows HDR color profile.

## Credits

This shader builds on earlier work:

- [DespairArdor/QD-OLED-APL-FIXER](https://github.com/DespairArdor/QD-OLED-APL-FIXER) is the original APL compensation shader.
- [mspeedo/QD-OLED-APL-FIXER](https://github.com/mspeedo/QD-OLED-APL-FIXER) modeled it on measurements of the Samsung Odyssey OLED G8 (G85SB) in Peak 1000 mode and added the rolling full-frame histogram.
- [shansolox/QD-OLED-APL-FIXER](https://github.com/shansolox/QD-OLED-APL-FIXER) added the color-preserving boost and versions for the Aorus FO32U/2/2P and other TB400 QD-OLED monitors. This shader starts from its v8.18.7.14F version.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
