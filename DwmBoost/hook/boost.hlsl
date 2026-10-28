// EOTF Boost for DWM, the scRGB desktop path of Shaders/EOTF_BoostMod3.1_27M2N6500.fx.
//
// The algorithm and output match the ReShade shader at its default settings. Only the scRGB input path is kept,
// since DWM composes into FP16 scRGB, so the PQ decode table and the dither go, and so do the OSD, the debug graph,
// the calibration LUT and every runtime uniform, with their defaults baked below. ReShade intrinsics become plain
// HLSL: tex2Dstore is a RWTexture store, tex2Dfetch a Load, atomicAdd InterlockedAdd and barrier
// GroupMemoryBarrierWithGroupSync.
//
// DWM runs the boost only when it composes, so the gain smoothing runs on time instead of frames, the shader's
// 20 frame period at the panel's 240 Hz.
//
// Five stages, with the shader's sync boundaries:
//   1  CS_Setup          last run's state copy and row histogram clear
//   2  CS_Build          full-frame row histogram build (reads the clean copy)
//   3  CS_Reduce         global histogram reduction
//   4  CS_Solve          full compensation solve, gain pick, smoothing, tone curve and its lookup
//   5  VS_Boost/PS_Boost fullscreen boost (clean copy -> back buffer)

// Panel peak, load peak and compensation curve, fitted to abl_curve.csv.
#include "../../Shaders/PanelModel_27M2N6500.fxh"

static const float SCRGB_REFERENCE_NITS = 80.0;
static const float REFERENCE_WHITE_NITS = 203.0;

// The shader's smoothing period of 20 frames, at the panel's 240 Hz.
static const float SMOOTHING_PERIOD_MS = 20.0 * 1000.0 / 240.0;

// libplacebo's scene change thresholds, in units of 1% PQ of the frame's mean.
static const float SCENE_CHANGE_LOW_PQ = 1.0;
static const float SCENE_CHANGE_HIGH_PQ = 3.0;

// Full-frame histogram layout. Each 16x16 group processes one 32x32 pixel tile, and pixels are binned by their
// brightest channel, each level bin split into quarters by position.
#define APL_FFH_TILE_SIZE          32
#define APL_FFH_THREADS_X          16
#define APL_FFH_THREADS_Y          16
#define APL_FFH_LEVEL_BINS         64
#define APL_FFH_SUB_BINS            4
#define APL_FFH_MAX_BINS          256
#define APL_FFH_BLOCK_W            16
#define APL_FFH_BLOCK_H            16
#define APL_FFH_AUX_X              APL_FFH_BLOCK_W
#define APL_FFH_REDUCE_THREADS     64

// Packed value: pixel count in the upper bits and summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT  20
#define APL_FFH_PACK_OFFSET_MASK  ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE 1023
#define APL_FFH_PACK_ONE_COUNT    (1 << APL_FFH_PACK_COUNT_SHIFT)

// Shown level in PQ for each 10-bit PQ code, read with linear interpolation.
#define TONE_CURVE_LUT_SIZE 1024

#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)


cbuffer BoostCB : register(b0)
{
    uint  ResetFlag;       // 1 = resume after a pause: drop the last run's gain
    uint  BufferWidthPx;   // target back-buffer size; sets the histogram geometry
    uint  BufferHeightPx;
    float LitFraction;     // share of the native panel the buffer covers; the rest is black bars
    float FrameTime;       // milliseconds since the last run
};

#define BUFFER_WIDTH  int(BufferWidthPx)
#define BUFFER_HEIGHT int(BufferHeightPx)


// ST.2084 transfer functions, relative to 10000 nits.
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
    return pow(num / max(den, 1e-6), 1.0 / m1);
}

float LinearToPQScalar(float linearValue)
{
    const float m1 = 0.1593017578125;
    const float m2 = 78.84375;
    const float c1 = 0.8359375;
    const float c2 = 18.8515625;
    const float c3 = 18.6875;

    float Lm1 = pow(saturate(linearValue), m1);
    float num = c1 + c2 * Lm1;
    float den = 1.0 + c3 * Lm1;
    return pow(num / max(den, 1e-6), m2);
}

float NitsToPQ(float nits)
{
    return LinearToPQScalar(saturate(nits / 10000.0));
}

float PQToNits(float pq)
{
    return PQToLinearScalar(pq) * 10000.0;
}

