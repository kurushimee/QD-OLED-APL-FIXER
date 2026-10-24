// EOTF Boost v8.18.7.15 (EOTF_BoostMod3.0.fx) for DWM.
//
// The shader's code is unchanged. Its uniforms are constants holding the settings below, and the
// features its preprocessor definitions turn off (the debug graph, the calibration LUT, tooltips) are
// left out. A shim maps ReShade's intrinsics and the back buffer onto plain D3D11, the back buffer
// being the hook's clean copy of the composed desktop.
//
// Live pipeline, one dispatch or draw each:
//   1  CS_SetupAndClearAPLFullFrameRowHistograms        frame setup and rolling-row clear
//   2  CS_BuildAPLFullFrameRowHistogram                 full-frame row histogram build
//   3  CS_ReduceAPLFullFrameRowHistogram                global histogram reduction
//   4  CS_EvaluateSolveAndSmoothAPLFullFrameHistogram   response solve, smoothing and boost parameters
//   5  PostProcessVS / PS_MainPass                      fullscreen boost

// Preprocessor definitions.
#define APL_FULLFRAME_ROLLING_PHASES  6
#define PER_APL_BOOST_STRENGTH_ENABLE 1

// Settings.
static const bool  EnableEOTFBoost              = true;
static const int   APLInputMode                 = 0;        // scRGB Normalized
static const float APLReferenceWhiteNits        = 150.0;
static const float CompensationFreezeAPLPercent = 80.0;
static const float MaxAPLBoostStrength          = 0.25;
static const bool  EnablePerAPLBoostStrength    = true;
static const float APLBoostStrength03           = 0.25;
static const float APLBoostStrength05           = 0.25;
static const float APLBoostStrength07           = 0.26;
static const float APLBoostStrength10           = 0.26;
static const float APLBoostStrength14           = 0.27;
static const float APLBoostStrength18           = 0.27;
static const float APLBoostStrength22           = 0.28;
static const float APLBoostStrength25           = 0.28;
static const float APLBoostStrength35           = 0.30;
static const float APLBoostStrength50           = 0.55;
static const float BoostRollOff                 = 800.0;
static const float BoostRollOffShape            = 1.20;
static const float TransitionSpeed              = 0.50;
static const bool  EnableColorPreservingBoostMode = true;
static const float COLOR_PRESERVING_BOOST_KNEE  = 0.85;
static const float SIGNAL_REFERENCE_NITS        = 150.0;
static const bool  ShowOSD                      = false;
static const float OSDBrightness                = 0.50;


// -------- ReShade shim --------

cbuffer EOTFBoostCB : register(b0)
{
    uint  BufferWidthPx;
    uint  BufferHeightPx;
    float FrameTime;        // ms since the last run, ReShade's "frametime" source
};

#define BUFFER_WIDTH  int(BufferWidthPx)
#define BUFFER_HEIGHT int(BufferHeightPx)

#define ScreenSize float2(BUFFER_WIDTH, BUFFER_HEIGHT)

// SRVs keep one slot across all passes. UAVs are bound per pass, and passes never share a slot's texture.
Texture2D<float4> BackBuffer                   : register(t0);
Texture2D<float4> SamplerAPL                   : register(t1);
Texture2D<float4> SamplerCandidateBoostParams  : register(t2);
Texture2D<float4> SamplerBoostParams           : register(t3);
Texture2D<float4> SamplerAPLInstant            : register(t4);
Texture2D<float4> SamplerAPLPrev               : register(t5);
Texture2D<float>  SamplerAPLFastPQNits         : register(t6);
Texture2D<int>    SamplerAPLRowHistCount       : register(t7);
Texture2D<int>    SamplerAPLRowHistOffset10    : register(t8);
Texture2D<int>    SamplerAPLRowHistMaxNits     : register(t9);
Texture2D<int>    SamplerAPLRowMeta            : register(t10);
Texture2D<int>    SamplerAPLGlobalHistCount    : register(t11);
Texture2D<float>  SamplerAPLGlobalHistOffset10 : register(t12);
Texture2D<float>  SamplerAPLGlobalHistMaxNits  : register(t13);

// Pass 1
RWTexture2D<float4> StorageCandidateBoostParams : register(u0);
RWTexture2D<float>  StorageAPLFastPQNits        : register(u1);
RWTexture2D<float4> StorageAPLPrev              : register(u2);

// Passes 1 and 2
RWTexture2D<int>    StorageAPLRowHistCount      : register(u3);
RWTexture2D<int>    StorageAPLRowHistOffset10   : register(u4);
RWTexture2D<int>    StorageAPLRowHistMaxNits    : register(u5);
RWTexture2D<int>    StorageAPLRowMeta           : register(u6);

// Pass 3
RWTexture2D<int>    StorageAPLGlobalHistCount    : register(u0);
RWTexture2D<float>  StorageAPLGlobalHistOffset10 : register(u1);
RWTexture2D<float>  StorageAPLGlobalHistMaxNits  : register(u2);

// Pass 4
RWTexture2D<float4> StorageAPLInstant           : register(u0);
RWTexture2D<float4> StorageAPL                  : register(u1);
RWTexture2D<float4> StorageBoostParams          : register(u2);

// The fast PQ table filters linearly, every other sampler reads texel centers.
SamplerState PointClamp  : register(s0);
SamplerState LinearClamp : register(s1);

float4 tex2D(Texture2D<float4> t, float2 uv)     { return t.SampleLevel(PointClamp, uv, 0.0); }
float4 tex2Dlod(Texture2D<float4> t, float4 uv)  { return t.SampleLevel(PointClamp, uv.xy, uv.w); }
float  tex2Dlod(Texture2D<float> t, float4 uv)   { return t.SampleLevel(LinearClamp, uv.xy, uv.w); }

