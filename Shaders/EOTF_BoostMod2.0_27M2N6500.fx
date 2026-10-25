/*
    EOTF Boost v8.18.7.14F
    Calibrated for 27" 1440p 3rd-gen QD-OLED in HDR Peak 1000 mode,
    with a 1060 nit panel peak, the peak measured at 3% APL.

    Compensates the panel's APL-dependent dimming (ABL) from a measured 1D table.

        full gain = compensation(APL of the boosted signal)

    Levels at full gain show as bright as they do at 3% APL. The panel cannot
    show more than its peak divided by the gain, the ceiling, so content above
    the ceiling needs room under the panel peak. Every frame the boost curve is
    fitted to that frame's histogram and tonemaps the whole frame. The
    brightest pixel lands on the panel peak, nothing goes above it, and no two
    levels ever merge. Content the panel can show keeps the full gain, and
    content above the ceiling keeps at most a quarter of its PQ contrast. Each
    level weighs the detail its pixels would lose if it were flattened against
    the pixels above it that keeping it would shift down, counting both their
    shift and the contrast it costs them against the rest of the frame. So the
    room comes from empty and sparse levels first, from the top down, and a few
    stray pixels move nothing else.

    When bright content fills most of the screen, most of the picture sits
    above the ceiling and would keep only a quarter of its contrast. So every
    frame the curve is also fitted at lower gains, on an even grid and then in
    passes closer and closer around the gain the costs point to. Each pixel
    pays for how far it lands under its exact level, for how far its contrast
    against every other pixel is off, and for the fine detail it loses. Gains
    whose costs differ by less than half a 10-bit code look the same, so the
    frame takes their average, each gain weighed down by e for every further
    half code it costs, and a tiny change of content moves the gain only a
    little. A frame that fits keeps the full gain unless it is near full white,
    where it can fall up to 1% short.

    A fixed shoulder that depends only on the gain sets the knee and a floor.
    It lands a 10000 nit signal on the panel peak. Below the knee, nothing ever
    moves. Above it no level gets darker or flatter than the fixed shoulder,
    and levels follow what is on screen. They are exact when nothing needs the
    room, and they go down to the fixed shoulder's values, never further, when
    bright content fills it.

    Luma drives the curve and the RGB ratios are kept. The brightest channel
    follows the same curve, which keeps it under the panel peak.

    A full-frame histogram of every frame gives its raw APL and the
    display-side APL it shows with the boost applied. The panel dims each frame
    for the display-side APL of the frame before it, so the full gain is the
    compensation for that load. When content stops needing a lower gain, the
    loop starts again from the gain it showed. With smoothing that loop keeps
    running on its own, and the shown gain eases toward the one it settles on
    over the smoothing time. The ease runs on the log of the gain, so it covers
    the same share of a change up or down, and a change of content moves the
    gain one way.

    Live pipeline:
      1. Frame setup and row histogram clear
      2. Full-frame row histogram build
      3. Global histogram reduction
      4. APL solve and boost curve fit
      5. Fullscreen boost and optional calibration LUT

    Analysis runs only while the boost or the OSD is enabled. When it resumes
    after a pause, the panel last showed an unboosted frame, so the gain starts
    from that frame's load.
*/

#include "ReShade.fxh"

#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 0
#endif


#ifndef PQHDRLUT_ENABLE
    #define PQHDRLUT_ENABLE 0
#endif


#ifndef ENABLE_APL_GRAPH
    #define ENABLE_APL_GRAPH 0
#endif

#ifndef ENABLE_UI_TOOLTIPS
    #define ENABLE_UI_TOOLTIPS 0
#endif


// Full-frame histogram layout. Each 16x16 group processes one 32x32 pixel tile.
#define APL_FFH_TILE_SIZE             32
#define APL_FFH_THREADS_X             16
#define APL_FFH_THREADS_Y             16
#define APL_FFH_PIXELS_X               2
#define APL_FFH_PIXELS_Y               2
#define APL_FFH_LUMA_BINS              64
#define APL_FFH_COLOR_LUMA_BINS        64
#define APL_FFH_COLOR_RATIO_BINS        4
#define APL_FFH_MAX_BINS              256
#define APL_FFH_BLOCK_W                16
#define APL_FFH_BLOCK_H                16
#define APL_FFH_REDUCE_THREADS         64
#define APL_SETUP_THREADS             256


// Packed value: pixel count in the upper bits and summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT       20
#define APL_FFH_PACK_OFFSET_MASK       ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE      1023
#define APL_FFH_PACK_ONE_COUNT         (1 << APL_FFH_PACK_COUNT_SHIFT)

#define APL_FFH_TILE_COUNT_X ((BUFFER_WIDTH  + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)
#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)


// 16x16 histogram block for each 32-pixel-high screen row, rebuilt every frame.
#define APL_FFH_ROW_HIST_TEX_W APL_FFH_BLOCK_W
#define APL_FFH_ROW_TEX_H (APL_FFH_TILE_COUNT_Y * APL_FFH_BLOCK_H)

#if (APL_FFH_THREADS_X * APL_FFH_PIXELS_X != APL_FFH_TILE_SIZE) || (APL_FFH_THREADS_Y * APL_FFH_PIXELS_Y != APL_FFH_TILE_SIZE)
    #error "Full-frame APL histogram tile/thread dimensions are inconsistent"
#endif
#if (APL_FFH_PIXELS_X != 2) || (APL_FFH_PIXELS_Y != 2)
    #error "Row histogram build decodes exactly 2x2 pixels per thread"
#endif
#if (APL_FFH_BLOCK_W * APL_FFH_BLOCK_H != APL_FFH_MAX_BINS)
    #error "Full-frame APL histogram block dimensions do not match maximum bin count"
#endif
#if (APL_FFH_COLOR_LUMA_BINS * APL_FFH_COLOR_RATIO_BINS != APL_FFH_MAX_BINS)
    #error "Color-preserving full-frame APL histogram dimensions are inconsistent"
#endif
#if (APL_FFH_TILE_SIZE * APL_FFH_TILE_SIZE * APL_FFH_PACK_OFFSET_SCALE) > APL_FFH_PACK_OFFSET_MASK
    #error "Packed tile offset sum overflows its bit field"
#endif
#if (APL_FFH_TILE_SIZE * APL_FFH_TILE_SIZE) >= (1 << (31 - APL_FFH_PACK_COUNT_SHIFT))
    #error "Packed tile pixel count overflows its bit field"
#endif

// Rows take tile sums of squared bin positions in units of 256, so a whole row still fits an int.
#define APL_FFH_ROW_OFFSET_SQ_UNIT    256
#if (APL_FFH_TILE_SIZE * APL_FFH_TILE_SIZE * APL_FFH_PACK_OFFSET_SCALE * APL_FFH_PACK_OFFSET_SCALE) > (2147483647 - APL_FFH_ROW_OFFSET_SQ_UNIT / 2)
    #error "Tile sum of squared bin positions overflows an int"
#endif
#if (APL_FFH_TILE_COUNT_X * (APL_FFH_TILE_SIZE * APL_FFH_TILE_SIZE * APL_FFH_PACK_OFFSET_SCALE * APL_FFH_PACK_OFFSET_SCALE / APL_FFH_ROW_OFFSET_SQ_UNIT + 1)) > 2147483647
    #error "Row sum of squared bin positions overflows an int"
#endif


// The curve above the knee is a table of output PQ codes over equal cells of full-gain PQ. One pixel can change
// one cell's slope, so the cells are narrow enough that this moves no level by a whole 10-bit step.
#define BOOST_CURVE_CELLS            512

// Each step of the curve solve keeps a third of its bracket, so 21 make it as narrow as 32 halvings.
#define BOOST_CURVE_SOLVE_STEPS       21

// Fits that find the frame's gain, on an even grid of log gains from 1 to the table's top compensation and then in
// passes of two either side of the gain the fits before them give, half as far each pass. On recorded game frames
// with the flattest costs they keep the gain within 1.5% of the same average taken over 128 gains.
#define BOOST_GAIN_GRID_POINTS        8
#define BOOST_GAIN_PASSES             3
#define BOOST_GAIN_FITS               (BOOST_GAIN_GRID_POINTS + 2 * BOOST_GAIN_PASSES)

// The solve runs one thread per curve cell, and the first threads also read one histogram bin each.
#define APL_EVAL_THREADS             BOOST_CURVE_CELLS
#if APL_EVAL_THREADS < APL_FFH_MAX_BINS
    #error "The solve needs at least one thread per histogram bin"
#endif


// UI tooltips can be removed at compile time.
#if ENABLE_UI_TOOLTIPS
    #define UI_TOOLTIP(text) ui_tooltip = text;
#else
    #define UI_TOOLTIP(text)
#endif


#if PQHDRLUT_ENABLE
#ifndef PQHDRLUT_SIZE
    #define PQHDRLUT_SIZE 65
#endif
#endif


uniform bool EnableEOTFBoost <
    ui_label = "Enable EOTF Boost";
    UI_TOOLTIP("Enables APL-based HDR brightness compensation.")
> = true;

uniform int InputSignal <
    ui_type = "combo";
    ui_items = "Auto\0PQ (HDR10)\0scRGB\0";
    ui_label = "Input Signal";
    UI_TOOLTIP("Selects how the game's HDR output is decoded for APL, boost, and LUT. Auto follows the format ReShade reports and falls back to PQ.")
> = 0;

uniform float APLReferenceWhiteNits <
    ui_type = "slider";
    ui_min = 10.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "APL Reference White (nits)";
    UI_TOOLTIP("Sets the luminance represented by 100% APL.")
> = 1060.0;

uniform float PanelPeakNits <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1500.0; ui_step = 1.0;
    ui_label = "Panel Peak (nits)";
    UI_TOOLTIP("Peak signal the boost tonemaps into. Nothing is shown above it, and brighter content is compressed under it instead of clipped. 0 disables highlight protection.")
> = 1060.0;

uniform float APLSmoothingSeconds <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "APL Smoothing Time (s)";
    UI_TOOLTIP("Smooths APL changes over time. 0 disables smoothing.")
> = 0.5;

uniform float SIGNAL_REFERENCE_NITS <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 200.0; ui_step = 1.0;
    ui_label = "scRGB Signal Reference (nits)";
    UI_TOOLTIP("Sets the nits represented by scRGB value 1.0.")
> = 80.0;


#if PQHDRLUT_ENABLE
uniform bool EnablePQHDRLUT <
    ui_label = "Enable PQ HDR LUT";
    UI_TOOLTIP("Applies PQHDRLUT.cube after boost, or directly when boost is disabled.")
> = true;
#endif

uniform bool ShowOSD <
    ui_label = "Show APL Stats";
    UI_TOOLTIP("Shows raw APL, solved APL, and the output nits where the curve leaves the full gain, orange while that sits under the panel peak.")
> = false;

uniform bool ShowCompression <
    ui_label = "Show Compression";
    UI_TOOLTIP("Shows the image in gray, with each pixel the boost shows below the level the full gain gives it tinted from yellow for a slight cut to red for the deepest.")
> = false;

uniform float OSDBrightness <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 1.0; ui_step = 0.01;
    ui_label = "OSD Brightness";
    UI_TOOLTIP("Sets OSD and graph brightness.")
> = 0.5;

uniform int FrameCount < source = "framecount"; >;
uniform float FrameTime < source = "frametime"; >;

#if ENABLE_APL_GRAPH
uniform bool ShowAPLGraph <
    ui_label = "Show APL EOTF Debug Graph";
    UI_TOOLTIP("Shows identity, measured, remapped, predicted-output, and optional BT.2390 reference curves.")
> = true;

uniform bool GraphShowBT2390Reference <
    ui_label = "Graph Show BT.2390-Style Reference";
    UI_TOOLTIP("Shows the BT.2390-style reference curve.")
> = false;

uniform bool GraphUseFullFieldWindowProjection <
    ui_label = "Graph Use Window Projection";
    UI_TOOLTIP("Uses measured window data instead of the fixed-APL graph.")
> = true;

uniform int GraphProjectionWindowSize <
    ui_type = "combo";
    ui_items = "100% Window\0 50% Window\0 25% Window\0 15% Window\0 10% Window\0";
    ui_label = "Graph Projection Window Size";
    UI_TOOLTIP("Selects the measured window data used by the graph.")
> = 0;

uniform float GraphAPLIndex <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 50.0; ui_step = 0.01;
    ui_label = "Graph APL (%)";
    UI_TOOLTIP("Sets the raw APL used by the fixed-APL graph.")
> = 50.0;

uniform float GraphInputSignalLimitNits <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4000.0; ui_step = 1.0;
    ui_label = "Graph Input Signal Limit (nits)";
    UI_TOOLTIP("Caps the graph input signal. 0 disables the cap.")
> = 0.0;

uniform float GraphAxisMaxNits <
    ui_type = "slider";
    ui_min = 100.0; ui_max = 10000.0; ui_step = 1.0;
    ui_label = "Graph Axis Max (nits)";
    UI_TOOLTIP("Sets the maximum value shown on both graph axes.")
> = 1300.0;

uniform float GraphOpacity <
    ui_type = "slider";
    ui_min = 0.05; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Graph Opacity";
    UI_TOOLTIP("Sets graph opacity.")
> = 0.5;

uniform bool GraphUsePQSpace <
    ui_label = "Graph PQ-Encoded Axes";
    UI_TOOLTIP("Uses PQ spacing on the graph axes while labels remain in nits.")
> = true;
#endif