static const float3x3 REC709_TO_REC2020 = float3x3(
    0.6274040, 0.3292820, 0.0433136,
    0.0690970, 0.9195400, 0.0113612,
    0.0163916, 0.0880132, 0.8955950);

static const float3x3 REC2020_TO_REC709 = float3x3(
     1.660490296, -0.587639106, -0.072851598,
    -0.124549970,  1.132899922, -0.008347964,
    -0.018151119, -0.100578724,  1.118729878);

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}

// Linear nits in Rec.2020, the primaries the panel receives.
float3 DecodeScRGBToRec2020Nits(float3 color)
{
    return mul(REC709_TO_REC2020, color) * SCRGB_REFERENCE_NITS;
}

// libplacebo's peak detection smoothing: a single-pole IIR that a scene change bypasses. The frame's mean PQ eases
// the same way, and a scene change is the frame's mean moving away from the eased one, fully at SCENE_CHANGE_HIGH_PQ
// percent or more.
float ComputeTemporalBlendFactor(float meanPQ, float smoothedMeanPQ, out float nextSmoothedMeanPQ)
{
    float coefficient = 1.0 - exp(-max(FrameTime, 0.0) / SMOOTHING_PERIOD_MS);
    float easedMeanPQ = lerp(smoothedMeanPQ, meanPQ, coefficient);
    float changePercentPQ = 100.0 * abs(meanPQ - easedMeanPQ);
    float sceneChange = smoothstep(SCENE_CHANGE_LOW_PQ, SCENE_CHANGE_HIGH_PQ, changePercentPQ);

    nextSmoothedMeanPQ = lerp(easedMeanPQ, meanPQ, sceneChange);
    return lerp(coefficient, 1.0, sceneChange);
}


// =====================================================================================
// Histogram bins
// =====================================================================================
int APL_QuantizeNitsQ4(float nits)
{
    return clamp((int)floor(max(nits, 0.0) * 4.0 + 0.5), 0, 40000);
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

// A row's brightest level, and the frame's in the global histogram, as float bits in the aux column. The levels are
// never negative, so their bits order like them.
int2 APL_RowMaxLevelCoord(int rowIndex)
{
    return int2(APL_FFH_AUX_X, rowIndex * APL_FFH_BLOCK_H);
}

int2 APL_GlobalMaxLevelCoord()
{
    return int2(APL_FFH_AUX_X, 0);
}


// =====================================================================================
// Pass 1: copy the last run's state and clear the row histograms.
// SRV  t0 = APLState
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = APLPrev
// =====================================================================================
Texture2D<float4>   Setup_APLState  : register(t0);
RWTexture2D<int>    Setup_RowCount  : register(u0);
RWTexture2D<int>    Setup_RowOffset : register(u1);
RWTexture2D<float4> Setup_APLPrev   : register(u2);

[numthreads(APL_FFH_MAX_BINS, 1, 1)]
void CS_Setup(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    if (localIndex == 0)
    {
        float4 state = Setup_APLState.Load(int3(0, 0, 0));

        // After a pause the panel showed the frames unboosted, so the last gain is stale.
        if (ResetFlag != 0u)
            state.z = 0.0;

        Setup_APLPrev[int2(0, 0)] = state;
    }

    [loop]
    for (int entry = localIndex; entry < APL_FFH_TILE_COUNT_Y * APL_FFH_MAX_BINS; entry += APL_FFH_MAX_BINS)
    {
        int rowIndex = entry / APL_FFH_MAX_BINS;
        int binIndex = entry - rowIndex * APL_FFH_MAX_BINS;
        int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
        Setup_RowCount[coord] = 0;
        Setup_RowOffset[coord] = 0;

        if (binIndex == 0)
            Setup_RowCount[APL_RowMaxLevelCoord(rowIndex)] = 0;
    }
}


// =====================================================================================
// Pass 2: decode source pixels and accumulate row histograms.
// SRV  t0 = CleanCopy
// UAV  u0 = RowHistCount u1 = RowHistOffset10
// =====================================================================================
Texture2D<float4> Build_CleanCopy : register(t0);
RWTexture2D<int>  Build_RowCount  : register(u0);
RWTexture2D<int>  Build_RowOffset : register(u1);

groupshared int APL_TilePackedCountLevel[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxLevelBits;

void APL_DecodePackedFullFrameSample(int2 pixel, out int binIndex, out int packedContribution, out int levelBits, out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    levelBits = 0;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 channelNits = DecodeScRGBToRec2020Nits(Build_CleanCopy.Load(int3(pixel, 0)).rgb);
    float levelNits = Max3(max(channelNits, 0.0));
    levelBits = asint(levelNits);

    int levelQ4 = APL_QuantizeNitsQ4(levelNits);
    int levelBin = APL_HistogramLevelBin64(levelQ4);
    int offset10 = APL_EncodeWithinBinOffset10(levelQ4, levelBin);

    binIndex = levelBin * APL_FFH_SUB_BINS + offset10 * APL_FFH_SUB_BINS / (APL_FFH_PACK_OFFSET_SCALE + 1);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    valid = 1;
}

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int valid)
{
    if (valid != 0)
        InterlockedAdd(APL_TilePackedCountLevel[binIndex], packedContribution);
}

[numthreads(APL_FFH_THREADS_X, APL_FFH_THREADS_Y, 1)]
void CS_Build(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;

    APL_TilePackedCountLevel[localIndex] = 0;
    if (localIndex == 0)
        APL_TileMaxLevelBits = 0;
    GroupMemoryBarrierWithGroupSync();

    int row = int(groupID.y);
    int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, row * APL_FFH_TILE_SIZE) + int2(threadID.xy) * 2;

    int b0, p0, l0, v0;
    int b1, p1, l1, v1;
    int b2, p2, l2, v2;
    int b3, p3, l3, v3;
    APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), b0, p0, l0, v0);
    APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), b1, p1, l1, v1);
    APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), b2, p2, l2, v2);
    APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), b3, p3, l3, v3);

    InterlockedMax(APL_TileMaxLevelBits, max(max(l0, l1), max(l2, l3)));

    if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; v1 = 0; }
    if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; v2 = 0; }
    if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; v2 = 0; }
    if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; v3 = 0; }
    if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; v3 = 0; }
    if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; v3 = 0; }

    APL_AtomicAddMergedTileSample(b0, p0, v0);
    APL_AtomicAddMergedTileSample(b1, p1, v1);
    APL_AtomicAddMergedTileSample(b2, p2, v2);
    APL_AtomicAddMergedTileSample(b3, p3, v3);
    GroupMemoryBarrierWithGroupSync();

    if (localIndex == 0)
        InterlockedMax(Build_RowCount[APL_RowMaxLevelCoord(row)], APL_TileMaxLevelBits);

    int packedValue = APL_TilePackedCountLevel[localIndex];
    int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
    if (count > 0)
    {
        int2 rowCoord = APL_RowHistogramCoord(row, int(localIndex));
        InterlockedAdd(Build_RowCount[rowCoord], count);
        InterlockedAdd(Build_RowOffset[rowCoord], packedValue & APL_FFH_PACK_OFFSET_MASK);
    }
}


