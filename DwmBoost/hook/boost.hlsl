// EOTF Boost for DWM — scRGB desktop path, ported from Shaders/EOTF_BoostMod2.0_27M2N6500.fx.
//
// The algorithm and output match the ReShade shader at its current defaults. Only the scRGB input
// path is kept (DWM composes into FP16 scRGB); the PQ-input branch, the fast-PQ decode table, the
// OSD, the compression heatmap, the debug graph, the calibration LUT, and every runtime uniform are
// removed, their values baked below. ReShade's frame time comes from the host in the constant buffer.
// ReShade intrinsics are replaced with plain HLSL: tex2Dstore ->
// RWTexture store, tex2Dfetch -> Load, atomicAdd -> InterlockedAdd, atomicMax -> InterlockedMax,
// barrier -> GroupMemoryBarrierWithGroupSync.
//
// Five stages, same sync boundaries as the source:
//   1  CS_Setup          last run's solve copy, row histogram and frame top clear
//   2  CS_Build          full-frame row histogram build (reads the clean copy)
//   3  CS_Reduce         global histogram reduction
//   4  CS_Solve          APL solve and boost curve fit
//   5  VS_Boost/PS_Boost fullscreen boost (clean copy -> back buffer)
//
// The source's skipped-frame pause detection used ReShade's frame counter, which does not exist
// here; the host raises ResetFlag instead (on enable, prime, and mode change) to drop the last
// frame's load.

// Baked defaults (ReShade uniform values).
static const float APLReferenceWhiteNits = 1060.0;
static const float PanelPeakNits         = 1060.0;
static const float SIGNAL_REFERENCE_NITS = 80.0;   // scRGB 1.0
static const float APLSmoothingSeconds   = 0.5;

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

// Rows take tile sums of squared bin positions in units of 256, so a whole row still fits an int.
#define APL_FFH_ROW_OFFSET_SQ_UNIT 256

// The curve above the knee is a table of output PQ codes over equal cells of full-gain PQ. One pixel can change
// one cell's slope, so the cells are narrow enough that this moves no level by a whole 10-bit step.
#define BOOST_CURVE_CELLS        512

// Each step of the curve solve keeps a third of its bracket, so 21 make it as narrow as 32 halvings.
#define BOOST_CURVE_SOLVE_STEPS   21

// Golden section steps of the gain search. Each keeps 0.618 of the bracket, so 12 shrink it from ln 3.77, up to the
// table's top compensation, to 0.0041, under the 0.0045 in ln of half a 10-bit PQ code at the panel peak.
#define BOOST_GAIN_SEARCH_STEPS   12

// The solve runs one thread per curve cell, and the first threads also read one histogram bin each.
#define APL_EVAL_THREADS         BOOST_CURVE_CELLS


cbuffer BoostCB : register(b0)
{
    uint  ResetFlag;       // 1 = resume after a pause: drop the last frame's load
    uint  BufferWidthPx;   // target back-buffer size; sets the histogram geometry
    uint  BufferHeightPx;
    float LitFraction;     // share of the native panel the buffer covers; the rest is black bars
    float FrameTime;       // milliseconds since the last run, as ReShade's frametime
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

// PQ contrast the fixed shoulder eases to. Content above the panel peak keeps at most this and no level keeps less.
static const float HIGHLIGHT_CONTRAST = 0.25;

// PQ width over which slopes ease between the full gain and the highlight contrast.
static const float KNEE_TRANSITION_PQ = 0.04;

// PQ size of the fine detail a pixel carries, the 0.2 average local RMS contrast of natural images (Frazor and
// Geisler 2006) at highlight levels, where a unit of natural log luminance spans about 0.108 PQ.
static const float DETAIL_PQ = 0.022;

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
// Pass 1: copy the last run's solve and clear the row histograms and the frame top. APLInstant holds the last
// run's raw APL, solved display APL, and a written flag, and in its second texel the track's load, the APL whose
// compensation is the shown gain and the APL whose compensation is the run's best gain.
// SRV  t0 = APLInstant
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowHistLoad u4 = APLPrev
//      u5 = RowHistOffsetSq u6 = FrameTop
// =====================================================================================
Texture2D<float4>   Setup_APLInstant  : register(t0);
RWTexture2D<int>    Setup_RowCount    : register(u0);
RWTexture2D<int>    Setup_RowOffset   : register(u1);
RWTexture2D<int>    Setup_RowMaxNits  : register(u2);
RWTexture2D<int>    Setup_RowLoad     : register(u3);
RWTexture2D<float4> Setup_APLPrev     : register(u4);
RWTexture2D<int>    Setup_RowOffsetSq : register(u5);
RWTexture2D<int>    Setup_FrameTop    : register(u6);

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
        Setup_APLPrev[int2(1, 0)] = Setup_APLInstant.Load(int3(1, 0, 0));
        Setup_FrameTop[int2(0, 0)] = 0;
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
        Setup_RowOffsetSq[coord] = 0;
    }
}


