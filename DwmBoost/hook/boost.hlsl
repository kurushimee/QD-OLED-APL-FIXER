// EOTF Boost v8.18.7.15 (EOTF_BoostMod3.0.fx) for DWM.
//
// The shader's code is unchanged. Its uniforms are constants holding the settings below, and the
// features its preprocessor definitions turn off (the debug graph, the calibration LUT, tooltips) are
// left out. A shim maps ReShade's intrinsics and the back buffer onto plain D3D11, the back buffer
// being the hook's clean copy of the composed desktop.
//
// Live pipeline, one dispatch or draw each:
//   1  CS_SetupAndClearAPLFullFrameRowHistograms   frame setup and rolling-row clear
//   2  CS_BuildAPLFullFrameRowHistogram            full-frame row histogram build
//   3  CS_ReduceAPLFullFrameRowHistogram           global histogram reduction
//   4  CS_SolveGainAndToneCurve                    gain solve, smoothing, and tone curve slopes
//   5  CS_BuildToneCurveLookup                     knee solve and tone curve lookup
//   6  PostProcessVS / PS_MainPass                 fullscreen boost

// Preprocessor definitions. DWM composes in scRGB.
#define BUFFER_COLOR_SPACE            2
#define APL_FULLFRAME_ROLLING_PHASES  6

// Settings.
static const bool  EnableEOTFBoost = true;
static const float TransitionSpeed = 0.50;
static const bool  ShowOSD         = false;
static const float OSDBrightness   = 0.50;


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
Texture2D<float4> BackBuffer                      : register(t0);
Texture2D<float4> SamplerAPL                      : register(t1);
Texture2D<float4> SamplerToneCurve                : register(t2);
Texture2D<float4> SamplerToneCurveShape           : register(t3);
Texture2D<float>  SamplerToneCurveLUT             : register(t4);
Texture2D<float4> SamplerAPLInstant               : register(t5);
Texture2D<float4> SamplerAPLPrev                  : register(t6);
Texture2D<float>  SamplerAPLFastPQNits            : register(t7);
Texture2D<int>    SamplerAPLRowHistCount          : register(t8);
Texture2D<int>    SamplerAPLRowHistOffset10       : register(t9);
Texture2D<int>    SamplerAPLRowHistLumaRatio10    : register(t10);
Texture2D<int>    SamplerAPLRowMeta               : register(t11);
Texture2D<int>    SamplerAPLGlobalHistCount       : register(t12);
Texture2D<float>  SamplerAPLGlobalHistOffset10    : register(t13);
Texture2D<float>  SamplerAPLGlobalHistLumaRatio10 : register(t14);

// Pass 1
RWTexture2D<float>  StorageAPLFastPQNits         : register(u0);
RWTexture2D<float4> StorageAPLPrev               : register(u1);

// Passes 1 and 2
RWTexture2D<int>    StorageAPLRowHistCount       : register(u2);
RWTexture2D<int>    StorageAPLRowHistOffset10    : register(u3);
RWTexture2D<int>    StorageAPLRowHistLumaRatio10 : register(u4);
RWTexture2D<int>    StorageAPLRowMeta            : register(u5);

// Pass 3
RWTexture2D<int>    StorageAPLGlobalHistCount       : register(u0);
RWTexture2D<float>  StorageAPLGlobalHistOffset10    : register(u1);
RWTexture2D<float>  StorageAPLGlobalHistLumaRatio10 : register(u2);

// Pass 4
RWTexture2D<float4> StorageToneCurve             : register(u0);
RWTexture2D<float4> StorageToneCurveShape        : register(u1);
RWTexture2D<float4> StorageAPLInstant            : register(u2);
RWTexture2D<float4> StorageAPL                   : register(u3);

// Pass 5
RWTexture2D<float>  StorageToneCurveLUT          : register(u0);

// The fast PQ table and the tone curve lookup filter linearly, every other sampler reads texel centers.
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


// Peak the compensation data was measured at, and the luminance that counts as 100% load.
static const float PANEL_PEAK_NITS = 1000.932391;

// scRGB 1.0 is 80 nits by definition.
static const float SCRGB_REFERENCE_NITS = 80.0;

