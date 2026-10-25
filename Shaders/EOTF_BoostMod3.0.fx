/*
    EOTF Boost v8.18.7.15
    Calibrated for 3rd gen QD-OLEDS TB400

    Undoes the panel's automatic brightness limiter (ABL) with a scene-uniform gain. Full
    compensation is the gain equal to the measured compensation at the panel load the
    boosted frame causes.

        full gain = compensation(load(boosted frame)),  load = mean luminance / panel peak

    The panel can't show more than peak / gain in any channel of a frame boosted this way.
    The boost maps each pixel's brightest channel and scales the others with it, so colors
    keep their ratios and no channel crosses the peak. Frames whose brightest channels fit
    under that ceiling show at their source levels. Frames that don't get a shoulder from
    BT.2390's knee for a source mastered to the panel peak and shown under the ceiling.
    Below the knee everything stays at its source level, and the range above it is shared
    out by the frame's own histogram in PQ, from the ceiling down: each histogram bin keeps
    the contrast its share of the shoulder earns and never more than the source has (Ward
    Larson, Rushmeier and Piatko 1997).

    More gain lifts the frame but squeezes more of it into the shoulder, so the gain used is
    the one between 1 and full compensation that maximizes the shown mean luminance times the
    detail the curve keeps, weighing 1% of brightness against 1% of detail. A frame that fits
    under the ceiling keeps all its detail and gets full compensation, and a frame already at
    the panel's limit, like a screen full of snow, stays close to how it shows unboosted.

    Live pipeline:
      1. Frame setup and rolling-row clear
      2. Full-frame row histogram build
      3. Global histogram reduction
      4. Full compensation solve, gain pick, smoothing, tone curve slopes, and knee solve
      5. Tone curve lookup
      6. Fullscreen boost and optional calibration LUT

    Max Raw Nits is tracked only while the OSD is visible.
    Rolling phases advance per shader execution, independent of presented-frame count.
*/

#include "ReShade.fxh"

#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 0
#endif


// Compile-time features.
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
// Pixels are binned by their brightest channel, each level bin split into quarters by position.
#define APL_FFH_TILE_SIZE             32
#define APL_FFH_THREADS_X             16
#define APL_FFH_THREADS_Y             16
#define APL_FFH_PIXELS_X               2
#define APL_FFH_PIXELS_Y               2
#define APL_FFH_LEVEL_BINS             64
#define APL_FFH_SUB_BINS                4
#define APL_FFH_MAX_BINS              256
#define APL_FFH_BLOCK_W                16
#define APL_FFH_BLOCK_H                16
#define APL_FFH_AUX_X                  APL_FFH_BLOCK_W
#define APL_FFH_REDUCE_THREADS         64


// Packed value: pixel count in the upper bits and summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT       20
#define APL_FFH_PACK_OFFSET_MASK       ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE      1023
#define APL_FFH_PACK_ONE_COUNT         (1 << APL_FFH_PACK_COUNT_SHIFT)

#define APL_FFH_TILE_COUNT_X ((BUFFER_WIDTH  + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)
#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)


// Persistent 16x16 histogram block for each 32-pixel-high screen row.
#define APL_FFH_ROW_HIST_TEX_W APL_FFH_BLOCK_W
#define APL_FFH_ROW_COUNT_TEX_W (APL_FFH_BLOCK_W + 1)
#define APL_FFH_ROW_TEX_H (APL_FFH_TILE_COUNT_Y * APL_FFH_BLOCK_H)


// 0 refreshes all rows each frame. N refreshes one of N interleaved row phases.
#ifndef APL_FULLFRAME_ROLLING_PHASES
    #define APL_FULLFRAME_ROLLING_PHASES 6
#endif

#if APL_FULLFRAME_ROLLING_PHASES < 0
    #error "APL_FULLFRAME_ROLLING_PHASES must be >= 0"
#endif

#if APL_FULLFRAME_ROLLING_PHASES > APL_FFH_TILE_COUNT_Y
    #error "APL_FULLFRAME_ROLLING_PHASES cannot exceed the number of full-frame tile rows"
#endif

#if APL_FULLFRAME_ROLLING_PHASES > 0
    #define APL_FFH_ROLLING_ROW_SLOTS ((APL_FFH_TILE_COUNT_Y + APL_FULLFRAME_ROLLING_PHASES - 1) / APL_FULLFRAME_ROLLING_PHASES)
#else
    #define APL_FFH_ROLLING_ROW_SLOTS APL_FFH_TILE_COUNT_Y
#endif

#if (APL_FFH_THREADS_X * APL_FFH_PIXELS_X != APL_FFH_TILE_SIZE) || (APL_FFH_THREADS_Y * APL_FFH_PIXELS_Y != APL_FFH_TILE_SIZE)
    #error "Full-frame APL histogram tile/thread dimensions are inconsistent"
#endif
#if (APL_FFH_BLOCK_W * APL_FFH_BLOCK_H != APL_FFH_MAX_BINS)
    #error "Full-frame APL histogram block dimensions do not match maximum bin count"
#endif
#if (APL_FFH_LEVEL_BINS * APL_FFH_SUB_BINS != APL_FFH_MAX_BINS)
    #error "Full-frame APL histogram level and sub-bin counts do not match maximum bin count"
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


// User settings.
uniform bool EnableEOTFBoost <
    ui_label = "Enable EOTF Boost";
    UI_TOOLTIP("Enables APL-based HDR brightness compensation.")
> = true;

uniform float TransitionSpeed <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "APL Smoothing Time (s)";
    UI_TOOLTIP("Smooths brightness changes after the scene changes. 0 disables smoothing.")
> = 0.25;

// Peak the compensation data was measured at, and the luminance that counts as 100% load.
static const float PANEL_PEAK_NITS = 1000.932391;

// scRGB 1.0 is 80 nits by definition.
static const float SCRGB_REFERENCE_NITS = 80.0;


#if PQHDRLUT_ENABLE
uniform bool EnablePQHDRLUT <
    ui_label = "Enable PQ HDR LUT";
    UI_TOOLTIP("Applies PQHDRLUT.cube after boost, or directly when boost is disabled.")
> = true;

uniform int PQHDRLUTInputColorSpace <
    ui_category = "Optional HDR LUT Calibration";
    ui_category_closed = true;
    ui_type = "combo";
    ui_items = "Auto\0HDR10 PQ / Rec.2020\0scRGB / linear Rec.709\0";
    ui_label = "LUT Input Color Space";
    UI_TOOLTIP("Selects the LUT input color space. Auto uses ReShade's reported buffer color space.")
> = 0;
#endif

uniform bool ShowOSD <
    ui_label = "Show APL Stats";
    UI_TOOLTIP("Shows the panel load without and with the boost, and Max Raw Nits. Max tracking runs only while visible.")
> = false;

uniform float OSDBrightness <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 1.0; ui_step = 0.01;
    ui_label = "OSD Brightness";
    UI_TOOLTIP("Sets OSD and graph brightness.")
> = 0.5;

uniform float FrameTime < source = "frametime"; >;

#if ENABLE_APL_GRAPH
uniform bool ShowAPLGraph <
    ui_label = "Show APL EOTF Debug Graph";
    UI_TOOLTIP("Shows identity, measured, remapped, predicted-output, and optional BT.2390 reference curves.")
> = true;

uniform bool GraphShowBT2390Reference <
    ui_label = "Graph Show BT.2390-Style Reference";
    UI_TOOLTIP("Shows a BT.2390-style curve aimed at the live ceiling.")
> = false;

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
> = 1000.0;

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


// GPU state and histogram resources.
texture TexAPL
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerAPL
{
    Texture = TexAPL;
};
storage2D<float4> StorageAPL
{
    Texture = TexAPL;
};