int    tex2Dfetch(Texture2D<int> t, int2 c)      { return t.Load(int3(c, 0)); }
float  tex2Dfetch(Texture2D<float> t, int2 c)    { return t.Load(int3(c, 0)); }
float4 tex2Dfetch(Texture2D<float4> t, int2 c)   { return t.Load(int3(c, 0)); }

void tex2Dstore(RWTexture2D<int> t, int2 c, int v)       { t[c] = v; }
void tex2Dstore(RWTexture2D<float> t, int2 c, float v)   { t[c] = v; }
void tex2Dstore(RWTexture2D<float4> t, int2 c, float4 v) { t[c] = v; }

void atomicAdd(RWTexture2D<int> t, int2 c, int v) { InterlockedAdd(t[c], v); }
void atomicMax(RWTexture2D<int> t, int2 c, int v) { InterlockedMax(t[c], v); }

void barrier() { GroupMemoryBarrierWithGroupSync(); }

// ReShade.fxh's fullscreen triangle.
void PostProcessVS(in uint id : SV_VertexID, out float4 position : SV_Position, out float2 texcoord : TEXCOORD)
{
    texcoord.x = (id == 2) ? 2.0 : 0.0;
    texcoord.y = (id == 1) ? 2.0 : 0.0;
    position = float4(texcoord * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}


// -------- EOTF_BoostMod3.0.fx --------

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
#define APL_FFH_AUX_X                  APL_FFH_BLOCK_W
#define APL_FFH_REDUCE_THREADS         64


// Packed value: pixel count in the upper bits and summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT       20
#define APL_FFH_PACK_OFFSET_MASK       ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE      1023
#define APL_FFH_PACK_ONE_COUNT         (1 << APL_FFH_PACK_COUNT_SHIFT)

#define APL_FFH_TILE_COUNT_X ((BUFFER_WIDTH  + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)
#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)


// 0 refreshes all rows each frame. N refreshes one of N interleaved row phases.
#if APL_FULLFRAME_ROLLING_PHASES > 0
    #define APL_FFH_ROLLING_ROW_SLOTS ((APL_FFH_TILE_COUNT_Y + APL_FULLFRAME_ROLLING_PHASES - 1) / APL_FULLFRAME_ROLLING_PHASES)


    // Metadata stores a runtime signature and the completed row pixel count.
    #define APL_FFH_ROW_META_COUNT_BITS 20
    #define APL_FFH_ROW_META_COUNT_MASK ((1 << APL_FFH_ROW_META_COUNT_BITS) - 1)
#else
    #define APL_FFH_ROLLING_ROW_SLOTS APL_FFH_TILE_COUNT_Y
#endif

#if (APL_FFH_THREADS_X * APL_FFH_PIXELS_X != APL_FFH_TILE_SIZE) || (APL_FFH_THREADS_Y * APL_FFH_PIXELS_Y != APL_FFH_TILE_SIZE)
    #error "Full-frame APL histogram tile/thread dimensions are inconsistent"
#endif
#if (APL_FFH_BLOCK_W * APL_FFH_BLOCK_H != APL_FFH_MAX_BINS)
    #error "Full-frame APL histogram block dimensions do not match maximum bin count"
#endif
#if (APL_FFH_COLOR_LUMA_BINS * APL_FFH_COLOR_RATIO_BINS != APL_FFH_MAX_BINS)
    #error "Color-preserving full-frame APL histogram dimensions are inconsistent"
#endif

float GetLuma709(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

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

bool NeedsAPLProcessing()
{
    return EnableEOTFBoost;
}



// PQ-space highlight roll-off.
static const float PQ_BLACK = 7.309559025783966e-07;


float ComputeBT2390ShapedKneeStart(float maxLum, float shapeControl)
{
    float standardKneeStart = saturate(1.5 * maxLum - 0.5);


    if (abs(shapeControl - 1.0) <= 1e-4)
        return standardKneeStart;

    float safeShapeControl = max(shapeControl, 1e-4);
    float shapeBias = log2(safeShapeControl);

    if (shapeBias > 0.0)
    {
        float hardT = saturate(shapeBias * 0.5);
        float aggressiveKneeStart = standardKneeStart * 0.15;
        return saturate(lerp(standardKneeStart, aggressiveKneeStart, hardT));
    }

    if (shapeBias < 0.0)
    {
        float softT = saturate(-shapeBias * 0.5);
        float softerKneeStart = standardKneeStart + (maxLum - standardKneeStart) * 0.85;
        return min(lerp(standardKneeStart, softerKneeStart, softT), maxLum - 1e-6);
    }

    return standardKneeStart;
}



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

// Measured APL data used by the optional graph and per-APL controls.
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


// Dense live compensation table. Values correspond to COMP_APL_POINTS.
static const int COMP_APL_COUNT = 10;

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
    50.000000
};

// Representative 1D compensation values for the 8 APL anchors above.
// These values are taken/approximated from the original denser tables so the
// reduced table preserves the overall shape of the compensation curve.
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
    3.345667  // 50%
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

float ApplyCompensationFreezeAPL(float aplPct)
{
    float freezeAPL = CompensationFreezeAPLPercent;
    if (freezeAPL > 0.0)
        aplPct = min(aplPct, freezeAPL);

    return aplPct;
}

float LookupMeasuredComp1D(float aplPct)
{
    float lookupAPL = ApplyCompensationFreezeAPL(aplPct);
    float clampedAPL = clamp(lookupAPL, COMP_APL_POINTS[0], COMP_APL_POINTS[COMP_APL_COUNT - 1]);
    int a0 = FindCompAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, COMP_APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        COMP_APL_POINTS[a0], COMP_APL_1D[a0],
        COMP_APL_POINTS[a1], COMP_APL_1D[a1]
    );
}

