// EOTF Boost for DWM — scRGB desktop path, ported from Shaders/EOTF_BoostMod2.0_27M2N6500.fx.
//
// The algorithm and output match the ReShade shader at its current defaults. Only the scRGB input
// path is kept (DWM composes into FP16 scRGB); the PQ-input branch, the fast-PQ decode table, the
// OSD, the debug graph, the calibration LUT, and every runtime uniform are removed, their values
// baked below. ReShade intrinsics are replaced with plain HLSL: tex2Dstore -> RWTexture store,
// tex2Dfetch -> Load, atomicAdd/atomicMax -> InterlockedAdd/Max, barrier -> GroupMemoryBarrierWithGroupSync.
//
// Five stages, same sync boundaries as the source:
//   1  CS_Setup          last run's solve copy and row histogram clear
//   2  CS_Build          full-frame row histogram build (reads the clean copy)
//   3  CS_Reduce         global histogram reduction
//   4  CS_Solve          APL solve and boost curve
//   5  VS_Boost/PS_Boost fullscreen boost (clean copy -> back buffer)
//
// The source's skipped-frame pause detection used ReShade's frame counter, which does not exist
// here; the host raises ResetFlag instead (on enable, prime, and mode change) to drop the last
// frame's load.

// Baked defaults (ReShade uniform values).
static const float APLReferenceWhiteNits = 1060.0;
static const float PanelPeakNits         = 1060.0;
static const float SIGNAL_REFERENCE_NITS = 80.0;   // scRGB 1.0

// Full-frame histogram layout. Each 16x16 group processes one 32x32 pixel tile.
#define APL_FFH_TILE_SIZE        32
#define APL_FFH_THREADS_X        16
#define APL_FFH_THREADS_Y        16
#define APL_FFH_PIXELS_X          2
#define APL_FFH_PIXELS_Y          2
#define APL_FFH_LUMA_BINS        64
#define APL_FFH_COLOR_RATIO_BINS  4
#define APL_FFH_MAX_BINS        256
#define APL_FFH_BLOCK_W          16
#define APL_FFH_BLOCK_H          16
#define APL_FFH_REDUCE_THREADS   64
#define APL_SETUP_THREADS       256

// Packed value: pixel count in the upper bits, summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT  20
#define APL_FFH_PACK_OFFSET_MASK  ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE 1023
#define APL_FFH_PACK_ONE_COUNT    (1 << APL_FFH_PACK_COUNT_SHIFT)

#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)


cbuffer BoostCB : register(b0)
{
    uint  ResetFlag;       // 1 = resume after a pause: drop the last frame's load
    uint  BufferWidthPx;   // target back-buffer size; sets the histogram geometry
    uint  BufferHeightPx;
    float LitFraction;     // share of the native panel the buffer covers; the rest is black bars
};

#define BUFFER_WIDTH  int(BufferWidthPx)
#define BUFFER_HEIGHT int(BufferHeightPx)


// -------- color and transfer helpers --------