// Applied tone curve, one texel per level bin: center slope, lower and upper PQ edge,
// and the slope's integral from the lower edge to the top.
texture TexToneCurve
{
    Width = APL_FFH_LEVEL_BINS;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerToneCurve
{
    Texture = TexToneCurve;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float4> StorageToneCurve
{
    Texture = TexToneCurve;
};


// Knee bend start and width and the ceiling in PQ, and the level in nits where the lookup takes over.
texture TexToneCurveShape
{
    Width = 1;
    Height = 1;
    Format = RGBA32F;
};
sampler SamplerToneCurveShape
{
    Texture = TexToneCurveShape;
};
storage2D<float4> StorageToneCurveShape
{
    Texture = TexToneCurveShape;
};


// Shown level in PQ for each 10-bit PQ code, sampled with linear filtering.
#define TONE_CURVE_LUT_SIZE 1024

texture TexToneCurveLUT
{
    Width = TONE_CURVE_LUT_SIZE;
    Height = 1;
    Format = R32F;
};
sampler SamplerToneCurveLUT
{
    Texture = TexToneCurveLUT;
    AddressU = CLAMP;
    AddressV = CLAMP;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    MipFilter = POINT;
};
storage2D<float> StorageToneCurveLUT
{
    Texture = TexToneCurveLUT;
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

texture TexAPLInstant
{
    Width = 1;
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

texture TexAPLPrev
{
    Width = 1;
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


// Exact 129-node PQ decode table used with linear filtering.
texture TexAPLFastPQNits
{
    Width = 129;
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


// Persistent row histograms. The count texture also stores the row maximum.
texture TexAPLRowHistCount
{
    Width = APL_FFH_ROW_COUNT_TEX_W;
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


texture TexAPLRowHistLumaRatio10
{
    Width = APL_FFH_ROW_HIST_TEX_W;
    Height = APL_FFH_ROW_TEX_H;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowHistLumaRatio10
{
    Texture = TexAPLRowHistLumaRatio10;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowHistLumaRatio10
{
    Texture = TexAPLRowHistLumaRatio10;
};

#if APL_FULLFRAME_ROLLING_PHASES > 0


// Rolling-row validity metadata.
texture TexAPLRowMeta
{
    Width = 1;
    Height = APL_FFH_TILE_COUNT_Y;
    Format = R32I;
};
sampler2D<int> SamplerAPLRowMeta
{
    Texture = TexAPLRowMeta;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageAPLRowMeta
{
    Texture = TexAPLRowMeta;
};
#endif

texture TexAPLGlobalHistCount
{
    Width = APL_FFH_BLOCK_W + 1;
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

texture TexAPLGlobalHistLumaRatio10
{
    Width = APL_FFH_BLOCK_W;
    Height = APL_FFH_BLOCK_H;
    Format = R32F;
};
sampler2D<float> SamplerAPLGlobalHistLumaRatio10
{
    Texture = TexAPLGlobalHistLumaRatio10;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<float> StorageAPLGlobalHistLumaRatio10
{
    Texture = TexAPLGlobalHistLumaRatio10;
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


// Per-sample graph projection: remapped nits, predicted output, out load, valid flag.
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


float GetLuma2020(float3 color)
{
    return dot(color, float3(0.2627, 0.6780, 0.0593));
}

// ST.2084 transfer functions.
float3 PQToLinearBT2100(float3 v)
{

    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float3 vp = pow(saturate(v), 1.0 / m2);
    float3 num = max(vp - c1, 0.0);
    float3 den = c2 - c3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / m1);
}

float LinearToPQBT2100(float linearValue)
{

    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float L = saturate(linearValue);
    float Lm1 = pow(L, m1);
    float num = c1 + c2 * Lm1;
    float den = 1.0 + c3 * Lm1;
    return pow(num / max(den, 1e-6), m2);
}


float3 LinearToPQBT2100(float3 v)
{
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float3 Lm1 = pow(saturate(v), m1);
    float3 num = c1 + c2 * Lm1;
    float3 den = 1.0 + c3 * Lm1;
    return pow(num / max(den, 1e-6), m2);
}


float PQToLinearScalar(float v)
{
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float vp = pow(saturate(v), 1.0 / m2);
    float num = max(vp - c1, 0.0);
    float den = c2 - c3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / m1); // Relative to 10000 nits.
}

float NitsToPQ(float nits)
{
    return LinearToPQBT2100(saturate(nits / 10000.0));
}

static const float3x3 REC709_TO_REC2020 = float3x3(
    0.6274040, 0.3292820, 0.0433136,
    0.0690970, 0.9195400, 0.0113612,
    0.0163916, 0.0880132, 0.8955950);

// Linear nits in Rec.2020, the primaries the panel receives, for either buffer format.
float3 DecodeBufferToRec2020Nits(float3 color)
{
#if BUFFER_COLOR_SPACE == 2
    return mul(REC709_TO_REC2020, color) * SCRGB_REFERENCE_NITS;
#else
    return PQToLinearBT2100(saturate(color)) * 10000.0;
#endif
}

bool NeedsAPLProcessing()
{
    return EnableEOTFBoost;
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


float3 PQHDRLUT_Rec709_To_XYZ(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.4123907993, 0.3575843394, 0.1804807884)),
        dot(rgb, float3(0.2126390059, 0.7151686788, 0.0721923154)),
        dot(rgb, float3(0.0193308187, 0.1191947790, 0.9505321522))
    );
}


float3 PQHDRLUT_XYZ_To_Rec709(float3 xyz)
{
    return float3(
        dot(xyz, float3( 3.2409699419, -1.5373831776, -0.4986107603)),
        dot(xyz, float3(-0.9692436363,  1.8759675015,  0.0415550574)),
        dot(xyz, float3( 0.0556300797, -0.2039769589,  1.0569715142))
    );
}


float3 PQHDRLUT_Rec2020_To_XYZ(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.6369580483, 0.1446169036, 0.1688809752)),
        dot(rgb, float3(0.2627002120, 0.6779980715, 0.0593017165)),
        dot(rgb, float3(0.0000000000, 0.0280726930, 1.0609850577))
    );
}


float3 PQHDRLUT_XYZ_To_Rec2020(float3 xyz)
{
    return float3(
        dot(xyz, float3( 1.7166511880, -0.3556707838, -0.2533662814)),
        dot(xyz, float3(-0.6666843518,  1.6164812366,  0.0157685458)),
        dot(xyz, float3( 0.0176398574, -0.0427706133,  0.9421031212))
    );
}

int PQHDRLUT_Resolve_Input_Mode()
{
    if (PQHDRLUTInputColorSpace == 1)
        return 1;

    if (PQHDRLUTInputColorSpace == 2)
        return 2;

#if BUFFER_COLOR_SPACE == 2

    return 2;
#elif BUFFER_COLOR_SPACE == 3

    return 1;
#else

    return 1;
#endif
}

float3 PQHDRLUT_Buffer_To_PQ2020(float3 color, int mode)
{
    if (mode == 2)
    {


        // Keep signed scRGB components through the gamut conversion.
        float3 rec709_nits = color * 80.0;
        float3 xyz_nits = PQHDRLUT_Rec709_To_XYZ(rec709_nits);
        float3 rec2020_nits = PQHDRLUT_XYZ_To_Rec2020(xyz_nits);
        return PQHDRLUT_Nits_To_PQ(max(rec2020_nits, 0.0));
    }

    return max(color, 0.0);
}

float3 PQHDRLUT_PQ2020_To_Buffer(float3 pq, int mode)
{
    if (mode == 2)
    {
        float3 rec2020_nits = PQHDRLUT_PQ_To_Nits(max(pq, 0.0));
        float3 xyz_nits = PQHDRLUT_Rec2020_To_XYZ(rec2020_nits);
        float3 rec709_nits = PQHDRLUT_XYZ_To_Rec709(xyz_nits);


        // Signed scRGB components can represent colors outside Rec.709.
        return rec709_nits / 80.0;
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
    int inputMode = PQHDRLUT_Resolve_Input_Mode();
    float3 sourcePQ = PQHDRLUT_Buffer_To_PQ2020(color, inputMode);
    float3 calibratedPQ = PQHDRLUT_Sample(sourcePQ);
    return PQHDRLUT_PQ2020_To_Buffer(calibratedPQ, inputMode);
}
#endif


#if ENABLE_APL_GRAPH
static const float PQ_BLACK = 7.309559025783966e-07;


// BT.2390-style shoulder from sourcePeakNits down to targetPeakNits, the graph's reference curve.
float ApplyBT2390EETFToPQ(float inputPQ, float sourcePeakNits, float targetPeakNits)
{
    float safeSourcePeakNits = max(sourcePeakNits, 1e-4);
    float safeTargetPeakNits = max(targetPeakNits, 0.0);

    if (safeTargetPeakNits <= 0.0)
        return PQ_BLACK;

    if (safeTargetPeakNits >= safeSourcePeakNits - 1e-4)
        return saturate(inputPQ);

    float sourceBlackPQ = PQ_BLACK;
    float sourceWhitePQ = max(NitsToPQ(safeSourcePeakNits), sourceBlackPQ + 1e-6);
    float targetWhitePQ = min(NitsToPQ(safeTargetPeakNits), sourceWhitePQ - 1e-6);

    float pqRange = max(sourceWhitePQ - sourceBlackPQ, 1e-6);
    float e1 = saturate((saturate(inputPQ) - sourceBlackPQ) / pqRange);
    float maxLum = saturate((targetWhitePQ - sourceBlackPQ) / pqRange);

    if (maxLum >= 1.0 - 1e-6)
        return saturate(inputPQ);

    float kneeStart = saturate(1.5 * maxLum - 0.5);
    float e2 = e1;

    if (e1 >= kneeStart)
    {
        float shoulderSpan = max(1.0 - kneeStart, 1e-6);
        float compressionSpan = max(maxLum - kneeStart, 1e-6);
        float u = saturate((e1 - kneeStart) / shoulderSpan);
        float shoulderPower = max(shoulderSpan / compressionSpan, 1.0);

        e2 = kneeStart + compressionSpan * (1.0 - pow(1.0 - u, shoulderPower));
    }


    return saturate(e2 * pqRange + sourceBlackPQ);
}

float ApplyBT2390EETFToNits(float inputNits, float sourcePeakNits, float targetPeakNits)
{
    float outputPQ = ApplyBT2390EETFToPQ(NitsToPQ(max(inputNits, 0.0)), sourcePeakNits, targetPeakNits);
    return max(PQToLinearScalar(outputPQ) * 10000.0, 0.0);
}
#endif


float GetDigit(int digit, float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    int patterns[10] = { 31599, 9362, 29671, 29391, 23497, 31183, 31215, 29257, 31727, 31695 };
    int num = patterns[clamp(digit, 0, 9)];
    int x = int(uv.x * 3.0);
    int y = int((1.0 - uv.y) * 5.0);

    return (num >> (x + y * 3)) & 1;
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

float Remap01(float x, float a, float b)
{
    return saturate((x - a) / max(b - a, 1e-6));
}

float SegmentLerp(float x, float x0, float y0, float x1, float y1)
{
    return lerp(y0, y1, Remap01(x, x0, x1));
}

// Measured APL data used by the optional graph.
static const int GRAPH_APL_COUNT = 10;
static const int NIT_COUNT = 24;


static const float GRAPH_APL_POINTS[GRAPH_APL_COUNT] =
{
    3.000000, 5.000000, 7.000000, 10.000000, 14.000000, 18.000000, 22.000000, 25.000000, 35.000000, 50.000000
};

static const float NIT_POINTS[NIT_COUNT] =
{
    10.302358, 13.132379, 16.611621, 20.870708, 26.064850, 32.378420, 40.030390, 49.280814, 60.438551, 73.870492, 90.012580, 109.383004, 130.598006, 157.390856, 190.634650, 230.369755, 282.836899, 334.517130, 400.180165, 480.942985, 580.341000, 702.414628, 840.814884, 1000.932391
};


// Live compensation table. Values correspond to COMP_APL_POINTS.
static const int COMP_APL_COUNT = 14;

static const float COMP_APL_POINTS[COMP_APL_COUNT] =
{
    3.000000,
    5.000000,
    7.000000,
    10.000000,
    14.000000,
    18.000000,
    22.000000,
    25.000000,
    35.000000,
    50.000000,
    56.624363,
    70.942259,
    88.020279,
    100.000000
};

// Compensation at each load above. Up to 50% the values are taken/approximated from the
// original denser tables, past it they are the full-field window measurement, input over
// measured output.
static const float COMP_APL_1D[COMP_APL_COUNT] =
{
    1.000000, // 3%
    1.352556, // 5%
    1.673813, // 7%
    2.151376, // 10%
    2.455437, // 14% (approx from 15%)
    2.636610, // 18%
    2.760512, // 22%
    2.839076, // 25%
    3.064304, // 35%
    3.345667, // 50%
    3.411850, // 56.6%
    3.606801, // 70.9%
    3.826662, // 88.0%
    3.940351  // 100%
};


int FindCompAPLIndex(float aplPct)
{

    int idx = 0;
    [unroll]
    for (int i = 0; i < COMP_APL_COUNT - 1; ++i)
        idx += int(step(COMP_APL_POINTS[i + 1], aplPct));
    return min(idx, COMP_APL_COUNT - 2);
}

int FindGraphAPLIndex(float aplPct)
{
    int idx = 0;
    [unroll]
    for (int i = 0; i < GRAPH_APL_COUNT - 1; ++i)
        idx += int(step(GRAPH_APL_POINTS[i + 1], aplPct));
    return min(idx, GRAPH_APL_COUNT - 2);
}

float LookupMeasuredComp1D(float aplPct)
{
    float clampedAPL = clamp(aplPct, COMP_APL_POINTS[0], COMP_APL_POINTS[COMP_APL_COUNT - 1]);
    int a0 = FindCompAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, COMP_APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        COMP_APL_POINTS[a0], COMP_APL_1D[a0],
        COMP_APL_POINTS[a1], COMP_APL_1D[a1]
    );
}

float ComputeTemporalBlendFactor(float smoothingSeconds)
{
    if (smoothingSeconds <= 1e-6)
        return 1.0;

    float dtSeconds = max(FrameTime, 0.0) * 0.001;
    return saturate(1.0 - exp(-dtSeconds / max(smoothingSeconds, 1e-6)));
}

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}

#if ENABLE_APL_GRAPH


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

float LookupGraphCompForAPLRow2D(int aplIdx, float inputNits)
{
    float clampedNits = clamp(inputNits, NIT_POINTS[0], NIT_POINTS[NIT_COUNT - 1]);
    int n0 = FindNitIndex(clampedNits);
    int n1 = min(n0 + 1, NIT_COUNT - 1);

    return SegmentLerp(
        clampedNits,
        NIT_POINTS[n0], GraphTableComp2D(aplIdx, n0),
        NIT_POINTS[n1], GraphTableComp2D(aplIdx, n1)
    );
}

float LookupMeasuredComp2DGraph(float aplPct, float inputNits)
{
    float clampedAPL = clamp(aplPct, GRAPH_APL_POINTS[0], GRAPH_APL_POINTS[GRAPH_APL_COUNT - 1]);
    int a0 = FindGraphAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, GRAPH_APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        GRAPH_APL_POINTS[a0], LookupGraphCompForAPLRow2D(a0, inputNits),
        GRAPH_APL_POINTS[a1], LookupGraphCompForAPLRow2D(a1, inputNits)
    );
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


#if ENABLE_APL_GRAPH
float ApplyGraphInputSignalLimitNits(float inputNits)
{
    float safeInputNits = max(inputNits, 0.0);

    if (GraphInputSignalLimitNits > 0.0)
        return min(safeInputNits, GraphInputSignalLimitNits);

    return safeInputNits;
}

float ComputeGraphCurveMeasuredRawOutputNits(float rawLoadPercent, float inputNits)
{
    return SampleRealMeasuredOutputNitsForAPL(rawLoadPercent, ApplyGraphInputSignalLimitNits(inputNits));
}
#endif

float ComputeBT2390ReferenceOutputNits(float inputNits, float sourcePeakNits, float targetPeakNits)
{
    return ApplyBT2390EETFToNits(inputNits, sourcePeakNits, targetPeakNits);
}

float GraphAxisCoordinateWithPQMax(float nits, float axisMaxNits, float axisMaxPQ)
{
    float safeNits = max(nits, 0.0);
    float safeAxisMaxNits = max(axisMaxNits, 1.0);

    if (GraphUsePQSpace)
        return NitsToPQ(safeNits) / max(axisMaxPQ, 1e-6);

    return safeNits / safeAxisMaxNits;
}

float GraphTickValueFromFractionWithPQMax(float frac, float axisMaxNits, float axisMaxPQ)
{
    float safeAxisMaxNits = max(axisMaxNits, 1e-6);
    float safeFrac = saturate(frac);

    if (!GraphUsePQSpace)
        return safeAxisMaxNits * safeFrac;

    float tickPQ = axisMaxPQ * safeFrac;
    return max(PQToLinearScalar(tickPQ) * 10000.0, 0.0);
}

float GraphSampleNitsFromFraction(float frac, float axisMaxNits, float axisMaxPQ)
{
    return GraphTickValueFromFractionWithPQMax(frac, axisMaxNits, axisMaxPQ);
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

float DrawGraphLine(float2 p, float2 a, float2 b, float thickness)
{
    float pad = thickness * 2.2;
    float2 bbMin = min(a, b) - pad.xx;
    float2 bbMax = max(a, b) + pad.xx;

    if (p.x < bbMin.x || p.x > bbMax.x || p.y < bbMin.y || p.y > bbMax.y)
        return 0.0;

    float h;
    float d = DistanceToSegment(p, a, b, h);
    return 1.0 - smoothstep(thickness, thickness * 1.8, d);
}

float DrawGraphDashedLine(float2 p, float2 a, float2 b, float thickness, float dashCount)
{
    float pad = thickness * 2.2;
    float2 bbMin = min(a, b) - pad.xx;
    float2 bbMax = max(a, b) + pad.xx;

    if (p.x < bbMin.x || p.x > bbMax.x || p.y < bbMin.y || p.y > bbMax.y)
        return 0.0;

    float h;
    float d = DistanceToSegment(p, a, b, h);
    float lineMask = 1.0 - smoothstep(thickness, thickness * 1.8, d);
    float dashMask = step(frac(h * dashCount), 0.55);
    return lineMask * dashMask;
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

float DrawDigitAt(float2 texcoord, float2 topRight, float scale, float aspect, int digit)
{
    float2 uv = texcoord;
    uv.x *= aspect;

    float2 anchor = topRight;
    anchor.x *= aspect;

    uv -= anchor;
    uv.x = -uv.x;

    return GetDigit(digit, uv / scale);
}

float DrawNumberRightAligned(float2 texcoord, float2 topRight, float scale, float aspect, int value)
{
    int v = max(value, 0);
    int digits = CountDigitsInt(v);
    float stepX = (scale * 0.82) / max(aspect, 1e-6);
    float mask = 0.0;

    mask += DrawDigitAt(texcoord, topRight, scale, aspect, v % 10);

    if (digits >= 2)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX, 0.0), scale, aspect, (v / 10) % 10);

    if (digits >= 3)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect, (v / 100) % 10);

    if (digits >= 4)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, aspect, (v / 1000) % 10);

    if (digits >= 5)
        mask += DrawDigitAt(texcoord, topRight - float2(stepX * 4.0, 0.0), scale, aspect, (v / 10000) % 10);

    return saturate(mask);
}

float DrawNumberCentered(float2 texcoord, float2 centerTop, float scale, float aspect, int value)
{
    int digits = CountDigitsInt(value);
    float stepX = (scale * 0.82) / max(aspect, 1e-6);
    float totalWidth = stepX * float(max(digits - 1, 0));
    float2 topRight = centerTop + float2(totalWidth * 0.5, 0.0);
    return DrawNumberRightAligned(texcoord, topRight, scale, aspect, value);
}

float3 DrawAPLGraphOverlay(float2 texcoord, float3 sceneColor)
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 p = texcoord;
    p.x *= aspect;


    float2 graphPos = float2(0.055 * aspect, 0.48);
    float2 graphSize = float2(0.43 * aspect, 0.44);
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


            float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
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

            if (GraphShowBT2390Reference)
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
    graphColor = lerp(graphColor, float3(0.58, 0.58, 0.58) * OSDBrightness * 1.25, saturate(gridMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(0.90, 0.90, 0.90) * OSDBrightness * 1.45, saturate(tickMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(1.0, 1.0, 1.0) * OSDBrightness * 1.8, saturate(frameMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(0.85, 0.85, 0.85) * OSDBrightness * 1.7, saturate(labelMask) * saturate(GraphOpacity + 0.05));
    float measuredMaskSat = saturate(measuredMask);
    float correctedMaskSat = saturate(correctedMask);

    float3 measuredCurveColor = float3(0.62, 0.82, 1.00);
    float3 correctedCurveColor = float3(0.62, 0.62, 0.62);

    graphColor = lerp(graphColor, float3(0.40, 0.65, 1.00) * OSDBrightness * 2.0, saturate(refMask) * GraphOpacity);
    graphColor = lerp(graphColor, float3(1.00, 0.35, 0.92) * OSDBrightness * 2.0, saturate(idealPQRefMask) * saturate(GraphOpacity + 0.02));
    graphColor = lerp(graphColor, measuredCurveColor * OSDBrightness * 1.95, measuredMaskSat * saturate(GraphOpacity * 0.95));
    graphColor = lerp(graphColor, float3(0.30, 0.88, 0.42) * OSDBrightness * 1.55, saturate(remappedMask) * saturate(GraphOpacity + 0.06));
    graphColor = lerp(graphColor, correctedCurveColor * OSDBrightness * 1.85, correctedMaskSat * saturate(GraphOpacity + 0.20));

    return saturate(graphColor);
}

#endif


// Bilinear lookup in the 129-node PQ decode table.
float APL_FastPQCodeToNits(float pqCode)
{


    float u = (saturate(pqCode) * 128.0 + 0.5) * (1.0 / 129.0);
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
    return clamp((int)floor(max(nits, 0.0) * 4.0 + 0.5), 0, 40000);
}

// Luma as a fraction of the brightest channel, which it never exceeds.
int APL_EncodeLumaRatio10(float lumaNits, float levelNits)
{
    float ratio = (levelNits > 0.0) ? saturate(lumaNits / levelNits) : 0.0;
    return (int)floor(ratio * APL_FFH_PACK_OFFSET_SCALE + 0.5);
}

int APL_HistogramLevelBin64(int levelQ4)
{
    if (levelQ4 <= 0) return 0;
    int exponent = firstbithigh(levelQ4);
    int subBin = (exponent >= 2) ? ((levelQ4 >> (exponent - 2)) & 3) : 0;
    return min(exponent * 4 + subBin, APL_FFH_LEVEL_BINS - 1);
}

void APL_HistogramLevelBinBoundsQ4(int levelBin, out int lowerQ4, out int upperQ4)
{
    lowerQ4 = 0;
    upperQ4 = 0;

    int exponent = levelBin >> 2;
    int subBin = levelBin & 3;

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

int APL_EncodeWithinBinOffset10(int levelQ4, int levelBin)
{
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLevelBinBoundsQ4(levelBin, lowerQ4, upperQ4);

    uint rangeQ4 = uint(upperQ4 - lowerQ4);
    if (rangeQ4 == 0u)
        return 0;

    uint positionQ4 = uint(clamp(levelQ4, lowerQ4, upperQ4) - lowerQ4);
    uint numerator = positionQ4 * uint(APL_FFH_PACK_OFFSET_SCALE);
    uint offset10 = (numerator + (rangeQ4 >> 1)) / rangeQ4;
    return int(min(offset10, uint(APL_FFH_PACK_OFFSET_SCALE)));
}

float APL_ReconstructMeanLevelQ4(int binIndex, float pixelCount, float offsetSum10)
{
    int levelBin = binIndex / APL_FFH_SUB_BINS;
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLevelBinBoundsQ4(levelBin, lowerQ4, upperQ4);
    float rangeQ4 = float(upperQ4 - lowerQ4);

    if (pixelCount <= 0.0 || rangeQ4 <= 0.0)
        return float(lowerQ4);

    float meanOffset10 = offsetSum10 / pixelCount;
    return float(lowerQ4) + rangeQ4 * (meanOffset10 / float(APL_FFH_PACK_OFFSET_SCALE));
}

int2 APL_HistogramBlockCoord(int binIndex)
{
    return int2(binIndex & 15, binIndex >> 4);
}

int2 APL_RowHistogramCoord(int rowIndex, int binIndex)
{
    int2 binCoord = APL_HistogramBlockCoord(binIndex);
    return int2(binCoord.x, rowIndex * APL_FFH_BLOCK_H + binCoord.y);
}

int2 APL_RowExactMaxLumaCoord(int rowIndex)
{
    return int2(APL_FFH_AUX_X, rowIndex * APL_FFH_BLOCK_H);
}

int2 APL_GlobalExactMaxLumaCoord()
{
    return int2(APL_FFH_AUX_X, 0);
}

int APL_DecodeStoredRollingPhase(float storedPhase)
{
#if APL_FULLFRAME_ROLLING_PHASES > 0
    return clamp(int(floor(storedPhase + 0.5)), 0, APL_FULLFRAME_ROLLING_PHASES - 1);
#else
    return 0;
#endif
}

int APL_GetNextRollingPhase(int currentPhase)
{
#if APL_FULLFRAME_ROLLING_PHASES > 0
    int nextPhase = currentPhase + 1;
    return (nextPhase < APL_FULLFRAME_ROLLING_PHASES) ? nextPhase : 0;
#else
    return 0;
#endif
}

int APL_GetPhysicalRowFromDispatchSlot(int dispatchRowSlot, int rollingPhase)
{
#if APL_FULLFRAME_ROLLING_PHASES > 0
    return rollingPhase + dispatchRowSlot * APL_FULLFRAME_ROLLING_PHASES;
#else
    return dispatchRowSlot;
#endif
}

int APL_GetExpectedRowPixelCount(int rowIndex)
{
    int rowStartY = rowIndex * APL_FFH_TILE_SIZE;
    int rowHeight = clamp(BUFFER_HEIGHT - rowStartY, 0, APL_FFH_TILE_SIZE);
    return BUFFER_WIDTH * rowHeight;
}

int APL_GetExpectedTilePixelCount(int tileX, int rowIndex)
{
    int tileStartX = tileX * APL_FFH_TILE_SIZE;
    int tileStartY = rowIndex * APL_FFH_TILE_SIZE;
    int tileWidth = clamp(BUFFER_WIDTH - tileStartX, 0, APL_FFH_TILE_SIZE);
    int tileHeight = clamp(BUFFER_HEIGHT - tileStartY, 0, APL_FFH_TILE_SIZE);
    return tileWidth * tileHeight;
}

void APL_DecodePackedFullFrameSample(
    int2 pixel,
    out int binIndex,
    out int packedContribution,
    out int lumaRatio10,
    out int lumaQ4,
    out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    lumaRatio10 = 0;
    lumaQ4 = 0;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 color = tex2Dfetch(ReShade::BackBuffer, pixel).rgb;
#if BUFFER_COLOR_SPACE == 2
    float3 channelNits = mul(REC709_TO_REC2020, color) * SCRGB_REFERENCE_NITS;
#else
    float3 channelNits = APL_FastPQToNits(color);
#endif
    float sceneNits = max(GetLuma2020(channelNits), 0.0);
    float levelNits = Max3(max(channelNits, 0.0));

    int levelQ4 = APL_QuantizeNitsQ4(levelNits);
    int levelBin = APL_HistogramLevelBin64(levelQ4);
    int offset10 = APL_EncodeWithinBinOffset10(levelQ4, levelBin);

    binIndex = levelBin * APL_FFH_SUB_BINS + offset10 * APL_FFH_SUB_BINS / (APL_FFH_PACK_OFFSET_SCALE + 1);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    lumaRatio10 = APL_EncodeLumaRatio10(sceneNits, levelNits);
    lumaQ4 = APL_QuantizeNitsQ4(sceneNits);
    valid = 1;
}

groupshared int APL_SetupRollingPhase;
groupshared int APL_TilePackedCountLevel[APL_FFH_MAX_BINS];
groupshared int APL_TileLumaRatio10[APL_FFH_MAX_BINS];
groupshared int APL_TileExactMaxLumaQ4;
groupshared int APL_BuildRollingPhase;

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int lumaRatio10, int valid)
{
    if (valid == 0)
        return;

    atomicAdd(APL_TilePackedCountLevel[binIndex], packedContribution);
    atomicAdd(APL_TileLumaRatio10[binIndex], lumaRatio10);
}


[shader("compute")]
// Pass 1: build frame constants, copy APL history, and clear updated rows.
void CS_SetupAndClearAPLFullFrameRowHistograms(uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    bool trackExactMax = aplActive && ShowOSD;


    if (aplActive && localIndex < 129)
    {
        float pqCode = float(localIndex) * (1.0 / 128.0);
        tex2Dstore(StorageAPLFastPQNits, int2(localIndex, 0), PQToLinearScalar(pqCode) * 10000.0);
    }


    if (localIndex == 0)
    {
        float4 previousAPL = aplActive
            ? tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0))
            : 0.0.xxxx;
        float storedPhase = aplActive
            ? tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0)).b
            : 0.0;
        APL_SetupRollingPhase = APL_DecodeStoredRollingPhase(storedPhase);

        // TexAPLPrev.g is unused by the solver and carries this execution's phase.
        previousAPL.g = float(APL_SetupRollingPhase);
        tex2Dstore(StorageAPLPrev, int2(0, 0), previousAPL);
    }
    barrier();

    int totalEntries = APL_FFH_ROLLING_ROW_SLOTS * APL_FFH_MAX_BINS;


    if (!trackExactMax)
    {
        [loop]
        for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += 256)
            tex2Dstore(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex), 0);
    }

    if (aplActive)
    {
        [loop]
        for (int entry = localIndex; entry < totalEntries; entry += 256)
        {
            int rowSlot = entry / APL_FFH_MAX_BINS;
            int binIndex = entry - rowSlot * APL_FFH_MAX_BINS;
            int rowIndex = APL_GetPhysicalRowFromDispatchSlot(rowSlot, APL_SetupRollingPhase);
            if (rowIndex < APL_FFH_TILE_COUNT_Y)
            {
                int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
                tex2Dstore(StorageAPLRowHistCount, coord, 0);
                tex2Dstore(StorageAPLRowHistOffset10, coord, 0);
                tex2Dstore(StorageAPLRowHistLumaRatio10, coord, 0);
                if (binIndex == 0)
                {
                    if (trackExactMax)
                        tex2Dstore(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex), 0);
#if APL_FULLFRAME_ROLLING_PHASES > 0
                    tex2Dstore(StorageAPLRowMeta, int2(0, rowIndex), 0);
#endif
                }
            }
        }
    }
}