// =====================================================================================
// Pass 2: decode source pixels, accumulate row histograms and raise the frame top.
// SRV  t0 = CleanCopy
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowHistLoad u4 = RowHistOffsetSq
//      u5 = FrameTop
// =====================================================================================
Texture2D<float4> Build_CleanCopy   : register(t0);
RWTexture2D<int>  Build_RowCount    : register(u0);
RWTexture2D<int>  Build_RowOffset   : register(u1);
RWTexture2D<int>  Build_RowMaxNits  : register(u2);
RWTexture2D<int>  Build_RowLoad     : register(u3);
RWTexture2D<int>  Build_RowOffsetSq : register(u4);
RWTexture2D<int>  Build_FrameTop    : register(u5);

groupshared int APL_TilePackedCountLuma[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxNits[APL_FFH_MAX_BINS];
groupshared int APL_TileLoad[APL_FFH_MAX_BINS];
groupshared int APL_TileOffsetSq[APL_FFH_MAX_BINS];
groupshared int APL_TileTop;

void APL_DecodePackedFullFrameSample(int2 pixel, out int binIndex, out int packedContribution, out int maxNits2, out int loadQ4, out int offsetSq10, out int maxQ4, out int valid)
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

    float3 color = Build_CleanCopy.Load(int3(pixel, 0)).rgb;
    float3 channelNits = Rec709ToRec2020(color) * SIGNAL_REFERENCE_NITS;
    float sceneNits = max(GetLuma709(color) * SIGNAL_REFERENCE_NITS, 0.0);
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

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int maxNits2, int loadQ4, int offsetSq10, int valid)
{
    if (valid == 0)
        return;
    InterlockedAdd(APL_TilePackedCountLuma[binIndex], packedContribution);
    InterlockedAdd(APL_TileMaxNits[binIndex], maxNits2);
    InterlockedAdd(APL_TileLoad[binIndex], loadQ4);
    InterlockedAdd(APL_TileOffsetSq[binIndex], offsetSq10);
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
        APL_TileOffsetSq[localIndex] = 0;
    }
    if (localIndex == 0)
        APL_TileTop = 0;
    GroupMemoryBarrierWithGroupSync();

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
    InterlockedMax(APL_TileTop, max(max(t0, t1), max(t2, t3)));

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
    GroupMemoryBarrierWithGroupSync();

    if (localIndex == 0)
        InterlockedMax(Build_FrameTop[int2(0, 0)], APL_TileTop);

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

            InterlockedAdd(Build_RowOffsetSq[rowCoord], (APL_TileOffsetSq[localIndex] + APL_FFH_ROW_OFFSET_SQ_UNIT / 2) / APL_FFH_ROW_OFFSET_SQ_UNIT);
        }
    }
}