// =====================================================================================
// Pass 3: reduce the row histograms into one global histogram.
// SRV  t0 = RowHistCount t1 = RowHistOffset10
// UAV  u0 = GlobalHistCount u1 = GlobalHistOffset10
// =====================================================================================
Texture2D<int>     Reduce_RowCount     : register(t0);
Texture2D<int>     Reduce_RowOffset    : register(t1);
RWTexture2D<int>   Reduce_GlobalCount  : register(u0);
RWTexture2D<float> Reduce_GlobalOffset : register(u1);

groupshared int APL_ReduceCount[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffset10[APL_FFH_REDUCE_THREADS];

[numthreads(APL_FFH_REDUCE_THREADS, 1, 1)]
void CS_Reduce(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;

    int countSum = 0;
    float offsetSum10 = 0.0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
    {
        int3 sourceCoord = int3(APL_RowHistogramCoord(rowIndex, binIndex), 0);
        countSum += Reduce_RowCount.Load(sourceCoord);
        offsetSum10 += float(Reduce_RowOffset.Load(sourceCoord));
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    GroupMemoryBarrierWithGroupSync();

    [unroll]
    for (int stride = APL_FFH_REDUCE_THREADS / 2; stride > 0; stride /= 2)
    {
        if (localIndex < stride)
        {
            APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + stride];
            APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + stride];
        }
        GroupMemoryBarrierWithGroupSync();
    }

    if (localIndex == 0)
    {
        Reduce_GlobalCount[localBinCoord] = APL_ReduceCount[0];
        Reduce_GlobalOffset[localBinCoord] = APL_ReduceOffset10[0];
    }

    if (localIndex == 0 && binIndex == 0)
    {
        int maxLevelBits = 0;

        [loop]
        for (int maxRow = 0; maxRow < APL_FFH_TILE_COUNT_Y; ++maxRow)
            maxLevelBits = max(maxLevelBits, Reduce_RowCount.Load(int3(APL_RowMaxLevelCoord(maxRow), 0)));

        Reduce_GlobalCount[APL_GlobalMaxLevelCoord()] = maxLevelBits;
    }
}