// Final boost curve used by the main pass, its parameters and its output PQ codes at the cell edges.
texture TexBoostParams
{
    Width = 2;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerBoostParams
{
    Texture = TexBoostParams;
};
storage2D<float4> StorageBoostParams
{
    Texture = TexBoostParams;
};

texture TexBoostCurve
{
    Width = BOOST_CURVE_CELLS + 1;
    Height = 1;
    Format = R32F;
};
sampler2D<float> SamplerBoostCurve
{
    Texture = TexBoostCurve;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageBoostCurve
{
    Texture = TexBoostCurve;
};

#if PQHDRLUT_ENABLE
texture3D PQHDRLUTTexture <
    source = "PQHDRLUT.cube";
>
{
    Width = PQHDRLUT_SIZE;
    Height = PQHDRLUT_SIZE;
    Depth = PQHDRLUT_SIZE;
    Format = RGBA32F;
};

sampler3D PQHDRLUTSampler
{
    Texture = PQHDRLUTTexture;
    AddressU = CLAMP;
    AddressV = CLAMP;
    AddressW = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

#endif

// This frame's raw APL, solved display APL, a written flag and the frame stamp, and in its second texel the track's
// load, the APL whose compensation is the shown gain and the APL whose compensation is the frame's best gain.
texture TexAPLInstant
{
    Width = 2;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerAPLInstant
{
    Texture = TexAPLInstant;
};
storage2D<float4> StorageAPLInstant
{
    Texture = TexAPLInstant;
};

// Last frame's copy of TexAPLInstant, its written flag cleared when frames were skipped.
texture TexAPLPrev
{
    Width = 2;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerAPLPrev
{
    Texture = TexAPLPrev;
};
storage2D<float4> StorageAPLPrev
{
    Texture = TexAPLPrev;
};

// PQ decode table with one node per 10-bit code. HDR10 input lands on node centers and reads exact values,
// finer input interpolates between neighboring codes.
#define APL_FAST_PQ_NODES 1024

texture TexAPLFastPQNits
{
    Width = APL_FAST_PQ_NODES;
    Height = 1;
    Format = R32F;
};
sampler SamplerAPLFastPQNits
{
    Texture = TexAPLFastPQNits;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = POINT;
};
storage2D<float> StorageAPLFastPQNits
{
    Texture = TexAPLFastPQNits;
};


// Row histograms.
texture TexAPLRowHistCount
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistCount
{
    Texture = TexAPLRowHistCount;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistCount
{
    Texture = TexAPLRowHistCount;
};

texture TexAPLRowHistOffset10
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistOffset10
{
    Texture = TexAPLRowHistOffset10;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistOffset10
{
    Texture = TexAPLRowHistOffset10;
};

texture TexAPLRowHistOffsetSq
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistOffsetSq
{
    Texture = TexAPLRowHistOffsetSq;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistOffsetSq
{
    Texture = TexAPLRowHistOffsetSq;
};


texture TexAPLRowHistMaxNits
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistMaxNits
{
    Texture = TexAPLRowHistMaxNits;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistMaxNits
{
    Texture = TexAPLRowHistMaxNits;
};

texture TexAPLRowHistLoad
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistLoad
{
    Texture = TexAPLRowHistLoad;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistLoad
{
    Texture = TexAPLRowHistLoad;
};

texture TexAPLGlobalHistCount
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLGlobalHistCount
{
    Texture = TexAPLGlobalHistCount;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLGlobalHistCount
{
    Texture = TexAPLGlobalHistCount;
};


// Global histogram sums generated after all row writes complete.
texture TexAPLGlobalHistOffset10
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32F;
};
sampler2D<float> SamplerAPLGlobalHistOffset10
{
    Texture = TexAPLGlobalHistOffset10;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageAPLGlobalHistOffset10
{
    Texture = TexAPLGlobalHistOffset10;
};

texture TexAPLGlobalHistOffsetSq
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32F;
};
sampler2D<float> SamplerAPLGlobalHistOffsetSq
{
    Texture = TexAPLGlobalHistOffsetSq;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageAPLGlobalHistOffsetSq
{
    Texture = TexAPLGlobalHistOffsetSq;
};

texture TexAPLGlobalHistMaxNits
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32F;
};
sampler2D<float> SamplerAPLGlobalHistMaxNits
{
    Texture = TexAPLGlobalHistMaxNits;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageAPLGlobalHistMaxNits
{
    Texture = TexAPLGlobalHistMaxNits;
};

texture TexAPLGlobalHistLoad
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32F;
};
sampler2D<float> SamplerAPLGlobalHistLoad
{
    Texture = TexAPLGlobalHistLoad;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageAPLGlobalHistLoad
{
    Texture = TexAPLGlobalHistLoad;
};

// The frame's brightest channel in quarter nits, so the curve's top lands exactly on the brightest pixel.
texture TexAPLFrameTop
{
    Width = 1;
    Height = 1;
    Format = R32I;
};
sampler2D<int> SamplerAPLFrameTop
{
    Texture = TexAPLFrameTop;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLFrameTop
{
    Texture = TexAPLFrameTop;
};


#if ENABLE_APL_GRAPH
#define GRAPH_CURVE_SAMPLES 64

// Graph curve rows: remapped signal, predicted output, measured output, reference.
#define GCURVE_REMAPPED  0
#define GCURVE_CORRECTED 1
#define GCURVE_MEASURED  2
#define GCURVE_BT2390REF 3

texture TexGraphParams
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerGraphParams
{
    Texture = TexGraphParams;
};


// Per-sample graph projection: remapped nits, predicted output, solved APL, valid flag.
texture TexGraphProjection
{
    Width  = GRAPH_CURVE_SAMPLES;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerGraphProjection
{
    Texture   = TexGraphProjection;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};


// Screen-space line segments for the four graph curves.
texture TexGraphCurves
{
    Width  = GRAPH_CURVE_SAMPLES;
    Height = 4;
    Format = RGBA32F;
};
sampler SamplerGraphCurves
{
    Texture   = TexGraphCurves;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};


#define GRAPH_LINE_COUNT 32
// Screen-space grid, tick, and identity-line segments.
texture TexGraphLines
{
    Width  = GRAPH_LINE_COUNT;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerGraphLines
{
    Texture   = TexGraphLines;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};

#endif


float GetLuma709(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float GetLuma2020(float3 color)
{
    return dot(color, float3(0.2627, 0.6780, 0.0593));
}

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}

// Channel limits are judged in Rec.2020, the gamut of the HDR10 signal the panel receives.
float3 Rec709ToRec2020(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.6274040, 0.3292820, 0.0433136)),
        dot(rgb, float3(0.0690970, 0.9195400, 0.0113612)),
        dot(rgb, float3(0.0163916, 0.0880132, 0.8955950))
    );
}

// The panel's own primaries from its EDID, with the D65 white the signal's gray sits on.
float3 Rec2020ToPanel(float3 rgb)
{
    return float3(
        dot(rgb, float3( 1.215214748, -0.179592899, -0.035621849)),
        dot(rgb, float3(-0.033322071,  1.046218857, -0.012896786)),
        dot(rgb, float3(-0.008296491, -0.018309355,  1.026605846))
    );
}

// Load of a pure panel primary as a share of white's at the same channel level, from ABL_NullTest's color checks.
static const float SINGLE_PRIMARY_LOAD = 0.75;

// The panel counts a pixel partly by its brightest subpixel and partly by the mean of all three, so a pure
// primary loads it nearly as much as white at the same channel level. Gray loads at its luma either way, and
// a color past the panel's gamut drives no channel below zero.
float GetPanelLoadNits(float3 rec2020Nits)
{
    float3 channels = max(Rec2020ToPanel(rec2020Nits), 0.0);
    float brightestShare = (3.0 * SINGLE_PRIMARY_LOAD - 1.0) * 0.5;
    return lerp(dot(channels, 1.0 / 3.0), Max3(channels), brightestShare);
}

// ST.2084 transfer functions. Linear values are relative to 10000 nits.
static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

float3 PQToLinearBT2100(float3 v)
{
    float3 vp = pow(saturate(v), 1.0 / PQ_M2);
    float3 num = max(vp - PQ_C1, 0.0);
    float3 den = PQ_C2 - PQ_C3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / PQ_M1);
}

float PQToLinearBT2100(float v)
{
    float vp = pow(saturate(v), 1.0 / PQ_M2);
    float num = max(vp - PQ_C1, 0.0);
    float den = PQ_C2 - PQ_C3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / PQ_M1);
}

float3 LinearToPQBT2100(float3 v)
{
    float3 Lm1 = pow(saturate(v), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * Lm1) / (1.0 + PQ_C3 * Lm1), PQ_M2);
}

// Monotonic above 1.0, so gain offsets stay ordered past 10000 nits.
float LinearToPQBT2100Unclamped(float linearValue)
{
    float Lm1 = pow(max(linearValue, 0.0), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * Lm1) / (1.0 + PQ_C3 * Lm1), PQ_M2);
}

float LinearToPQBT2100(float linearValue)
{
    return LinearToPQBT2100Unclamped(saturate(linearValue));
}

float NitsToPQ(float nits)
{
    return LinearToPQBT2100(nits / 10000.0);
}

float NitsToPQUnclamped(float nits)
{
    return LinearToPQBT2100Unclamped(nits / 10000.0);
}

bool IsPQInput()
{
    if (InputSignal == 1)
        return true;

    if (InputSignal == 2)
        return false;

    return BUFFER_COLOR_SPACE != 2;
}

// Optional PQ Rec.2020 calibration LUT.
#if PQHDRLUT_ENABLE
float3 PQHDRLUT_PQ_To_Nits(float3 pq)
{
    return PQToLinearBT2100(max(pq, 0.0)) * 10000.0;
}

float3 PQHDRLUT_Nits_To_PQ(float3 nits)
{
    return LinearToPQBT2100(max(nits, 0.0) / 10000.0);
}


// Exact inverse of Rec709ToRec2020, so an identity LUT round-trips in-gamut scRGB.
float3 Rec2020ToRec709(float3 rgb)
{
    return float3(
        dot(rgb, float3( 1.660490296, -0.587639106, -0.072851598)),
        dot(rgb, float3(-0.124549970,  1.132899922, -0.008347964)),
        dot(rgb, float3(-0.018151119, -0.100578724,  1.118729878))
    );
}

float3 PQHDRLUT_Buffer_To_PQ2020(float3 color, bool pqInput)
{
    if (!pqInput)
    {
        // Keep signed scRGB components through the gamut conversion.
        float3 rec2020_nits = Rec709ToRec2020(color * SIGNAL_REFERENCE_NITS);
        return PQHDRLUT_Nits_To_PQ(max(rec2020_nits, 0.0));
    }

    return max(color, 0.0);
}

float3 PQHDRLUT_PQ2020_To_Buffer(float3 pq, bool pqInput)
{
    if (!pqInput)
    {
        float3 rec709_nits = Rec2020ToRec709(PQHDRLUT_PQ_To_Nits(max(pq, 0.0)));

        // Signed scRGB components can represent colors outside Rec.709.
        return rec709_nits / SIGNAL_REFERENCE_NITS;
    }

    return pq;
}

// Map normalized PQ values to texel centers for trilinear sampling.
float3 PQHDRLUT_Sample(float3 pq)
{
    float3 coordinate = saturate(pq);

    coordinate =
        (coordinate * (PQHDRLUT_SIZE - 1.0) + 0.5) /
        PQHDRLUT_SIZE;

    return tex3D(PQHDRLUTSampler, coordinate).rgb;
}


float3 PQHDRLUT_Apply(float3 color)
{
    bool pqInput = IsPQInput();
    float3 sourcePQ = PQHDRLUT_Buffer_To_PQ2020(color, pqInput);
    float3 calibratedPQ = PQHDRLUT_Sample(sourcePQ);
    return PQHDRLUT_PQ2020_To_Buffer(calibratedPQ, pqInput);
}
#endif


// PQ contrast the fixed shoulder eases to. Content above the panel peak keeps at most this and no level keeps less.
static const float HIGHLIGHT_CONTRAST = 0.25;

// PQ width over which slopes ease between the full gain and the highlight contrast.
static const float KNEE_TRANSITION_PQ = 0.04;

// PQ size of the fine detail a pixel carries, the 0.2 average local RMS contrast of natural images (Frazor and
// Geisler 2006) at highlight levels, where a unit of natural log luminance spans about 0.108 PQ.
static const float DETAIL_PQ = 0.022;

// Half a 10-bit PQ code, the step the eye cannot see. The gain's cost is in PQ, so it is also the cost of shifting
// every pixel by that step.
static const float HALF_CODE_PQ = 0.5 / 1023.0;


// Full gain up to the knee. Above it the output PQ codes come from a table fitted to the frame, up to maxU, the
// full-gain PQ code of a 10000 nit signal. Levels named U are PQ codes after the full gain. comp is the gain that
// cancels the panel's dimming, which shows every level exact, and the full gain never exceeds it.
struct BoostCurve
{
    float gain;
    float comp;
    float peakPQ;
    float kneeNits;
    float kneeU;
    float maxU;
    float departureU;
};

// How far the shoulder sits below the full gain at u.
float ShoulderCompressionPQ(float u, float kneeU)
{
    float t = max(u - kneeU, 0.0);
    float eased = (t < KNEE_TRANSITION_PQ)
        ? t * t / (2.0 * KNEE_TRANSITION_PQ)
        : t - 0.5 * KNEE_TRANSITION_PQ;

    return (1.0 - HIGHLIGHT_CONTRAST) * eased;
}

// The fixed shoulder depends only on the gain. It eases from the knee to the highlight contrast and lands a 10000
// nit signal on the panel peak, and the fitted curve never goes under it or flatter than it.
BoostCurve MakeBoostCurve(float gain, float comp)
{
    BoostCurve curve;
    curve.gain = max(gain, 1.0);
    curve.comp = comp;
    curve.peakPQ = 1.0;
    curve.kneeNits = 10000.0;
    curve.kneeU = 1.0;
    curve.maxU = 1.0;
    curve.departureU = 1.0;

    if (PanelPeakNits <= 0.0)
        return curve;

    curve.peakPQ = NitsToPQ(PanelPeakNits);
    curve.maxU = NitsToPQUnclamped(10000.0 * curve.gain);

    // The shoulder span that absorbs the overshoot, ending inside the slope ease or past it.
    float eased = (curve.maxU - curve.peakPQ) / (1.0 - HIGHLIGHT_CONTRAST);
    float span = (eased < 0.5 * KNEE_TRANSITION_PQ)
        ? sqrt(2.0 * KNEE_TRANSITION_PQ * eased)
        : eased + 0.5 * KNEE_TRANSITION_PQ;

    curve.kneeU = curve.maxU - span;
    curve.kneeNits = PQToLinearBT2100(curve.kneeU) * 10000.0 / curve.gain;
    curve.departureU = curve.kneeU;
    return curve;
}

// The first texel holds the gain and the knee, the second the curve's top, where it leaves the exact levels and the
// compensation.
float4 PackBoostCurve(BoostCurve curve, int texel)
{
    if (texel == 0)
        return float4(curve.gain, curve.peakPQ, curve.kneeNits, curve.kneeU);

    return float4(curve.maxU, curve.departureU, curve.comp, 0.0);
}

BoostCurve UnpackBoostCurve(float4 knee, float4 top)
{
    BoostCurve curve;
    curve.gain = knee.x;
    curve.peakPQ = knee.y;
    curve.kneeNits = knee.z;
    curve.kneeU = knee.w;
    curve.maxU = top.x;
    curve.departureU = top.y;
    curve.comp = top.z;
    return curve;
}

float CurveCellWidth(BoostCurve curve)
{
    return (curve.maxU - curve.kneeU) / BOOST_CURVE_CELLS;
}

// Full-gain PQ code at a cell edge.
float CurveNodeU(int node, BoostCurve curve)
{
    return curve.kneeU + node * CurveCellWidth(curve);
}

// Cell of the curve that holds u, and how far through the cell u sits.
int CurveCell(float u, BoostCurve curve, out float fraction)
{
    float position = (min(u, curve.maxU) - curve.kneeU) / CurveCellWidth(curve);
    int cell = min(int(position), BOOST_CURVE_CELLS - 1);
    fraction = position - cell;
    return cell;
}

// PQ code after the full gain, inside the curve's range.
float FullGainPQ(float nits, BoostCurve curve)
{
    return NitsToPQUnclamped(clamp(nits, 0.0, 10000.0) * curve.gain);
}

// Signal nits of a level whose curve output is the PQ code y.
float CurveOutputNits(float nits, float y, BoostCurve curve)
{
    float safeNits = max(nits, 0.0);

    if (safeNits <= curve.kneeNits)
        return safeNits * curve.gain;

    return PQToLinearBT2100(min(y, curve.peakPQ)) * 10000.0;
}

// One scale for all channels. Luma follows the curve, and the brightest channel follows it too, which keeps it
// under the panel peak.
float CurveBoostScale(float lumaNits, float lumaY, float maxChannelNits, float maxChannelY, BoostCurve curve)
{
    return min(
        CurveOutputNits(lumaNits, lumaY, curve) / max(lumaNits, 1e-6),
        CurveOutputNits(maxChannelNits, maxChannelY, curve) / max(maxChannelNits, 1e-6));
}


// 3x5 glyphs, bit (x + 3 * y) with y = 0 on the bottom row.
static const int DIGIT_GLYPHS[10] = { 31599, 9362, 29671, 29391, 23497, 31183, 31215, 29257, 31727, 31695 };

float SampleGlyph(int pattern, float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    int x = min(int(uv.x * 3.0), 2);
    int y = min(int((1.0 - uv.y) * 5.0), 4);
    return (pattern >> (x + y * 3)) & 1;
}

float GetDigit(int digit, float2 uv)
{
    return SampleGlyph(DIGIT_GLYPHS[clamp(digit, 0, 9)], uv);
}

float GetPercent(float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    float2 d0 = uv - float2(0.3, 0.25);
    float2 d1 = uv - float2(0.7, 0.75);
    bool slash = abs(uv.x - (1.0 - uv.y)) < 0.15;
    bool circles = (dot(d0, d0) < 0.04) || (dot(d1, d1) < 0.04);

    return (slash || circles) ? 1.0 : 0.0;
}

float GetDot(float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    float y = 1.0 - uv.y;
    return (uv.x > 0.35 && uv.x < 0.65 && y > 0.00 && y < 0.20) ? 1.0 : 0.0;
}

float DrawOSDDigitAt(float2 texcoord, float2 topRight, float scale, float aspect, int digit)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x *= aspect;

    uv -= anchor;
    uv.x = -uv.x;

    return GetDigit(digit, uv / scale);
}

float DrawOSDRow5(float2 texcoord, float2 topRight, float scale, float stepX, float aspect, int value)
{
    uint v = (uint)clamp(value, 0, 99999);
    float mask = 0.0;

    mask += DrawOSDDigitAt(texcoord, topRight, scale, aspect, (int)(v % 10));

    if (v >= 10)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX, 0.0), scale, aspect, (int)((v / 10) % 10));

    if (v >= 100)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect, (int)((v / 100) % 10));

    if (v >= 1000)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, aspect, (int)((v / 1000) % 10));

    if (v >= 10000)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 4.0, 0.0), scale, aspect, (int)((v / 10000) % 10));

    return saturate(mask);
}

float Remap01(float x, float a, float b)
{
    return saturate((x - a) / max(b - a, 1e-6));
}

float SegmentLerp(float x, float x0, float y0, float x1, float y1)
{
    return lerp(y0, y1, Remap01(x, x0, x1));
}

// 1D compensation table in log2, so lookups need no logs of their own. Each anchor holds log2 of its APL in
// percent and log2 of the 1060 nit peak at 3% APL divided by the peak measured at that APL.
static const int APL_ANCHOR_COUNT = 24;

static const float2 APL_ANCHORS[APL_ANCHOR_COUNT] =
{
    float2(1.584963, 0.000000), // 3%   (1060.0 nits)
    float2(2.000000, 0.198724), // 4%   (923.6 nits)
    float2(2.321928, 0.384513), // 5%   (812.0 nits)
    float2(2.584963, 0.559800), // 6%   (719.1 nits)
    float2(2.807355, 0.720276), // 7%   (643.4 nits)
    float2(3.000000, 0.860765), // 8%   (583.7 nits)
    float2(3.169925, 0.988072), // 9%   (534.4 nits)
    float2(3.321928, 1.104405), // 10%  (493.0 nits)
    float2(3.459432, 1.146569), // 11%  (478.8 nits)
    float2(3.584963, 1.173946), // 12%  (469.8 nits)
    float2(3.700440, 1.204986), // 13%  (459.8 nits)
    float2(3.807355, 1.230627), // 14%  (451.7 nits)
    float2(3.906891, 1.260641), // 15%  (442.4 nits)
    float2(4.087463, 1.299644), // 17%  (430.6 nits)
    float2(4.321928, 1.362298), // 20%  (412.3 nits)
    float2(4.459432, 1.391637), // 22%  (404.0 nits)
    float2(4.643856, 1.443258), // 25%  (389.8 nits)
    float2(4.754888, 1.474309), // 27%  (381.5 nits)
    float2(4.906891, 1.506043), // 30%  (373.2 nits)
    float2(5.129283, 1.551199), // 35%  (361.7 nits)
    float2(5.321928, 1.606491), // 40%  (348.1 nits)
    float2(5.643856, 1.689660), // 50%  (328.6 nits)
    float2(6.228819, 1.824882), // 75%  (299.2 nits)
    float2(6.643856, 1.914396)  // 100% (281.2 nits)
};