// =====================================================================================
// Pass 3: reduce the row histograms into one global histogram.
// SRV  t0 = RowHistCount t1 = RowHistOffset10 t2 = RowHistMaxNits t3 = RowHistLoad t4 = RowHistOffsetSq
// UAV  u0 = GlobalHistCount u1 = GlobalHistOffset10 u2 = GlobalHistMaxNits u3 = GlobalHistLoad
//      u4 = GlobalHistOffsetSq
// =====================================================================================
Texture2D<int>      Reduce_RowCount    : register(t0);
Texture2D<int>      Reduce_RowOffset   : register(t1);
Texture2D<int>      Reduce_RowMaxNits  : register(t2);
Texture2D<int>      Reduce_RowLoad     : register(t3);
Texture2D<int>      Reduce_RowOffsetSq : register(t4);
RWTexture2D<int>    Reduce_GlobalCount    : register(u0);
RWTexture2D<float>  Reduce_GlobalOffset   : register(u1);
RWTexture2D<float>  Reduce_GlobalMaxNits  : register(u2);
RWTexture2D<float>  Reduce_GlobalLoad     : register(u3);
RWTexture2D<float>  Reduce_GlobalOffsetSq : register(u4);

groupshared int   APL_ReduceCount[APL_FFH_REDUCE_THREADS];
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
    float offsetSqSum = 0.0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
    {
        int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
        countSum += Reduce_RowCount.Load(int3(sourceCoord, 0));
        offsetSum10 += float(Reduce_RowOffset.Load(int3(sourceCoord, 0)));
        maxSumNits += float(Reduce_RowMaxNits.Load(int3(sourceCoord, 0)));
        loadSumNits += float(Reduce_RowLoad.Load(int3(sourceCoord, 0)));
        offsetSqSum += float(Reduce_RowOffsetSq.Load(int3(sourceCoord, 0)));
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceMaxNits[localIndex] = maxSumNits;
    APL_ReduceLoad[localIndex] = loadSumNits;
    APL_ReduceOffsetSq[localIndex] = offsetSqSum;
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
        Reduce_GlobalOffsetSq[localBinCoord] = APL_ReduceOffsetSq[0];
    }
}

#undef APL_REDUCE_ROW_STAGE


// =====================================================================================
// Pass 4: measure the raw APL, pick the gain, fit the boost curve to the frame, and measure the APL it shows.
// SRV  t0 = GlobalHistCount t1 = GlobalHistOffset10 t2 = GlobalHistMaxNits t3 = GlobalHistLoad t4 = APLPrev
//      t5 = GlobalHistOffsetSq t6 = FrameTop
// UAV  u0 = APLInstant u1 = BoostParams u2 = BoostCurve
// =====================================================================================
Texture2D<int>      Solve_GlobalCount    : register(t0);
Texture2D<float>    Solve_GlobalOffset   : register(t1);
Texture2D<float>    Solve_GlobalMaxNits  : register(t2);
Texture2D<float>    Solve_GlobalLoad     : register(t3);
Texture2D<float4>   Solve_APLPrev        : register(t4);
Texture2D<float>    Solve_GlobalOffsetSq : register(t5);
Texture2D<int>      Solve_FrameTop       : register(t6);
RWTexture2D<float4> Solve_APLInstant  : register(u0);
RWTexture2D<float4> Solve_BoostParams : register(u1);
RWTexture2D<float>  Solve_BoostCurve  : register(u2);

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

// Sums every thread's APL_EvalSums entry and hands the total to every thread.
float2 APL_SumEvalSums(int localIndex)
{
    GroupMemoryBarrierWithGroupSync();

    if (localIndex < APL_REDUCE_SLICES)
    {
        float2 slice = 0.0;

        [loop]
        for (int entry = localIndex; entry < APL_EVAL_THREADS; entry += APL_REDUCE_SLICES)
            slice += APL_EvalSums[entry];

        APL_ReduceSlices[localIndex] = slice;
    }
    GroupMemoryBarrierWithGroupSync();

    if (localIndex == 0)
    {
        float2 total = 0.0;

        [loop]
        for (int i = 0; i < APL_REDUCE_SLICES; ++i)
            total += APL_ReduceSlices[i];

        APL_ReduceTotal = total;
    }
    GroupMemoryBarrierWithGroupSync();

    return APL_ReduceTotal;
}