#if PER_APL_BOOST_STRENGTH_ENABLE
float GetPerAPLBoostStrengthAtIndex(int idx)
{
    if (idx == 0) return APLBoostStrength03;
    if (idx == 1) return APLBoostStrength05;
    if (idx == 2) return APLBoostStrength07;
    if (idx == 3) return APLBoostStrength10;
    if (idx == 4) return APLBoostStrength14;
    if (idx == 5) return APLBoostStrength18;
    if (idx == 6) return APLBoostStrength22;
    if (idx == 7) return APLBoostStrength25;
    if (idx == 8) return APLBoostStrength35;
    return APLBoostStrength50;
}

float LookupPerAPLBoostStrength(float aplPct)
{
    if (!EnablePerAPLBoostStrength)
        return MaxAPLBoostStrength;

    float clampedAPL = clamp(aplPct, GRAPH_APL_POINTS[0], GRAPH_APL_POINTS[GRAPH_APL_COUNT - 1]);
    int a0 = FindGraphAPLIndex(clampedAPL);
    int a1 = min(a0 + 1, GRAPH_APL_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        GRAPH_APL_POINTS[a0], GetPerAPLBoostStrengthAtIndex(a0),
        GRAPH_APL_POINTS[a1], GetPerAPLBoostStrengthAtIndex(a1)
    );
}
#endif

float ComputeTemporalBlendFactor(float smoothingSeconds)
{
    if (smoothingSeconds <= 1e-6)
        return 1.0;

    float dtSeconds = max(FrameTime, 0.0) * 0.001;
    return saturate(1.0 - exp(-dtSeconds / max(smoothingSeconds, 1e-6)));
}


float ComputeSceneBoostStrength(float currentAPL)
{
#if PER_APL_BOOST_STRENGTH_ENABLE
    float aplPct = saturate(currentAPL) * 100.0;
    float boostStrength = LookupPerAPLBoostStrength(aplPct);
#else
    float boostStrength = MaxAPLBoostStrength;
#endif
    return max(boostStrength, 0.0);
}


float ComputeSceneLogGainFromMeasuredComp(float measuredComp, float currentAPL)
{
    float safeMeasuredComp = max(measuredComp, 1.0);
    return log2(safeMeasuredComp) * ComputeSceneBoostStrength(currentAPL);
}

float ComputeSceneLogGainFromAPL(float currentAPL)
{
    float aplPct = saturate(currentAPL) * 100.0;
    float measuredComp = max(LookupMeasuredComp1D(aplPct), 1.0);
    return ComputeSceneLogGainFromMeasuredComp(measuredComp, currentAPL);
}


// Upper bound for the closed-loop gain search.
float ComputeCandidateMaxLogGain()
{
    float maxComp = max(LookupMeasuredComp1D(COMP_APL_POINTS[COMP_APL_COUNT - 1]), 1.0);
    float maxStrength = MaxAPLBoostStrength;

#if PER_APL_BOOST_STRENGTH_ENABLE
    if (EnablePerAPLBoostStrength)
    {
        maxStrength = 0.0;
        [unroll]
        for (int j = 0; j < GRAPH_APL_COUNT; ++j)
            maxStrength = max(maxStrength, GetPerAPLBoostStrengthAtIndex(j));
    }
#endif

    return max(log2(maxComp) * max(maxStrength, 0.0), 0.0);
}


float ComputeRollOffAnchorBoostedNitsFromSceneLogGain(float sceneLogGain)
{
    float rollOffEndNits = max(BoostRollOff, 0.0);

    if (rollOffEndNits <= 0.0)
        return 0.0;

    float referenceInputNits = max(rollOffEndNits, 1e-4);
    return referenceInputNits * exp2(sceneLogGain);
}


// Build scene-uniform gain and roll-off parameters.
float4 ComputeBoostRolloffParamsFromSceneLogGain(float sceneLogGain)
{
    if (sceneLogGain <= 1e-6)
        return float4(1.0, 0.0, 1.0, 0.0);

    float sceneGain = exp2(sceneLogGain);
    float rollOffEndNits = max(BoostRollOff, 0.0);
    float anchorBoostedNits = ComputeRollOffAnchorBoostedNitsFromSceneLogGain(sceneLogGain);

    if (rollOffEndNits <= 0.0)
        return float4(sceneGain, 0.0, 1.0, 0.0);

    float sourcePeakNits = max(anchorBoostedNits, rollOffEndNits + 1e-4);
    float sourceWhitePQ = max(NitsToPQ(sourcePeakNits), PQ_BLACK + 1e-6);
    float targetWhitePQ = min(NitsToPQ(rollOffEndNits), sourceWhitePQ - 1e-6);

    float pqRange = max(sourceWhitePQ - PQ_BLACK, 1e-6);
    float maxLum = saturate((targetWhitePQ - PQ_BLACK) / pqRange);

    if (maxLum >= 1.0 - 1e-6)
        return float4(sceneGain, 0.0, 1.0, 0.0);

    float kneeStart = ComputeBT2390ShapedKneeStart(maxLum, BoostRollOffShape);
    float compressionSpan = max(maxLum - kneeStart, 1e-6);

    return float4(sceneGain, pqRange, kneeStart, compressionSpan);
}

float4 LoadCandidateBoostParams(int candidateIndex)
{
    int idx = clamp(candidateIndex, 1, 3);
    float u = (float(idx) - 0.5) / 3.0;
    return tex2Dlod(SamplerCandidateBoostParams, float4(u, 0.5, 0.0, 0.0));
}