int FindAPLAnchorIndex(float logAPL)
{
    int idx = 0;
    [unroll]
    for (int i = 0; i < APL_ANCHOR_COUNT - 1; ++i)
        idx += int(step(APL_ANCHORS[i + 1].x, logAPL));
    return min(idx, APL_ANCHOR_COUNT - 2);
}

// Log compensation, and so log nits, is linear in log APL between anchors.
float LookupMeasuredLogComp1D(float aplPct)
{
    float logAPL = clamp(log2(max(aplPct, 1e-6)), APL_ANCHORS[0].x, APL_ANCHORS[APL_ANCHOR_COUNT - 1].x);
    int a0 = FindAPLAnchorIndex(logAPL);
    float2 p0 = APL_ANCHORS[a0];
    float2 p1 = APL_ANCHORS[a0 + 1];

    return SegmentLerp(logAPL, p0.x, p0.y, p1.x, p1.y);
}

float ComputeSceneLogGainFromAPL(float currentAPL)
{
    float aplPct = saturate(currentAPL) * 100.0;
    return max(LookupMeasuredLogComp1D(aplPct), 0.0);
}


float SceneGainFromLogGain(float sceneLogGain)
{
    return exp2(max(sceneLogGain, 0.0));
}

// The APL whose compensation is the gain, the table read the other way. The compensation rises at every anchor, so
// each gain up to the top one has a single APL.
float APLFromSceneGain(float gain)
{
    float logGain = clamp(log2(max(gain, 1.0)), APL_ANCHORS[0].y, APL_ANCHORS[APL_ANCHOR_COUNT - 1].y);
    int a0 = 0;
    [unroll]
    for (int i = 0; i < APL_ANCHOR_COUNT - 2; ++i)
        a0 += int(step(APL_ANCHORS[i + 1].y, logGain));

    float2 p0 = APL_ANCHORS[a0];
    float2 p1 = APL_ANCHORS[a0 + 1];

    return exp2(SegmentLerp(logGain, p0.y, p0.x, p1.y, p1.x)) * 0.01;
}

float ComputeTemporalBlendFactor(float smoothingSeconds)
{
    if (smoothingSeconds <= 1e-6)
        return 1.0;

    float dtSeconds = max(FrameTime, 0.0) * 0.001;
    return saturate(1.0 - exp(-dtSeconds / max(smoothingSeconds, 1e-6)));
}

BoostCurve LoadBoostCurve()
{
    return UnpackBoostCurve(tex2Dfetch(SamplerBoostParams, int2(0, 0)), tex2Dfetch(SamplerBoostParams, int2(1, 0)));
}

// Output PQ code of the fitted curve at the full-gain PQ code u.
float CurvePQ(float u, BoostCurve curve)
{
    if (u <= curve.kneeU)
        return u;

    float fraction;
    int cell = CurveCell(u, curve, fraction);
    float y0 = tex2Dfetch(SamplerBoostCurve, int2(cell, 0));
    float y1 = tex2Dfetch(SamplerBoostCurve, int2(cell + 1, 0));
    return min(lerp(y0, y1, fraction), curve.peakPQ);
}

// Luma and brightest Rec.2020 channel of a signal in nits, the channel never under the luma.
float2 GetSignalLumaAndMaxNits(float3 color)
{
    float2 levels;

    if (IsPQInput())
    {
        float3 linearColorNits = PQToLinearBT2100(saturate(color)) * 10000.0;
        levels = float2(GetLuma2020(linearColorNits), Max3(linearColorNits));
    }
    else
    {
        levels = float2(GetLuma709(color), Max3(Rec709ToRec2020(color))) * SIGNAL_REFERENCE_NITS;
    }

    return float2(levels.x, max(levels.y, levels.x));
}

float ComputeBoostScale(float2 levels, BoostCurve curve)
{
    if (levels.y <= curve.kneeNits)
        return curve.gain;

    float lumaY = CurvePQ(FullGainPQ(levels.x, curve), curve);
    float maxChannelY = CurvePQ(FullGainPQ(levels.y, curve), curve);
    return CurveBoostScale(levels.x, lumaY, levels.y, maxChannelY, curve);
}

float3 ApplyBoostFromPrecomputedParams(float3 color, BoostCurve curve)
{
    float3 boosted = color;

    if (IsPQInput())
    {
        float3 linearColorNits = PQToLinearBT2100(saturate(color)) * 10000.0;
        float lumaNits = GetLuma2020(linearColorNits);

        if (lumaNits > 1e-6)
        {
            float2 levels = float2(lumaNits, max(Max3(linearColorNits), lumaNits));
            boosted = LinearToPQBT2100(linearColorNits * (ComputeBoostScale(levels, curve) / 10000.0));
        }
    }
    else
    {
        float2 levels = GetSignalLumaAndMaxNits(color);

        if (levels.x > 1e-6)
            boosted = color * ComputeBoostScale(levels, curve);
    }

    return boosted;
}

// A cut under half a 10-bit step rounds to the same code.
static const float HALF_10BIT_STEP_PQ = 0.5 / 1023.0;

// Gray where a pixel shows its compensated level, and yellow to red as the gain and the curve cut it deeper under it,
// red at the cut that lands a 10000 nit signal on the panel peak.
float3 DrawCompressionHeatmap(float3 sourceColor, float3 boostedColor, BoostCurve curve)
{
    float sourceLumaNits = GetSignalLumaAndMaxNits(sourceColor).x;
    float shownLumaNits = GetSignalLumaAndMaxNits(boostedColor).x;
    float cut = NitsToPQUnclamped(sourceLumaNits * curve.comp) - NitsToPQ(shownLumaNits);

    float3 tint = 1.0;
    if (cut > HALF_10BIT_STEP_PQ)
        tint = lerp(float3(1.0, 1.0, 0.0), float3(1.0, 0.0, 0.0), saturate(cut / max(NitsToPQUnclamped(10000.0 * curve.comp) - curve.peakPQ, 1e-6)));

    if (IsPQInput())
        return LinearToPQBT2100(tint * (shownLumaNits / GetLuma2020(tint) / 10000.0));

    return tint * (shownLumaNits / GetLuma709(tint) / SIGNAL_REFERENCE_NITS);
}


#if ENABLE_APL_GRAPH
// A gray window over black is one level, so the fitted curve keeps it at the full gain up to the panel peak and
// lands it on the panel peak above.
float ComputeGraphWindowNits(float nits, float gain)
{
    float safeNits = max(nits, 0.0);

    if (PanelPeakNits <= 0.0)
        return safeNits * gain;

    return min(safeNits * gain, PanelPeakNits);
}

// Display-side APL of a gray level over a share of the screen, boosted with a log gain.
float ComputeGrayAreaDisplayAPL(float nits, float areaFraction, float logGain)
{
    float windowNits = ComputeGraphWindowNits(nits, SceneGainFromLogGain(logGain));
    return saturate(areaFraction * saturate(windowNits / max(APLReferenceWhiteNits, 1.0)));
}

// The graph shows settled states, where the gain is the compensation for the APL it shows. The compensation
// rises slower than the log gain, so there is one settled gain, found with ten bisection steps.
float SolveSettledGrayAreaDisplayAPL(float nits, float areaFraction)
{
    float maxLogGain = ComputeSceneLogGainFromAPL(1.0);
    float lo = 0.0;
    float hi = maxLogGain;

    [loop]
    for (int i = 0; i < 10; ++i)
    {
        float mid = 0.5 * (lo + hi);

        if (ComputeSceneLogGainFromAPL(ComputeGrayAreaDisplayAPL(nits, areaFraction, mid)) > mid)
            lo = mid;
        else
            hi = mid;
    }

    float logGain = 0.5 * (lo + hi);

    // Scenes at either end of the table get its exact end values.
    if (ComputeSceneLogGainFromAPL(ComputeGrayAreaDisplayAPL(nits, areaFraction, 0.0)) <= 1e-6)
        logGain = 0.0;
    else if (ComputeSceneLogGainFromAPL(ComputeGrayAreaDisplayAPL(nits, areaFraction, maxLogGain)) >= maxLogGain - 1e-6)
        logGain = maxLogGain;

    return ComputeGrayAreaDisplayAPL(nits, areaFraction, logGain);
}

float SolveUniformSceneDisplayAPL(float rawAPL)
{
    float safeRawAPL = saturate(rawAPL);

    if (safeRawAPL <= 1e-6 || !EnableEOTFBoost)
        return safeRawAPL;

    return SolveSettledGrayAreaDisplayAPL(safeRawAPL * max(APLReferenceWhiteNits, 1.0), 1.0);
}

// APL rows of the measured 2D compensation table.
static const int GRAPH_APL_COUNT = 10;

static const float GRAPH_APL_POINTS[GRAPH_APL_COUNT] =
{
    3.000000, 5.000000, 7.000000, 10.000000, 14.000000, 18.000000, 22.000000, 25.000000, 35.000000, 50.000000
};

// Input levels of the measured 2D compensation table.
static const int NIT_COUNT = 24;

static const float NIT_POINTS[NIT_COUNT] =
{
    10.302358, 13.132379, 16.611621, 20.870708, 26.064850, 32.378420, 40.030390, 49.280814, 60.438551, 73.870492, 90.012580, 109.383004, 132.598006, 160.390856, 193.634650, 233.369755, 280.836899, 337.517130, 405.180165, 485.942985, 587.341000, 707.414628, 845.814884, 1040.932391
};

static const float GRAPH_COMP_TABLE_2D[GRAPH_APL_COUNT * NIT_COUNT] =
{
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,
    1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000, 1.000000,

    1.275485, 1.279098, 1.298112, 1.311262, 1.320233, 1.306626, 1.336365, 1.320144,
    1.337008, 1.337614, 1.354279, 1.352556, 1.347158, 1.353409, 1.354995, 1.357722,
    1.360410, 1.379355, 1.375188, 1.377428, 1.380128, 1.378296, 1.394903, 1.403779,

    1.636865, 1.586585, 1.600228, 1.632120, 1.646603, 1.656140, 1.653732, 1.648574,
    1.659723, 1.638967, 1.676518, 1.673813, 1.667162, 1.672429, 1.678772, 1.682167,
    1.684833, 1.688457, 1.682479, 1.705485, 1.708849, 1.722217, 1.732755, 1.743012,

    2.222370, 2.139135, 2.131274, 2.103239, 2.119450, 2.139539, 2.144950, 2.119860,
    2.154030, 2.144674, 2.181553, 2.151376, 2.139477, 2.150906, 2.153600, 2.140693,
    2.162291, 2.190399, 2.181303, 2.170379, 2.194950, 2.195467, 2.208124, 2.226317,

    2.574646, 2.466301, 2.477981, 2.440763, 2.439207, 2.453153, 2.457554, 2.437744,
    2.459988, 2.467005, 2.474901, 2.455437, 2.446400, 2.453859, 2.454635, 2.467066,
    2.467625, 2.465686, 2.466095, 2.466487, 2.476404, 2.484286, 2.496364, 2.518080,

    2.748700, 2.653554, 2.657380, 2.630880, 2.595614, 2.617234, 2.624612, 2.604644,
    2.621808, 2.624117, 2.640117, 2.636610, 2.604680, 2.617061, 2.615594, 2.612188,
    2.617207, 2.621120, 2.624654, 2.626987, 2.640365, 2.633628, 2.665580, 2.675877,

    2.916959, 2.818433, 2.786699, 2.777913, 2.748502, 2.748234, 2.764812, 2.754077,
    2.767587, 2.764558, 2.776648, 2.760512, 2.734844, 2.742903, 2.740379, 2.745571,
    2.753666, 2.757212, 2.750390, 2.758649, 2.770630, 2.772743, 2.790399, 2.814688,

    3.005716, 2.911831, 2.892784, 2.875547, 2.824210, 2.833016, 2.856895, 2.834469,
    2.853785, 2.843423, 2.864118, 2.839076, 2.816207, 2.827746, 2.825887, 2.840115,
    2.842497, 2.844660, 2.835615, 2.839335, 2.859106, 2.857170, 2.876447, 2.900269,

    3.227778, 3.139621, 3.086106, 3.101464, 3.053503, 3.050585, 3.063989, 3.034956,
    3.074032, 3.056235, 3.082187, 3.064304, 3.033025, 3.038294, 3.037854, 3.051513,
    3.057893, 3.059339, 3.042766, 3.063924, 3.067941, 3.076905, 3.098045, 3.124520,

    3.605147, 3.469041, 3.422317, 3.396852, 3.379085, 3.350383, 3.331431, 3.333736,
    3.385554, 3.346382, 3.380603, 3.345667, 3.325029, 3.308191, 3.317324, 3.329362,
    3.338411, 3.331323, 3.321922, 3.330550, 3.342307, 3.347892, 3.376754, 3.407354
};


// Measured window responses used only by graph projection, all sampled at FULLFIELD_INPUT_NITS.
static const int FULLFIELD_COUNT = 33;

static const float FULLFIELD_INPUT_NITS[FULLFIELD_COUNT] =
{
    0.000000, 0.011931, 0.054452, 0.138304, 0.282443, 0.521309, 0.865680, 1.384067,
    2.082348, 3.035066, 4.374848, 6.086059, 8.324707, 11.363916, 15.134164, 19.949442,
    26.352272, 34.156536, 43.978027, 56.870362, 72.413132, 92.698470, 117.036078, 147.265282,
    186.502536, 233.369755, 291.383762, 368.488542, 460.037005, 571.771366, 720.083776, 901.023134,
    1040.932000
};

static const float FULLFIELD_100_MEASURED_NITS[FULLFIELD_COUNT] =
{
    0.000000, 0.000000, 0.025553, 0.118012, 0.288831, 0.591004, 0.975432, 1.522651,
    2.381936, 3.378590, 5.068168, 6.945428, 9.627818, 12.967435, 16.961642, 20.195403,
    23.503979, 30.959431, 35.582524, 38.937325, 42.492201, 45.812047, 49.682839, 59.134684,
    70.803150, 84.266779, 100.396451, 118.819227, 141.396332, 169.118513, 202.873554, 239.232825,
    265.021011
};


static const float FULLFIELD_50_MEASURED_NITS[FULLFIELD_COUNT] =
{
    0.000000, 0.000000, 0.019611, 0.097831, 0.249949, 0.526106, 0.889249, 1.411673,
    2.227720, 3.168462, 4.802616, 6.558748, 9.185429, 12.424980, 16.227606, 19.369587,
    23.859118, 31.436385, 40.137642, 53.197343, 65.392805, 74.547320, 80.127169, 85.519747,
    92.611297, 100.748551, 119.449653, 140.743873, 168.553173, 197.406956, 239.022413, 280.116401,
    310.507285
};

static const float FULLFIELD_25_MEASURED_NITS[FULLFIELD_COUNT] =
{
    0.000000, 0.000000, 0.020193, 0.098958, 0.253351, 0.530072, 0.894046, 1.417652,
    2.236172, 3.175224, 4.814092, 6.578921, 9.210201, 12.453936, 16.233701, 19.360823,
    24.324769, 31.664910, 40.662945, 53.441695, 68.002699, 88.193059, 111.606274, 135.299708,
    149.261837, 161.082050, 170.971315, 185.138530, 201.136027, 235.942743, 283.942968, 331.624744,
    366.448525
};

static const float FULLFIELD_15_MEASURED_NITS[FULLFIELD_COUNT] =
{
    0.000000, 0.000000, 0.024520, 0.114708, 0.280640, 0.581359, 0.958295, 1.494907,
    2.323773, 3.286472, 4.984005, 6.824739, 9.518044, 12.823650, 16.687334, 19.874191,
    24.870417, 32.192746, 41.126911, 53.811406, 68.639696, 88.228024, 111.933290, 142.016629,
    178.322722, 218.856152, 244.621474, 264.975028, 281.601565, 304.076471, 324.154317, 379.958739,
    415.885700
};

static const float FULLFIELD_10_MEASURED_NITS[FULLFIELD_COUNT] =
{
    0.000000, 0.000000, 0.023311, 0.111391, 0.276822, 0.572010, 0.949903, 1.489990,
    2.313793, 3.300262, 4.981862, 6.854603, 9.544428, 12.853254, 16.722919, 20.305498,
    26.128305, 33.665465, 42.636117, 55.207774, 69.932789, 89.672005, 112.739759, 141.994701,
    180.269676, 227.876442, 287.603899, 341.189386, 373.286063, 402.007822, 430.822267, 464.211151,
    474.045533
};


static const int GRAPH_WINDOW_MODE_50  = 1;
static const int GRAPH_WINDOW_MODE_25  = 2;
static const int GRAPH_WINDOW_MODE_15  = 3;
static const int GRAPH_WINDOW_MODE_10  = 4;

int FindFullFieldWindowInputIndex(float inputNits)
{
    [loop]
    for (int i = 0; i < FULLFIELD_COUNT - 1; ++i)
    {
        if (inputNits < FULLFIELD_INPUT_NITS[i + 1])
            return i;
    }

    return FULLFIELD_COUNT - 2;
}

float GetFullFieldWindowScaleByMode(int mode)
{
    switch (mode)
    {
        case GRAPH_WINDOW_MODE_10: return 0.10;
        case GRAPH_WINDOW_MODE_15: return 0.15;
        case GRAPH_WINDOW_MODE_25: return 0.25;
        case GRAPH_WINDOW_MODE_50: return 0.50;
        default:                   return 1.00;
    }
}