[shader("compute")]
// Pass 2: decode source pixels and accumulate row histograms.
void CS_BuildAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;
    bool trackExactMax = aplActive && ShowOSD;

    if (localIndex == 0)
    {
        float storedPhase = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0)).g;
        APL_BuildRollingPhase = APL_DecodeStoredRollingPhase(storedPhase);
    }

    APL_TilePackedCountLevel[localIndex] = 0;
    APL_TileLumaRatio10[localIndex] = 0;
    if (trackExactMax && localIndex == 0)
        APL_TileExactMaxLumaQ4 = 0;
    barrier();

    int physicalRow = APL_GetPhysicalRowFromDispatchSlot(int(groupID.y), APL_BuildRollingPhase);
    bool validPhysicalRow = physicalRow < APL_FFH_TILE_COUNT_Y;
    bool decodeThisGroup = aplActive && validPhysicalRow;

    if (decodeThisGroup)
    {
        int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, physicalRow * APL_FFH_TILE_SIZE) + int2(threadID.xy) * 2;

        int b0, p0, r0, l0, v0;
        int b1, p1, r1, l1, v1;
        int b2, p2, r2, l2, v2;
        int b3, p3, r3, l3, v3;
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), b0, p0, r0, l0, v0);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), b1, p1, r1, l1, v1);
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), b2, p2, r2, l2, v2);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), b3, p3, r3, l3, v3);

        if (trackExactMax)
            atomicMax(APL_TileExactMaxLumaQ4, max(max(l0, l1), max(l2, l3)));


        if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; r0 += r1; v1 = 0; }
        if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; r0 += r2; v2 = 0; }
        if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; r1 += r2; v2 = 0; }
        if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; r0 += r3; v3 = 0; }
        if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; r1 += r3; v3 = 0; }
        if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; r2 += r3; v3 = 0; }

        APL_AtomicAddMergedTileSample(b0, p0, r0, v0);
        APL_AtomicAddMergedTileSample(b1, p1, r1, v1);
        APL_AtomicAddMergedTileSample(b2, p2, r2, v2);
        APL_AtomicAddMergedTileSample(b3, p3, r3, v3);
    }
    barrier();

    if (trackExactMax && decodeThisGroup && localIndex == 0)
        atomicMax(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(physicalRow), APL_TileExactMaxLumaQ4);

    if (decodeThisGroup)
    {
        int packedValue = APL_TilePackedCountLevel[localIndex];
        int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
        if (count > 0)
        {
            int offsetSum10 = packedValue & APL_FFH_PACK_OFFSET_MASK;
            int2 rowCoord = APL_RowHistogramCoord(physicalRow, int(localIndex));
            atomicAdd(StorageAPLRowHistCount, rowCoord, count);
            atomicAdd(StorageAPLRowHistOffset10, rowCoord, offsetSum10);
            atomicAdd(StorageAPLRowHistLumaRatio10, rowCoord, APL_TileLumaRatio10[localIndex]);
        }
    }