// Apply roll-off only to added boost; source luminance is preserved.
float ApplyBT2390EETFToNitsWithPrecomputedParams(float inputNits, float4 boostParams)
{
    float safeInputNits = max(inputNits, 0.0);
    float pqRange = boostParams.g;

    if (pqRange <= 0.0)
        return safeInputNits;

    float inputPQ = NitsToPQ(safeInputNits);
    float kneeStart = saturate(boostParams.b);
    float e1 = saturate((inputPQ - PQ_BLACK) / pqRange);


    if (e1 < kneeStart)
        return safeInputNits;

    float shoulderSpan = max(1.0 - kneeStart, 1e-6);
    float compressionSpan = max(boostParams.a, 1e-6);
    float u = saturate((e1 - kneeStart) / shoulderSpan);
    float shoulderPower = max(shoulderSpan / compressionSpan, 1.0);
    float e2 = kneeStart + compressionSpan * (1.0 - pow(1.0 - u, shoulderPower));
    float outputPQ = saturate(e2 * pqRange + PQ_BLACK);

    return max(PQToLinearScalar(outputPQ) * 10000.0, 0.0);
}

float ComputeBoostedLumaNitsFromPrecomputedParams(float inputLumaNits, float4 boostParams)
{

    float safeInputLumaNits = max(inputLumaNits, 0.0);
    float fullyBoostedNits = safeInputLumaNits * max(boostParams.r, 0.0);

    if (boostParams.g <= 0.0)
        return fullyBoostedNits;

    return max(ApplyBT2390EETFToNitsWithPrecomputedParams(fullyBoostedNits, boostParams), safeInputLumaNits);
}

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}

// Compute channel headroom for ratio-preserving boost.
float ComputeMaxHuePreservingScale(float3 rgb, float channelLimit)
{
    float maxChannel = Max3(rgb);

    if (maxChannel <= 1e-6)
        return 1.0;

    return max(channelLimit / maxChannel, 0.0);
}

float SoftLimitBoostScale(float desiredScale, float maxScale, float kneeFraction)
{


    // The limiter only removes added gain.
    float safeDesired = max(desiredScale, 1.0);
    float safeMax = max(maxScale, 1.0);

    if (safeDesired <= 1.0 || safeMax <= 1.0 + 1e-6)
        return 1.0;

    float kneeStart = lerp(1.0, safeMax, saturate(kneeFraction));

    if (safeDesired <= kneeStart)
        return safeDesired;

    float span = max(safeMax - kneeStart, 1e-6);
    float x = (safeDesired - kneeStart) / span;

    return min(kneeStart + span * (x / (1.0 + x)), safeMax);
}

