
here's the stack, sorted by how much it'll change your shader

**your load metric is probably the weakest part**

your capability curve comes from white windows, but the panel likely isn't limiting on white apl

- [color characterization model for APL dependent OLED displays](https://library.imaging.org/admin/apis/public/api/ist/website/downloadArticle/cic/32/1/5) (IS&T CIC32). they model oled colorimetry from the power draw of the actual pixel content, and two different images with matching power got about the same peak white and gamut volume. probably the best base for your model
- [dong & zhong, power modeling of GUIs on OLED displays](https://cases.justia.com/federal/district-courts/california/candce/5:2011cv01846/239768/434/2.pdf) (DAC 2009). per pixel power model where power is nonlinear in each color channel's intensity. old panel but the method transfers
- [tftcentral, exploring OLED brightness](https://tftcentral.co.uk/articles/exploring-oled-brightness-improvements-woled-vs-qd-oled-and-the-need-for-new-metrics-and-specs). on qd-oled, color brightness ends up much closer to white than white-only numbers suggest
- peak luminance control patents, the classic implementations. [US 9607552](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9607552) defines apl on gray levels, like 25% of pixels at 255 = 25% apl. [US 12067944](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12067944) computes it from RGB or YUV data and uses a curve that's flat then drops hard. [US 10089959](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/10089959) does it as an apl lookup table of brightness offsets

what to do with it. measure R G B C M Y windows at a few apls, not just white, and fit a weighted per channel load. then find which domain the panel computes it in. cheap test, two patterns with the same linear light average but different code value average (big dim window vs small bright one). whichever metric predicts the dimming wins

**what the samsung controller actually does**

- [the candela writeup](https://candela.fyi/research/reverse-engineered-oled-monitor/), its [samsung source notes](https://github.com/Rydersel/Candela/blob/main/docs/evidence/oled-protection/samsung-source.md) and its [python sim](https://github.com/Rydersel/Candela/tree/main/tools/pontusm-sim)
- [samsung open source release center](https://opensource.samsung.com/uploadSearch), grab the PontusM archives and read QD_burn_in.c. it keeps a 15x15 region map updated in phases on a 20ms tick, there's a uniform ceiling tied to app and osd state, and a long window peak exposure accumulator. so some dimming is LOCAL and slow, which a global apl shader can't model. it's related samsung code, not the exact thing in your monitor
- [tftcentral, OLED dimming confusion](https://tftcentral.co.uk/articles/oled-dimming-confusion-apl-abl-asbl-tpc-and-gsr-explained), abl vs asbl/tpc vs gsr so you know which one you're measuring

**timing**

abl has a time constant. if your shader reacts faster or slower than the panel you get pumping where they disagree. log a black to window step with spotread continuously and fit it

- [libplacebo peak detection redesign](https://github.com/haasn/libplacebo/issues/40). single pole IIR for smoothing plus a smoothstep scene change curve with low and high thresholds. same structure works for an apl tracker

**highlight tonemapping**

- [ITU-R BT.2390](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2390-8-2020-PDF-E.pdf), the eetf section
- [ITU-R BT.2408-5](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2408-5-2022-PDF-E.pdf), annex 5 walks through computing the eetf for displaying PQ. also the 203 nit reference white, good anchor for where your boost should stay hands off
- [burke, smith, zink, hue preservation in HDR tone mapping](https://journal.smpte.org/periodicals/SMPTE%20Motion%20Imaging%20Journal/129/4/14/09086648.pdf). compares the four variants of the BT.2390 eetf. read before picking maxRGB vs luminance scaling, your boost scales color and you don't want hue shifts near clip
- [libplacebo](https://github.com/haasn/libplacebo) source for working GLSL of all this

**measuring**

- [VESA DisplayHDR CTS 1.0](https://source.netsyms.com/skylarmt/glenwing.github.io_withhdmi/raw/branch/master/docs/VESA-DisplayHDR-CTS-1.0.pdf), the patterns and procedures. newer CTS docs need a free vesa.org registration
- tftcentral's [MSI peak 1000 article](https://tftcentral.co.uk/articles/the-new-msi-firmware-update-properly-fixes-the-peak-1000-hdr-mode-for-many-of-their-qd-oled-monitors) and [AW3225QF investigation](https://tftcentral.co.uk/articles/hdr-brightness-investigation-and-how-to-get-a-brighter-hdr-experience-on-the-dell-alienware-aw3225qf). luminance error table plus eotf at multiple apls, basically your validation suite
- [ArgyllCMS spotread](https://argyllcms.com/doc/spotread.html) for scripted logging, and the [ccss correction docs](https://argyllcms.com/doc/ArgyllDoc.html). qd-oled spectra are super narrow and a colorimeter without the right correction will lie to you, which poisons the whole curve
- [lilium's ReShade HDR shaders](https://github.com/EndlesslyFlowering/ReShade_HDR_shaders), the analysis one shows max/avg/min nits of what's actually being sent

**windows side**

- [microsoft, DirectX with Advanced Color](https://learn.microsoft.com/windows/win32/direct3darticles/high-dynamic-range). scRGB 1.0 is 80 nits, 12.5 is 1000. the display info api exposes both max frame average and max peak luminance, which matters when you lower the peak in calibration
- [dwm_lut](https://github.com/lauralex/dwm_lut). hooks dwm to apply a lut across the whole desktop in SDR and HDR, HDR luts are BT.2020 PQ in and out, exclusive fullscreen bypasses it. a static lut can't do apl but the hook is the best starting point if you want your shader running desktop wide

Sources:
- [scRGB, Wikipedia](https://en.wikipedia.org/wiki/ScRGB)