#if APL_FULLFRAME_ROLLING_PHASES > 0


    if (decodeThisGroup && localIndex == 0)
    {
        int tilePixelCount = APL_GetExpectedTilePixelCount(int(groupID.x), physicalRow);
        if (tilePixelCount > 0)
            atomicAdd(StorageAPLRowMeta, int2(0, physicalRow), tilePixelCount);
    }
#endif
}

groupshared int APL_ReduceCount[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffset10[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceLumaRatio10[APL_FFH_REDUCE_THREADS];

#define APL_REDUCE_ROW_STAGE(S) \
    if (localIndex < S) { \
        APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + S]; \
        APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + S]; \
        APL_ReduceLumaRatio10[localIndex] += APL_ReduceLumaRatio10[localIndex + S]; \
    } \
    barrier();

// A rolling row counts once every tile in it has been written this cycle.
bool APL_IsRowComplete(int rowIndex)
{
#if APL_FULLFRAME_ROLLING_PHASES > 0
    return tex2Dfetch(SamplerAPLRowMeta, int2(0, rowIndex)) == APL_GetExpectedRowPixelCount(rowIndex);
#else
    return true;
#endif
}

[shader("compute")]
// Pass 3: reduce complete persistent rows into one global histogram.
void CS_ReduceAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;
    bool trackExactMax = aplActive && ShowOSD;

    int countSum = 0;
    float offsetSum10 = 0.0;
    float lumaRatioSum10 = 0.0;
    if (aplActive)
    {
        [loop]
        for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
        {
            if (APL_IsRowComplete(rowIndex))
            {
                int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
                countSum += tex2Dfetch(SamplerAPLRowHistCount, sourceCoord);
                offsetSum10 += float(tex2Dfetch(SamplerAPLRowHistOffset10, sourceCoord));
                lumaRatioSum10 += float(tex2Dfetch(SamplerAPLRowHistLumaRatio10, sourceCoord));
            }
        }
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceLumaRatio10[localIndex] = lumaRatioSum10;
    barrier();

    APL_REDUCE_ROW_STAGE(32)
    APL_REDUCE_ROW_STAGE(16)
    APL_REDUCE_ROW_STAGE(8)
    APL_REDUCE_ROW_STAGE(4)
    APL_REDUCE_ROW_STAGE(2)
    APL_REDUCE_ROW_STAGE(1)

    if (aplActive && localIndex == 0)
    {
        tex2Dstore(StorageAPLGlobalHistCount, localBinCoord, APL_ReduceCount[0]);
        tex2Dstore(StorageAPLGlobalHistOffset10, localBinCoord, APL_ReduceOffset10[0]);
        tex2Dstore(StorageAPLGlobalHistLumaRatio10, localBinCoord, APL_ReduceLumaRatio10[0]);


        if (binIndex == 0)
        {
            int exactMaxLumaQ4 = 0;
            if (trackExactMax)
            {
                [loop]
                for (int rowIndex = 0; rowIndex < APL_FFH_TILE_COUNT_Y; ++rowIndex)
                {
                    if (APL_IsRowComplete(rowIndex))
                        exactMaxLumaQ4 = max(exactMaxLumaQ4, tex2Dfetch(SamplerAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex)));
                }
            }
            tex2Dstore(StorageAPLGlobalHistCount, APL_GlobalExactMaxLumaCoord(), exactMaxLumaQ4);
        }
    }
}