float3 ApplyBoostPreserveColorFromPrecomputedParams(float3 color, float4 boostParams)
{
    if (boostParams.r <= 1.000001 && boostParams.g <= 0.0)
        return color;

    if (APLInputMode == 1)
    {
        float3 linearColorNits = PQToLinearBT2100(saturate(color)) * 10000.0;
        float originalLumaNits = max(GetLuma2020(linearColorNits), 0.0);

        if (originalLumaNits <= 1e-6)
            return color;

        float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(originalLumaNits, boostParams);
        float colorScale = boostedLumaNits / originalLumaNits;

        if (EnableColorPreservingBoostMode)
        {


            float outputChannelLimitNits = (BoostRollOff > 0.0) ? clamp(BoostRollOff, 1.0, 10000.0) : 10000.0;
            float maxHuePreservingScale = ComputeMaxHuePreservingScale(linearColorNits, outputChannelLimitNits);
            colorScale = SoftLimitBoostScale(colorScale, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
        }

        float3 boostedColorNits = linearColorNits * colorScale;

        return LinearToPQBT2100(saturate(max(boostedColorNits, 0.0) / 10000.0));
    }

    float3 linearColor = color;


    float originalLumaNits = max(GetLuma709(linearColor) * SIGNAL_REFERENCE_NITS, 0.0);

    if (originalLumaNits <= 1e-6)
        return color;

    float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(originalLumaNits, boostParams);
    float colorScale = boostedLumaNits / originalLumaNits;

    if (EnableColorPreservingBoostMode)
    {


        float outputChannelLimit = ((BoostRollOff > 0.0) ? clamp(BoostRollOff, 1.0, 10000.0) : 10000.0) / max(SIGNAL_REFERENCE_NITS, 1.0);
        float maxHuePreservingScale = ComputeMaxHuePreservingScale(max(linearColor, 0.0.xxx), outputChannelLimit);
        colorScale = SoftLimitBoostScale(colorScale, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
    }

    return linearColor * colorScale;
}


// Scalar response used by live APL analysis and graph simulation.
float ComputePostBoostNitsForSample(float lumaNits, float maxChannelNits, float4 boostParams)
{
    if (lumaNits <= 1e-6)
        return 0.0;

    float boostedLumaNits = ComputeBoostedLumaNitsFromPrecomputedParams(lumaNits, boostParams);

    if (EnableColorPreservingBoostMode && maxChannelNits > 1e-6)
    {

        float outputChannelLimitNits = (BoostRollOff > 0.0) ? clamp(BoostRollOff, 1.0, 10000.0) : 10000.0;
        float maxHuePreservingScale = max(outputChannelLimitNits / maxChannelNits, 0.0);
        float colorScale = SoftLimitBoostScale(boostedLumaNits / lumaNits, maxHuePreservingScale, COLOR_PRESERVING_BOOST_KNEE);
        boostedLumaNits = lumaNits * colorScale;
    }

    return boostedLumaNits;
}


float ComputePostBoostMetricForSample(float lumaNits, float maxChannelNits, float4 boostParams)
{
    return saturate(
        ComputePostBoostNitsForSample(lumaNits, maxChannelNits, boostParams) /
        max(APLReferenceWhiteNits, 1.0)
    );
}


// Interpolate APL response at four log-gain nodes.
float EvaluateDisplayAPLResponseFromLogNodes(float4 logA, float logGain, float gainToNodeScale)
{
    float t = clamp(logGain * gainToNodeScale, 0.0, 3.0);
    float logEst;

    if (t <= 1.0)
        logEst = lerp(logA.x, logA.y, t);
    else if (t <= 2.0)
        logEst = lerp(logA.y, logA.z, t - 1.0);
    else
        logEst = lerp(logA.z, logA.w, t - 2.0);

    return saturate(exp2(logEst));
}


// Solve gain = compensation(APL response) with ten bisection steps.
float SolveClosedLoopDisplayAPLFromResponseNodes(float rawAPL, float3 responseNodes, float gMax)
{
    float safeRawAPL = saturate(rawAPL);

    if (safeRawAPL <= 1e-6)
        return 0.0;

    if (gMax <= 1e-6)
        return safeRawAPL;


    float4 logA = log2(max(float4(safeRawAPL, responseNodes), 1e-6));
    float gainToNodeScale = 3.0 / gMax;

    float lo = 0.0;
    float hi = gMax;

    float aplLo = safeRawAPL;           // A(0)
    float fLo = clamp(ComputeSceneLogGainFromAPL(aplLo), 0.0, gMax);


    if (fLo <= 1e-6)
        return aplLo;

    float aplHi = saturate(responseNodes.z); // A(gMax)
    float fHi = clamp(ComputeSceneLogGainFromAPL(aplHi), 0.0, gMax) - gMax;

    if (fHi >= -1e-6)
        return aplHi;


    [loop]
    for (int i = 0; i < 10; ++i)
    {
        float mid = 0.5 * (lo + hi);
        float aplMid = EvaluateDisplayAPLResponseFromLogNodes(logA, mid, gainToNodeScale);
        float fMid = clamp(ComputeSceneLogGainFromAPL(aplMid), 0.0, gMax) - mid;

        if (fMid > 0.0)
            lo = mid;
        else
            hi = mid;
    }

    float solvedGain = 0.5 * (lo + hi);
    return EvaluateDisplayAPLResponseFromLogNodes(logA, solvedGain, gainToNodeScale);
}


float SolveUniformSceneDisplayAPL(float rawAPL)
{
    float safeRawAPL = saturate(rawAPL);

    if (safeRawAPL <= 1e-6 || !EnableEOTFBoost)
        return safeRawAPL;

    float gMax = ComputeCandidateMaxLogGain();

    if (gMax <= 1e-6)
        return safeRawAPL;

    float representativeNits = safeRawAPL * max(APLReferenceWhiteNits, 1.0);
    float3 responseNodes;

    [unroll]
    for (int k = 1; k <= 3; ++k)
    {
        responseNodes[k - 1] = ComputePostBoostMetricForSample(
            representativeNits,
            representativeNits,
            LoadCandidateBoostParams(k)
        );
    }

    return SolveClosedLoopDisplayAPLFromResponseNodes(safeRawAPL, responseNodes, gMax);
}

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

int APL_QuantizeMaxNits2(float nits)
{


    return clamp((int)floor(max(nits, 0.0) * 0.5 + 0.5), 0, 5000);
}

int APL_ActiveHistogramBins()
{
    return (EnableEOTFBoost && EnableColorPreservingBoostMode) ? APL_FFH_MAX_BINS : APL_FFH_LUMA_BINS;
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

float APL_ReconstructMeanLumaQ4(int binIndex, bool colorHistogram, float pixelCount, float offsetSum10)
{
    int lumaBin = colorHistogram ? (binIndex / APL_FFH_COLOR_RATIO_BINS) : binIndex;
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

// Signature prevents rows built with different runtime settings from mixing.
int APL_GetRollingHistogramSignature(bool colorHistogram)
{


    int signalRef = clamp(int(SIGNAL_REFERENCE_NITS + 0.5), 1, 200);
    return clamp(APLInputMode, 0, 1) + (colorHistogram ? 2 : 0) + signalRef * 4;
}

void APL_DecodePackedFullFrameSample(
    int2 pixel,
    bool needsMaxHistogram,
    out int binIndex,
    out int packedContribution,
    out int maxNits2,
    out int lumaQ4,
    out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    maxNits2 = 0;
    lumaQ4 = 0;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 color = tex2Dfetch(BackBuffer, pixel).rgb;
    float sceneNits = 0.0;
    float maxChannelNits = 0.0;

    if (APLInputMode == 1)
    {
        float3 channelNits = APL_FastPQToNits(color);
        sceneNits = max(GetLuma2020(channelNits), 0.0);
        if (needsMaxHistogram)
            maxChannelNits = max(max(channelNits.r, channelNits.g), channelNits.b);
    }
    else
    {
        sceneNits = max(GetLuma709(color) * SIGNAL_REFERENCE_NITS, 0.0);
        if (needsMaxHistogram)
        {
            float3 positiveColor = max(color, 0.0.xxx);
            maxChannelNits = max(max(positiveColor.r, positiveColor.g), positiveColor.b) * SIGNAL_REFERENCE_NITS;
        }
    }

    lumaQ4 = APL_QuantizeNitsQ4(sceneNits);
    int maxQ4 = needsMaxHistogram ? APL_QuantizeNitsQ4(maxChannelNits) : 0;
    int lumaBin = APL_HistogramLumaBin64(lumaQ4);
    binIndex = needsMaxHistogram
        ? lumaBin * APL_FFH_COLOR_RATIO_BINS + APL_HistogramColorRatioBin(lumaQ4, maxQ4)
        : lumaBin;

    int offset10 = APL_EncodeWithinBinOffset10(lumaQ4, lumaBin);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    maxNits2 = needsMaxHistogram ? APL_QuantizeMaxNits2(maxChannelNits) : 0;
    valid = 1;
}

groupshared int APL_SetupRollingPhase;
groupshared int APL_TilePackedCountLuma[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxNits[APL_FFH_MAX_BINS];
groupshared int APL_TileExactMaxLumaQ4;
groupshared int APL_BuildRollingPhase;

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int maxNits2, int valid, bool needsMaxHistogram)
{
    if (valid == 0)
        return;

    InterlockedAdd(APL_TilePackedCountLuma[binIndex], packedContribution);
    if (needsMaxHistogram)
        InterlockedAdd(APL_TileMaxNits[binIndex], maxNits2);
}


[numthreads(256, 1, 1)]
// Pass 1: build frame constants, copy APL history, and clear updated rows.
void CS_SetupAndClearAPLFullFrameRowHistograms(uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    int activeBins = APL_ActiveHistogramBins();
    bool needsMaxHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    bool trackExactMax = aplActive && ShowOSD;


    if (localIndex < 3)
    {
        float4 candidateParams = float4(1.0, 0.0, 1.0, 0.0);
        if (aplActive)
        {
            float gMax = ComputeCandidateMaxLogGain();
            float candidateLogGain = gMax * (float(localIndex + 1) / 3.0);
            candidateParams = ComputeBoostRolloffParamsFromSceneLogGain(candidateLogGain);
        }
        tex2Dstore(StorageCandidateBoostParams, int2(localIndex, 0), candidateParams);
    }


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

#if APL_FULLFRAME_ROLLING_PHASES > 0
    int rowSlots = APL_FFH_ROLLING_ROW_SLOTS;
    int totalEntries = rowSlots * activeBins;
    int signature = APL_GetRollingHistogramSignature(needsMaxHistogram);
#else
    int rowSlots = APL_FFH_TILE_COUNT_Y;
    int totalEntries = rowSlots * activeBins;
#endif


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
            int rowSlot = entry / activeBins;
            int binIndex = entry - rowSlot * activeBins;
            int rowIndex = APL_GetPhysicalRowFromDispatchSlot(rowSlot, APL_SetupRollingPhase);
            if (rowIndex < APL_FFH_TILE_COUNT_Y)
            {
                int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
                tex2Dstore(StorageAPLRowHistCount, coord, 0);
                tex2Dstore(StorageAPLRowHistOffset10, coord, 0);
                if (needsMaxHistogram)
                    tex2Dstore(StorageAPLRowHistMaxNits, coord, 0);
                if (binIndex == 0)
                {
                    if (trackExactMax)
                        tex2Dstore(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex), 0);
#if APL_FULLFRAME_ROLLING_PHASES > 0
                    tex2Dstore(StorageAPLRowMeta, int2(0, rowIndex), signature << APL_FFH_ROW_META_COUNT_BITS);
#endif
                }
            }
        }
    }
}

[numthreads(16, 16, 1)]
// Pass 2: decode source pixels and accumulate row histograms.
void CS_BuildAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{

    bool aplActive = NeedsAPLProcessing();
    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;
    int activeBins = APL_ActiveHistogramBins();
    bool needsMaxHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    bool trackExactMax = aplActive && ShowOSD;

    if (localIndex == 0)
    {
        float storedPhase = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0)).g;
        APL_BuildRollingPhase = APL_DecodeStoredRollingPhase(storedPhase);
    }

    if (localIndex < activeBins)
    {
        APL_TilePackedCountLuma[localIndex] = 0;
        APL_TileMaxNits[localIndex] = 0;
    }
    if (trackExactMax && localIndex == 0)
        APL_TileExactMaxLumaQ4 = 0;
    barrier();

    int physicalRow = APL_GetPhysicalRowFromDispatchSlot(int(groupID.y), APL_BuildRollingPhase);
    bool validPhysicalRow = physicalRow < APL_FFH_TILE_COUNT_Y;
    bool decodeThisGroup = aplActive && validPhysicalRow;

    if (decodeThisGroup)
    {
        int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, physicalRow * APL_FFH_TILE_SIZE) + int2(threadID.xy) * 2;

        int b0, p0, m0, l0, v0;
        int b1, p1, m1, l1, v1;
        int b2, p2, m2, l2, v2;
        int b3, p3, m3, l3, v3;
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), needsMaxHistogram, b0, p0, m0, l0, v0);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), needsMaxHistogram, b1, p1, m1, l1, v1);
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), needsMaxHistogram, b2, p2, m2, l2, v2);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), needsMaxHistogram, b3, p3, m3, l3, v3);

        if (trackExactMax)
            InterlockedMax(APL_TileExactMaxLumaQ4, max(max(l0, l1), max(l2, l3)));


        if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; m0 += m1; v1 = 0; }
        if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; m0 += m2; v2 = 0; }
        if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; m1 += m2; v2 = 0; }
        if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; m0 += m3; v3 = 0; }
        if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; m1 += m3; v3 = 0; }
        if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; m2 += m3; v3 = 0; }

        APL_AtomicAddMergedTileSample(b0, p0, m0, v0, needsMaxHistogram);
        APL_AtomicAddMergedTileSample(b1, p1, m1, v1, needsMaxHistogram);
        APL_AtomicAddMergedTileSample(b2, p2, m2, v2, needsMaxHistogram);
        APL_AtomicAddMergedTileSample(b3, p3, m3, v3, needsMaxHistogram);
    }
    barrier();

    if (trackExactMax && decodeThisGroup && localIndex == 0)
        atomicMax(StorageAPLRowHistCount, APL_RowExactMaxLumaCoord(physicalRow), APL_TileExactMaxLumaQ4);

    if (decodeThisGroup && localIndex < activeBins)
    {
        int packedValue = APL_TilePackedCountLuma[localIndex];
        int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
        if (count > 0)
        {
            int offsetSum10 = packedValue & APL_FFH_PACK_OFFSET_MASK;
            int2 rowCoord = APL_RowHistogramCoord(physicalRow, int(localIndex));
            atomicAdd(StorageAPLRowHistCount, rowCoord, count);
            atomicAdd(StorageAPLRowHistOffset10, rowCoord, offsetSum10);
            if (needsMaxHistogram)
                atomicAdd(StorageAPLRowHistMaxNits, rowCoord, APL_TileMaxNits[localIndex]);
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
groupshared float APL_ReduceMaxNits[APL_FFH_REDUCE_THREADS];

#define APL_REDUCE_ROW_STAGE(S) \
    if (localIndex < S) { \
        APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + S]; \
        APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + S]; \
        if (needsMaxHistogram) APL_ReduceMaxNits[localIndex] += APL_ReduceMaxNits[localIndex + S]; \
    } \
    barrier();