// =====================================================================================
// Pass 4: solve full compensation, pick the gain up to it, smooth it, and build its tone curve and lookup.
// SRV  t0 = GlobalHistCount t1 = GlobalHistOffset10 t2 = APLPrev
// UAV  u0 = APLState u1 = ToneCurveShape u2 = ToneCurveLUT
// =====================================================================================
Texture2D<int>      Solve_GlobalCount  : register(t0);
Texture2D<float>    Solve_GlobalOffset : register(t1);
Texture2D<float4>   Solve_APLPrev      : register(t2);
RWTexture2D<float4> Solve_APLState     : register(u0);
RWTexture2D<float4> Solve_ToneShape    : register(u1);
RWTexture2D<float>  Solve_ToneLUT      : register(u2);

// Tone curve over the brightest-channel histogram in PQ. The shoulder starts at BT.2408's reference white, or at
// BT.2390's knee where that's higher, and its range is shared out top down from the ceiling (Ward Larson, Rushmeier
// and Piatko 1997): each bin's center slope is its share of the pixels above the shoulder start times the
// shoulder's range over its PQ width, capped at 1, the source's own contrast. Slopes run linearly between centers,
// so the curve bends no sharper than one bin, and the brightest level the frame's pixels can hold sits at the
// ceiling.
groupshared float APL_CurveSlope[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveLowerPQ[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveUpperPQ[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveBinIntegral[APL_FFH_LEVEL_BINS];
groupshared float APL_CurveAbove[APL_FFH_LEVEL_BINS];

groupshared float2 APL_EvalSum[APL_FFH_MAX_BINS];
groupshared float APL_EvalBinCount[APL_FFH_MAX_BINS];
groupshared float2 APL_SolveLogGainRange;
groupshared float4 APL_ToneShape;

// The curve's top sits at the frame's brightest level, so the brightest content lands on the ceiling.
groupshared float APL_ContentTopPQ;

// Bins 1-3 and 5-7 never get pixels, and bins past 60 sit above the 10000 nit clamp.
static const int APL_TOP_LEVEL_BIN = 60;

static const int APL_GAIN_SOLVE_STEPS = 10;
static const int APL_GAIN_PICK_POINTS = 9;

// Half the smallest relative step between 10-bit PQ codes up to the signal peak, in log2. Gains whose mean error
// differs by less can't be told apart on the panel.
static const float APL_GAIN_TIE_LOG2 = 0.0065;
static const int APL_KNEE_SOLVE_STEPS = 20;
static const int APL_BEND_MAX_PIECES = 8;

float APL_ShoulderStartPQ(float ceilingPQ)
{
    float bt2390KneePQ = 1.5 * ceilingPQ - 0.5 * NitsToPQ(PANEL_SIGNAL_PEAK_NITS);
    return max(bt2390KneePQ, min(NitsToPQ(REFERENCE_WHITE_NITS), ceilingPQ));
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
    return APL_HistogramLevelBin64(APL_QuantizeNitsQ4(PQToNits(pq)));
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

// The knee bends over a quarter octave, about one histogram bin, and never less than at 1 nit. It never spans more
// than the gain lowered the ceiling, so an unboosted frame keeps the panel's own clip, or more than the content rises
// past the ceiling, so a frame that fits under it keeps its source levels and one just over it is pressed down only
// as far as it has to be. The compiler folds the signal peak's PQ, which can land a few ulps under the ceiling the
// GPU computes at gain 1, so the headroom never goes negative.
float APL_BendWidthPQ(float kneePQ, float ceilingPQ)
{
    float kneeNits = max(PQToNits(kneePQ), 1.0);
    float halfWidth = exp2(0.125);
    float quarterOctavePQ = NitsToPQ(kneeNits * halfWidth) - NitsToPQ(kneeNits / halfWidth);
    float headroomPQ = max(NitsToPQ(PANEL_SIGNAL_PEAK_NITS) - ceilingPQ, 0.0);
    float overshootPQ = max(APL_ContentTopPQ - ceilingPQ, 0.0);
    return min(quarterOctavePQ, min(headroomPQ, overshootPQ));
}

// Bent curve minus top-down curve where the bend ends. It grows with the knee and is 0 at the right one.
float APL_KneeMismatch(float kneePQ, float ceilingPQ)
{
    float bendWidth = APL_BendWidthPQ(kneePQ, ceilingPQ);
    float bendStart = kneePQ - 0.5 * bendWidth;
    float bendEnd = bendStart + bendWidth;
    float bentEndPQ = kneePQ + APL_CurveRampIntegral(bendStart, bendWidth, bendEnd);
    // The top-down curve never rises past the source, which it would on a frame that fits under the ceiling.
    return bentEndPQ - min(ceilingPQ - APL_CurveIntegralAbove(bendEnd), bendEnd);
}

// Where the curve leaves the source, or the ceiling when it never does. Without a bend the mismatch stays 0 below
// that point, so 0 moves the knee up.
float APL_SolveKneePQ(float ceilingPQ)
{
    float2 range = float2(0.0, ceilingPQ);

    [loop]
    for (int step = 0; step < APL_KNEE_SOLVE_STEPS; ++step)
    {
        float midPQ = 0.5 * (range.x + range.y);
        range = (APL_KneeMismatch(midPQ, ceilingPQ) <= 0.0) ? float2(midPQ, range.y) : float2(range.x, midPQ);
    }

    return 0.5 * (range.x + range.y);
}

// Source below the bend, the top-down curve above it, and a slope easing from 1 to the curve's across it.
float APL_EvaluateToneCurvePQ(float pq, float bendStart, float bendWidth, float ceilingPQ)
{
    if (pq <= bendStart)
        return pq;

    if (pq >= bendStart + bendWidth)
        return min(ceilingPQ - APL_CurveIntegralAbove(pq), pq);

    float bendOffset = pq - bendStart;
    return pq - bendOffset * bendOffset / (2.0 * bendWidth) + APL_CurveRampIntegral(bendStart, bendWidth, pq);
}

// Sums APL_EvalSum over the group. Every thread calls it and gets the total.
float2 APL_ReduceEvalSum(int localIndex)
{
    GroupMemoryBarrierWithGroupSync();

    [unroll]
    for (int stride = APL_FFH_MAX_BINS / 2; stride > 0; stride /= 2)
    {
        if (localIndex < stride)
            APL_EvalSum[localIndex] += APL_EvalSum[localIndex + stride];
        GroupMemoryBarrierWithGroupSync();
    }

    // Every thread reads the total before any writes the next sum, or a fast warp would overwrite it first.
    float2 total = APL_EvalSum[0];
    GroupMemoryBarrierWithGroupSync();
    return total;
}

float APL_LevelBinPixelCount(int levelBin)
{
    int first = levelBin * APL_FFH_SUB_BINS;
    return APL_EvalBinCount[first] + APL_EvalBinCount[first + 1] + APL_EvalBinCount[first + 2] + APL_EvalBinCount[first + 3];
}

// The tone curve's output for a sub-bin's mean level, valid once APL_SumBoostedFrame built the curve.
float APL_CurveNits(int localIndex, float meanLevelPQ, float ceilingPQ)
{
    int levelBin = localIndex / APL_FFH_SUB_BINS;
    float topDownPQ = ceilingPQ - (APL_CurveAbove[levelBin] - APL_CurveIntegralInBin(levelBin, meanLevelPQ));
    return PQToNits(min(meanLevelPQ, topDownPQ));
}

// Builds the tone curve for one gain in groupshared and returns the boosted frame's summed load and the detail it
// keeps. Each thread brings its own histogram bin and, below APL_FFH_LEVEL_BINS, its own level bin. Bins are mapped
// without the knee bend, which moves the load by a fraction of a percent.
float2 APL_SumBoostedFrame(int localIndex, float logGain, float binCount, float meanLevelPQ)
{
    float gain = exp2(logGain);
    float ceilingPQ = NitsToPQ(PANEL_SIGNAL_PEAK_NITS / gain);
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
    GroupMemoryBarrierWithGroupSync();

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        bool holdsContent = APL_IsRealLevelBin(localIndex) && APL_CurveLowerPQ[localIndex] < APL_ContentTopPQ;
        float binTopPQ = min(APL_CurveUpperPQ[localIndex], APL_ContentTopPQ);
        APL_CurveBinIntegral[localIndex] = holdsContent ? APL_CurveIntegralInBin(localIndex, binTopPQ) : 0.0;
    }
    GroupMemoryBarrierWithGroupSync();

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        float above = 0.0;

        [loop]
        for (int levelBin = localIndex; levelBin < APL_FFH_LEVEL_BINS; ++levelBin)
            above += APL_CurveBinIntegral[levelBin];

        APL_CurveAbove[localIndex] = above;
    }
    GroupMemoryBarrierWithGroupSync();

    float sentNits = gain * APL_CurveNits(localIndex, meanLevelPQ, ceilingPQ);
    float boostedNits = binCount * min(sentNits, PANEL_LOAD_PEAK_NITS);

    APL_EvalSum[localIndex] = float2(boostedNits, 0.0);
    return APL_ReduceEvalSum(localIndex);
}

// Black shows the same at every gain, so only lit pixels count toward the error and its tie tolerance.
bool APL_IsLitBin(float binCount, float meanLevelNits)
{
    return binCount > 0.0 && meanLevelNits > 1e-6;
}

// Pixels times the log2 error of shown over target, where the panel shows the sent light divided by the
// compensation at the boosted load. Valid once APL_SumBoostedFrame built the curve.
float APL_SumLogError(int localIndex, float logGain, float binCount, float meanLevelNits, float meanLevelPQ, float loadPercent)
{
    float error = 0.0;
    if (APL_IsLitBin(binCount, meanLevelNits))
    {
        float gain = exp2(logGain);
        float ceilingPQ = NitsToPQ(PANEL_SIGNAL_PEAK_NITS / gain);
        float shownNits = gain * APL_CurveNits(localIndex, meanLevelPQ, ceilingPQ) / PanelCompensation(loadPercent);
        float targetNits = min(meanLevelNits, PANEL_SIGNAL_PEAK_NITS);
        error = binCount * abs(log2(max(shownNits, 1e-6) / targetNits));
    }

    APL_EvalSum[localIndex] = float2(error, 0.0);
    return APL_ReduceEvalSum(localIndex).x;
}

// Highest grid point scoring within the tie tolerance of the best, since a higher gain keeps more of the frame at
// its target wherever the scores can't tell them apart.
int APL_HighestTiedGainPoint(float scores[APL_GAIN_PICK_POINTS], float litPixelCount)
{
    float bestScore = scores[0];

    [loop]
    for (int candidate = 1; candidate < APL_GAIN_PICK_POINTS; ++candidate)
        bestScore = max(bestScore, scores[candidate]);

    float tiedScore = bestScore - APL_GAIN_TIE_LOG2 * litPixelCount;
    int highest = 0;

    [loop]
    for (int gridIndex = 1; gridIndex < APL_GAIN_PICK_POINTS; ++gridIndex)
        highest = (scores[gridIndex] >= tiedScore) ? gridIndex : highest;

    return highest;
}

// Scores gains from 1 up to full compensation on a grid by their predicted EOTF error and takes the vertex of the
// parabola through the best point and its neighbors, so the pick moves smoothly as the frame changes.
float APL_PickLogGain(int localIndex, float fullLogGain, float binCount, float meanLevelNits, float meanLevelPQ, float fullLoadNitsSum, float litPixelCount)
{
    float scores[APL_GAIN_PICK_POINTS];
    float spacing = fullLogGain / float(APL_GAIN_PICK_POINTS - 1);

    [loop]
    for (int gridIndex = 0; gridIndex < APL_GAIN_PICK_POINTS; ++gridIndex)
    {
        float logGain = spacing * float(gridIndex);
        float loadPercent = 100.0 * APL_SumBoostedFrame(localIndex, logGain, binCount, meanLevelPQ).x / fullLoadNitsSum;
        scores[gridIndex] = -APL_SumLogError(localIndex, logGain, binCount, meanLevelNits, meanLevelPQ, loadPercent);
    }

    int best = 0;

    [loop]
    for (int candidate = 1; candidate < APL_GAIN_PICK_POINTS; ++candidate)
        best = (scores[candidate] > scores[best]) ? candidate : best;

    // Full compensation scoring best means nothing past it could score higher, and a parabola through its
    // neighbors would stop short of it on a frame that fits under the ceiling.
    if (best == APL_GAIN_PICK_POINTS - 1)
        return fullLogGain;

    // A tie above the best point is taken as is, since the parabola would pull it back toward the lower gain.
    int highestTied = APL_HighestTiedGainPoint(scores, litPixelCount);
    if (highestTied > best)
        return spacing * float(highestTied);

    int center = clamp(best, 1, APL_GAIN_PICK_POINTS - 2);
    float below = scores[center - 1];
    float above = scores[center + 1];
    float curvature = below - 2.0 * scores[center] + above;
    float offset = (curvature < 0.0) ? 0.5 * (below - above) / curvature : float(best - center);

    return clamp(spacing * (float(center) + offset), max(spacing * float(best - 1), 0.0), min(spacing * float(best + 1), fullLogGain));
}

[numthreads(APL_FFH_MAX_BINS, 1, 1)]
void CS_Solve(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    float binCount = 0.0;
    float meanLevelNits = 0.0;

    int3 binCoord = int3(APL_HistogramBlockCoord(localIndex), 0);
    binCount = float(Solve_GlobalCount.Load(binCoord));
    if (binCount > 0.0)
        meanLevelNits = APL_ReconstructMeanLevelQ4(localIndex, binCount, Solve_GlobalOffset.Load(binCoord)) * 0.25;

    float meanLevelPQ = NitsToPQ(meanLevelNits);
    float maxLevelNits = asfloat(Solve_GlobalCount.Load(int3(APL_GlobalMaxLevelCoord(), 0)));

    // Raw load counts pixels past the load peak as scaled down to it, and black bars as unlit panel.
    APL_EvalBinCount[localIndex] = binCount;
    APL_EvalSum[localIndex] = float2(binCount * min(meanLevelNits, PANEL_LOAD_PEAK_NITS), binCount);
    float2 rawFrame = APL_ReduceEvalSum(localIndex);
    float fullLoadNitsSum = max(rawFrame.y * PANEL_LOAD_PEAK_NITS / clamp(LitFraction, 0.01, 1.0), 1e-6);

    APL_EvalSum[localIndex] = float2(binCount * meanLevelPQ, APL_IsLitBin(binCount, meanLevelNits) ? binCount : 0.0);
    float2 meanAndLit = APL_ReduceEvalSum(localIndex);
    float frameMeanPQ = meanAndLit.x / max(rawFrame.y, 1.0);
    float litPixelCount = meanAndLit.y;

    if (localIndex < APL_FFH_LEVEL_BINS)
    {
        APL_CurveLowerPQ[localIndex] = NitsToPQ(APL_LevelBinLowerNits(localIndex));
        APL_CurveUpperPQ[localIndex] = NitsToPQ(APL_LevelBinUpperNits(localIndex));
    }

    if (localIndex == 0)
    {
        APL_SolveLogGainRange = float2(0.0, log2(PanelCompensation(100.0)));
        APL_ContentTopPQ = NitsToPQ(maxLevelNits);
    }
    GroupMemoryBarrierWithGroupSync();

    [loop]
    for (int step = 0; step < APL_GAIN_SOLVE_STEPS; ++step)
    {
        float2 range = APL_SolveLogGainRange;
        float midLogGain = 0.5 * (range.x + range.y);
        float boostedNitsSum = APL_SumBoostedFrame(localIndex, midLogGain, binCount, meanLevelPQ).x;

        if (localIndex == 0)
        {
            float loadPercent = 100.0 * boostedNitsSum / fullLoadNitsSum;
            bool needsMoreGain = log2(PanelCompensation(loadPercent)) > midLogGain;
            APL_SolveLogGainRange = needsMoreGain ? float2(midLogGain, range.y) : float2(range.x, midLogGain);
        }
        GroupMemoryBarrierWithGroupSync();
    }

    float2 solvedRange = APL_SolveLogGainRange;
    // A range that never moved up means the frame needs no gain, and the midpoint would only add the solve's
    // resolution, which the boost and the dither would then apply to every pixel.
    float fullLogGain = (solvedRange.x > 0.0) ? 0.5 * (solvedRange.x + solvedRange.y) : 0.0;
    float pickedLogGain = APL_PickLogGain(localIndex, fullLogGain, binCount, meanLevelNits, meanLevelPQ, fullLoadNitsSum, litPixelCount);

    float4 prevData = Solve_APLPrev.Load(int3(0, 0, 0));
    float hasPrev = (prevData.z > 0.0) ? 1.0 : 0.0;
    float smoothedMeanPQ = 0.0;
    float alpha = ComputeTemporalBlendFactor(frameMeanPQ, lerp(frameMeanPQ, prevData.x, hasPrev), smoothedMeanPQ);

    // Smoothing in log gain covers the same share of a brightness change both ways.
    float logGain = lerp(pickedLogGain, lerp(prevData.w, pickedLogGain, alpha), hasPrev);
    float boostedNitsSum = APL_SumBoostedFrame(localIndex, logGain, binCount, meanLevelPQ).x;

    if (localIndex == 0)
    {
        float ceilingPQ = NitsToPQ(PANEL_SIGNAL_PEAK_NITS / exp2(logGain));
        float kneePQ = APL_SolveKneePQ(ceilingPQ);
        float bendWidth = APL_BendWidthPQ(kneePQ, ceilingPQ);
        float bendStart = kneePQ - 0.5 * bendWidth;

        // The lookup takes over at its last entry before the bend, so it continues the source exactly.
        float lookupStartPQ = floor(bendStart * (TONE_CURVE_LUT_SIZE - 1)) / (TONE_CURVE_LUT_SIZE - 1);
        APL_ToneShape = float4(bendStart, bendWidth, ceilingPQ, PQToNits(lookupStartPQ));

        float rawLoad = rawFrame.x / fullLoadNitsSum;
        float outLoad = boostedNitsSum / fullLoadNitsSum;
        Solve_APLState[int2(0, 0)] = float4(smoothedMeanPQ, outLoad, 1.0, logGain);
        Solve_APLState[int2(1, 0)] = float4(rawLoad, fullLogGain, PQToNits(bendStart), PQToNits(ceilingPQ));
        Solve_ToneShape[int2(0, 0)] = APL_ToneShape;
    }
    GroupMemoryBarrierWithGroupSync();

    float4 shape = APL_ToneShape;

    [loop]
    for (int entry = localIndex; entry < TONE_CURVE_LUT_SIZE; entry += APL_FFH_MAX_BINS)
    {
        // Entries past the frame's brightest level stay unclamped, so the ones around it interpolate onto the ceiling
        // instead of under it. The boost clamps after interpolating.
        float inputPQ = float(entry) / float(TONE_CURVE_LUT_SIZE - 1);
        float shownPQ = APL_EvaluateToneCurvePQ(inputPQ, shape.x, shape.y, shape.z);
        Solve_ToneLUT[int2(entry, 0)] = max(shownPQ, 0.0);
    }
}


// =====================================================================================
// Pass 5: fullscreen boost. Clean copy -> back buffer.
// SRV  t0 = CleanCopy t1 = APLState t2 = ToneCurveShape t3 = ToneCurveLUT
// =====================================================================================
Texture2D<float4> Boost_CleanCopy : register(t0);
Texture2D<float4> Boost_APLState  : register(t1);
Texture2D<float4> Boost_ToneShape : register(t2);
Texture2D<float>  Boost_ToneLUT   : register(t3);

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

VSOut VS_Boost(uint id : SV_VertexID)
{
    VSOut o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

// Shown brightest channel under the applied tone curve, before the gain, interpolated between lookup entries.
float ComputeShownLevelNits(float levelNits, float4 shape)
{
    if (levelNits <= shape.w)
        return levelNits;

    float position = NitsToPQ(levelNits) * (TONE_CURVE_LUT_SIZE - 1);
    int entry = min(int(position), TONE_CURVE_LUT_SIZE - 2);
    float lower = Boost_ToneLUT.Load(int3(entry, 0, 0));
    float upper = Boost_ToneLUT.Load(int3(entry + 1, 0, 0));
    return PQToNits(min(lerp(lower, upper, saturate(position - float(entry))), shape.z));
}

// Scales the color by gain times the tone curve's shown brightest channel over its own, keeping its channel ratios.
// The scaling runs in Rec.2020 nits like the shader's, so both round the same way in the FP16 buffer.
float4 PS_Boost(VSOut i) : SV_Target
{
    float3 color = Boost_CleanCopy.Load(int3(int2(i.pos.xy), 0)).rgb;
    float3 colorNits = DecodeScRGBToRec2020Nits(color);
    float levelNits = Max3(max(colorNits, 0.0));

    if (levelNits <= 1e-6)
        return float4(color, 1.0);

    float gain = exp2(Boost_APLState.Load(int3(0, 0, 0)).w);
    float shownLevelNits = ComputeShownLevelNits(levelNits, Boost_ToneShape.Load(int3(0, 0, 0)));

    if (gain == 1.0 && shownLevelNits == levelNits)
        return float4(color, 1.0);

    float3 boostedNits = gain * colorNits * (shownLevelNits / levelNits);
    return float4(mul(REC2020_TO_REC709, boostedNits) / SCRGB_REFERENCE_NITS, 1.0);
}