#undef APL_REDUCE_ROW_STAGE


// Tone curve over the brightest-channel histogram in PQ. The shoulder starts at BT.2390's knee
// and its range is shared out top down from the ceiling (Ward Larson, Rushmeier and Piatko
// 1997): each bin's center slope is its share of the pixels above the shoulder start times
// the shoulder's range over its PQ width, capped at 1, the source's own contrast. Slopes run
// linearly between centers, so the curve bends no sharper than one bin, and the empty bin
// above the content brings the slope down to 0 so the curve's top sits at the ceiling.
groupshared float APL_CurveSlope[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveLowerPQ[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveUpperPQ[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveBinIntegral[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveAbove[APL_FFH_LEVEL_BINS];

// Bins 1-3 and 5-7 never get pixels, and bins past 60 sit above the 10000 nit clamp.
static const int APL_TOP_LEVEL_BIN = 60;

static const int APL_GAIN_SOLVE_STEPS = 10;
static const int APL_GAIN_PICK_POINTS = 9;
static const int APL_KNEE_SOLVE_STEPS = 20;
static const int APL_BEND_MAX_PIECES = 8;

// BT.2390's knee for a source mastered to the panel peak and shown under the ceiling.
float APL_ShoulderStartPQ(float ceilingPQ)
{
    return 1.5 * ceilingPQ - 0.5 * NitsToPQ(PANEL_PEAK_NITS);
}

bool APL_IsRealLevelBin(int levelBin)
{
    return levelBin == 0 || levelBin == 4 || (levelBin >= 8 && levelBin <= APL_TOP_LEVEL_BIN);
}

int APL_PreviousRealLevelBin(int levelBin)
{
    if (levelBin == 8)
        return 4;

    if (levelBin == 4)
        return 0;

    return levelBin - 1;
}

int APL_NextRealLevelBin(int levelBin)
{
    if (levelBin == 0)
        return 4;

    if (levelBin == 4)
        return 8;

    return levelBin + 1;
}

// Levels round to the nearest quarter nit, so each bin edge sits half a step out.
float APL_LevelBinLowerNits(int levelBin)
{
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLevelBinBoundsQ4(levelBin, lowerQ4, upperQ4);
    return max(float(lowerQ4) - 0.5, 0.0) * 0.25;
}

float APL_LevelBinUpperNits(int levelBin)
{
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLevelBinBoundsQ4(levelBin, lowerQ4, upperQ4);
    return (float(upperQ4) + 0.5) * 0.25;
}

int APL_LevelBinOfPQ(float pq)
{
    return APL_HistogramLevelBin64(APL_QuantizeNitsQ4(PQToLinearScalar(pq) * 10000.0));
}

float APL_CurveCenterPQ(int levelBin)
{
    return 0.5 * (APL_CurveLowerPQ[levelBin] + APL_CurveUpperPQ[levelBin]);
}

// Slope at pq, which lies between levelBin's center and a neighbor's.
float APL_CurveSlopeAt(float pq, int levelBin)
{
    float center = APL_CurveCenterPQ(levelBin);
    int neighbor = (pq < center) ? APL_PreviousRealLevelBin(levelBin) : APL_NextRealLevelBin(levelBin);

    float slope = APL_CurveSlope[levelBin];
    if (neighbor >= 0 && neighbor <= APL_TOP_LEVEL_BIN)
        slope = lerp(slope, APL_CurveSlope[neighbor], (pq - center) / (APL_CurveCenterPQ(neighbor) - center));

    return slope;
}

// Slope integral from the bin's lower edge up to pq.
float APL_CurveIntegralInBin(int levelBin, float pq)
{
    float lower = APL_CurveLowerPQ[levelBin];
    float center = APL_CurveCenterPQ(levelBin);
    float lowerSlope = APL_CurveSlopeAt(lower, levelBin);
    float pqSlope = APL_CurveSlopeAt(pq, levelBin);

    if (pq <= center)
        return 0.5 * (pq - lower) * (lowerSlope + pqSlope);

    float centerSlope = APL_CurveSlope[levelBin];
    return 0.5 * (center - lower) * (lowerSlope + centerSlope) + 0.5 * (pq - center) * (centerSlope + pqSlope);
}

// Slope integral from pq up to the top.
float APL_CurveIntegralAbove(float pq)
{
    int levelBin = APL_LevelBinOfPQ(pq);
    return APL_CurveAbove[levelBin] - APL_CurveIntegralInBin(levelBin, pq);
}

// Integral of slope times a ramp rising from 0 at bendStart to 1 one bend width up, from
// bendStart to pq. Both are linear between bin centers, so Simpson's rule is exact.
float APL_CurveRampIntegral(float bendStart, float bendWidth, float pq)
{
    float total = 0.0;
    float pieceStart = bendStart;

    [loop]
    for (int piece = 0; piece < APL_BEND_MAX_PIECES && pieceStart < pq; ++piece)
    {
        int levelBin = APL_LevelBinOfPQ(pieceStart);
        int nextBin = APL_NextRealLevelBin(levelBin);
        float center = APL_CurveCenterPQ(levelBin);
        float breakPQ = pq;

        if (pieceStart < center)
            breakPQ = center;
        else if (nextBin <= APL_TOP_LEVEL_BIN)
            breakPQ = APL_CurveCenterPQ(nextBin);

        float pieceEnd = min(breakPQ, pq);
        float pieceMid = 0.5 * (pieceStart + pieceEnd);
        float startValue = (pieceStart - bendStart) * APL_CurveSlopeAt(pieceStart, levelBin);
        float midValue = (pieceMid - bendStart) * APL_CurveSlopeAt(pieceMid, levelBin);
        float endValue = (pieceEnd - bendStart) * APL_CurveSlopeAt(pieceEnd, levelBin);

        total += (pieceEnd - pieceStart) * (startValue + 4.0 * midValue + endValue) / 6.0;
        pieceStart = pieceEnd;
    }

    return (bendWidth > 0.0) ? total / bendWidth : 0.0;
}

// The knee bends over a quarter octave, about one histogram bin, and never less than at 1 nit.
// It never spans more than the gain lowered the ceiling, so an unboosted frame keeps the panel's own clip.
float APL_BendWidthPQ(float kneePQ, float ceilingPQ)
{
    float kneeNits = max(PQToLinearScalar(kneePQ) * 10000.0, 1.0);
    float halfWidth = exp2(0.125);
    float quarterOctavePQ = NitsToPQ(kneeNits * halfWidth) - NitsToPQ(kneeNits / halfWidth);
    return min(quarterOctavePQ, NitsToPQ(PANEL_PEAK_NITS) - ceilingPQ);
}

// Bent curve minus top-down curve where the bend ends. It grows with the knee and is 0 at the right one.
float APL_KneeMismatch(float kneePQ, float ceilingPQ)
{
    float bendWidth = APL_BendWidthPQ(kneePQ, ceilingPQ);
    float bendStart = kneePQ - 0.5 * bendWidth;
    float bendEnd = bendStart + bendWidth;
    float bentEndPQ = kneePQ + APL_CurveRampIntegral(bendStart, bendWidth, bendEnd);
    return bentEndPQ - (ceilingPQ - APL_CurveIntegralAbove(bendEnd));
}

float APL_SolveKneePQ(float ceilingPQ)
{
    float2 range = float2(0.0, ceilingPQ);

    [loop]
    for (int step = 0; step < APL_KNEE_SOLVE_STEPS; ++step)
    {
        float midPQ = 0.5 * (range.x + range.y);
        range = (APL_KneeMismatch(midPQ, ceilingPQ) < 0.0) ? float2(midPQ, range.y) : float2(range.x, midPQ);
    }

    return 0.5 * (range.x + range.y);
}

// Source below the bend, the top-down curve above it, and a slope easing from 1 to the curve's across it.
float APL_EvaluateToneCurvePQ(float pq, float bendStart, float bendWidth, float ceilingPQ)
{
    if (pq <= bendStart)
        return pq;

    if (pq >= bendStart + bendWidth)
        return ceilingPQ - APL_CurveIntegralAbove(pq);

    float bendOffset = pq - bendStart;
    return pq - bendOffset * bendOffset / (2.0 * bendWidth) + APL_CurveRampIntegral(bendStart, bendWidth, pq);
}

groupshared float2 APL_EvalSum[APL_FFH_MAX_BINS];
groupshared float APL_EvalBinCount[APL_FFH_MAX_BINS];
groupshared float2 APL_SolveLogGainRange;

// Sums APL_EvalSum over the group. Every thread calls it and gets the total.
float2 APL_ReduceEvalSum(int localIndex)
{
    barrier();

    [unroll]
    for (int stride = APL_FFH_MAX_BINS / 2; stride > 0; stride /= 2)
    {
        if (localIndex < stride)
            APL_EvalSum[localIndex] += APL_EvalSum[localIndex + stride];
        barrier();
    }

    return APL_EvalSum[0];
}

float APL_LevelBinPixelCount(int levelBin)
{
    int first = levelBin * APL_FFH_SUB_BINS;
    return APL_EvalBinCount[first] + APL_EvalBinCount[first + 1] + APL_EvalBinCount[first + 2] + APL_EvalBinCount[first + 3];
}

// Builds the tone curve for one gain in groupshared and returns the boosted frame's summed luma
// and the detail it keeps: each lit level bin's pixels times the share of its PQ width the
// curve keeps, counting only the part of the bin the panel can show at all.
// Each thread brings its own histogram bin and, below APL_FFH_LEVEL_BINS, its own level bin.
// Bins are mapped without the knee bend, which moves the load by a fraction of a percent.
float2 APL_SumBoostedFrame(int localIndex, float logGain, float binCount, float meanLevelNits, float meanLevelPQ, float lumaSumNits)
{
    float gain = exp2(logGain);
    float ceilingPQ = NitsToPQ(PANEL_PEAK_NITS / gain);
    float shoulderStartPQ = APL_ShoulderStartPQ(ceilingPQ);

    // A bin straddling the shoulder start counts with the part of it above.
    float shoulderCount = 0.0;
    float widthPQ = 1.0;
    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        widthPQ = APL_CurveUpperPQ[localIndex] - APL_CurveLowerPQ[localIndex];
        float shareAbove = saturate((APL_CurveUpperPQ[localIndex] - shoulderStartPQ) / widthPQ);
        shoulderCount = APL_IsRealLevelBin(localIndex) ? shareAbove * APL_LevelBinPixelCount(localIndex) : 0.0;
    }

    APL_EvalSum[localIndex] = float2(shoulderCount, 0.0);
    float shoulderTotal = max(APL_ReduceEvalSum(localIndex).x, 1.0);

    if (localIndex < APL_FFH_LEVEL_BINS)
        APL_CurveSlope[localIndex] = min((ceilingPQ - shoulderStartPQ) * shoulderCount / shoulderTotal / widthPQ, 1.0);
    barrier();

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        APL_CurveBinIntegral[localIndex] = APL_IsRealLevelBin(localIndex)
            ? APL_CurveIntegralInBin(localIndex, APL_CurveUpperPQ[localIndex])
            : 0.0;
    }
    barrier();

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        float above = 0.0;

        [loop]
        for (int levelBin = localIndex; levelBin < APL_FFH_LEVEL_BINS; ++levelBin)
            above += APL_CurveBinIntegral[levelBin];

        APL_CurveAbove[localIndex] = above;
    }
    barrier();

    float boostedNits = 0.0;
    if (meanLevelNits > 1e-6)
    {
        int levelBin = localIndex / APL_FFH_SUB_BINS;
        float topDownPQ = ceilingPQ - (APL_CurveAbove[levelBin] - APL_CurveIntegralInBin(levelBin, meanLevelPQ));
        float shownNits = PQToLinearScalar(min(meanLevelPQ, topDownPQ)) * 10000.0;
        boostedNits = gain * shownNits / meanLevelNits * lumaSumNits;
    }

    float keptDetail = 0.0;
    if (localIndex > 0 && localIndex < APL_FFH_LEVEL_BINS && APL_IsRealLevelBin(localIndex))
    {
        float lowerPQ = APL_CurveLowerPQ[localIndex];
        float upperPQ = APL_CurveUpperPQ[localIndex];
        float shownLowerPQ = min(lowerPQ, ceilingPQ - APL_CurveAbove[localIndex]);
        float shownUpperPQ = min(upperPQ, ceilingPQ - (APL_CurveAbove[localIndex] - APL_CurveBinIntegral[localIndex]));
        float visibleShare = saturate((NitsToPQ(PANEL_PEAK_NITS) - lowerPQ) / widthPQ);
        keptDetail = APL_LevelBinPixelCount(localIndex) * min((shownUpperPQ - shownLowerPQ) / widthPQ, visibleShare);
    }

    APL_EvalSum[localIndex] = float2(boostedNits, keptDetail);
    return APL_ReduceEvalSum(localIndex);
}

// Shown mean luminance times kept detail, in log, so 1% of brightness weighs as much as 1% of detail.
float APL_GainScore(float2 frame, float fullLoadNitsSum)
{
    float loadPercent = 100.0 * frame.x / fullLoadNitsSum;
    return log(max(loadPercent, 1e-6)) - log(LookupMeasuredComp1D(loadPercent)) + log(max(frame.y, 1e-6));
}

// Scores gains from 1 up to full compensation on a grid and takes the vertex of the parabola
// through the best point and its neighbors, so the pick moves smoothly as the frame changes.
float APL_PickLogGain(int localIndex, float fullLogGain, float binCount, float meanLevelNits, float meanLevelPQ, float lumaSumNits, float fullLoadNitsSum)
{
    float scores[APL_GAIN_PICK_POINTS];
    float spacing = fullLogGain / float(APL_GAIN_PICK_POINTS - 1);

    [loop]
    for (int gridIndex = 0; gridIndex < APL_GAIN_PICK_POINTS; ++gridIndex)
    {
        float2 frame = APL_SumBoostedFrame(localIndex, spacing * float(gridIndex), binCount, meanLevelNits, meanLevelPQ, lumaSumNits);
        scores[gridIndex] = APL_GainScore(frame, fullLoadNitsSum);
    }

    int best = 0;

    [loop]
    for (int candidate = 1; candidate < APL_GAIN_PICK_POINTS; ++candidate)
        best = (scores[candidate] > scores[best]) ? candidate : best;

    int center = clamp(best, 1, APL_GAIN_PICK_POINTS - 2);
    float below = scores[center - 1];
    float above = scores[center + 1];
    float curvature = below - 2.0 * scores[center] + above;
    float offset = (curvature < 0.0) ? 0.5 * (below - above) / curvature : float(best - center);

    return clamp(spacing * (float(center) + offset), max(spacing * float(best - 1), 0.0), min(spacing * float(best + 1), fullLogGain));
}

[shader("compute")]
// Pass 4: solve full compensation, pick the gain up to it, smooth it, and build its tone curve.
void CS_SolveGainAndToneCurve(uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);

    float binCount = 0.0;
    float meanLevelNits = 0.0;
    float lumaSumNits = 0.0;

    if (aplActive)
    {
        int2 binCoord = APL_HistogramBlockCoord(localIndex);
        binCount = float(tex2Dfetch(SamplerAPLGlobalHistCount, binCoord));
        if (binCount > 0.0)
        {
            float offsetSum10 = tex2Dfetch(SamplerAPLGlobalHistOffset10, binCoord);
            float lumaRatioSum10 = tex2Dfetch(SamplerAPLGlobalHistLumaRatio10, binCoord);
            meanLevelNits = APL_ReconstructMeanLevelQ4(localIndex, binCount, offsetSum10) * 0.25;
            lumaSumNits = meanLevelNits * lumaRatioSum10 / APL_FFH_PACK_OFFSET_SCALE;
        }
    }

    float meanLevelPQ = NitsToPQ(meanLevelNits);

    // Raw load counts pixels past the panel peak as scaled down to it.
    APL_EvalBinCount[localIndex] = binCount;
    APL_EvalSum[localIndex] = float2(lumaSumNits * min(PANEL_PEAK_NITS / max(meanLevelNits, 1e-6), 1.0), binCount);
    float2 rawFrame = APL_ReduceEvalSum(localIndex);
    float fullLoadNitsSum = max(rawFrame.y * PANEL_PEAK_NITS, 1e-6);

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        APL_CurveLowerPQ[localIndex] = NitsToPQ(APL_LevelBinLowerNits(localIndex));
        APL_CurveUpperPQ[localIndex] = NitsToPQ(APL_LevelBinUpperNits(localIndex));
    }

    if (localIndex == 0)
        APL_SolveLogGainRange = float2(0.0, log2(COMP_APL_1D[COMP_APL_COUNT - 1]));
    barrier();

    [loop]
    for (int step = 0; step < APL_GAIN_SOLVE_STEPS; ++step)
    {
        float2 range = APL_SolveLogGainRange;
        float midLogGain = 0.5 * (range.x + range.y);
        float boostedNitsSum = APL_SumBoostedFrame(localIndex, midLogGain, binCount, meanLevelNits, meanLevelPQ, lumaSumNits).x;

        if (localIndex == 0)
        {
            float loadPercent = 100.0 * boostedNitsSum / fullLoadNitsSum;
            bool needsMoreGain = log2(LookupMeasuredComp1D(loadPercent)) > midLogGain;
            APL_SolveLogGainRange = needsMoreGain ? float2(midLogGain, range.y) : float2(range.x, midLogGain);
        }
        barrier();
    }

    float2 solvedRange = APL_SolveLogGainRange;
    float fullLogGain = 0.5 * (solvedRange.x + solvedRange.y);
    float pickedLogGain = APL_PickLogGain(localIndex, fullLogGain, binCount, meanLevelNits, meanLevelPQ, lumaSumNits, fullLoadNitsSum);

    float4 prevData = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0));
    float hasPrev = (prevData.b > 0.0) ? 1.0 : 0.0;
    float alpha = ComputeTemporalBlendFactor(TransitionSpeed);

    // Smoothing in log gain covers the same share of a brightness change both ways.
    float logGain = lerp(pickedLogGain, lerp(prevData.a, pickedLogGain, alpha), hasPrev);
    float boostedNitsSum = APL_SumBoostedFrame(localIndex, logGain, binCount, meanLevelNits, meanLevelPQ, lumaSumNits).x;

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        float4 curveBin = float4(APL_CurveSlope[localIndex], APL_CurveLowerPQ[localIndex], APL_CurveUpperPQ[localIndex], APL_CurveAbove[localIndex]);
        tex2Dstore(StorageToneCurve, int2(localIndex, 0), curveBin);
    }

    if (localIndex != 0)
        return;

    float ceilingPQ = NitsToPQ(PANEL_PEAK_NITS / exp2(logGain));
    float kneePQ = APL_SolveKneePQ(ceilingPQ);
    float bendWidth = APL_BendWidthPQ(kneePQ, ceilingPQ);
    float bendStart = kneePQ - 0.5 * bendWidth;

    // The lookup takes over at its last entry before the bend, so it continues the source exactly.
    float lookupStartPQ = floor(bendStart * (TONE_CURVE_LUT_SIZE - 1)) / (TONE_CURVE_LUT_SIZE - 1);
    float lookupStartNits = PQToLinearScalar(lookupStartPQ) * 10000.0;
    tex2Dstore(StorageToneCurveShape, int2(0, 0), float4(bendStart, bendWidth, ceilingPQ, lookupStartNits));

    if (!aplActive)
    {
        tex2Dstore(StorageAPLInstant, int2(0, 0), 0.0.xxxx);
        tex2Dstore(StorageAPL, int2(0, 0), 0.0.xxxx);
        return;
    }

    float exactRollingMaxNits = ShowOSD
        ? float(tex2Dfetch(SamplerAPLGlobalHistCount, APL_GlobalExactMaxLumaCoord())) * 0.25
        : 0.0;
    int nextRollingPhase = APL_GetNextRollingPhase(APL_DecodeStoredRollingPhase(prevData.g));
    float rawLoad = rawFrame.x / fullLoadNitsSum;
    float outLoad = boostedNitsSum / fullLoadNitsSum;

    tex2Dstore(
        StorageAPLInstant,
        int2(0, 0),
        float4(rawLoad, exactRollingMaxNits, float(nextRollingPhase), (rawFrame.y > 0.0) ? 1.0 : 0.0)
    );
    tex2Dstore(StorageAPL, int2(0, 0), float4(outLoad, outLoad, 1.0, logGain));
}