[numthreads(64, 1, 1)]
// Pass 3: reduce valid persistent rows into one global histogram.
void CS_ReduceAPLFullFrameRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;
    int activeBins = APL_ActiveHistogramBins();
    bool validBin = binIndex < activeBins;
    bool needsMaxHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    bool trackExactMax = aplActive && ShowOSD;

    int countSum = 0;
    float offsetSum10 = 0.0;
    float maxSumNits = 0.0;
    if (aplActive && validBin)
    {
        [loop]
        for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
        {
            bool includeRow = true;
#if APL_FULLFRAME_ROLLING_PHASES > 0
            int rowMeta = tex2Dfetch(SamplerAPLRowMeta, int2(0, rowIndex));
            int rowCount = rowMeta & APL_FFH_ROW_META_COUNT_MASK;
            int rowSignature = rowMeta >> APL_FFH_ROW_META_COUNT_BITS;
            int expectedSignature = APL_GetRollingHistogramSignature(needsMaxHistogram);
            includeRow = (rowCount == APL_GetExpectedRowPixelCount(rowIndex)) && (rowSignature == expectedSignature);
#endif
            if (includeRow)
            {
                int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
                countSum += tex2Dfetch(SamplerAPLRowHistCount, sourceCoord);
                offsetSum10 += float(tex2Dfetch(SamplerAPLRowHistOffset10, sourceCoord));
                if (needsMaxHistogram)
                    maxSumNits += float(tex2Dfetch(SamplerAPLRowHistMaxNits, sourceCoord));
            }
        }
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceMaxNits[localIndex] = maxSumNits;
    barrier();

    APL_REDUCE_ROW_STAGE(32)
    APL_REDUCE_ROW_STAGE(16)
    APL_REDUCE_ROW_STAGE(8)
    APL_REDUCE_ROW_STAGE(4)
    APL_REDUCE_ROW_STAGE(2)
    APL_REDUCE_ROW_STAGE(1)

    if (aplActive && validBin && localIndex == 0)
    {
        tex2Dstore(StorageAPLGlobalHistCount, localBinCoord, APL_ReduceCount[0]);
        tex2Dstore(StorageAPLGlobalHistOffset10, localBinCoord, APL_ReduceOffset10[0]);
        if (needsMaxHistogram)
            tex2Dstore(StorageAPLGlobalHistMaxNits, localBinCoord, APL_ReduceMaxNits[0]);


        if (binIndex == 0)
        {
            int exactMaxLumaQ4 = 0;
            if (trackExactMax)
            {
                [loop]
                for (int rowIndex = 0; rowIndex < APL_FFH_TILE_COUNT_Y; ++rowIndex)
                {
                    bool includeRow = true;
#if APL_FULLFRAME_ROLLING_PHASES > 0
                    int rowMeta = tex2Dfetch(SamplerAPLRowMeta, int2(0, rowIndex));
                    int rowCount = rowMeta & APL_FFH_ROW_META_COUNT_MASK;
                    int rowSignature = rowMeta >> APL_FFH_ROW_META_COUNT_BITS;
                    int expectedSignature = APL_GetRollingHistogramSignature(needsMaxHistogram);
                    includeRow = (rowCount == APL_GetExpectedRowPixelCount(rowIndex)) && (rowSignature == expectedSignature);
#endif
                    if (includeRow)
                        exactMaxLumaQ4 = max(exactMaxLumaQ4, tex2Dfetch(SamplerAPLRowHistCount, APL_RowExactMaxLumaCoord(rowIndex)));
                }
            }
            tex2Dstore(StorageAPLGlobalHistCount, APL_GlobalExactMaxLumaCoord(), exactMaxLumaQ4);
        }
    }
}