float GetFullFieldMeasuredNitsByModeAndIndex(int mode, int idx)
{
    switch (mode)
    {
        case GRAPH_WINDOW_MODE_10: return FULLFIELD_10_MEASURED_NITS[idx];
        case GRAPH_WINDOW_MODE_15: return FULLFIELD_15_MEASURED_NITS[idx];
        case GRAPH_WINDOW_MODE_25: return FULLFIELD_25_MEASURED_NITS[idx];
        case GRAPH_WINDOW_MODE_50: return FULLFIELD_50_MEASURED_NITS[idx];
        default:                   return FULLFIELD_100_MEASURED_NITS[idx];
    }
}

// The windows were measured at 10-bit PQ input codes, so the response interpolates in PQ.
float SampleMeasuredOutputNitsFullFieldByMode(int mode, float targetNits)
{
    float clampedNits = clamp(targetNits, FULLFIELD_INPUT_NITS[0], FULLFIELD_INPUT_NITS[FULLFIELD_COUNT - 1]);
    int i0 = FindFullFieldWindowInputIndex(clampedNits);
    int i1 = min(i0 + 1, FULLFIELD_COUNT - 1);

    float outputPQ = SegmentLerp(
        NitsToPQ(clampedNits),
        NitsToPQ(FULLFIELD_INPUT_NITS[i0]), NitsToPQ(GetFullFieldMeasuredNitsByModeAndIndex(mode, i0)),
        NitsToPQ(FULLFIELD_INPUT_NITS[i1]), NitsToPQ(GetFullFieldMeasuredNitsByModeAndIndex(mode, i1))
    );

    return PQToLinearBT2100(outputPQ) * 10000.0;
}

float GetFullFieldMeasuredMaxInputNits()
{
    return FULLFIELD_INPUT_NITS[FULLFIELD_COUNT - 1];
}

float GetFullFieldMeasuredMaxOutputNitsByMode(int mode)
{
    float maxMeasuredNits = 0.0;

    [loop]
    for (int i = 0; i < FULLFIELD_COUNT; ++i)
        maxMeasuredNits = max(maxMeasuredNits, GetFullFieldMeasuredNitsByModeAndIndex(mode, i));

    return maxMeasuredNits;
}


// Simulate a grayscale window on black with the live solver.
float4 ComputeFullFieldLiveProjectionByMode(int mode, float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);
    float windowFraction = saturate(GetFullFieldWindowScaleByMode(mode));
    float referenceWhite = max(APLReferenceWhiteNits, 1.0);

    float rawWindowMetric = saturate(safeInputNits / referenceWhite);
    float rawAPL = saturate(windowFraction * rawWindowMetric);
    float displayAPL = rawAPL;
    float remappedSignalNits = safeInputNits;

    if (EnableEOTFBoost && rawAPL > 1e-6)
    {
        displayAPL = SolveSettledGrayAreaDisplayAPL(safeInputNits, windowFraction);
        remappedSignalNits = ComputeGraphWindowNits(safeInputNits, SceneGainFromLogGain(ComputeSceneLogGainFromAPL(displayAPL)));
    }

    float predictedMeasuredOutputNits = SampleMeasuredOutputNitsFullFieldByMode(mode, remappedSignalNits);
    return float4(remappedSignalNits, predictedMeasuredOutputNits, displayAPL, 1.0);
}

float GraphTableComp2D(int aplIdx, int nitIdx)
{
    return GRAPH_COMP_TABLE_2D[aplIdx * NIT_COUNT + nitIdx];
}

float GetGraphMeasuredMaxInputNits()
{
    return NIT_POINTS[NIT_COUNT - 1];
}

int FindNitIndex(float inputNits)
{
    [loop]
    for (int i = 0; i < NIT_COUNT - 1; ++i)
    {
        if (inputNits < NIT_POINTS[i + 1])
            return i;
    }

    return NIT_COUNT - 2;
}

// The levels were measured at 10-bit PQ input codes, so log compensation interpolates in PQ.
float LookupGraphLogCompForAPLRow2D(int aplIdx, float inputNits)
{
    float clampedNits = clamp(inputNits, NIT_POINTS[0], NIT_POINTS[NIT_COUNT - 1]);
    int n0 = FindNitIndex(clampedNits);
    int n1 = min(n0 + 1, NIT_COUNT - 1);

    return SegmentLerp(
        NitsToPQ(clampedNits),
        NitsToPQ(NIT_POINTS[n0]), log2(GraphTableComp2D(aplIdx, n0)),
        NitsToPQ(NIT_POINTS[n1]), log2(GraphTableComp2D(aplIdx, n1))
    );
}

int FindGraphAPLIndex(float aplPct)
{
    int idx = 0;
    [unroll]
    for (int i = 0; i < GRAPH_APL_COUNT - 1; ++i)
        idx += int(step(GRAPH_APL_POINTS[i + 1], aplPct));
    return min(idx, GRAPH_APL_COUNT - 2);
}

// Log compensation is linear in log APL between rows, as in the live table.
float LookupMeasuredComp2DGraph(float aplPct, float inputNits)
{
    float clampedAPL = clamp(aplPct, GRAPH_APL_POINTS[0], GRAPH_APL_POINTS[GRAPH_APL_COUNT - 1]);
    int a0 = FindGraphAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, GRAPH_APL_COUNT - 1);

    return exp2(SegmentLerp(
        log2(clampedAPL),
        log2(GRAPH_APL_POINTS[a0]), LookupGraphLogCompForAPLRow2D(a0, inputNits),
        log2(GRAPH_APL_POINTS[a1]), LookupGraphLogCompForAPLRow2D(a1, inputNits)
    ));
}

float SampleRealMeasuredOutputNitsForAPL(float aplPct, float targetNits)
{
    float comp = max(LookupMeasuredComp2DGraph(aplPct, targetNits), 1e-6);
    return targetNits / comp;
}

float GetAPLMaxMeasuredNits(float aplPct)
{
    float maxMeasured = 0.0;

    [loop]
    for (int i = 0; i < NIT_COUNT; ++i)
    {
        float targetNits = NIT_POINTS[i];
        maxMeasured = max(maxMeasured, SampleRealMeasuredOutputNitsForAPL(aplPct, targetNits));
    }

    return maxMeasured;
}

float SampleCorrectedOutputNitsForAPL(float aplPct, float boostedTargetNits, float maxMeasuredNits)
{
    float comp = max(LookupMeasuredComp2DGraph(aplPct, boostedTargetNits), 1e-6);
    return min(boostedTargetNits / comp, maxMeasuredNits);
}


float ApplyGraphInputSignalLimitNits(float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);

    if (GraphInputSignalLimitNits > 0.0)
        return min(safeInputNits, GraphInputSignalLimitNits);

    return safeInputNits;
}

float ComputeGraphCurveMeasuredRawOutputNits(bool useFullFieldWindowProjection, int fullFieldWindowMode, float graphRawAPLPercent, float inputNits)
{
    float limitedInputNits = ApplyGraphInputSignalLimitNits(inputNits);

    if (useFullFieldWindowProjection)
        return SampleMeasuredOutputNitsFullFieldByMode(fullFieldWindowMode, limitedInputNits);

    return SampleRealMeasuredOutputNitsForAPL(graphRawAPLPercent, limitedInputNits);
}

// BT.2390 EETF with the standard Hermite shoulder, mapping sourcePeakNits onto targetPeakNits.
float ApplyBT2390EETFToNits(float inputNits, float sourcePeakNits, float targetPeakNits)
{
    if (targetPeakNits <= 0.0)
        return 0.0;

    float safeInputNits = max(inputNits, 0.0);
    float sourcePeakPQ = NitsToPQ(max(sourcePeakNits, 1e-4));
    float maxLum = NitsToPQ(targetPeakNits) / sourcePeakPQ;

    if (maxLum >= 1.0)
        return safeInputNits;

    float kneeStart = 1.5 * maxLum - 0.5;
    float e1 = saturate(NitsToPQ(safeInputNits) / sourcePeakPQ);

    if (e1 <= kneeStart)
        return safeInputNits;

    float t = (e1 - kneeStart) / (1.0 - kneeStart);
    float t2 = t * t;
    float t3 = t2 * t;
    float e2 = (2.0 * t3 - 3.0 * t2 + 1.0) * kneeStart
             + (t3 - 2.0 * t2 + t) * (1.0 - kneeStart)
             + (-2.0 * t3 + 3.0 * t2) * maxLum;

    return PQToLinearBT2100(e2 * sourcePeakPQ) * 10000.0;
}

float GraphAxisCoordinateWithPQMax(float nits, float axisMaxNits, float axisMaxPQ)
{
    float safeNits = max(nits, 0.0);
    float safeAxisMaxNits = max(axisMaxNits, 1.0);

    if (GraphUsePQSpace)
        return NitsToPQ(safeNits) / max(axisMaxPQ, 1e-6);

    return safeNits / safeAxisMaxNits;
}

float GraphNitsFromAxisFraction(float frac, float axisMaxNits, float axisMaxPQ)
{
    float safeAxisMaxNits = max(axisMaxNits, 1e-6);
    float safeFrac = saturate(frac);

    if (!GraphUsePQSpace)
        return safeAxisMaxNits * safeFrac;

    float axisPQ = axisMaxPQ * safeFrac;
    return max(PQToLinearBT2100(axisPQ) * 10000.0, 0.0);
}

float2 ToGraphPointWithPQMax(float2 graphPos, float2 graphSize, float axisMaxNits, float axisMaxPQ, float xNits, float yNits)
{
    float nx = saturate(GraphAxisCoordinateWithPQMax(xNits, axisMaxNits, axisMaxPQ));
    float ny = GraphAxisCoordinateWithPQMax(yNits, axisMaxNits, axisMaxPQ);
    return graphPos + float2(nx * graphSize.x, (1.0 - ny) * graphSize.y);
}

float DistanceToSegment(float2 p, float2 a, float2 b, out float h)
{
    float2 pa = p - a;
    float2 ba = b - a;
    float denom = max(dot(ba, ba), 1e-6);
    h = saturate(dot(pa, ba) / denom);
    return length(pa - ba * h);
}

// h is the position along the segment, 0 at a and 1 at b.
float GraphLineMask(float2 p, float2 a, float2 b, float thickness, out float h)
{
    h = 0.0;

    float pad = thickness * 2.2;
    float2 bbMin = min(a, b) - pad.xx;
    float2 bbMax = max(a, b) + pad.xx;

    if (p.x < bbMin.x || p.x > bbMax.x || p.y < bbMin.y || p.y > bbMax.y)
        return 0.0;

    float d = DistanceToSegment(p, a, b, h);
    return 1.0 - smoothstep(thickness, thickness * 1.8, d);
}

float DrawGraphLine(float2 p, float2 a, float2 b, float thickness)
{
    float h;
    return GraphLineMask(p, a, b, thickness, h);
}

float DrawGraphDashedLine(float2 p, float2 a, float2 b, float thickness, float dashCount)
{
    float h;
    float lineMask = GraphLineMask(p, a, b, thickness, h);
    return lineMask * step(frac(h * dashCount), 0.55);
}

float DrawGraphRect(float2 p, float2 minP, float2 maxP, float thickness)
{
    float inside = step(minP.x, p.x) * step(minP.y, p.y) * step(p.x, maxP.x) * step(p.y, maxP.y);
    float left   = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.x - minP.x));
    float right  = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.x - maxP.x));
    float top    = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.y - minP.y));
    float bottom = 1.0 - smoothstep(thickness, thickness * 1.8, abs(p.y - maxP.y));
    return inside * saturate(left + right + top + bottom);
}

int CountDigitsInt(int value)
{
    int v = max(value, 0);

    if (v >= 10000) return 5;
    if (v >= 1000) return 4;
    if (v >= 100) return 3;
    if (v >= 10) return 2;
    return 1;
}

float DrawNumberRightAligned(float2 texcoord, float2 topRight, float scale, float aspect, int value)
{
    float stepX = (scale * 0.82) / max(aspect, 1e-6);
    return DrawOSDRow5(texcoord, topRight, scale, stepX, aspect, value);
}

float DrawNumberCentered(float2 texcoord, float2 centerTop, float scale, float aspect, int value)
{
    int digits = CountDigitsInt(value);
    float stepX = (scale * 0.82) / max(aspect, 1e-6);
    float totalWidth = stepX * float(max(digits - 1, 0));
    float2 topRight = centerTop + float2(totalWidth * 0.5, 0.0);
    return DrawNumberRightAligned(texcoord, topRight, scale, aspect, value);
}

// Graph rectangle in aspect-scaled screen space: xy = position, zw = size.
float4 GetGraphRect()
{
    return float4(0.055 * ReShade::AspectRatio, 0.48, 0.43 * ReShade::AspectRatio, 0.44);
}

// Overlay colors are clamped on their own so the scene behind the graph keeps its HDR range.
float3 GraphInk(float3 color, float brightnessScale)
{
    return saturate(color * OSDBrightness * brightnessScale);
}