float GetLuma709(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
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

static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

float PQToLinearBT2100(float v)
{
    float vp = pow(saturate(v), 1.0 / PQ_M2);
    float num = max(vp - PQ_C1, 0.0);
    float den = PQ_C2 - PQ_C3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / PQ_M1);
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

float NitsToPQ(float nits)          { return LinearToPQBT2100(nits / 10000.0); }
float NitsToPQUnclamped(float nits) { return LinearToPQBT2100Unclamped(nits / 10000.0); }


// -------- boost curve --------

// PQ contrast the shoulder keeps above the knee.
static const float HIGHLIGHT_CONTRAST = 0.25;

// PQ width over which the slope eases from the full gain to the highlight contrast.
static const float KNEE_TRANSITION_PQ = 0.04;

// Full gain up to the knee. Above it the slope eases to the highlight contrast so the panel peak signal lands
// on the panel peak. Levels named U are PQ codes after the full gain.
struct BoostCurve
{
    float gain;
    float peakPQ;
    float kneeNits;
    float kneeU;
};

// PQ code of a source PQ code after the full gain.
float GainMapPQ(float pq, float gain)
{
    return NitsToPQUnclamped(PQToLinearBT2100(pq) * 10000.0 * gain);
}

// How far the shoulder sits below the full gain at u.
float ShoulderCompressionPQ(float u, float kneeU)
{
    float t = max(u - kneeU, 0.0);
    float eased = (t < KNEE_TRANSITION_PQ)
        ? t * t / (2.0 * KNEE_TRANSITION_PQ)
        : t - 0.5 * KNEE_TRANSITION_PQ;

    return (1.0 - HIGHLIGHT_CONTRAST) * eased;
}

// The panel shows at most its peak divided by the gain, and that limit alone places the shoulder, so a level
// keeps its brightness whatever else is in the scene.
BoostCurve MakeBoostCurve(float gain)
{
    BoostCurve curve;
    curve.gain = max(gain, 1.0);
    curve.peakPQ = 1.0;
    curve.kneeNits = 10000.0;
    curve.kneeU = 1.0;

    if (PanelPeakNits <= 0.0 || curve.gain <= 1.000001)
        return curve;

    curve.peakPQ = NitsToPQ(PanelPeakNits);
    float maxU = GainMapPQ(curve.peakPQ, curve.gain);

    // The shoulder span that absorbs the overshoot, ending inside the slope ease or past it.
    float eased = (maxU - curve.peakPQ) / (1.0 - HIGHLIGHT_CONTRAST);
    float span = (eased < 0.5 * KNEE_TRANSITION_PQ)
        ? sqrt(2.0 * KNEE_TRANSITION_PQ * eased)
        : eased + 0.5 * KNEE_TRANSITION_PQ;

    curve.kneeU = maxU - span;
    curve.kneeNits = PQToLinearBT2100(curve.kneeU) * 10000.0 / curve.gain;
    return curve;
}

float4 PackBoostCurve(BoostCurve curve)
{
    return float4(curve.gain, curve.peakPQ, curve.kneeNits, curve.kneeU);
}

BoostCurve UnpackBoostCurve(float4 params)
{
    BoostCurve curve;
    curve.gain = params.x;
    curve.peakPQ = params.y;
    curve.kneeNits = params.z;
    curve.kneeU = params.w;
    return curve;
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
    float2(2.321928, 0.381141), // 5%   (813.9 nits)
    float2(2.584963, 0.553194), // 6%   (722.4 nits)
    float2(2.807355, 0.712673), // 7%   (646.8 nits)
    float2(3.000000, 0.851895), // 8%   (587.3 nits)
    float2(3.169925, 0.978654), // 9%   (537.9 nits)
    float2(3.321928, 1.093618), // 10%  (496.7 nits)
    float2(3.459432, 1.133372), // 11%  (483.2 nits)
    float2(3.584963, 1.161714), // 12%  (473.8 nits)
    float2(3.700440, 1.192490), // 13%  (463.8 nits)
    float2(3.807355, 1.216959), // 14%  (456.0 nits)
    float2(3.906891, 1.248625), // 15%  (446.1 nits)
    float2(4.087463, 1.285640), // 17%  (434.8 nits)
    float2(4.321928, 1.348022), // 20%  (416.4 nits)
    float2(4.459432, 1.375656), // 22%  (408.5 nits)
    float2(4.643856, 1.429629), // 25%  (393.5 nits)
    float2(4.754888, 1.457765), // 27%  (385.9 nits)
    float2(4.906891, 1.489516), // 30%  (377.5 nits)
    float2(5.129283, 1.533755), // 35%  (366.1 nits)
    float2(5.321928, 1.585916), // 40%  (353.1 nits)
    float2(5.643856, 1.668306), // 50%  (333.5 nits)
    float2(6.228819, 1.797656), // 75%  (304.9 nits)
    float2(6.643856, 1.882430)  // 100% (287.5 nits)
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

// Curve in signal nits: full gain up to the knee, then the shoulder. The panel clips signals above its peak,
// so those pass through.
float ApplyBoostCurveToNits(float nits, BoostCurve curve)
{
    float safeNits = max(nits, 0.0);

    if (safeNits <= curve.kneeNits)
        return safeNits * curve.gain;

    if (safeNits >= PanelPeakNits)
        return safeNits;

    float u = NitsToPQUnclamped(safeNits * curve.gain);
    float y = min(u - ShoulderCompressionPQ(u, curve.kneeU), curve.peakPQ);
    return max(PQToLinearBT2100(y) * 10000.0, safeNits);
}

// One scale for all channels. Luma follows the curve, and the brightest channel follows it too, which keeps it
// under the panel peak.
float ComputeBoostScale(float lumaNits, float maxChannelNits, BoostCurve curve)
{
    float lumaScale = ApplyBoostCurveToNits(lumaNits, curve) / max(lumaNits, 1e-6);

    if (maxChannelNits <= curve.kneeNits)
        return lumaScale;

    return min(lumaScale, ApplyBoostCurveToNits(maxChannelNits, curve) / maxChannelNits);
}

float3 ApplyBoostFromPrecomputedParams(float3 color, BoostCurve curve)
{
    if (curve.gain <= 1.000001)
        return color;

    float lumaNits = GetLuma709(color) * SIGNAL_REFERENCE_NITS;
    if (lumaNits <= 1e-6)
        return color;

    float maxChannelNits = Max3(Rec709ToRec2020(color)) * SIGNAL_REFERENCE_NITS;
    return color * ComputeBoostScale(lumaNits, maxChannelNits, curve);
}

// The boost scales all channels of a pixel by one factor, so the panel load scales with it.
float ComputePostBoostLoadMetric(float loadNits, float lumaNits, float maxChannelNits, BoostCurve curve)
{
    float boostScale = (lumaNits > 1e-6) ? ComputeBoostScale(lumaNits, max(maxChannelNits, lumaNits), curve) : 1.0;
    return saturate(loadNits * boostScale / max(APLReferenceWhiteNits, 1.0));
}


// -------- histogram quantization and binning --------

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

// =====================================================================================
// Pass 1: copy the last run's solve and clear the row histograms. APLInstant holds the last run's raw APL,
// solved display APL, and a written flag.
// SRV  t0 = APLInstant
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowHistLoad u4 = APLPrev
// =====================================================================================
Texture2D<float4>   Setup_APLInstant : register(t0);
RWTexture2D<int>    Setup_RowCount   : register(u0);
RWTexture2D<int>    Setup_RowOffset  : register(u1);
RWTexture2D<int>    Setup_RowMaxNits : register(u2);
RWTexture2D<int>    Setup_RowLoad    : register(u3);
RWTexture2D<float4> Setup_APLPrev    : register(u4);

[numthreads(APL_SETUP_THREADS, 1, 1)]
void CS_Setup(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    if (localIndex == 0)
    {
        float4 instantData = Setup_APLInstant.Load(int3(0, 0, 0));

        // Before a reset the panel showed the frames unboosted, so the stored load is stale.
        if (ResetFlag != 0u)
            instantData.z = 0.0;

        Setup_APLPrev[int2(0, 0)] = instantData;
    }

    [loop]
    for (int entry = localIndex; entry < APL_FFH_TILE_COUNT_Y * APL_FFH_MAX_BINS; entry += APL_SETUP_THREADS)
    {
        int rowIndex = entry / APL_FFH_MAX_BINS;
        int binIndex = entry - rowIndex * APL_FFH_MAX_BINS;
        int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
        Setup_RowCount[coord] = 0;
        Setup_RowOffset[coord] = 0;
        Setup_RowMaxNits[coord] = 0;
        Setup_RowLoad[coord] = 0;
    }
}


// =====================================================================================
// Pass 2: decode source pixels and accumulate row histograms.
// SRV  t0 = CleanCopy
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowHistLoad
// =====================================================================================
Texture2D<float4> Build_CleanCopy : register(t0);
RWTexture2D<int>  Build_RowCount   : register(u0);
RWTexture2D<int>  Build_RowOffset  : register(u1);
RWTexture2D<int>  Build_RowMaxNits : register(u2);
RWTexture2D<int>  Build_RowLoad    : register(u3);

groupshared int APL_TilePackedCountLuma[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxNits[APL_FFH_MAX_BINS];
groupshared int APL_TileLoad[APL_FFH_MAX_BINS];

void APL_DecodePackedFullFrameSample(int2 pixel, out int binIndex, out int packedContribution, out int maxNits2, out int loadQ4, out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    maxNits2 = 0;
    loadQ4 = 0;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 color = Build_CleanCopy.Load(int3(pixel, 0)).rgb;
    float3 channelNits = Rec709ToRec2020(color) * SIGNAL_REFERENCE_NITS;
    float sceneNits = max(GetLuma709(color) * SIGNAL_REFERENCE_NITS, 0.0);
    float maxChannelNits = max(Max3(channelNits), 0.0);
    loadQ4 = APL_QuantizeNitsQ4(GetPanelLoadNits(channelNits));

    int lumaQ4 = APL_QuantizeNitsQ4(sceneNits);
    int maxQ4 = APL_QuantizeNitsQ4(maxChannelNits);
    int lumaBin = APL_HistogramLumaBin64(lumaQ4);
    binIndex = lumaBin * APL_FFH_COLOR_RATIO_BINS + APL_HistogramColorRatioBin(lumaQ4, maxQ4);

    int offset10 = APL_EncodeWithinBinOffset10(lumaQ4, lumaBin);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    maxNits2 = APL_QuantizeMaxNits2(maxChannelNits);
    valid = 1;
}

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int maxNits2, int loadQ4, int valid)
{
    if (valid == 0)
        return;
    InterlockedAdd(APL_TilePackedCountLuma[binIndex], packedContribution);
    InterlockedAdd(APL_TileMaxNits[binIndex], maxNits2);
    InterlockedAdd(APL_TileLoad[binIndex], loadQ4);
}

[numthreads(APL_FFH_THREADS_X, APL_FFH_THREADS_Y, 1)]
void CS_Build(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;

    if (localIndex < APL_FFH_MAX_BINS)
    {
        APL_TilePackedCountLuma[localIndex] = 0;
        APL_TileMaxNits[localIndex] = 0;
        APL_TileLoad[localIndex] = 0;
    }
    GroupMemoryBarrierWithGroupSync();

    int row = int(groupID.y);
    int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, row * APL_FFH_TILE_SIZE) + int2(threadID.xy) * int2(APL_FFH_PIXELS_X, APL_FFH_PIXELS_Y);

    int b0, p0, m0, w0, v0;
    int b1, p1, m1, w1, v1;
    int b2, p2, m2, w2, v2;
    int b3, p3, m3, w3, v3;
    APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), b0, p0, m0, w0, v0);
    APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), b1, p1, m1, w1, v1);
    APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), b2, p2, m2, w2, v2);
    APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), b3, p3, m3, w3, v3);

    if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; m0 += m1; w0 += w1; v1 = 0; }
    if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; m0 += m2; w0 += w2; v2 = 0; }
    if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; m1 += m2; w1 += w2; v2 = 0; }
    if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; m0 += m3; w0 += w3; v3 = 0; }
    if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; m1 += m3; w1 += w3; v3 = 0; }
    if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; m2 += m3; w2 += w3; v3 = 0; }

    APL_AtomicAddMergedTileSample(b0, p0, m0, w0, v0);
    APL_AtomicAddMergedTileSample(b1, p1, m1, w1, v1);
    APL_AtomicAddMergedTileSample(b2, p2, m2, w2, v2);
    APL_AtomicAddMergedTileSample(b3, p3, m3, w3, v3);
    GroupMemoryBarrierWithGroupSync();

    if (localIndex < APL_FFH_MAX_BINS)
    {
        int packedValue = APL_TilePackedCountLuma[localIndex];
        int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
        if (count > 0)
        {
            int offsetSum10 = packedValue & APL_FFH_PACK_OFFSET_MASK;
            int2 rowCoord = APL_RowHistogramCoord(row, int(localIndex));
            InterlockedAdd(Build_RowCount[rowCoord], count);
            InterlockedAdd(Build_RowOffset[rowCoord], offsetSum10);
            InterlockedAdd(Build_RowMaxNits[rowCoord], APL_TileMaxNits[localIndex]);

            // Rows take whole nits so a row of 10000 nit pixels still fits an int.
            InterlockedAdd(Build_RowLoad[rowCoord], (APL_TileLoad[localIndex] + 2) >> 2);
        }
    }
}