#undef APL_REDUCE_ROW_STAGE

groupshared float4 APL_EvalWeightedMetrics[APL_FFH_MAX_BINS];
groupshared float APL_EvalPixelCount[APL_FFH_MAX_BINS];

#define APL_REDUCE_EVAL_STAGE(S) \
    if (localIndex < S) { \
        APL_EvalWeightedMetrics[localIndex] += APL_EvalWeightedMetrics[localIndex + S]; \
        APL_EvalPixelCount[localIndex] += APL_EvalPixelCount[localIndex + S]; \
    } \
    barrier();

[numthreads(256, 1, 1)]
// Pass 4: evaluate response, solve APL, smooth state, and write boost parameters.
void CS_EvaluateSolveAndSmoothAPLFullFrameHistogram(uint3 threadID : SV_GroupThreadID)
{
    bool aplActive = NeedsAPLProcessing();
    int localIndex = int(threadID.x);
    bool colorHistogram = EnableEOTFBoost && EnableColorPreservingBoostMode;
    int activeBins = colorHistogram ? APL_FFH_MAX_BINS : APL_FFH_LUMA_BINS;

    float4 weighted = 0.0.xxxx;
    float pixelCount = 0.0;

    if (aplActive && localIndex < activeBins)
    {
        int2 binCoord = APL_HistogramBlockCoord(localIndex);
        int pixelCountI = tex2Dfetch(SamplerAPLGlobalHistCount, binCoord);
        if (pixelCountI > 0)
        {
            pixelCount = float(pixelCountI);
            float offsetSum10 = tex2Dfetch(SamplerAPLGlobalHistOffset10, binCoord);
            float meanLumaQ4 = APL_ReconstructMeanLumaQ4(localIndex, colorHistogram, pixelCount, offsetSum10);
            float sceneNits = max(meanLumaQ4 * 0.25, 0.0);
            float rawMetric = saturate(sceneNits / max(APLReferenceWhiteNits, 1.0));
            float3 candidateMetrics = rawMetric.xxx;

            if (EnableEOTFBoost)
            {
                float maxChannelNits = 0.0;
                if (colorHistogram)
                {
                    float maxSumNits = tex2Dfetch(SamplerAPLGlobalHistMaxNits, binCoord);
                    maxChannelNits = max((maxSumNits / pixelCount) * 2.0, sceneNits);
                }
                candidateMetrics.x = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, LoadCandidateBoostParams(1));
                candidateMetrics.y = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, LoadCandidateBoostParams(2));
                candidateMetrics.z = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, LoadCandidateBoostParams(3));
            }

            weighted = float4(rawMetric, candidateMetrics) * pixelCount;
        }
    }

    APL_EvalWeightedMetrics[localIndex] = weighted;
    APL_EvalPixelCount[localIndex] = pixelCount;
    barrier();

    APL_REDUCE_EVAL_STAGE(128)
    APL_REDUCE_EVAL_STAGE(64)
    APL_REDUCE_EVAL_STAGE(32)
    APL_REDUCE_EVAL_STAGE(16)
    APL_REDUCE_EVAL_STAGE(8)
    APL_REDUCE_EVAL_STAGE(4)
    APL_REDUCE_EVAL_STAGE(2)
    APL_REDUCE_EVAL_STAGE(1)

    if (localIndex == 0)
    {


        if (!aplActive)
        {
            tex2Dstore(StorageAPLInstant, int2(0, 0), 0.0.xxxx);
            tex2Dstore(StorageAPL, int2(0, 0), 0.0.xxxx);
            tex2Dstore(StorageBoostParams, int2(0, 0), float4(1.0, 0.0, 1.0, 0.0));
            return;
        }

        float rawAPL = 0.0;
        float3 responseNodes = 0.0.xxx;
        float exactRollingMaxNits = 0.0;
        float totalPixelCount = APL_EvalPixelCount[0];

        if (totalPixelCount > 0.0)
        {
            float4 averages = APL_EvalWeightedMetrics[0] / totalPixelCount;
            rawAPL = saturate(averages.r);
            responseNodes = saturate(averages.gba);
            exactRollingMaxNits = ShowOSD
                ? float(tex2Dfetch(SamplerAPLGlobalHistCount, APL_GlobalExactMaxLumaCoord())) * 0.25
                : 0.0;
        }

        float4 prevData = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0));
        float prevSmoothedAPL = saturate(prevData.r);
        float hasPrev = (prevData.b > 0.0) ? 1.0 : 0.0;
        float alpha = ComputeTemporalBlendFactor(TransitionSpeed);
        int currentRollingPhase = APL_DecodeStoredRollingPhase(prevData.g);
        int nextRollingPhase = APL_GetNextRollingPhase(currentRollingPhase);


        float gMax = ComputeCandidateMaxLogGain();
        float currentDisplayAPL = SolveClosedLoopDisplayAPLFromResponseNodes(rawAPL, responseNodes, gMax);
        float smoothedAPL = lerp(
            currentDisplayAPL,
            lerp(prevSmoothedAPL, currentDisplayAPL, alpha),
            hasPrev
        );

        float sceneLogGain = ComputeSceneLogGainFromAPL(smoothedAPL);


        tex2Dstore(
            StorageAPLInstant,
            int2(0, 0),
            float4(rawAPL, exactRollingMaxNits, float(nextRollingPhase), (totalPixelCount > 0.0) ? 1.0 : 0.0)
        );
        tex2Dstore(StorageAPL, int2(0, 0), float4(smoothedAPL, smoothedAPL, 1.0, sceneLogGain));
        tex2Dstore(StorageBoostParams, int2(0, 0), ComputeBoostRolloffParamsFromSceneLogGain(sceneLogGain));
    }
}