float3 DrawAPLGraphOverlay(float2 texcoord, float3 sceneColor)
{
    float aspect = ReShade::AspectRatio;
    float2 p = texcoord;
    p.x *= aspect;

    float4 graphRect = GetGraphRect();
    float2 graphPos = graphRect.xy;
    float2 graphSize = graphRect.zw;
    float2 graphMin = graphPos;
    float2 graphMax = graphPos + graphSize;

    float thickness = 0.00105;
    float curveThickness = thickness * 0.95;
    float refThickness = thickness * 0.90;
    float gridThickness = 0.00050;
    float tickThickness = 0.00075;
    float labelScale = 0.014;
    float digitStepScaled = labelScale * 0.82;
    float margin = thickness * 5.0;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float graphMaxMeasuredNits = graphParams.g;
    float graphAxisMaxPQ = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;

    float graphXMin = graphMin.x - margin;
    float graphXMax = graphMax.x + margin;

    float xLabelMinX = graphMin.x - labelScale * 2.0;
    float xLabelMaxX = graphMax.x + labelScale * 2.0;
    float xLabelMinY = graphMax.y - margin;
    float xLabelMaxY = graphMax.y + 0.010 + labelScale * 1.25;

    int maxAxisLabelDigits = CountDigitsInt((int)round(graphAxisMaxNits));
    float yLabelAnchorX = graphPos.x - graphSize.x * 0.035;
    float yLabelMinX = yLabelAnchorX - digitStepScaled * (float(maxAxisLabelDigits) + 0.25) - labelScale * 0.35;
    float yLabelMaxX = graphPos.x + margin;
    float yLabelMinY = graphMin.y - labelScale * 0.6;
    float yLabelMaxY = graphMax.y + labelScale * 0.6;

    if (p.x < min(yLabelMinX, xLabelMinX) || p.x > max(graphXMax, xLabelMaxX))
        return sceneColor;

    bool inGraphX = (p.x >= graphXMin && p.x <= graphXMax);

    bool inGraphCore = inGraphX && (p.y >= graphMin.y - margin) && (p.y <= graphMax.y + margin);
    bool inXLabelRegion = (p.x >= xLabelMinX) && (p.x <= xLabelMaxX) && (p.y >= xLabelMinY) && (p.y <= xLabelMaxY);
    bool inYLabelRegion = (p.x >= yLabelMinX) && (p.x <= yLabelMaxX) && (p.y >= yLabelMinY) && (p.y <= yLabelMaxY);

    if (!inGraphCore && !inXLabelRegion && !inYLabelRegion)
        return sceneColor;

    float inside = step(graphMin.x, p.x) * step(graphMin.y, p.y) * step(p.x, graphMax.x) * step(p.y, graphMax.y);

    float frameMask = 0.0;
    float gridMask = 0.0;
    float tickMask = 0.0;
    float labelMask = 0.0;
    float refMask = 0.0;
    float idealPQRefMask = 0.0;
    float measuredMask = 0.0;
    float remappedMask = 0.0;
    float correctedMask = 0.0;

    if (inGraphCore)
    {
        frameMask = DrawGraphRect(p, graphMin, graphMax, thickness);

        [loop]
        for (int i = 0; i < 9; i++)
        {
            float uV = (float(i)     + 0.5) / float(GRAPH_LINE_COUNT);
            float uH = (float(i + 9) + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segV = tex2Dlod(SamplerGraphLines, float4(uV, 0.5, 0.0, 0.0));
            float4 segH = tex2Dlod(SamplerGraphLines, float4(uH, 0.5, 0.0, 0.0));
            gridMask += DrawGraphLine(p, segV.xy, segV.zw, gridThickness) * 0.32;
            gridMask += DrawGraphLine(p, segH.xy, segH.zw, gridThickness) * 0.32;
        }

        [loop]
        for (int i = 0; i < 6; i++)
        {
            float uX = (float(i + 18) + 0.5) / float(GRAPH_LINE_COUNT);
            float uY = (float(i + 24) + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segX = tex2Dlod(SamplerGraphLines, float4(uX, 0.5, 0.0, 0.0));
            float4 segY = tex2Dlod(SamplerGraphLines, float4(uY, 0.5, 0.0, 0.0));
            tickMask += DrawGraphLine(p, segX.xy, segX.zw, tickThickness);
            tickMask += DrawGraphLine(p, segY.xy, segY.zw, tickThickness);
        }

        {
            float uRef = (30.0 + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segRef = tex2Dlod(SamplerGraphLines, float4(uRef, 0.5, 0.0, 0.0));
            refMask = DrawGraphDashedLine(p, segRef.xy, segRef.zw, refThickness, 22.0);
        }
    }

    if (inXLabelRegion || inYLabelRegion)
    {
        [loop]
        for (int i = 0; i < 6; i++)
        {
            float uX = (float(i + 18) + 0.5) / float(GRAPH_LINE_COUNT);
            float uY = (float(i + 24) + 0.5) / float(GRAPH_LINE_COUNT);
            float4 segX = tex2Dlod(SamplerGraphLines, float4(uX, 0.5, 0.0, 0.0));
            float4 segY = tex2Dlod(SamplerGraphLines, float4(uY, 0.5, 0.0, 0.0));
            float2 xTick = segX.zw;
            float2 yTick = segY.xy;

            float tickValue = GraphNitsFromAxisFraction(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
            int tickLabel = (int)round(tickValue);

            if (inXLabelRegion)
            {
                float2 xLabelCenter = float2(xTick.x / max(aspect, 1e-6), graphMax.y + 0.010);
                labelMask += DrawNumberCentered(texcoord, xLabelCenter, labelScale, aspect, tickLabel);
            }

            if (inYLabelRegion)
            {
                float2 yLabelTopRight = float2(yLabelAnchorX / max(aspect, 1e-6), yTick.y - labelScale * 0.52);
                labelMask += DrawNumberRightAligned(texcoord, yLabelTopRight, labelScale, aspect, tickLabel);
            }
        }
    }

    if (inGraphCore)
    {
        float curveX = saturate((p.x - graphMin.x) / max(graphSize.x, 1e-6));
        int centerSegment = clamp(
            int(floor(curveX * float(GRAPH_CURVE_SAMPLES - 1))),
            0,
            GRAPH_CURVE_SAMPLES - 2
        );

        [unroll]
        for (int neighbor = 0; neighbor < 5; ++neighbor)
        {
            int s = clamp(centerSegment + neighbor - 2, 0, GRAPH_CURVE_SAMPLES - 2);
            float u = (float(s) + 0.5) / float(GRAPH_CURVE_SAMPLES);

            float4 remappedSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.125, 0.0, 0.0));
            if (remappedSeg.x >= 0.0)
                remappedMask = max(remappedMask, DrawGraphLine(p, remappedSeg.xy, remappedSeg.zw, curveThickness * 0.95));

            float4 correctedSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.375, 0.0, 0.0));
            if (correctedSeg.x >= 0.0)
                correctedMask = max(correctedMask, DrawGraphLine(p, correctedSeg.xy, correctedSeg.zw, curveThickness));

            float4 measuredSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.625, 0.0, 0.0));
            if (measuredSeg.x >= 0.0)
                measuredMask = max(measuredMask, DrawGraphLine(p, measuredSeg.xy, measuredSeg.zw, curveThickness));

            if (GraphShowBT2390Reference && graphMaxMeasuredNits > 0.0)
            {
                float4 referenceSeg = tex2Dlod(SamplerGraphCurves, float4(u, 0.875, 0.0, 0.0));
                if (referenceSeg.x >= 0.0)
                    idealPQRefMask = max(
                        idealPQRefMask,
                        DrawGraphDashedLine(p, referenceSeg.xy, referenceSeg.zw, refThickness * 0.95, 18.0)
                    );
            }
        }
    }

    float bgMask = inside * 0.12;
    float3 graphColor = sceneColor;
    graphColor = lerp(graphColor, float3(0.0, 0.0, 0.0), bgMask * saturate(GraphOpacity * 0.95));
    graphColor = lerp(graphColor, GraphInk(float3(0.58, 0.58, 0.58), 1.25), saturate(gridMask) * GraphOpacity);
    graphColor = lerp(graphColor, GraphInk(float3(0.90, 0.90, 0.90), 1.45), saturate(tickMask) * GraphOpacity);
    graphColor = lerp(graphColor, GraphInk(float3(1.0, 1.0, 1.0), 1.8), saturate(frameMask) * GraphOpacity);
    graphColor = lerp(graphColor, GraphInk(float3(0.85, 0.85, 0.85), 1.7), saturate(labelMask) * saturate(GraphOpacity + 0.05));
    float measuredMaskSat = saturate(measuredMask);
    float correctedMaskSat = saturate(correctedMask);

    float3 measuredCurveColor = float3(0.62, 0.82, 1.00);
    float3 correctedCurveColor = float3(0.62, 0.62, 0.62);

    graphColor = lerp(graphColor, GraphInk(float3(0.40, 0.65, 1.00), 2.0), saturate(refMask) * GraphOpacity);
    graphColor = lerp(graphColor, GraphInk(float3(1.00, 0.35, 0.92), 2.0), saturate(idealPQRefMask) * saturate(GraphOpacity + 0.02));
    graphColor = lerp(graphColor, GraphInk(measuredCurveColor, 1.95), measuredMaskSat * saturate(GraphOpacity * 0.95));
    graphColor = lerp(graphColor, GraphInk(float3(0.30, 0.88, 0.42), 1.55), saturate(remappedMask) * saturate(GraphOpacity + 0.06));
    graphColor = lerp(graphColor, GraphInk(correctedCurveColor, 1.85), correctedMaskSat * saturate(GraphOpacity + 0.20));

    return graphColor;
}

#endif


float APL_FastPQCodeToNits(float pqCode)
{
    float u = (saturate(pqCode) * (APL_FAST_PQ_NODES - 1) + 0.5) * (1.0 / APL_FAST_PQ_NODES);
    return tex2Dlod(SamplerAPLFastPQNits, float4(u, 0.5, 0.0, 0.0)).r;
}

float3 APL_FastPQToNits(float3 pq)
{
    return float3(
        APL_FastPQCodeToNits(pq.r),
        APL_FastPQCodeToNits(pq.g),
        APL_FastPQCodeToNits(pq.b));
}

int APL_QuantizeNitsQ4(float nits)
{
    return (int)floor(clamp(nits, 0.0, 10000.0) * 4.0 + 0.5);
}

int APL_QuantizeMaxNits2(float nits)
{
    return (int)floor(clamp(nits, 0.0, 10000.0) * 0.5 + 0.5);
}

int APL_HistogramLumaBin64(int lumaQ4)
{
    if (lumaQ4 <= 0) return 0;
    int exponent = firstbithigh(lumaQ4);
    int subBin = (exponent >= 2) ? ((lumaQ4 >> (exponent - 2)) & 3) : 0;
    return min(exponent * 4 + subBin, APL_FFH_LUMA_BINS - 1);
}

int APL_HistogramColorRatioBin(int lumaQ4, int maxQ4)
{
    int safeLumaQ4 = max(lumaQ4, 1);
    int ratioBin = 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 2) ? 1 : 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 4) ? 1 : 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 8) ? 1 : 0;
    return min(ratioBin, APL_FFH_COLOR_RATIO_BINS - 1);
}

void APL_HistogramLumaBinBoundsQ4(int lumaBin, out int lowerQ4, out int upperQ4)
{
    lowerQ4 = 0;
    upperQ4 = 0;

    int exponent = lumaBin >> 2;
    int subBin = lumaBin & 3;

    if (exponent < 2)
    {
        lowerQ4 = (exponent == 0) ? 0 : (1 << exponent);
        upperQ4 = (1 << (exponent + 1)) - 1;
    }
    else
    {
        int stepQ4 = 1 << (exponent - 2);
        lowerQ4 = (1 << exponent) + subBin * stepQ4;
        upperQ4 = lowerQ4 + stepQ4 - 1;
    }

    upperQ4 = min(upperQ4, 40000);
    lowerQ4 = min(lowerQ4, upperQ4);
}

int APL_EncodeWithinBinOffset10(int lumaQ4, int lumaBin)
{
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);

    uint rangeQ4 = uint(upperQ4 - lowerQ4);
    if (rangeQ4 == 0u)
        return 0;

    uint positionQ4 = uint(clamp(lumaQ4, lowerQ4, upperQ4) - lowerQ4);
    uint numerator = positionQ4 * uint(APL_FFH_PACK_OFFSET_SCALE);
    uint offset10 = (numerator + (rangeQ4 >> 1)) / rangeQ4;
    return int(min(offset10, uint(APL_FFH_PACK_OFFSET_SCALE)));
}

float APL_ReconstructMeanLumaQ4(int binIndex, float pixelCount, float offsetSum10)
{
    int lumaBin = binIndex / APL_FFH_COLOR_RATIO_BINS;
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);
    float rangeQ4 = float(upperQ4 - lowerQ4);

    if (pixelCount <= 0.0 || rangeQ4 <= 0.0)
        return float(lowerQ4);

    float meanOffset10 = offsetSum10 / pixelCount;
    return float(lowerQ4) + rangeQ4 * (meanOffset10 / float(APL_FFH_PACK_OFFSET_SCALE));
}

int2 APL_HistogramBlockCoord(int binIndex)
{
    return int2(binIndex % APL_FFH_BLOCK_W, binIndex / APL_FFH_BLOCK_W);
}

int2 APL_RowHistogramCoord(int rowIndex, int binIndex)
{
    int2 binCoord = APL_HistogramBlockCoord(binIndex);
    return int2(binCoord.x, rowIndex * APL_FFH_BLOCK_H + binCoord.y);
}

// Stamps wrap at 2^20 so they stay exact in a float channel.
static const int APL_FRAME_STAMP_MASK = (1 << 20) - 1;

int APL_GetFrameStamp()
{
    return FrameCount & APL_FRAME_STAMP_MASK;
}

// The frame counter keeps running while the effect is disabled.
bool APL_HasSkippedFrames(float storedFrameStamp)
{
    int elapsedFrames = (FrameCount - int(storedFrameStamp)) & APL_FRAME_STAMP_MASK;
    return elapsedFrames > 1;
}

void APL_DecodePackedFullFrameSample(
    int2 pixel,
    out int binIndex,
    out int packedContribution,
    out int maxNits2,
    out int loadQ4,
    out int offsetSq10,
    out int maxQ4,
    out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    maxNits2 = 0;
    loadQ4 = 0;
    offsetSq10 = 0;
    maxQ4 = 0;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 color = tex2Dfetch(ReShade::BackBuffer, pixel).rgb;
    float3 channelNits = 0.0.xxx;
    float sceneNits = 0.0;

    if (IsPQInput())
    {
        channelNits = APL_FastPQToNits(color);
        sceneNits = max(GetLuma2020(channelNits), 0.0);
    }
    else
    {
        channelNits = Rec709ToRec2020(color) * SIGNAL_REFERENCE_NITS;
        sceneNits = max(GetLuma709(color) * SIGNAL_REFERENCE_NITS, 0.0);
    }

    float maxChannelNits = max(Max3(channelNits), 0.0);
    loadQ4 = APL_QuantizeNitsQ4(GetPanelLoadNits(channelNits));

    int lumaQ4 = APL_QuantizeNitsQ4(sceneNits);
    maxQ4 = APL_QuantizeNitsQ4(maxChannelNits);
    int lumaBin = APL_HistogramLumaBin64(lumaQ4);
    binIndex = lumaBin * APL_FFH_COLOR_RATIO_BINS + APL_HistogramColorRatioBin(lumaQ4, maxQ4);

    int offset10 = APL_EncodeWithinBinOffset10(lumaQ4, lumaBin);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    maxNits2 = APL_QuantizeMaxNits2(maxChannelNits);
    offsetSq10 = offset10 * offset10;
    valid = 1;
}

// Skipped passes leave the frame stamp behind, so resuming drops the stale load.
bool IsAPLAnalysisActive()
{
    return EnableEOTFBoost || ShowOSD;
}

groupshared int APL_TilePackedCountLuma[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxNits[APL_FFH_MAX_BINS];
groupshared int APL_TileLoad[APL_FFH_MAX_BINS];
groupshared int APL_TileOffsetSq[APL_FFH_MAX_BINS];
groupshared int APL_TileTop;

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int maxNits2, int loadQ4, int offsetSq10, int valid)
{
    if (valid == 0)
        return;

    atomicAdd(APL_TilePackedCountLuma[binIndex], packedContribution);
    atomicAdd(APL_TileMaxNits[binIndex], maxNits2);
    atomicAdd(APL_TileLoad[binIndex], loadQ4);
    atomicAdd(APL_TileOffsetSq[binIndex], offsetSq10);
}


[shader("compute")]
// Pass 1: build the PQ decode table, copy the last frame's solve, and clear the row histograms.
void CS_SetupAndClearAPLFullFrameRowHistograms(uint3 threadID : SV_GroupThreadID)
{
    if (!IsAPLAnalysisActive())
        return;

    int localIndex = int(threadID.x);

    [loop]
    for (int node = localIndex; node < APL_FAST_PQ_NODES; node += APL_SETUP_THREADS)
    {
        float pqCode = float(node) / (APL_FAST_PQ_NODES - 1);
        tex2Dstore(StorageAPLFastPQNits, int2(node, 0), PQToLinearBT2100(pqCode) * 10000.0);
    }

    if (localIndex == 0)
    {
        float4 instantData = tex2Dfetch(SamplerAPLInstant, int2(0, 0));

        // Over skipped frames the panel showed the frames unboosted, so the stored load is stale.
        if (APL_HasSkippedFrames(instantData.a))
            instantData.z = 0.0;

        tex2Dstore(StorageAPLPrev, int2(0, 0), instantData);
        tex2Dstore(StorageAPLPrev, int2(1, 0), tex2Dfetch(SamplerAPLInstant, int2(1, 0)));
        tex2Dstore(StorageAPLFrameTop, int2(0, 0), 0);
    }

    [loop]
    for (int entry = localIndex; entry < APL_FFH_TILE_COUNT_Y * APL_FFH_MAX_BINS; entry += APL_SETUP_THREADS)
    {
        int rowIndex = entry / APL_FFH_MAX_BINS;
        int binIndex = entry - rowIndex * APL_FFH_MAX_BINS;
        int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
        tex2Dstore(StorageAPLRowHistCount, coord, 0);
        tex2Dstore(StorageAPLRowHistOffset10, coord, 0);
        tex2Dstore(StorageAPLRowHistMaxNits, coord, 0);
        tex2Dstore(StorageAPLRowHistLoad, coord, 0);
        tex2Dstore(StorageAPLRowHistOffsetSq, coord, 0);
    }
}

[shader("compute")]
// Pass 2: decode source pixels and accumulate row histograms.
void CS_BuildAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    if (!IsAPLAnalysisActive())
        return;

    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;

    if (localIndex < APL_FFH_MAX_BINS)
    {
        APL_TilePackedCountLuma[localIndex] = 0;
        APL_TileMaxNits[localIndex] = 0;
        APL_TileLoad[localIndex] = 0;
        APL_TileOffsetSq[localIndex] = 0;
    }
    if (localIndex == 0)
        APL_TileTop = 0;
    barrier();

    int row = int(groupID.y);
    int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, row * APL_FFH_TILE_SIZE) + int2(threadID.xy) * int2(APL_FFH_PIXELS_X, APL_FFH_PIXELS_Y);

    int b0, p0, m0, w0, q0, t0, v0;
    int b1, p1, m1, w1, q1, t1, v1;
    int b2, p2, m2, w2, q2, t2, v2;
    int b3, p3, m3, w3, q3, t3, v3;
    APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), b0, p0, m0, w0, q0, t0, v0);
    APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), b1, p1, m1, w1, q1, t1, v1);
    APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), b2, p2, m2, w2, q2, t2, v2);
    APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), b3, p3, m3, w3, q3, t3, v3);
    atomicMax(APL_TileTop, max(max(t0, t1), max(t2, t3)));

    if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; m0 += m1; w0 += w1; q0 += q1; v1 = 0; }
    if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; m0 += m2; w0 += w2; q0 += q2; v2 = 0; }
    if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; m1 += m2; w1 += w2; q1 += q2; v2 = 0; }
    if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; m0 += m3; w0 += w3; q0 += q3; v3 = 0; }
    if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; m1 += m3; w1 += w3; q1 += q3; v3 = 0; }
    if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; m2 += m3; w2 += w3; q2 += q3; v3 = 0; }

    APL_AtomicAddMergedTileSample(b0, p0, m0, w0, q0, v0);
    APL_AtomicAddMergedTileSample(b1, p1, m1, w1, q1, v1);
    APL_AtomicAddMergedTileSample(b2, p2, m2, w2, q2, v2);
    APL_AtomicAddMergedTileSample(b3, p3, m3, w3, q3, v3);
    barrier();

    if (localIndex == 0)
        atomicMax(StorageAPLFrameTop, int2(0, 0), APL_TileTop);

    if (localIndex < APL_FFH_MAX_BINS)
    {
        int packedValue = APL_TilePackedCountLuma[localIndex];
        int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
        if (count > 0)
        {
            int offsetSum10 = packedValue & APL_FFH_PACK_OFFSET_MASK;
            int2 rowCoord = APL_RowHistogramCoord(row, int(localIndex));
            atomicAdd(StorageAPLRowHistCount, rowCoord, count);
            atomicAdd(StorageAPLRowHistOffset10, rowCoord, offsetSum10);
            atomicAdd(StorageAPLRowHistMaxNits, rowCoord, APL_TileMaxNits[localIndex]);

            // Rows take whole nits so a row of 10000 nit pixels still fits an int.
            atomicAdd(StorageAPLRowHistLoad, rowCoord, (APL_TileLoad[localIndex] + 2) >> 2);

            atomicAdd(StorageAPLRowHistOffsetSq, rowCoord, (APL_TileOffsetSq[localIndex] + APL_FFH_ROW_OFFSET_SQ_UNIT / 2) / APL_FFH_ROW_OFFSET_SQ_UNIT);
        }
    }
}