[shader("compute")]
// Pass 5: write the applied tone curve into the lookup the boost samples.
void CS_BuildToneCurveLookup(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        float4 curveBin = tex2Dfetch(SamplerToneCurve, int2(localIndex, 0));
        APL_CurveSlope[localIndex] = curveBin.x;
        APL_CurveLowerPQ[localIndex] = curveBin.y;
        APL_CurveUpperPQ[localIndex] = curveBin.z;
        APL_CurveAbove[localIndex] = curveBin.w;
    }
    barrier();

    if (!NeedsAPLProcessing())
        return;

    float4 shape = tex2Dfetch(SamplerToneCurveShape, int2(0, 0));

    [loop]
    for (int entry = localIndex; entry < TONE_CURVE_LUT_SIZE; entry += 256)
    {
        float inputPQ = float(entry) / float(TONE_CURVE_LUT_SIZE - 1);
        float shownPQ = APL_EvaluateToneCurvePQ(inputPQ, shape.x, shape.y, shape.z);
        tex2Dstore(StorageToneCurveLUT, int2(entry, 0), clamp(shownPQ, 0.0, shape.z));
    }
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


#define OSD_CHAR_SPACE -1
#define OSD_CHAR_A 0
#define OSD_CHAR_I 8
#define OSD_CHAR_L 11
#define OSD_CHAR_M 12
#define OSD_CHAR_N 13
#define OSD_CHAR_O 14
#define OSD_CHAR_P 15
#define OSD_CHAR_R 17
#define OSD_CHAR_S 18
#define OSD_CHAR_T 19
#define OSD_CHAR_U 20
#define OSD_CHAR_W 22
#define OSD_CHAR_X 23