// =====================================================================================
// Pass 3: reduce the row histograms into one global histogram.
// SRV  t0 = RowHistCount t1 = RowHistOffset10 t2 = RowHistMaxNits t3 = RowHistLoad
// UAV  u0 = GlobalHistCount u1 = GlobalHistOffset10 u2 = GlobalHistMaxNits u3 = GlobalHistLoad
// =====================================================================================
Texture2D<int>      Reduce_RowCount   : register(t0);
Texture2D<int>      Reduce_RowOffset  : register(t1);
Texture2D<int>      Reduce_RowMaxNits : register(t2);
Texture2D<int>      Reduce_RowLoad    : register(t3);
RWTexture2D<int>    Reduce_GlobalCount   : register(u0);
RWTexture2D<float>  Reduce_GlobalOffset  : register(u1);
RWTexture2D<float>  Reduce_GlobalMaxNits : register(u2);
RWTexture2D<float>  Reduce_GlobalLoad    : register(u3);

groupshared int   APL_ReduceCount[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffset10[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceMaxNits[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceLoad[APL_FFH_REDUCE_THREADS];

#define APL_REDUCE_ROW_STAGE(S) \
    if (localIndex < S) { \
        APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + S]; \
        APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + S]; \
        APL_ReduceMaxNits[localIndex] += APL_ReduceMaxNits[localIndex + S]; \
        APL_ReduceLoad[localIndex] += APL_ReduceLoad[localIndex + S]; \
    } \
    GroupMemoryBarrierWithGroupSync();

[numthreads(APL_FFH_REDUCE_THREADS, 1, 1)]
void CS_Reduce(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;

    int countSum = 0;
    float offsetSum10 = 0.0;
    float maxSumNits = 0.0;
    float loadSumNits = 0.0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
    {
        int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
        countSum += Reduce_RowCount.Load(int3(sourceCoord, 0));
        offsetSum10 += float(Reduce_RowOffset.Load(int3(sourceCoord, 0)));
        maxSumNits += float(Reduce_RowMaxNits.Load(int3(sourceCoord, 0)));
        loadSumNits += float(Reduce_RowLoad.Load(int3(sourceCoord, 0)));
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceMaxNits[localIndex] = maxSumNits;
    APL_ReduceLoad[localIndex] = loadSumNits;
    GroupMemoryBarrierWithGroupSync();

    APL_REDUCE_ROW_STAGE(32)
    APL_REDUCE_ROW_STAGE(16)
    APL_REDUCE_ROW_STAGE(8)
    APL_REDUCE_ROW_STAGE(4)
    APL_REDUCE_ROW_STAGE(2)
    APL_REDUCE_ROW_STAGE(1)

    if (localIndex == 0)
    {
        Reduce_GlobalCount[localBinCoord] = APL_ReduceCount[0];
        Reduce_GlobalOffset[localBinCoord] = APL_ReduceOffset10[0];
        Reduce_GlobalMaxNits[localBinCoord] = APL_ReduceMaxNits[0];
        Reduce_GlobalLoad[localBinCoord] = APL_ReduceLoad[0];
    }
}

#undef APL_REDUCE_ROW_STAGE


// =====================================================================================
// Pass 4: measure the raw APL, pick the gain, measure the APL it shows, and write the boost curve.
// SRV  t0 = GlobalHistCount t1 = GlobalHistOffset10 t2 = GlobalHistMaxNits t3 = GlobalHistLoad t4 = APLPrev
// UAV  u0 = APLInstant u1 = BoostParams
// =====================================================================================
Texture2D<int>      Solve_GlobalCount   : register(t0);
Texture2D<float>    Solve_GlobalOffset  : register(t1);
Texture2D<float>    Solve_GlobalMaxNits : register(t2);
Texture2D<float>    Solve_GlobalLoad    : register(t3);
Texture2D<float4>   Solve_APLPrev       : register(t4);
RWTexture2D<float4> Solve_APLInstant  : register(u0);
RWTexture2D<float4> Solve_BoostParams : register(u1);

// Each bin's APL metric times its pixel count, and the pixel count.
groupshared float2 APL_EvalSums[APL_FFH_MAX_BINS];
groupshared float4 APL_EvalBoostParams;

#define APL_REDUCE_EVAL_STAGE(S) \
    if (localIndex < S) \
        APL_EvalSums[localIndex] += APL_EvalSums[localIndex + S]; \
    GroupMemoryBarrierWithGroupSync();

// Sums every bin into APL_EvalSums[0].
#define APL_REDUCE_EVAL_SUMS \
    APL_REDUCE_EVAL_STAGE(128) \
    APL_REDUCE_EVAL_STAGE(64) \
    APL_REDUCE_EVAL_STAGE(32) \
    APL_REDUCE_EVAL_STAGE(16) \
    APL_REDUCE_EVAL_STAGE(8) \
    APL_REDUCE_EVAL_STAGE(4) \
    APL_REDUCE_EVAL_STAGE(2) \
    APL_REDUCE_EVAL_STAGE(1)

// Black bars add zero light but count as panel area.
float APL_AverageFromSums(float2 sums)
{
    return (sums.y > 0.0) ? saturate(sums.x * clamp(LitFraction, 0.01, 1.0) / sums.y) : 0.0;
}

[numthreads(APL_FFH_MAX_BINS, 1, 1)]
void CS_Solve(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    float pixelCount = 0.0;
    float sceneNits = 0.0;
    float maxChannelNits = 0.0;
    float loadNits = 0.0;

    int2 binCoord = APL_HistogramBlockCoord(localIndex);
    int pixelCountI = Solve_GlobalCount.Load(int3(binCoord, 0));
    if (pixelCountI > 0)
    {
        pixelCount = float(pixelCountI);
        float offsetSum10 = Solve_GlobalOffset.Load(int3(binCoord, 0));
        float meanLumaQ4 = APL_ReconstructMeanLumaQ4(localIndex, pixelCount, offsetSum10);
        sceneNits = max(meanLumaQ4 * 0.25, 0.0);
        float maxSumNits = Solve_GlobalMaxNits.Load(int3(binCoord, 0));
        maxChannelNits = max((maxSumNits / pixelCount) * 2.0, sceneNits);
        loadNits = Solve_GlobalLoad.Load(int3(binCoord, 0)) / pixelCount;
    }

    APL_EvalSums[localIndex] = float2(saturate(loadNits / max(APLReferenceWhiteNits, 1.0)), 1.0) * pixelCount;
    GroupMemoryBarrierWithGroupSync();
    APL_REDUCE_EVAL_SUMS

    float rawAPL = 0.0;
    if (localIndex == 0)
    {
        rawAPL = APL_AverageFromSums(APL_EvalSums[0]);

        // The panel dims each frame for the load of the frame before it, the last one it has fully received,
        // so the gain cancels the dimming that load calls for. While nothing new is composed the panel keeps
        // showing that frame, so its load still holds. Without history the panel last showed the frame unboosted.
        float4 lastFrame = Solve_APLPrev.Load(int3(0, 0, 0));
        float lastDisplayAPL = (lastFrame.z > 0.0) ? lastFrame.y : rawAPL;
        APL_EvalBoostParams = PackBoostCurve(MakeBoostCurve(SceneGainFromLogGain(ComputeSceneLogGainFromAPL(lastDisplayAPL))));
    }
    GroupMemoryBarrierWithGroupSync();

    // The gain is known before this frame shows, so its load is measured at that gain.
    BoostCurve curve = UnpackBoostCurve(APL_EvalBoostParams);
    APL_EvalSums[localIndex] = float2(ComputePostBoostLoadMetric(loadNits, sceneNits, maxChannelNits, curve), 1.0) * pixelCount;
    GroupMemoryBarrierWithGroupSync();
    APL_REDUCE_EVAL_SUMS

    if (localIndex == 0)
    {
        float displayAPL = APL_AverageFromSums(APL_EvalSums[0]);
        Solve_APLInstant[int2(0, 0)] = float4(rawAPL, displayAPL, 1.0, 0.0);
        Solve_BoostParams[int2(0, 0)] = APL_EvalBoostParams;
    }
}

#undef APL_REDUCE_EVAL_SUMS
#undef APL_REDUCE_EVAL_STAGE


// =====================================================================================
// Pass 5: fullscreen boost. Clean copy -> back buffer.
// SRV  t0 = CleanCopy t1 = BoostParams
// =====================================================================================
Texture2D<float4> Boost_CleanCopy   : register(t0);
Texture2D<float4> Boost_BoostParams : register(t1);
SamplerState      Boost_PointSamp   : register(s0);

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

float4 PS_Boost(VSOut i) : SV_Target
{
    int2 pixel = int2(i.pos.xy);
    float3 color = Boost_CleanCopy.Load(int3(pixel, 0)).rgb;

    BoostCurve curve = UnpackBoostCurve(Boost_BoostParams.Load(int3(0, 0, 0)));
    color = ApplyBoostFromPrecomputedParams(color, curve);

    return float4(color, 1.0);
}