groupshared int APL_ReduceCount[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffset10[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceMaxNits[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceLoad[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffsetSq[APL_FFH_REDUCE_THREADS];

#define APL_REDUCE_ROW_STAGE(S) \
    if (localIndex < S) { \
        APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + S]; \
        APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + S]; \
        APL_ReduceMaxNits[localIndex] += APL_ReduceMaxNits[localIndex + S]; \
        APL_ReduceLoad[localIndex] += APL_ReduceLoad[localIndex + S]; \
        APL_ReduceOffsetSq[localIndex] += APL_ReduceOffsetSq[localIndex + S]; \
    } \
    barrier();

[shader("compute")]
// Pass 3: reduce the row histograms into one global histogram.
void CS_ReduceAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    if (!IsAPLAnalysisActive())
        return;

    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;

    int countSum = 0;
    float offsetSum10 = 0.0;
    float maxSumNits = 0.0;
    float loadSumNits = 0.0;
    float offsetSqSum = 0.0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
    {
        int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
        countSum += tex2Dfetch(SamplerAPLRowHistCount, sourceCoord);
        offsetSum10 += float(tex2Dfetch(SamplerAPLRowHistOffset10, sourceCoord));
        maxSumNits += float(tex2Dfetch(SamplerAPLRowHistMaxNits, sourceCoord));
        loadSumNits += float(tex2Dfetch(SamplerAPLRowHistLoad, sourceCoord));
        offsetSqSum += float(tex2Dfetch(SamplerAPLRowHistOffsetSq, sourceCoord));
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceMaxNits[localIndex] = maxSumNits;
    APL_ReduceLoad[localIndex] = loadSumNits;
    APL_ReduceOffsetSq[localIndex] = offsetSqSum;
    barrier();

    APL_REDUCE_ROW_STAGE(32)
    APL_REDUCE_ROW_STAGE(16)
    APL_REDUCE_ROW_STAGE(8)
    APL_REDUCE_ROW_STAGE(4)
    APL_REDUCE_ROW_STAGE(2)
    APL_REDUCE_ROW_STAGE(1)

    if (localIndex == 0)
    {
        tex2Dstore(StorageAPLGlobalHistCount, localBinCoord, APL_ReduceCount[0]);
        tex2Dstore(StorageAPLGlobalHistOffset10, localBinCoord, APL_ReduceOffset10[0]);
        tex2Dstore(StorageAPLGlobalHistMaxNits, localBinCoord, APL_ReduceMaxNits[0]);
        tex2Dstore(StorageAPLGlobalHistLoad, localBinCoord, APL_ReduceLoad[0]);
        tex2Dstore(StorageAPLGlobalHistOffsetSq, localBinCoord, APL_ReduceOffsetSq[0]);
    }
}

#undef APL_REDUCE_ROW_STAGE

// Each thread's APL metric times its pixel count and the pixel count, or its part of a curve sum.
groupshared float2 APL_EvalSums[APL_EVAL_THREADS];
groupshared float4 APL_EvalBoostParams[2];

// The sums and maxima over APL_EvalSums gather a strided slice of it on each of the first threads and combine the
// slices on the first, three barriers where halving the entries in place takes one per halving. 32 slices timed
// fastest.
#define APL_REDUCE_SLICES 32
groupshared float2 APL_ReduceSlices[APL_REDUCE_SLICES];
groupshared float2 APL_ReduceTotal;

// Full-gain PQ span and screen share of each bin that reaches above the knee.
groupshared float4 APL_CurveBinSpans[APL_FFH_MAX_BINS];

// The bins that hold pixels sit at the front of APL_CurveBinSpans, so the gathers walk only those.
groupshared int APL_LitBinCount;

// Each curve cell's screen share and the output PQ codes at the cell edges.
groupshared float APL_CurveShare[BOOST_CURVE_CELLS];
groupshared float APL_CurveNodes[BOOST_CURVE_CELLS + 1];

// The frame's brightest channels on equal PQ cells from black to its top, each cell's screen share and the weight of
// its shift in the frame's cost.
groupshared float APL_CostShare[BOOST_CURVE_CELLS];
groupshared float APL_CostWeight[BOOST_CURVE_CELLS];

// Log gain and cost of each fit of the gain, in the order the fits run.
groupshared float2 APL_GainCosts[BOOST_GAIN_FITS];

// Sums every thread's APL_EvalSums entry and hands the total to every thread.
float2 APL_SumEvalSums(int localIndex)
{
    barrier();

    if (localIndex < APL_REDUCE_SLICES)
    {
        float2 slice = 0.0;

        [loop]
        for (int entry = localIndex; entry < APL_EVAL_THREADS; entry += APL_REDUCE_SLICES)
            slice += APL_EvalSums[entry];

        APL_ReduceSlices[localIndex] = slice;
    }
    barrier();

    if (localIndex == 0)
    {
        float2 total = 0.0;

        [loop]
        for (int i = 0; i < APL_REDUCE_SLICES; ++i)
            total += APL_ReduceSlices[i];

        APL_ReduceTotal = total;
    }
    barrier();

    return APL_ReduceTotal;
}

float2 APL_MaxEvalSums(int localIndex)
{
    barrier();

    if (localIndex < APL_REDUCE_SLICES)
    {
        float2 slice = APL_EvalSums[localIndex];

        [loop]
        for (int entry = localIndex + APL_REDUCE_SLICES; entry < APL_EVAL_THREADS; entry += APL_REDUCE_SLICES)
            slice = max(slice, APL_EvalSums[entry]);

        APL_ReduceSlices[localIndex] = slice;
    }
    barrier();

    if (localIndex == 0)
    {
        float2 total = APL_ReduceSlices[0];

        [loop]
        for (int i = 1; i < APL_REDUCE_SLICES; ++i)
            total = max(total, APL_ReduceSlices[i]);

        APL_ReduceTotal = total;
    }
    barrier();

    return APL_ReduceTotal;
}

// Sum of the APL_EvalSums entries from the first through slot, the entry each thread wrote, handed to that thread.
float2 APL_RunningEvalSums(int slot)
{
    barrier();

    [unroll]
    for (int stride = 1; stride < APL_EVAL_THREADS; stride *= 2)
    {
        float2 lower = (slot >= stride) ? APL_EvalSums[slot - stride] : 0.0;
        barrier();
        APL_EvalSums[slot] += lower;
        barrier();
    }

    float2 total = APL_EvalSums[slot];
    barrier();
    return total;
}

float APL_AverageFromSums(float2 sums)
{
    return (sums.y > 0.0) ? saturate(sums.x / sums.y) : 0.0;
}

// Brightest-channel span of a bin in nits, uniform with the bin's mean and spread and inside its luma bounds.
float2 APL_BinMaxChannelSpan(int binIndex, float pixelCount, float offsetSum10, float offsetSqSum10, float lumaNits, float maxChannelNits)
{
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLumaBinBoundsQ4(binIndex / APL_FFH_COLOR_RATIO_BINS, lowerQ4, upperQ4);

    float offsetToNits = float(upperQ4 - lowerQ4) / APL_FFH_PACK_OFFSET_SCALE * 0.25;
    float meanOffset10 = offsetSum10 / pixelCount;
    float spreadNits = sqrt(max(offsetSqSum10 / pixelCount - meanOffset10 * meanOffset10, 0.0)) * offsetToNits;

    float halfWidthNits = sqrt(3.0) * spreadNits;
    float lowerNits = max(lumaNits - halfWidthNits, lowerQ4 * 0.25);
    float upperNits = min(lumaNits + halfWidthNits, upperQ4 * 0.25);
    return float2(lowerNits, upperNits) * (maxChannelNits / max(lumaNits, 1e-6));
}

// A bin's PQ span and screen share, with its share per PQ width, which is 0 for a bin with no width.
float4 APL_BinSpan(float lowerU, float upperU, float screenShare)
{
    float width = upperU - lowerU;
    return float4(lowerU, upperU, screenShare, (width < 1e-6) ? 0.0 : screenShare / width);
}

float4 APL_BinCurveSpan(float2 maxChannelSpan, float screenShare, BoostCurve curve)
{
    float topU = FullGainPQ(maxChannelSpan.y, curve);

    if (topU <= curve.kneeU)
        return 0.0;

    return APL_BinSpan(FullGainPQ(maxChannelSpan.x, curve), topU, screenShare);
}

// The frame's brightest channel, raised past the rounding and the histogram's PQ decode table.
float APL_FrameTopNits()
{
    return min((float(tex2Dfetch(SamplerAPLFrameTop, int2(0, 0))) + 1.5) * 0.25, 10000.0);
}

float CurveCellCenterU(int cell, BoostCurve curve)
{
    return CurveNodeU(cell, curve) + 0.5 * CurveCellWidth(curve);
}

// Steepest slope a cell may keep. Content the panel can show may stay exact, and content above the panel peak
// keeps at most the highlight contrast.
float CurveCellCap(int cell, BoostCurve curve)
{
    float overPeak = saturate((CurveCellCenterU(cell, curve) - curve.peakPQ) / KNEE_TRANSITION_PQ);
    return 1.0 - (1.0 - HIGHLIGHT_CONTRAST) * overPeak;
}

// Flattest slope a cell may take, the fixed shoulder's, so the curve never merges two levels.
float CurveCellFloor(int cell, BoostCurve curve)
{
    float overKnee = saturate((CurveCellCenterU(cell, curve) - curve.kneeU) / KNEE_TRANSITION_PQ);
    return 1.0 - (1.0 - HIGHLIGHT_CONTRAST) * overKnee;
}

// Length of a cell below the top of the content.
float CurveCellLength(int cell, int top, float topU, BoostCurve curve)
{
    if (cell < top)
        return CurveCellWidth(curve);

    if (cell == top)
        return topU - CurveNodeU(top, curve);

    return 0.0;
}

// Screen share of the content inside a cell of equal PQ cells from originU, each bin spread evenly in PQ over its
// span in APL_CurveBinSpans. A bin with no width counts in the cell holding it.
float APL_GatherCellShare(int cell, float originU, float width)
{
    float lowerU = originU + cell * width;
    float upperU = lowerU + width;
    float share = 0.0;

    [loop]
    for (int bin = 0; bin < APL_LitBinCount; ++bin)
    {
        float4 span = APL_CurveBinSpans[bin];

        if (span.z <= 0.0)
            continue;

        if (span.w <= 0.0)
        {
            if (min(int((span.y - originU) / width), BOOST_CURVE_CELLS - 1) == cell)
                share += span.z;
        }
        else
        {
            share += span.w * max(min(upperU, span.y) - max(lowerU, span.x), 0.0);
        }
    }

    return share;
}

// Screen share per PQ width over half the knee transition either side of the cell's middle, inside the curve's range
// and empty cells included, so slopes change smoothly and a level's weight grows from nothing with its share.
float APL_SmoothedCellDensity(int cell, BoostCurve curve)
{
    float width = CurveCellWidth(curve);
    float reach = 0.5 * KNEE_TRANSITION_PQ / width;
    float lower = max(cell + 0.5 - reach, 0.0);
    float upper = min(cell + 0.5 + reach, float(BOOST_CURVE_CELLS));
    int last = min(int(ceil(upper)), BOOST_CURVE_CELLS) - 1;
    float shareSum = 0.0;

    [loop]
    for (int i = int(lower); i <= last; ++i)
        shareSum += APL_CurveShare[i] * (min(upper, i + 1.0) - max(lower, float(i)));

    return shareSum / ((upper - lower) * width);
}

// What each PQ step a cell gives up costs the frame. Every pixel above the cell's middle shifts down by the step, and
// its contrast against every pixel below grows by it, once for each order of the pair.
float APL_CellWeight(int cell, float share)
{
    int fromTop = BOOST_CURVE_CELLS - 1 - cell;
    APL_EvalSums[fromTop] = float2(share, 0.0);
    float above = APL_RunningEvalSums(fromTop).x - 0.5 * share;
    return above + 2.0 * above * (1.0 - above);
}

// Slope that costs the frame the least, with mu what each PQ step of room is worth. Flattening a cell costs its
// pixels DETAIL_PQ times the log of the contrast they lose, and keeping it costs the cell's weight.
float APL_CellSlope(int cell, float mu, float weight, float density, BoostCurve curve)
{
    float slope = CurveCellCap(cell, curve);

    if (mu > weight)
        slope = clamp(DETAIL_PQ * density / (mu - weight), CurveCellFloor(cell, curve), slope);

    return slope;
}

// Levels whose slope still changes inside the last bracket of the price give up the room left above the panel peak,
// from the top down to their slope at the bracket's high end, which moves only what sits above them. Returns the room
// the cell gives up.
float APL_LeftoverGiven(int cell, float excess, float slope, float slopeAtMuHi, float length)
{
    float room = length * (slope - slopeAtMuHi);

    int fromTop = BOOST_CURVE_CELLS - 1 - cell;
    APL_EvalSums[fromTop] = float2(room, 0.0);
    float roomAbove = APL_RunningEvalSums(fromTop).x - room;
    return clamp(excess - roomAbove, 0.0, room);
}

// Output PQ codes at the cell edges, never under the fixed shoulder. The top cell keeps its slope across the whole
// cell, so the top of the content lands on the panel peak. Returns where the output leaves the exact levels, the
// bottom of the first cell that flattens, or the bottom when the gain sits under the compensation.
float APL_IntegrateCurveNodes(int cell, float slope, int top, BoostCurve curve)
{
    if (cell > top)
        slope = 0.0;

    APL_EvalSums[cell] = float2((1.0 - slope) * CurveCellWidth(curve), 0.0);
    float cut = APL_RunningEvalSums(cell).x;
    float u = CurveNodeU(cell + 1, curve);
    APL_CurveNodes[cell + 1] = max(u - cut, u - ShoulderCompressionPQ(u, curve.kneeU));

    if (cell == 0)
        APL_CurveNodes[0] = curve.kneeU;

    bool flattens = slope < 1.0;
    APL_EvalSums[cell] = flattens ? float2(-CurveNodeU(cell, curve), 1.0) : float2(-curve.maxU, 0.0);
    float2 lowestFlat = APL_MaxEvalSums(cell);
    float departureU = (lowestFlat.y > 0.0) ? -lowestFlat.x : curve.peakPQ;

    return (curve.gain < curve.comp) ? 0.0 : departureU;
}

// Fits the curve to the frame with one thread per cell, landing the brightest pixel at topU on the panel peak.
// Leaves the output PQ codes in APL_CurveNodes and where the curve leaves the full gain in APL_EvalBoostParams.
void APL_FitBoostCurve(int cell, float topU, BoostCurve curve)
{
    float share = APL_GatherCellShare(cell, curve.kneeU, CurveCellWidth(curve));
    APL_CurveShare[cell] = share;
    barrier();

    float density = APL_SmoothedCellDensity(cell, curve);
    float weight = APL_CellWeight(cell, share);

    // Nothing needs the room above the panel peak, so every level stays exact.
    bool fits = topU <= curve.peakPQ;

    int top = BOOST_CURVE_CELLS - 1;
    if (!fits)
    {
        float fraction;
        top = CurveCell(topU, curve, fraction);
    }

    float length = fits ? 0.0 : CurveCellLength(cell, top, topU, curve);

    // At the top price every cell sits on the fixed shoulder.
    APL_EvalSums[cell] = float2(weight + DETAIL_PQ * density / CurveCellFloor(cell, curve), 0.0);
    float muLo = 0.0;
    float muHi = APL_MaxEvalSums(cell).x;

    // Each step prices two values of mu at once, one in each lane of the sum, and keeps the third of the bracket where
    // the rise meets the panel peak. The solve runs every frame, since barriers cannot sit inside a branch on the
    // frame's content.
    [loop]
    for (int step = 0; step < BOOST_CURVE_SOLVE_STEPS; ++step)
    {
        float2 mu = muLo + (muHi - muLo) * float2(1.0, 2.0) / 3.0;
        APL_EvalSums[cell] = float2(APL_CellSlope(cell, mu.x, weight, density, curve), APL_CellSlope(cell, mu.y, weight, density, curve)) * length;
        float2 rise = APL_SumEvalSums(cell);

        if (curve.kneeU + rise.y > curve.peakPQ)
        {
            muLo = mu.y;
        }
        else if (curve.kneeU + rise.x > curve.peakPQ)
        {
            muLo = mu.x;
            muHi = mu.y;
        }
        else
        {
            muHi = mu.x;
        }
    }

    float slope = fits ? 1.0 : APL_CellSlope(cell, muLo, weight, density, curve);
    APL_EvalSums[cell] = float2(slope * length, 0.0);
    float excess = curve.kneeU + APL_SumEvalSums(cell).x - curve.peakPQ;

    float slopeAtMuHi = fits ? 1.0 : APL_CellSlope(cell, muHi, weight, density, curve);
    float given = APL_LeftoverGiven(cell, excess, slope, slopeAtMuHi, length);
    if (given > 0.0)
        slope -= given / length;

    float departureU = APL_IntegrateCurveNodes(cell, slope, top, curve);
    if (cell == 0)
        APL_EvalBoostParams[1].y = departureU;
    barrier();
}

float APL_CurvePQ(float u, BoostCurve curve)
{
    if (u <= curve.kneeU)
        return u;

    float fraction;
    int cell = CurveCell(u, curve, fraction);
    return min(lerp(APL_CurveNodes[cell], APL_CurveNodes[cell + 1], fraction), curve.peakPQ);
}

float APL_BinBoostScale(float lumaNits, float maxChannelNits, BoostCurve curve)
{
    float lumaY = APL_CurvePQ(FullGainPQ(lumaNits, curve), curve);
    float maxChannelY = APL_CurvePQ(FullGainPQ(maxChannelNits, curve), curve);
    return CurveBoostScale(lumaNits, lumaY, maxChannelNits, maxChannelY, curve);
}

// A histogram bin as its thread holds it, with its slot among the bins that hold pixels, or -1 when it holds none.
struct SolveBin
{
    float share;
    float2 maxChannelSpan;
    int slot;
};

int APL_LitBinSlot(int localIndex, float pixelCount)
{
    bool lit = pixelCount > 0.0;
    APL_EvalSums[localIndex] = float2(lit ? 1.0 : 0.0, 0.0);
    int litThrough = int(APL_RunningEvalSums(localIndex).x);

    if (localIndex == APL_EVAL_THREADS - 1)
        APL_LitBinCount = litThrough;

    return lit ? litThrough - 1 : -1;
}

// Spreads the frame's brightest channels over equal PQ cells from black to the frame's top, each bin evenly in PQ
// over its span, and weighs each cell's shift. A shift counts once for the cell's own pixels and, with shifts rising
// with the level, once for each order of every pair they form, so plus against the pixels below and minus against
// those above. Returns the cell width.
float APL_BuildCostGrid(int localIndex, SolveBin bin)
{
    float topNits = APL_FrameTopNits();
    float width = NitsToPQ(topNits) / BOOST_CURVE_CELLS;

    if (bin.slot >= 0)
        APL_CurveBinSpans[bin.slot] = APL_BinSpan(NitsToPQ(min(bin.maxChannelSpan.x, topNits)), NitsToPQ(min(bin.maxChannelSpan.y, topNits)), bin.share);
    barrier();

    float cellShare = APL_GatherCellShare(localIndex, 0.0, width);
    APL_EvalSums[localIndex] = float2(cellShare, 0.0);
    float below = APL_RunningEvalSums(localIndex).x - cellShare;

    APL_CostShare[localIndex] = cellShare;
    APL_CostWeight[localIndex] = 1.0 + 2.0 * (below - (1.0 - below - cellShare));
    return width;
}

// Integrals over one step of log gain of exp(-cost) and of log gain times it, with the cost in half codes over the
// least running linearly from c0 to c1 across the width w from x0. Both exponentials stay at or under 1.
float2 APL_SoftStep(float x0, float w, float c0, float c1)
{
    float rise = c1 - c0;
    float e0 = exp(-c0);

    if (abs(rise) < 0.05)
    {
        float mass = 1.0 - rise / 2.0 + rise * rise / 6.0;
        return w * e0 * float2(mass, x0 * mass + w * (0.5 - rise / 3.0 + rise * rise / 8.0));
    }

    float e1 = exp(-c1);
    float mass = (e0 - e1) / rise;
    return w * float2(mass, x0 * mass + w * (mass - e1) / rise);
}

// The log gain the first count fits give, the average log gain over the table's range weighed by exp(-cost), with the
// cost in half codes over the least and running linearly from each fit to the next one up. Every thread reads the fits
// in place and works out the same gain, so the solve needs no branch on the thread around its barriers. The loops run
// over every slot and skip the ones not yet filled, so their bounds stay fixed.
float APL_SoftLogGain(int count)
{
    float least = APL_GainCosts[0].y;
    [loop]
    for (int k = 1; k < BOOST_GAIN_FITS; ++k)
    {
        if (k < count)
            least = min(least, APL_GainCosts[k].y);
    }

    float2 sums = 0.0;
    [loop]
    for (int i = 0; i < BOOST_GAIN_FITS; ++i)
    {
        float2 lower = APL_GainCosts[i];
        float2 upper = lower;
        bool first = i < count;
        bool hasUpper = false;

        // A fit that repeats an earlier one's log gain adds nothing, so only the first of them starts a step.
        [loop]
        for (int j = 0; j < BOOST_GAIN_FITS; ++j)
        {
            float2 other = APL_GainCosts[j];
            bool nearer = j < count && other.x > lower.x && (!hasUpper || other.x < upper.x);
            first = first && !(j < i && other.x == lower.x);
            upper = nearer ? other : upper;
            hasUpper = hasUpper || nearer;
        }

        if (first && hasUpper)
            sums += APL_SoftStep(lower.x, upper.x - lower.x, lower.y - least, upper.y - least);
    }

    return sums.y / sums.x;
}

// What the curve costs the pixels of one cost cell against the exact levels, less the part only the exact levels make.
// They pay their PQ shift at the cell's weight and DETAIL_PQ times the log of the fine contrast they lose across the
// cell. The exact levels add the same to every gain, so the gain that costs the least is the same whatever the
// compensation, and float rounding cannot move it from frame to frame while the compensation settles.
float APL_GainCostCellTerm(int cell, float width, BoostCurve curve)
{
    float share = APL_CostShare[cell];

    if (share <= 0.0)
        return 0.0;

    float shownLower = APL_CurvePQ(FullGainPQ(PQToLinearBT2100(cell * width) * 10000.0, curve), curve);
    float shownUpper = APL_CurvePQ(FullGainPQ(PQToLinearBT2100((cell + 1) * width) * 10000.0, curve), curve);
    return -share * (APL_CostWeight[cell] * 0.5 * (shownLower + shownUpper) + DETAIL_PQ * log(shownUpper - shownLower));
}

// Fits the curve at a gain and returns what it costs the frame, less the part only the exact levels make. Leaves the
// curve in APL_CurveNodes and APL_EvalBoostParams.
float APL_FitAndCost(int localIndex, float gain, float comp, float costWidth, SolveBin bin)
{
    BoostCurve curve = MakeBoostCurve(gain, comp);

    if (localIndex == 0)
    {
        APL_EvalBoostParams[0] = PackBoostCurve(curve, 0);
        APL_EvalBoostParams[1] = PackBoostCurve(curve, 1);
    }
    if (bin.slot >= 0)
        APL_CurveBinSpans[bin.slot] = APL_BinCurveSpan(bin.maxChannelSpan, bin.share, curve);
    barrier();

    APL_FitBoostCurve(localIndex, FullGainPQ(APL_FrameTopNits(), curve), curve);

    APL_EvalSums[localIndex] = float2(APL_GainCostCellTerm(localIndex, costWidth, curve), 0.0);
    return APL_SumEvalSums(localIndex).x;
}

// The APL a frame shows through the curve the last fit left. The gain is known before the frame shows, so its load is
// measured through its own curve.
float APL_ShownAPL(int localIndex, float pixelCount, float sceneNits, float maxChannelNits, float loadNits)
{
    BoostCurve curve = UnpackBoostCurve(APL_EvalBoostParams[0], APL_EvalBoostParams[1]);

    float boostScale = 1.0;
    if (sceneNits > 1e-6)
        boostScale = APL_BinBoostScale(sceneNits, maxChannelNits, curve);

    APL_EvalSums[localIndex] = float2(saturate(loadNits * boostScale / max(APLReferenceWhiteNits, 1.0)), 1.0) * pixelCount;
    return APL_AverageFromSums(APL_SumEvalSums(localIndex));
}

[shader("compute")]
// Pass 4: measure the raw APL, pick the gain, fit the boost curve to the frame, and measure the APL it shows.
void CS_EvaluateAndSolveAPLFullFrameHistogram(uint3 threadID : SV_GroupThreadID)
{
    if (!IsAPLAnalysisActive())
        return;

    int localIndex = int(threadID.x);

    float pixelCount = 0.0;
    float sceneNits = 0.0;
    float maxChannelNits = 0.0;
    float loadNits = 0.0;
    float2 maxChannelSpan = 0.0;

    if (localIndex < APL_FFH_MAX_BINS)
    {
        int2 binCoord = APL_HistogramBlockCoord(localIndex);
        int pixelCountI = tex2Dfetch(SamplerAPLGlobalHistCount, binCoord);
        if (pixelCountI > 0)
        {
            pixelCount = float(pixelCountI);
            float offsetSum10 = tex2Dfetch(SamplerAPLGlobalHistOffset10, binCoord);
            float meanLumaQ4 = APL_ReconstructMeanLumaQ4(localIndex, pixelCount, offsetSum10);
            sceneNits = max(meanLumaQ4 * 0.25, 0.0);
            float maxSumNits = tex2Dfetch(SamplerAPLGlobalHistMaxNits, binCoord);
            maxChannelNits = max((maxSumNits / pixelCount) * 2.0, sceneNits);
            loadNits = tex2Dfetch(SamplerAPLGlobalHistLoad, binCoord) / pixelCount;

            float offsetSqSum10 = tex2Dfetch(SamplerAPLGlobalHistOffsetSq, binCoord) * APL_FFH_ROW_OFFSET_SQ_UNIT;
            maxChannelSpan = APL_BinMaxChannelSpan(localIndex, pixelCount, offsetSum10, offsetSqSum10, sceneNits, maxChannelNits);
        }
    }

    APL_EvalSums[localIndex] = float2(saturate(loadNits / max(APLReferenceWhiteNits, 1.0)), 1.0) * pixelCount;
    float2 rawSums = APL_SumEvalSums(localIndex);

    SolveBin bin;
    bin.share = pixelCount / rawSums.y;
    bin.maxChannelSpan = maxChannelSpan;
    bin.slot = APL_LitBinSlot(localIndex, pixelCount);

    // The panel dims each frame for the load of the frame before it, the last one it has fully received. The track
    // follows that without smoothing. Each frame it takes the compensation for its last load, finds its gain under it
    // and measures the load the frame shows through the curve that gives, so it lands where the compensation stops
    // moving. It holds that load under the APL whose compensation is the last frame's best gain, so a lowering that
    // lets go starts the track from the gain it showed. The shown gain eases toward the track's gain over the smoothing
    // time in log gain, so one smoothing time covers the same share of a brightness change up or down, and a change of
    // content moves the gain one way. While the game presents nothing new the panel keeps showing that frame, so its
    // load still holds. Without history the panel last showed the frame unboosted.
    float4 lastFrame = tex2Dfetch(SamplerAPLPrev, int2(0, 0));
    float3 lastTrack = tex2Dfetch(SamplerAPLPrev, int2(1, 0)).xyz;
    bool hasHistory = lastFrame.z > 0.0;
    float lastLoad = hasHistory ? lastTrack.x : APL_AverageFromSums(rawSums);
    float trackAPL = hasHistory ? min(lastLoad, lastTrack.z) : lastLoad;
    float trackComp = SceneGainFromLogGain(ComputeSceneLogGainFromAPL(trackAPL));
    float costWidth = APL_BuildCostGrid(localIndex, bin);

    // The frame's gain averages the log gains the cost cannot tell apart, each weighed by exp(-d) for a cost d half
    // 10-bit codes over the least, and is held under the compensation. A flat or bumpy cost moves it smoothly with the
    // frame. A cost that falls all the way to the table's top compensation puts it under the top by one over the cost's
    // slope there, 0.5 to 1% on recorded game frames, so a frame that fits keeps its compensation unless it is near
    // full white. The cost runs linearly between fits on an even grid of log gains and fits either side of the gain
    // the fits before them give, which move smoothly with the frame too. Every fit runs every frame, since barriers
    // cannot sit inside a branch on the frame's content.
    const int trackFit = BOOST_GAIN_FITS;
    const int finalFit = trackFit + 1;
    const float topLog = APL_ANCHORS[APL_ANCHOR_COUNT - 1].y;
    const float gridStep = topLog / (BOOST_GAIN_GRID_POINTS - 1);
    float frameLogGain = 0.0;
    float trackGain = trackComp;
    float trackLoad = 0.0;
    float bestAPL = 1.0;
    float easedAPL = 0.0;
    float shownGain = 0.0;
    float shownComp = 0.0;

    // Every fit runs from this one call site, so the shader holds one copy of the fit, which runs faster than four. The
    // grid's fits come first, then two for each pass. The track's fit then measures the load the track's gain gives,
    // and the last fit leaves the shown curve at the eased gain.
    [loop]
    for (int fit = 0; fit <= finalFit; ++fit)
    {
        int passFit = fit - BOOST_GAIN_GRID_POINTS;
        if (passFit >= 0 && (passFit & 1) == 0 && fit <= trackFit)
        {
            barrier();
            frameLogGain = APL_SoftLogGain(fit);
        }

        float logGain = gridStep * fit;
        if (passFit >= 0 && fit < trackFit)
        {
            float spread = gridStep / float(1 << (passFit >> 1));
            logGain = clamp(frameLogGain - spread, 0.0, topLog - 2.0 * spread) + 2.0 * spread * float(passFit & 1);
        }

        if (fit == trackFit)
        {
            float frameGain = SceneGainFromLogGain(frameLogGain);
            trackGain = min(frameGain, trackComp);
            bestAPL = APLFromSceneGain(frameGain);
        }

        float gain = (fit < trackFit) ? SceneGainFromLogGain(logGain) : ((fit == trackFit) ? trackGain : shownGain);
        float fitComp = (fit == finalFit) ? shownComp : trackComp;
        float cost = APL_FitAndCost(localIndex, gain, fitComp, costWidth, bin) / HALF_CODE_PQ;

        if (localIndex == 0 && fit < trackFit)
            APL_GainCosts[fit] = float2(logGain, cost);

        if (fit == trackFit)
        {
            trackLoad = APL_ShownAPL(localIndex, pixelCount, sceneNits, maxChannelNits, loadNits);

            // The compensation is read at the eased APL plus however far the last load sits above the APL the ease
            // runs toward, which is nothing for a frame that fits, so there the gain matches it exactly.
            float targetAPL = (trackGain < trackComp) ? APLFromSceneGain(trackGain) : trackAPL;
            float loweredAPL = lastLoad - targetAPL;
            float blend = ComputeTemporalBlendFactor(APLSmoothingSeconds);
            float easedLogGain = lerp(ComputeSceneLogGainFromAPL(lastTrack.y), ComputeSceneLogGainFromAPL(targetAPL), blend);
            easedAPL = hasHistory ? APLFromSceneGain(SceneGainFromLogGain(easedLogGain)) : targetAPL;
            shownGain = SceneGainFromLogGain(ComputeSceneLogGainFromAPL(easedAPL));
            shownComp = SceneGainFromLogGain(ComputeSceneLogGainFromAPL(easedAPL + loweredAPL));
        }
    }

    float shownAPL = APL_ShownAPL(localIndex, pixelCount, sceneNits, maxChannelNits, loadNits);

    tex2Dstore(StorageBoostCurve, int2(localIndex + 1, 0), APL_CurveNodes[localIndex + 1]);

    if (localIndex == 0)
    {
        tex2Dstore(StorageBoostCurve, int2(0, 0), APL_CurveNodes[0]);
        tex2Dstore(StorageBoostParams, int2(0, 0), APL_EvalBoostParams[0]);
        tex2Dstore(StorageBoostParams, int2(1, 0), APL_EvalBoostParams[1]);
        tex2Dstore(StorageAPLInstant, int2(0, 0), float4(APL_AverageFromSums(rawSums), shownAPL, 1.0, float(APL_GetFrameStamp())));
        tex2Dstore(StorageAPLInstant, int2(1, 0), float4(trackLoad, easedAPL, bestAPL, 0.0));
    }
}


float DrawOSDPercentAt(float2 texcoord, float2 topRight, float scale, float aspect)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x -= scale / max(aspect, 1e-6);
    anchor.x *= aspect;

    uv -= anchor;

    return GetPercent(uv / scale);
}

float DrawOSDDotAt(float2 texcoord, float2 topRight, float scale, float aspect)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x *= aspect;

    uv -= anchor;
    uv.x = -uv.x;

    return GetDot(uv / scale);
}