float2 APL_MaxEvalSums(int localIndex)
{
    GroupMemoryBarrierWithGroupSync();

    if (localIndex < APL_REDUCE_SLICES)
    {
        float2 slice = APL_EvalSums[localIndex];

        [loop]
        for (int entry = localIndex + APL_REDUCE_SLICES; entry < APL_EVAL_THREADS; entry += APL_REDUCE_SLICES)
            slice = max(slice, APL_EvalSums[entry]);

        APL_ReduceSlices[localIndex] = slice;
    }
    GroupMemoryBarrierWithGroupSync();

    if (localIndex == 0)
    {
        float2 total = APL_ReduceSlices[0];

        [loop]
        for (int i = 1; i < APL_REDUCE_SLICES; ++i)
            total = max(total, APL_ReduceSlices[i]);

        APL_ReduceTotal = total;
    }
    GroupMemoryBarrierWithGroupSync();

    return APL_ReduceTotal;
}

// Sum of the APL_EvalSums entries from the first through slot, the entry each thread wrote, handed to that thread.
float2 APL_RunningEvalSums(int slot)
{
    GroupMemoryBarrierWithGroupSync();

    [unroll]
    for (int stride = 1; stride < APL_EVAL_THREADS; stride *= 2)
    {
        float2 lower = (slot >= stride) ? APL_EvalSums[slot - stride] : 0.0;
        GroupMemoryBarrierWithGroupSync();
        APL_EvalSums[slot] += lower;
        GroupMemoryBarrierWithGroupSync();
    }

    float2 total = APL_EvalSums[slot];
    GroupMemoryBarrierWithGroupSync();
    return total;
}