float GetOSDLetter(int letter, float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    int pattern = 0;


    if (letter == OSD_CHAR_A) pattern = 11245;
    else if (letter == OSD_CHAR_I) pattern = 29847;
    else if (letter == OSD_CHAR_L) pattern = 4687;
    else if (letter == OSD_CHAR_M) pattern = 24557;
    else if (letter == OSD_CHAR_N) pattern = 24573;
    else if (letter == OSD_CHAR_O) pattern = 31599;
    else if (letter == OSD_CHAR_P) pattern = 15049;
    else if (letter == OSD_CHAR_R) pattern = 15085;
    else if (letter == OSD_CHAR_S) pattern = 29671;
    else if (letter == OSD_CHAR_T) pattern = 29842;
    else if (letter == OSD_CHAR_U) pattern = 23407;
    else if (letter == OSD_CHAR_W) pattern = 23421;
    else if (letter == OSD_CHAR_X) pattern = 23213;

    int x = int(uv.x * 3.0);
    int y = int((1.0 - uv.y) * 5.0);

    return (pattern >> (x + y * 3)) & 1;
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


float3 DrawStatsOverlay(float2 texcoord, float3 sceneColor, float rawInputAPL, float outputAPL, float maxSceneNits)
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
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
    float2 nitsRowRight = inputRowRight + float2(0.0, lineSpacing * 2.0);

    float valueLeft = inputRowRight.x - stepX * 5.0 - glyphWidth;
    float2 inputLabelTopLeft = float2(valueLeft - labelGap - labelTotalWidth, inputRowRight.y);
    float2 outputLabelTopLeft = inputLabelTopLeft + float2(0.0, lineSpacing);
    float2 nitsLabelTopLeft = inputLabelTopLeft + float2(0.0, lineSpacing * 2.0);

    float left = inputLabelTopLeft.x;
    float right = inputPercentRight.x;
    float top = inputRowRight.y;
    float bottom = nitsRowRight.y + scale;

    float padX = glyphWidth * 0.48;
    float padY = scale * 0.20;

    if (texcoord.x < left - padX || texcoord.x > right + padX || texcoord.y < top - padY || texcoord.y > bottom + padY)
        return sceneColor;

    int nitDisplay = clamp(int(floor(max(maxSceneNits, 0.0) + 0.5)), 0, 99999);

    float bgMask = (texcoord.x >= left - padX && texcoord.x <= right + padX && texcoord.y >= top - padY && texcoord.y <= bottom + padY) ? 1.0 : 0.0;

    float rawLabelMask = DrawOSDLabel8(texcoord, inputLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_R, OSD_CHAR_A, OSD_CHAR_W, OSD_CHAR_SPACE, OSD_CHAR_A, OSD_CHAR_P, OSD_CHAR_L, OSD_CHAR_SPACE);
    float outputLabelMask = DrawOSDLabel8(texcoord, outputLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_O, OSD_CHAR_U, OSD_CHAR_T, OSD_CHAR_SPACE, OSD_CHAR_A, OSD_CHAR_P, OSD_CHAR_L, OSD_CHAR_SPACE);
    float nitsLabelMask = DrawOSDLabel8(texcoord, nitsLabelTopLeft, labelScale, labelStepX, aspect, OSD_CHAR_R, OSD_CHAR_A, OSD_CHAR_W, OSD_CHAR_SPACE, OSD_CHAR_N, OSD_CHAR_I, OSD_CHAR_T, OSD_CHAR_S);

    float inputMask = 0.0;
    inputMask += DrawOSDAPLPercent2(texcoord, inputRowRight, scale, stepX, aspect, rawInputAPL);
    inputMask += DrawOSDPercentAt(texcoord, inputPercentRight, scale, aspect);
    inputMask = saturate(inputMask);

    float outputMask = 0.0;
    outputMask += DrawOSDAPLPercent2(texcoord, outputRowRight, scale, stepX, aspect, outputAPL);
    outputMask += DrawOSDPercentAt(texcoord, outputPercentRight, scale, aspect);
    outputMask = saturate(outputMask);

    float nitsMask = DrawOSDRow5(texcoord, nitsRowRight, scale, stepX, aspect, nitDisplay);

    float bgAlpha = 0.18 * OSDBrightness * bgMask;
    float3 shadedScene = sceneColor * (1.0 - bgAlpha);

    float3 inputColor = float3(0.30, 1.00, 0.30) * OSDBrightness;
    float3 outputColor = float3(1.00, 0.90, 0.18) * OSDBrightness;
    float3 nitsColor = float3(0.60, 0.85, 1.00) * OSDBrightness;

    float3 result = shadedScene;
    result = lerp(result, inputColor, saturate(rawLabelMask + inputMask));
    result = lerp(result, outputColor, saturate(outputLabelMask + outputMask));
    result = lerp(result, nitsColor, saturate(nitsLabelMask + nitsMask));

    return result;
}