float DrawOSDAPLPercent2(float2 texcoord, float2 topRight, float scale, float stepX, float aspect, float currentAPL)
{
    int aplPctX100 = clamp(int(floor(saturate(currentAPL) * 10000.0 + 0.5)), 0, 10000);
    int integerPart = aplPctX100 / 100;
    int fractionalPart = aplPctX100 % 100;

    float mask = 0.0;

    mask += DrawOSDDigitAt(texcoord, topRight, scale, aspect, fractionalPart % 10);
    mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX, 0.0), scale, aspect, (fractionalPart / 10) % 10);
    mask += DrawOSDDotAt(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect);
    mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, aspect, integerPart % 10);

    if (integerPart >= 10)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 4.0, 0.0), scale, aspect, (integerPart / 10) % 10);

    if (integerPart >= 100)
        mask += DrawOSDDigitAt(texcoord, topRight - float2(stepX * 5.0, 0.0), scale, aspect, (integerPart / 100) % 10);

    return saturate(mask);
}


#define OSD_CHAR_SPACE -1
#define OSD_CHAR_A 0
#define OSD_CHAR_E 4
#define OSD_CHAR_I 8
#define OSD_CHAR_K 10
#define OSD_CHAR_L 11
#define OSD_CHAR_N 13
#define OSD_CHAR_O 14
#define OSD_CHAR_P 15
#define OSD_CHAR_R 17
#define OSD_CHAR_T 19
#define OSD_CHAR_U 20
#define OSD_CHAR_W 22