// Shown level in PQ for each 10-bit PQ code, sampled with linear filtering.
#define TONE_CURVE_LUT_SIZE 1024


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

    float3 color = tex2Dfetch(BackBuffer, pixel).rgb;
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

    InterlockedAdd(APL_TilePackedCountLevel[binIndex], packedContribution);
    InterlockedAdd(APL_TileLumaRatio10[binIndex], lumaRatio10);
}


[numthreads(256, 1, 1)]
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

[numthreads(16, 16, 1)]
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
            InterlockedMax(APL_TileExactMaxLumaQ4, max(max(l0, l1), max(l2, l3)));


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

[numthreads(64, 1, 1)]
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

    return total / bendWidth;
}

// The knee bends over a quarter octave, about one histogram bin, and never less than at 1 nit.
float APL_BendWidthPQ(float kneePQ)
{
    float kneeNits = max(PQToLinearScalar(kneePQ) * 10000.0, 1.0);
    float halfWidth = exp2(0.125);
    return NitsToPQ(kneeNits * halfWidth) - NitsToPQ(kneeNits / halfWidth);
}

// Bent curve minus top-down curve where the bend ends. It grows with the knee and is 0 at the right one.
float APL_KneeMismatch(float kneePQ, float ceilingPQ)
{
    float bendWidth = APL_BendWidthPQ(kneePQ);
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

// Builds the tone curve for one gain in groupshared and returns the boosted frame's summed luma.
// Each thread brings its own histogram bin and, below APL_FFH_LEVEL_BINS, its own level bin.
// Bins are mapped without the knee bend, which moves the load by a fraction of a percent.
float APL_SumBoostedFrame(int localIndex, float logGain, float binCount, float meanLevelNits, float meanLevelPQ, float lumaSumNits)
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

    APL_EvalSum[localIndex] = float2(boostedNits, binCount);
    return APL_ReduceEvalSum(localIndex).x;
}

[numthreads(256, 1, 1)]
// Pass 4: solve the gain the boosted frame calls for, smooth it, and build its tone curve.
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
        float boostedNitsSum = APL_SumBoostedFrame(localIndex, midLogGain, binCount, meanLevelNits, meanLevelPQ, lumaSumNits);

        if (localIndex == 0)
        {
            float loadPercent = 100.0 * boostedNitsSum / fullLoadNitsSum;
            bool needsMoreGain = log2(LookupMeasuredComp1D(loadPercent)) > midLogGain;
            APL_SolveLogGainRange = needsMoreGain ? float2(midLogGain, range.y) : float2(range.x, midLogGain);
        }
        barrier();
    }

    float2 solvedRange = APL_SolveLogGainRange;
    float solvedLogGain = 0.5 * (solvedRange.x + solvedRange.y);

    float4 prevData = tex2Dlod(SamplerAPLPrev, float4(0.5, 0.5, 0.0, 0.0));
    float hasPrev = (prevData.b > 0.0) ? 1.0 : 0.0;
    float alpha = ComputeTemporalBlendFactor(TransitionSpeed);

    // Smoothing in log gain covers the same share of a brightness change both ways.
    float logGain = lerp(solvedLogGain, lerp(prevData.a, solvedLogGain, alpha), hasPrev);
    float boostedNitsSum = APL_SumBoostedFrame(localIndex, logGain, binCount, meanLevelNits, meanLevelPQ, lumaSumNits);

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        float4 curveBin = float4(APL_CurveSlope[localIndex], APL_CurveLowerPQ[localIndex], APL_CurveUpperPQ[localIndex], APL_CurveAbove[localIndex]);
        tex2Dstore(StorageToneCurve, int2(localIndex, 0), curveBin);
    }

    if (localIndex != 0)
        return;

    float ceilingPQ = NitsToPQ(PANEL_PEAK_NITS / exp2(logGain));
    float kneePQ = APL_SolveKneePQ(ceilingPQ);
    float bendWidth = APL_BendWidthPQ(kneePQ);
    float bendStart = kneePQ - 0.5 * bendWidth;
    float bendStartNits = PQToLinearScalar(bendStart) * 10000.0;
    tex2Dstore(StorageToneCurveShape, int2(0, 0), float4(bendStart, bendWidth, ceilingPQ, bendStartNits));

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

[numthreads(256, 1, 1)]
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
    float3 color = tex2D(BackBuffer, texcoord).rgb;

    if (EnableEOTFBoost)
        color = ApplyBoost(color);


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


    return float4(color, 1.0);
}