#undef APL_REDUCE_EVAL_STAGE
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
    float aspect = ScreenSize.x / ScreenSize.y;
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


// Pass 5: apply scene-uniform boost, optional LUT, OSD, and graph.
float4 PS_MainPass(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 color = tex2D(BackBuffer, texcoord).rgb;
    bool boostEnabled = EnableEOTFBoost;


    if (!boostEnabled)
    {
        // LUT-only or passthrough path.
        return float4(color, 1.0);
    }

    float4 aplData = tex2Dlod(SamplerAPL, float4(0.5, 0.5, 0.0, 0.0));
    float sceneLogGain = aplData.a;

    if ((sceneLogGain <= 0.0) && (ShowOSD == false))
    {
        return float4(color, 1.0);
    }

    float3 finalColor = color;


    if (sceneLogGain > 1e-6)
    {
        float4 boostParams = tex2Dlod(SamplerBoostParams, float4(0.5, 0.5, 0.0, 0.0));
        finalColor = ApplyBoostPreserveColorFromPrecomputedParams(color, boostParams);
    }

    if (ShowOSD)
    {
        float4 instantData = tex2Dlod(SamplerAPLInstant, float4(0.5, 0.5, 0.0, 0.0));
        float rawInputAPL = saturate(instantData.r);
        float currentMaxSceneNits = max(instantData.g, 0.0);
        finalColor = DrawStatsOverlay(
            texcoord,
            finalColor,
            rawInputAPL,
            saturate(aplData.g),
            currentMaxSceneNits
        );
    }

    return float4(finalColor, 1.0);
}