float GetOSDLetter(int letter, float2 uv)
{
    int pattern = 0;

    if (letter == OSD_CHAR_A) pattern = 11245;
    else if (letter == OSD_CHAR_E) pattern = 29391;
    else if (letter == OSD_CHAR_I) pattern = 29847;
    else if (letter == OSD_CHAR_K) pattern = 23277;
    else if (letter == OSD_CHAR_L) pattern = 4687;
    else if (letter == OSD_CHAR_N) pattern = 24573;
    else if (letter == OSD_CHAR_O) pattern = 31599;
    else if (letter == OSD_CHAR_P) pattern = 15049;
    else if (letter == OSD_CHAR_R) pattern = 15085;
    else if (letter == OSD_CHAR_T) pattern = 29842;
    else if (letter == OSD_CHAR_U) pattern = 23407;
    else if (letter == OSD_CHAR_W) pattern = 23421;

    return SampleGlyph(pattern, uv);
}

float DrawOSDLetterAt(float2 texcoord, float2 topLeft, float scale, float aspect, int letter)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topLeft;
    anchor.x *= aspect;

    uv -= anchor;

    return GetOSDLetter(letter, uv / scale);
}

float DrawOSDLabel8(float2 texcoord, float2 topLeft, float scale, float stepX, float aspect, int c0, int c1, int c2, int c3, int c4, int c5, int c6, int c7)
{
    float mask = 0.0;
    if (c0 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft, scale, aspect, c0);
    if (c1 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX, 0.0), scale, aspect, c1);
    if (c2 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 2.0, 0.0), scale, aspect, c2);
    if (c3 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 3.0, 0.0), scale, aspect, c3);
    if (c4 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 4.0, 0.0), scale, aspect, c4);
    if (c5 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 5.0, 0.0), scale, aspect, c5);
    if (c6 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 6.0, 0.0), scale, aspect, c6);
    if (c7 >= 0) mask += DrawOSDLetterAt(texcoord, topLeft + float2(stepX * 7.0, 0.0), scale, aspect, c7);
    return saturate(mask);
}


// The knee row turns to a warning color while the curve compresses content on screen.
float3 DrawStatsOverlay(float2 texcoord, float3 sceneColor, float rawInputAPL, float outputAPL, float kneeNits, bool compressing)
{
    float aspect = ReShade::AspectRatio;
    float invAspect = 1.0 / max(aspect, 1e-6);

    float scale = 0.022;
    float glyphWidth = scale * invAspect;
    float stepX = glyphWidth * 1.06;
    float lineSpacing = scale * 1.18;
    float percentGap = glyphWidth * 0.20;

    float labelScale = scale * 0.92;
    float labelGlyphWidth = labelScale * invAspect;
    float labelStepX = labelGlyphWidth * 1.18;
    float labelTotalWidth = labelStepX * 7.0 + labelGlyphWidth;
    float labelGap = glyphWidth * 0.82;

    float rightMargin = 0.016;
    float2 inputPercentRight = float2(1.0 - rightMargin, 0.034);
    float2 inputRowRight = inputPercentRight - float2(glyphWidth + percentGap, 0.0);
    float2 outputPercentRight = inputPercentRight + float2(0.0, lineSpacing);
    float2 outputRowRight = inputRowRight + float2(0.0, lineSpacing);
    float2 kneeRowRight = inputRowRight + float2(0.0, lineSpacing * 2.0);

    float valueLeft = inputRowRight.x - stepX * 5.0 - glyphWidth;
    float2 inputLabelTopLeft = float2(valueLeft - labelGap - labelTotalWidth, inputRowRight.y);
    float2 outputLabelTopLeft = inputLabelTopLeft + float2(0.0, lineSpacing);
    float2 kneeLabelTopLeft = inputLabelTopLeft + float2(0.0, lineSpacing * 2.0);

    float left = inputLabelTopLeft.x;
    float right = inputPercentRight.x;
    float top = inputRowRight.y;
    float bottom = kneeRowRight.y + scale;

    float padX = glyphWidth * 0.48;
    float padY = scale * 0.20;

    if (texcoord.x < left - padX || texcoord.x > right + padX || texcoord.y < top - padY || texcoord.y > bottom + padY)
        return sceneColor;

    int kneeDisplay = clamp(int(floor(max(kneeNits, 0.0) + 0.5)), 0, 99999);

    float rawLabelMask = DrawOSDLabel8(texcoord, inputLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_R, OSD_CHAR_A, OSD_CHAR_W, OSD_CHAR_SPACE, OSD_CHAR_A, OSD_CHAR_P, OSD_CHAR_L, OSD_CHAR_SPACE);
    float outputLabelMask = DrawOSDLabel8(texcoord, outputLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_O, OSD_CHAR_U, OSD_CHAR_T, OSD_CHAR_SPACE, OSD_CHAR_A, OSD_CHAR_P, OSD_CHAR_L, OSD_CHAR_SPACE);
    float kneeLabelMask = DrawOSDLabel8(texcoord, kneeLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_K, OSD_CHAR_N, OSD_CHAR_E, OSD_CHAR_E, OSD_CHAR_SPACE, OSD_CHAR_N, OSD_CHAR_I, OSD_CHAR_T);

    float inputMask = 0.0;
    inputMask += DrawOSDAPLPercent2(texcoord, inputRowRight, scale, stepX, aspect, rawInputAPL);
    inputMask += DrawOSDPercentAt(texcoord, inputPercentRight, scale, aspect);
    inputMask = saturate(inputMask);

    float outputMask = 0.0;
    outputMask += DrawOSDAPLPercent2(texcoord, outputRowRight, scale, stepX, aspect, outputAPL);
    outputMask += DrawOSDPercentAt(texcoord, outputPercentRight, scale, aspect);
    outputMask = saturate(outputMask);

    float kneeMask = DrawOSDRow5(texcoord, kneeRowRight, scale, stepX, aspect, kneeDisplay);

    float bgAlpha = 0.18 * OSDBrightness;
    float3 shadedScene = sceneColor * (1.0 - bgAlpha);

    float3 inputColor = float3(0.30, 1.00, 0.30) * OSDBrightness;
    float3 outputColor = float3(1.00, 0.90, 0.18) * OSDBrightness;
    float3 kneeColor = (compressing ? float3(1.00, 0.42, 0.18) : float3(0.55, 0.55, 0.55)) * OSDBrightness;

    float3 result = shadedScene;
    result = lerp(result, inputColor, saturate(rawLabelMask + inputMask));
    result = lerp(result, outputColor, saturate(outputLabelMask + outputMask));
    result = lerp(result, kneeColor, saturate(kneeLabelMask + kneeMask));

    return result;
}


// Pass 5: apply the boost, optional LUT, OSD, and graph.
float4 PS_MainPass(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 sourceColor = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 color = sourceColor;

    BoostCurve curve = LoadBoostCurve();

    if (EnableEOTFBoost)
    {
        color = ApplyBoostFromPrecomputedParams(color, curve);

        if (ShowCompression)
            color = DrawCompressionHeatmap(sourceColor, color, curve);
    }

#if PQHDRLUT_ENABLE
    // The calibration LUT operates on the final boosted signal.
    if (EnablePQHDRLUT)
        color = PQHDRLUT_Apply(color);
#endif

    if (ShowOSD)
    {
        float4 instantData = tex2Dfetch(SamplerAPLInstant, int2(0, 0));
        bool compressing = curve.departureU < curve.peakPQ - 1e-4;
        color = DrawStatsOverlay(
            texcoord,
            color,
            saturate(instantData.r),
            saturate(instantData.g),
            compressing ? PQToLinearBT2100(curve.departureU) * 10000.0 : PanelPeakNits,
            compressing
        );
    }

#if ENABLE_APL_GRAPH
    if (ShowAPLGraph)
        color = DrawAPLGraphOverlay(texcoord, color);
#endif

    return float4(color, 1.0);
}

#if ENABLE_APL_GRAPH
// Solve one fixed operating point for the standard APL graph.
float ComputeAPLGraphLiveOperatingPoint(float rawAPLPercent)
{
    return SolveUniformSceneDisplayAPL(saturate(rawAPLPercent * 0.01));
}

float4 PS_CalcGraphParams(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return 0.0.xxxx;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float graphAxisMaxPQ = GraphUsePQSpace ? max(NitsToPQ(graphAxisMaxNits), 1e-6) : 0.0;

    if (GraphUseFullFieldWindowProjection)
        return float4(0.0, GetFullFieldMeasuredMaxOutputNitsByMode(GraphProjectionWindowSize), graphAxisMaxPQ, 0.0);

    float graphRawAPLPercent = clamp(GraphAPLIndex, 0.0, 100.0);
    float graphClosedLoopAPL = ComputeAPLGraphLiveOperatingPoint(graphRawAPLPercent);
    float graphClosedLoopAPLPercent = graphClosedLoopAPL * 100.0;
    float maxMeasuredNits = GetAPLMaxMeasuredNits(graphClosedLoopAPLPercent);

    return float4(graphClosedLoopAPLPercent, maxMeasuredNits, graphAxisMaxPQ, 0.0);
}


float4 ComputeAPLGraphLiveProjection(float displayAPL, float maxMeasuredNits, float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);
    float remappedSignalNits = safeInputNits;

    if (EnableEOTFBoost && displayAPL > 1e-6)
        remappedSignalNits = ComputeGraphWindowNits(safeInputNits, SceneGainFromLogGain(ComputeSceneLogGainFromAPL(displayAPL)));

    float displayAPLPercent = displayAPL * 100.0;
    float predictedMeasuredOutputNits = SampleCorrectedOutputNitsForAPL(
        displayAPLPercent,
        remappedSignalNits,
        maxMeasuredNits
    );

    return float4(remappedSignalNits, predictedMeasuredOutputNits, displayAPL, 1.0);
}


// Graph pass: compute live-equivalent projection at each x sample.
float4 PS_CalcGraphProjection(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return 0.0.xxxx;

    int sampleIndex = min(int(vpos.x), GRAPH_CURVE_SAMPLES - 1);
    float t = float(sampleIndex) / float(GRAPH_CURVE_SAMPLES - 1);

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float graphAxisMaxPQ = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;
    float inputNits = GraphNitsFromAxisFraction(t, graphAxisMaxNits, graphAxisMaxPQ);
    float limitedInputNits = ApplyGraphInputSignalLimitNits(inputNits);

    if (GraphUseFullFieldWindowProjection)
        return ComputeFullFieldLiveProjectionByMode(GraphProjectionWindowSize, limitedInputNits);

    float graphClosedLoopAPL = saturate(graphParams.r * 0.01);
    float graphMaxMeasuredNits = max(graphParams.g, 0.0);
    return ComputeAPLGraphLiveProjection(graphClosedLoopAPL, graphMaxMeasuredNits, limitedInputNits);
}


// Graph pass: build grid, tick, and identity-line segments.
float4 PS_CalcGraphLines(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return float4(-1.0, -1.0, -1.0, -1.0);

    int idx = int(vpos.x);

    float4 graphRect   = GetGraphRect();
    float2 graphPos    = graphRect.xy;
    float2 graphSize   = graphRect.zw;
    float  tickLen     = graphSize.y * 0.018;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams     = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ  = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;

    float2 a = 0.0, b = 0.0;

    if (idx < 9) // Vertical grid lines.
    {
        int i = idx + 1;
        float tickValue = GraphNitsFromAxisFraction(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, graphAxisMaxNits);
    }
    else if (idx < 18) // Horizontal grid lines.
    {
        int i = idx - 9 + 1;
        float tickValue = GraphNitsFromAxisFraction(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0,           tickValue);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, graphAxisMaxNits, tickValue);
    }
    else if (idx < 24) // X-axis ticks.
    {
        int i = idx - 18;
        float tickValue = GraphNitsFromAxisFraction(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
        float2 xTick = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        a = xTick + float2(0.0, -tickLen);
        b = xTick;
    }
    else if (idx < 30) // Y-axis ticks.
    {
        int i = idx - 24;
        float tickValue = GraphNitsFromAxisFraction(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
        float2 yTick = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0, tickValue);
        a = yTick;
        b = yTick + float2(tickLen, 0.0);
    }
    else if (idx == 30) // Identity line.
    {
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0,             0.0);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, graphAxisMaxNits, graphAxisMaxNits);
    }
    else
    {
        return float4(-1.0, -1.0, -1.0, -1.0);
    }

    return float4(a, b);
}


// Graph pass: build screen-space curve segments.
float4 PS_CalcGraphCurves(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    static const float4 SENTINEL = float4(-1.0, -1.0, -1.0, -1.0);

    if (!ShowAPLGraph)
        return SENTINEL;

    int s   = int(vpos.x);
    int row = int(vpos.y);

    if (s >= GRAPH_CURVE_SAMPLES - 1)
        return SENTINEL;

    float4 graphRect   = GetGraphRect();
    float2 graphPos    = graphRect.xy;
    float2 graphSize   = graphRect.zw;
    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);

    float4 graphParams               = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ            = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;
    float  graphRawAPLPercent        = clamp(GraphAPLIndex, 0.0, 100.0);

    bool useFF = GraphUseFullFieldWindowProjection;
    int fullFieldWindowMode = GraphProjectionWindowSize;

    float t0 = float(s)     / float(GRAPH_CURVE_SAMPLES - 1);
    float t1 = float(s + 1) / float(GRAPH_CURVE_SAMPLES - 1);
    float x0 = GraphNitsFromAxisFraction(t0, graphAxisMaxNits, graphAxisMaxPQ);
    float x1 = GraphNitsFromAxisFraction(t1, graphAxisMaxNits, graphAxisMaxPQ);

    float graphMaxMeasuredNits = graphParams.g;

    float4 result = SENTINEL;

    if (row == GCURVE_REMAPPED || row == GCURVE_CORRECTED)
    {
        static const float invGraphSamples = 1.0 / float(GRAPH_CURVE_SAMPLES);
        float4 graphProjection0 = tex2Dlod(SamplerGraphProjection, float4((float(s) + 0.5) * invGraphSamples, 0.5, 0.0, 0.0));
        float4 graphProjection1 = tex2Dlod(SamplerGraphProjection, float4((float(s + 1) + 0.5) * invGraphSamples, 0.5, 0.0, 0.0));

        if (graphProjection0.a > 0.0 && graphProjection1.a > 0.0)
        {
            float y0 = (row == GCURVE_REMAPPED) ? graphProjection0.r : graphProjection0.g;
            float y1 = (row == GCURVE_REMAPPED) ? graphProjection1.r : graphProjection1.g;
            float2 a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    else if (row == GCURVE_MEASURED)
    {
        float measuredMaxInputNits = useFF
            ? GetFullFieldMeasuredMaxInputNits()
            : GetGraphMeasuredMaxInputNits();

        if (x0 < measuredMaxInputNits)
        {
            float mx1 = min(x1, measuredMaxInputNits);
            float y0   = ComputeGraphCurveMeasuredRawOutputNits(useFF, fullFieldWindowMode, graphRawAPLPercent, x0);
            float y1   = ComputeGraphCurveMeasuredRawOutputNits(useFF, fullFieldWindowMode, graphRawAPLPercent, mx1);
            float2 a   = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0,  y0);
            float2 b   = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, mx1, y1);
            result = float4(a, b);
        }
    }
    else if (row == GCURVE_BT2390REF)
    {
        float idealReferencePeakNits = max(graphMaxMeasuredNits, 0.0);
        if (GraphShowBT2390Reference && idealReferencePeakNits > 0.0)
        {
            float lx0 = ApplyGraphInputSignalLimitNits(x0);
            float lx1 = ApplyGraphInputSignalLimitNits(x1);
            float y0  = ApplyBT2390EETFToNits(lx0, graphAxisMaxNits, idealReferencePeakNits);
            float y1  = ApplyBT2390EETFToNits(lx1, graphAxisMaxNits, idealReferencePeakNits);
            float2 a  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b  = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    return result;
}

#endif

// Technique order preserves the required histogram synchronization boundaries.
technique EOTF_Boost_1D_APL_LUT
{
    pass APL_FrameSetup_And_RowHistogramClear
    {
        ComputeShader = CS_SetupAndClearAPLFullFrameRowHistograms<APL_SETUP_THREADS, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }

    pass APL_FullFrame_RowHistogramBuild
    {
        ComputeShader = CS_BuildAPLFullFrameRowHistogram<APL_FFH_THREADS_X, APL_FFH_THREADS_Y, 1>;
        DispatchSizeX = APL_FFH_TILE_COUNT_X;
        DispatchSizeY = APL_FFH_TILE_COUNT_Y;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }

    pass APL_FullFrame_RowHistogramReduce
    {
        ComputeShader = CS_ReduceAPLFullFrameRowHistogram<APL_FFH_REDUCE_THREADS, 1, 1>;
        DispatchSizeX = APL_FFH_BLOCK_W;
        DispatchSizeY = APL_FFH_BLOCK_H;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }

    pass APL_Solve_And_Boost_Params
    {
        ComputeShader = CS_EvaluateAndSolveAPLFullFrameHistogram<APL_EVAL_THREADS, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }

#if ENABLE_APL_GRAPH
    pass Graph_Params
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphParams;
        RenderTarget = TexGraphParams;
    }

    pass Graph_Projection
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphProjection;
        RenderTarget = TexGraphProjection;
    }

    pass Graph_Lines
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphLines;
        RenderTarget = TexGraphLines;
    }

    pass Graph_Curves
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_CalcGraphCurves;
        RenderTarget = TexGraphCurves;
    }
#endif

    pass Main_Boost
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_MainPass;
    }
}