// Shown brightest channel under the applied tone curve, before the gain.
float ComputeShownLevelNits(float levelNits)
{
    float4 shape = tex2Dlod(SamplerToneCurveShape, float4(0.5, 0.5, 0.0, 0.0));

    if (levelNits <= shape.w)
        return levelNits;

    float lutCoord = (NitsToPQ(levelNits) * (TONE_CURVE_LUT_SIZE - 1) + 0.5) / TONE_CURVE_LUT_SIZE;
    float shownPQ = tex2Dlod(SamplerToneCurveLUT, float4(lutCoord, 0.5, 0.0, 0.0)).r;
    return PQToLinearScalar(shownPQ) * 10000.0;
}

// Scales the color by gain times the tone curve's shown brightest channel over its own, keeping its channel ratios.
float3 ApplyBoost(float3 color)
{
    float3 colorNits = DecodeBufferToRec2020Nits(color);
    float levelNits = Max3(max(colorNits, 0.0));

    if (levelNits <= 1e-6)
        return color;

    float gain = exp2(tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0)).a);
    float scale = gain * ComputeShownLevelNits(levelNits) / levelNits;

    if (scale == 1.0)
        return color;

#if BUFFER_COLOR_SPACE == 2
    return color * scale;
#else
    return LinearToPQBT2100(colorNits * (scale / 10000.0));
#endif
}


// Pass 6: apply the boost, optional LUT, OSD, and graph.
float4 PS_MainPass(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;

    if (EnableEOTFBoost)
        color = ApplyBoost(color);

#if PQHDRLUT_ENABLE

    // The calibration LUT operates on the final boosted signal.
    if (EnablePQHDRLUT)
        color = PQHDRLUT_Apply(color);
#endif

    if (EnableEOTFBoost && ShowOSD)
    {
        float4 instantData = tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0));
        float outLoad = tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0)).g;
        color = DrawStatsOverlay(
            texcoord,
            color,
            saturate(instantData.r),
            saturate(outLoad),
            max(instantData.g, 0.0)
        );
    }

#if ENABLE_APL_GRAPH
    if (ShowAPLGraph)
        color = DrawAPLGraphOverlay(texcoord, color);
#endif

    return float4(color, 1.0);
}

#if ENABLE_APL_GRAPH


// Graph params: out load %, max measured nits at it, axis max PQ, raw load %.
float4 PS_CalcGraphParams(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return 0.0.xxxx;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float graphAxisMaxPQ = GraphUsePQSpace ? max(NitsToPQ(graphAxisMaxNits), 1e-6) : 0.0;
    float rawLoadPercent = saturate(tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0)).r) * 100.0;
    float outLoadPercent = saturate(tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0)).g) * 100.0;

    return float4(outLoadPercent, GetAPLMaxMeasuredNits(outLoadPercent), graphAxisMaxPQ, rawLoadPercent);
}


// Graph pass: live remapped signal and predicted output at each x sample.
float4 PS_CalcGraphProjection(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return 0.0.xxxx;

    int sampleIndex = min(int(vpos.x), GRAPH_CURVE_SAMPLES - 1);
    float t = float(sampleIndex) / float(GRAPH_CURVE_SAMPLES - 1);

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float graphAxisMaxPQ = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;
    float inputNits = GraphSampleNitsFromFraction(t, graphAxisMaxNits, graphAxisMaxPQ);
    float limitedInputNits = ApplyGraphInputSignalLimitNits(inputNits);

    float remappedSignalNits = limitedInputNits;
    if (EnableEOTFBoost)
    {
        float gain = exp2(tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0)).a);
        remappedSignalNits = gain * ComputeShownLevelNits(limitedInputNits);
    }

    float outLoadPercent = graphParams.r;
    float predictedMeasuredOutputNits = SampleCorrectedOutputNitsForAPL(
        outLoadPercent,
        remappedSignalNits,
        max(graphParams.g, 0.0)
    );

    return float4(remappedSignalNits, predictedMeasuredOutputNits, outLoadPercent * 0.01, 1.0);
}


// Graph pass: build grid, tick, and identity-line segments.
float4 PS_CalcGraphLines(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    if (!ShowAPLGraph)
        return float4(-1.0, -1.0, -1.0, -1.0);

    int idx = int(vpos.x);

    float aspect       = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 graphPos    = float2(0.055 * aspect, 0.48);
    float2 graphSize   = float2(0.43  * aspect, 0.44);
    float  tickLen     = graphSize.y * 0.018;

    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);
    float4 graphParams     = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ  = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;

    float2 a = 0.0, b = 0.0;

    if (idx < 9) // Vertical grid lines.
    {
        int i = idx + 1;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, graphAxisMaxNits);
    }
    else if (idx < 18) // Horizontal grid lines.
    {
        int i = idx - 9 + 1;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 10.0, graphAxisMaxNits, graphAxisMaxPQ);
        a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, 0.0,           tickValue);
        b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, graphAxisMaxNits, tickValue);
    }
    else if (idx < 24) // X-axis ticks.
    {
        int i = idx - 18;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
        float2 xTick = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, tickValue, 0.0);
        a = xTick + float2(0.0, -tickLen);
        b = xTick;
    }
    else if (idx < 30) // Y-axis ticks.
    {
        int i = idx - 24;
        float tickValue = GraphTickValueFromFractionWithPQMax(float(i) / 5.0, graphAxisMaxNits, graphAxisMaxPQ);
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


    float aspect       = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 graphPos    = float2(0.055 * aspect, 0.48);
    float2 graphSize   = float2(0.43  * aspect, 0.44);
    float graphAxisMaxNits = clamp(GraphAxisMaxNits, 1.0, 10000.0);

    float4 graphParams               = tex2Dlod(SamplerGraphParams, float4(0.5, 0.5, 0.0, 0.0));
    float  graphAxisMaxPQ            = GraphUsePQSpace ? max(graphParams.b, 1e-6) : 0.0;
    float  graphRawLoadPercent       = graphParams.a;


    float t0 = float(s)     / float(GRAPH_CURVE_SAMPLES - 1);
    float t1 = float(s + 1) / float(GRAPH_CURVE_SAMPLES - 1);
    float x0 = GraphSampleNitsFromFraction(t0, graphAxisMaxNits, graphAxisMaxPQ);
    float x1 = GraphSampleNitsFromFraction(t1, graphAxisMaxNits, graphAxisMaxPQ);

    float4 result = SENTINEL;


    static const float invGraphSamples = 1.0 / float(GRAPH_CURVE_SAMPLES);
    float4 graphProjection0 = 0.0.xxxx;
    float4 graphProjection1 = 0.0.xxxx;

    if (row <= GCURVE_CORRECTED)
    {
        graphProjection0 = tex2Dlod(
            SamplerGraphProjection,
            float4((float(s) + 0.5) * invGraphSamples, 0.5, 0.0, 0.0)
        );
        graphProjection1 = tex2Dlod(
            SamplerGraphProjection,
            float4((float(s + 1) + 0.5) * invGraphSamples, 0.5, 0.0, 0.0)
        );
    }

    if (row == GCURVE_REMAPPED)
    {

        float y0 = graphProjection0.r;
        float y1 = graphProjection1.r;

        if (graphProjection0.a > 0.0 && graphProjection1.a > 0.0)
        {
            float2 a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    else if (row == GCURVE_CORRECTED)
    {

        float y0;
        float y1;

        y0 = graphProjection0.g;
        y1 = graphProjection1.g;

        if (graphProjection0.a > 0.0 && graphProjection1.a > 0.0)
        {
            float2 a = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0, y0);
            float2 b = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x1, y1);
            result = float4(a, b);
        }
    }
    else if (row == GCURVE_MEASURED)
    {

        float measuredMaxInputNits = GetGraphMeasuredMaxInputNits();

        if (x0 < measuredMaxInputNits)
        {
            float mx1 = min(x1, measuredMaxInputNits);
            float y0   = ComputeGraphCurveMeasuredRawOutputNits(graphRawLoadPercent, x0);
            float y1   = ComputeGraphCurveMeasuredRawOutputNits(graphRawLoadPercent, mx1);
            float2 a   = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, x0,  y0);
            float2 b   = ToGraphPointWithPQMax(graphPos, graphSize, graphAxisMaxNits, graphAxisMaxPQ, mx1, y1);
            result = float4(a, b);
        }
    }
    else
    {


        if (GraphShowBT2390Reference)
        {
            float ceilingNits = PANEL_PEAK_NITS / exp2(tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0)).a);
            float lx0 = ApplyGraphInputSignalLimitNits(x0);
            float lx1 = ApplyGraphInputSignalLimitNits(x1);
            float y0  = ComputeBT2390ReferenceOutputNits(lx0, graphAxisMaxNits, ceilingNits);
            float y1  = ComputeBT2390ReferenceOutputNits(lx1, graphAxisMaxNits, ceilingNits);
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
        ComputeShader = CS_SetupAndClearAPLFullFrameRowHistograms<256, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }


    pass APL_FullFrame_RowHistogramBuild
    {
        ComputeShader = CS_BuildAPLFullFrameRowHistogram<16, 16, 1>;
        DispatchSizeX = APL_FFH_TILE_COUNT_X;
        DispatchSizeY = APL_FFH_ROLLING_ROW_SLOTS;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }


    pass APL_FullFrame_RowHistogramReduce
    {
        ComputeShader = CS_ReduceAPLFullFrameRowHistogram<64, 1, 1>;
        DispatchSizeX = APL_FFH_BLOCK_W;
        DispatchSizeY = APL_FFH_BLOCK_H;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }


    pass APL_Gain_Solve_And_Tone_Curve
    {
        ComputeShader = CS_SolveGainAndToneCurve<256, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
        GenerateMipMaps = false;
    }


    pass Tone_Curve_Lookup
    {
        ComputeShader = CS_BuildToneCurveLookup<256, 1, 1>;
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
    