// Black bars add zero light but count as panel area.
float APL_AverageFromSums(float2 sums)
{
    return (sums.y > 0.0) ? saturate(sums.x * clamp(LitFraction, 0.01, 1.0) / sums.y) : 0.0;
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

// The frame's brightest channel, raised past the rounding.
float APL_FrameTopNits()
{
    return min((float(Solve_FrameTop.Load(int3(0, 0, 0))) + 1.5) * 0.25, 10000.0);
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

// Screen share per PQ width, averaged over the cells within half the knee transition, empty ones included, so slopes
// change smoothly and a level's weight grows from nothing with its share.
float APL_SmoothedCellDensity(int cell, BoostCurve curve)
{
    float width = CurveCellWidth(curve);
    int reach = int(min(0.5 * KNEE_TRANSITION_PQ / width, BOOST_CURVE_CELLS));
    int first = max(cell - reach, 0);
    int last = min(cell + reach, BOOST_CURVE_CELLS - 1);
    float shareSum = 0.0;

    [loop]
    for (int i = first; i <= last; ++i)
        shareSum += APL_CurveShare[i];

    return shareSum / float(last - first + 1) / width;
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

// Levels with no share nearby whose price ties mu give up the rest of the room from the top down, which moves only
// what sits above them. Returns the room the cell gives up.
float APL_FreeLevelGiven(int cell, float excess, float muLo, float muHi, float weight, float density, float slope, float length, BoostCurve curve)
{
    bool tied = density <= 0.0 && weight >= muLo && weight < muHi && length > 0.0;
    float room = tied ? length * (slope - CurveCellFloor(cell, curve)) : 0.0;

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
    GroupMemoryBarrierWithGroupSync();

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

    float given = APL_FreeLevelGiven(cell, excess, muLo, muHi, weight, density, slope, length, curve);
    if (given > 0.0)
        slope -= given / length;

    float departureU = APL_IntegrateCurveNodes(cell, slope, top, curve);
    if (cell == 0)
        APL_EvalBoostParams[1].y = departureU;
    GroupMemoryBarrierWithGroupSync();
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
    GroupMemoryBarrierWithGroupSync();

    float cellShare = APL_GatherCellShare(localIndex, 0.0, width);
    APL_EvalSums[localIndex] = float2(cellShare, 0.0);
    float below = APL_RunningEvalSums(localIndex).x - cellShare;

    APL_CostShare[localIndex] = cellShare;
    APL_CostWeight[localIndex] = 1.0 + 2.0 * (below - (1.0 - below - cellShare));
    return width;
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
    GroupMemoryBarrierWithGroupSync();

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

[numthreads(APL_EVAL_THREADS, 1, 1)]
void CS_Solve(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    float pixelCount = 0.0;
    float sceneNits = 0.0;
    float maxChannelNits = 0.0;
    float loadNits = 0.0;
    float2 maxChannelSpan = 0.0;

    if (localIndex < APL_FFH_MAX_BINS)
    {
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

            float offsetSqSum10 = Solve_GlobalOffsetSq.Load(int3(binCoord, 0)) * APL_FFH_ROW_OFFSET_SQ_UNIT;
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
    // time as the APL whose compensation it is, so a frame that fits eases its load linearly and a change of content
    // moves the gain one way. While nothing new is composed the panel keeps showing that frame, so its load still
    // holds. Without history the panel last showed the frame unboosted.
    float4 lastFrame = Solve_APLPrev.Load(int3(0, 0, 0));
    float3 lastTrack = Solve_APLPrev.Load(int3(1, 0, 0)).xyz;
    bool hasHistory = lastFrame.z > 0.0;
    float lastLoad = hasHistory ? lastTrack.x : APL_AverageFromSums(rawSums);
    float trackAPL = hasHistory ? min(lastLoad, lastTrack.z) : lastLoad;
    float trackComp = SceneGainFromLogGain(ComputeSceneLogGainFromAPL(trackAPL));
    float costWidth = APL_BuildCostGrid(localIndex, bin);

    // The gain that costs the frame the least, by golden section on its log up to the table's top compensation, held
    // under the compensation. While the bracket's top never comes down the cost falls all the way to the top, so the
    // compensation wins and a frame that fits stays exact. The search runs every frame, since barriers cannot sit
    // inside a branch on the frame's content.
    const float golden = 0.5 * (sqrt(5.0) - 1.0);
    const int trackFit = BOOST_GAIN_SEARCH_STEPS + 2;
    const int finalFit = trackFit + 1;
    float lo = 0.0;
    float hi = APL_ANCHORS[APL_ANCHOR_COUNT - 1].y * log(2.0);
    float a = hi - golden * hi;
    float b = golden * hi;
    float costA = 0.0;
    float costB = 0.0;
    bool fillA = true;
    bool lowered = false;
    float trackLoad = 0.0;
    float bestAPL = 1.0;
    float easedAPL = 0.0;
    float shownGain = 0.0;
    float shownComp = 0.0;

    // Every fit runs from this one call site, so the shader holds one copy of the fit, which runs faster than four. The
    // first two fits cost both inner points and each step after costs the point its shift adds. The track's fit then
    // measures the load the track's gain gives, and the last fit leaves the shown curve at the eased gain.
    [loop]
    for (int fit = 0; fit <= finalFit; ++fit)
    {
        float best = (costA < costB) ? a : b;
        float trackGain = lowered ? min(exp(best), trackComp) : trackComp;
        float gain = (fit < trackFit) ? exp(fillA ? a : b) : ((fit == trackFit) ? trackGain : shownGain);
        float fitComp = (fit == finalFit) ? shownComp : trackComp;
        float cost = APL_FitAndCost(localIndex, gain, fitComp, costWidth, bin);

        if (fit == trackFit)
        {
            trackLoad = APL_ShownAPL(localIndex, pixelCount, sceneNits, maxChannelNits, loadNits);
            if (lowered)
                bestAPL = APLFromSceneGain(exp(best));

            // The compensation is read at the eased APL plus however far the last load sits above the APL the ease
            // runs toward, which is nothing for a frame that fits, so there the gain matches it exactly.
            float targetAPL = (trackGain < trackComp) ? APLFromSceneGain(trackGain) : trackAPL;
            float loweredAPL = lastLoad - targetAPL;
            easedAPL = hasHistory ? lerp(lastTrack.y, targetAPL, ComputeTemporalBlendFactor(APLSmoothingSeconds)) : targetAPL;
            shownGain = SceneGainFromLogGain(ComputeSceneLogGainFromAPL(easedAPL));
            shownComp = SceneGainFromLogGain(ComputeSceneLogGainFromAPL(easedAPL + loweredAPL));
        }

        if (fit >= trackFit)
            continue;

        if (fillA)
            costA = cost;
        else
            costB = cost;

        fillA = costA < costB;

        if (fit == 0 || fit > BOOST_GAIN_SEARCH_STEPS)
            fillA = false;
        else if (fillA)
        {
            hi = b;
            b = a;
            costB = costA;
            a = hi - golden * (hi - lo);
            lowered = true;
        }
        else
        {
            lo = a;
            a = b;
            costA = costB;
            b = lo + golden * (hi - lo);
        }
    }

    float shownAPL = APL_ShownAPL(localIndex, pixelCount, sceneNits, maxChannelNits, loadNits);

    Solve_BoostCurve[int2(localIndex + 1, 0)] = APL_CurveNodes[localIndex + 1];

    if (localIndex == 0)
    {
        Solve_BoostCurve[int2(0, 0)] = APL_CurveNodes[0];
        Solve_BoostParams[int2(0, 0)] = APL_EvalBoostParams[0];
        Solve_BoostParams[int2(1, 0)] = APL_EvalBoostParams[1];
        Solve_APLInstant[int2(0, 0)] = float4(APL_AverageFromSums(rawSums), shownAPL, 1.0, 0.0);
        Solve_APLInstant[int2(1, 0)] = float4(trackLoad, easedAPL, bestAPL, 0.0);
    }
}


// =====================================================================================
// Pass 5: fullscreen boost. Clean copy -> back buffer.
// SRV  t0 = CleanCopy t1 = BoostParams t2 = BoostCurve
// =====================================================================================
Texture2D<float4> Boost_CleanCopy   : register(t0);
Texture2D<float4> Boost_BoostParams : register(t1);
Texture2D<float>  Boost_BoostCurve  : register(t2);
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

// Output PQ code of the fitted curve at the full-gain PQ code u.
float CurvePQ(float u, BoostCurve curve)
{
    if (u <= curve.kneeU)
        return u;

    float fraction;
    int cell = CurveCell(u, curve, fraction);
    float y0 = Boost_BoostCurve.Load(int3(cell, 0, 0));
    float y1 = Boost_BoostCurve.Load(int3(cell + 1, 0, 0));
    return min(lerp(y0, y1, fraction), curve.peakPQ);
}

// Luma and brightest Rec.2020 channel of a signal in nits, the channel never under the luma.
float2 GetSignalLumaAndMaxNits(float3 color)
{
    float2 levels = float2(GetLuma709(color), Max3(Rec709ToRec2020(color))) * SIGNAL_REFERENCE_NITS;
    return float2(levels.x, max(levels.y, levels.x));
}

float3 ApplyBoostFromPrecomputedParams(float3 color, BoostCurve curve)
{
    float2 levels = GetSignalLumaAndMaxNits(color);
    if (levels.x <= 1e-6)
        return color;

    if (levels.y <= curve.kneeNits)
        return color * curve.gain;

    float lumaY = CurvePQ(FullGainPQ(levels.x, curve), curve);
    float maxChannelY = CurvePQ(FullGainPQ(levels.y, curve), curve);
    return color * CurveBoostScale(levels.x, lumaY, levels.y, maxChannelY, curve);
}

float4 PS_Boost(VSOut i) : SV_Target
{
    int2 pixel = int2(i.pos.xy);
    float3 color = Boost_CleanCopy.Load(int3(pixel, 0)).rgb;

    BoostCurve curve = UnpackBoostCurve(Boost_BoostParams.Load(int3(0, 0, 0)), Boost_BoostParams.Load(int3(1, 0, 0)));
    color = ApplyBoostFromPrecomputedParams(color, curve);

    return float4(color, 1.0);
}
