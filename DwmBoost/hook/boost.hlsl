// EOTF Boost for DWM — scRGB desktop path, ported from Shaders/EOTF_BoostMod2.0_27M2N6500.fx.
//
// The algorithm and output match the ReShade shader at its current defaults. Only the scRGB input
// path is kept (DWM composes into FP16 scRGB); the PQ-input branch, the fast-PQ decode table, the
// OSD, the debug graph, the calibration LUT, and every runtime uniform are removed, their values
// baked below. ReShade intrinsics are replaced with plain HLSL: tex2Dstore -> RWTexture store,
// tex2Dfetch -> Load, atomicAdd/atomicMax -> InterlockedAdd/Max, barrier -> GroupMemoryBarrierWithGroupSync.
//
// Five stages, same sync boundaries as the source:
//   1  CS_Setup          frame setup and rolling-row clear
//   2  CS_Build          full-frame row histogram build (reads the clean copy)
//   3  CS_Reduce         global histogram reduction
//   4  CS_Solve          highlight peak, response solve, smoothing, boost parameters
//   5  VS_Boost/PS_Boost fullscreen boost (clean copy -> back buffer)
//
// The source's skipped-frame pause detection used ReShade's frame counter, which does not exist
// here; the host raises ResetFlag instead (on enable, prime, and mode change) to drop stale rows
// and smoothing history.
//
// DWM also stops presenting while the screen is static, where a game keeps presenting the same frame.
// The host passes that gap apart from the one-frame step, and the smoothing first converges toward
// the previous run's targets over the gap, as the ReShade passes would on the repeated frames.

// Baked defaults (ReShade uniform values).
static const float APLReferenceWhiteNits        = 1060.0;
static const float PanelPeakNits                = 1060.0;
static const float CompensationFreezeAPLPercent = 50.0;
static const float HighlightContrast            = 0.40;
static const float TransitionSpeed              = 0.25;   // APL smoothing time, seconds
static const float SIGNAL_REFERENCE_NITS        = 80.0;   // scRGB 1.0

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
#define APL_FFH_AUX_X            APL_FFH_BLOCK_W
#define APL_FFH_REDUCE_THREADS   64
#define APL_SETUP_THREADS       256

// Packed value: pixel count in the upper bits, summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT  20
#define APL_FFH_PACK_OFFSET_MASK  ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE 1023
#define APL_FFH_PACK_ONE_COUNT    (1 << APL_FFH_PACK_COUNT_SHIFT)

#define APL_FFH_TILE_COUNT_X ((BUFFER_WIDTH  + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)
#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)

#define APL_FFH_ROW_HIST_TEX_W  APL_FFH_BLOCK_W
#define APL_FFH_ROW_COUNT_TEX_W (APL_FFH_BLOCK_W + 1)
#define APL_FFH_ROW_TEX_H       (APL_FFH_TILE_COUNT_Y * APL_FFH_BLOCK_H)

#define APL_FULLFRAME_ROLLING_PHASES 6
#define APL_FFH_ROLLING_ROW_SLOTS ((APL_FFH_TILE_COUNT_Y + APL_FULLFRAME_ROLLING_PHASES - 1) / APL_FULLFRAME_ROLLING_PHASES)
#define APL_FFH_ROW_META_COUNT_BITS 20
#define APL_FFH_ROW_META_COUNT_MASK ((1 << APL_FFH_ROW_META_COUNT_BITS) - 1)


cbuffer BoostCB : register(b0)
{
    float FrameTime;   // ms, at most one refresh period: this frame's smoothing step
    float GapTime;     // ms the previous frame stayed on screen beyond that step
    uint  ResetFlag;   // 1 = resume after a pause: drop stale rows and smoothing history
    float _cbpad;
    uint  BufferWidthPx;   // target back-buffer size; sets the histogram geometry
    uint  BufferHeightPx;
    uint2 _cbpad2;
};

#define BUFFER_WIDTH  int(BufferWidthPx)
#define BUFFER_HEIGHT int(BufferHeightPx)


// Fixed constants carried over from the source.
static const float OUTLIER_HIGHLIGHT_CONTRAST   = 0.25;
static const float SHOULDER_BLEND_POWER         = 6.0;
static const float FULL_GAIN_SHOULDER_CLEARANCE = 3.0;
static const float HIGHLIGHT_PEAK_LIGHT_FRACTION = 1.0 / 256.0;


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

struct BoostParams
{
    float gain;
    float peakPQ;
    float highlightPQ;
    float highlightTopPQ;
    float fullGainNits;
};

float GetHighlightContrast()
{
    return clamp(HighlightContrast, OUTLIER_HIGHLIGHT_CONTRAST, 0.95);
}

float HighlightShoulderOffset(float x, BoostParams params)
{
    return params.highlightTopPQ + GetHighlightContrast() * (x - params.highlightPQ) - x;
}

float PeakShoulderOffset(float x, BoostParams params)
{
    return (1.0 - OUTLIER_HIGHLIGHT_CONTRAST) * (params.peakPQ - x);
}

float SmoothMinOffset(float a, float b, float c)
{
    float smallest = min(a, min(b, c));
    if (smallest <= 0.0)
        return 0.0;

    float3 ratios = smallest / max(float3(a, b, c), 1e-9);
    float3 weights = pow(ratios, SHOULDER_BLEND_POWER);
    return smallest * pow(weights.x + weights.y + weights.z, -1.0 / SHOULDER_BLEND_POWER);
}

float SmoothMinOffset(float a, float b)
{
    float smallest = min(a, b);
    if (smallest <= 0.0)
        return 0.0;

    float2 ratios = smallest / max(float2(a, b), 1e-9);
    float2 weights = pow(ratios, SHOULDER_BLEND_POWER);
    return smallest * pow(weights.x + weights.y, -1.0 / SHOULDER_BLEND_POWER);
}

float ComputeFullGainLimitNits(BoostParams params)
{
    float maxGainOffset = max(NitsToPQUnclamped(PanelPeakNits * params.gain) - params.peakPQ, 0.0);
    float clearance = FULL_GAIN_SHOULDER_CLEARANCE * maxGainOffset;
    float highlightContrast = GetHighlightContrast();

    float highlightLimitPQ = (params.highlightTopPQ - highlightContrast * params.highlightPQ - clearance) / (1.0 - highlightContrast);
    float peakLimitPQ = params.peakPQ - clearance / (1.0 - OUTLIER_HIGHLIGHT_CONTRAST);
    float limitPQ = min(highlightLimitPQ, peakLimitPQ);

    return (limitPQ > 0.0) ? PQToLinearBT2100(limitPQ) * 10000.0 : 0.0;
}

BoostParams MakeBoostParams(float gain, float highlightPQ)
{
    BoostParams params;
    params.gain = max(gain, 1.0);
    params.peakPQ = 0.0;
    params.highlightPQ = 0.0;
    params.highlightTopPQ = 0.0;
    params.fullGainNits = 10000.0;

    if (PanelPeakNits <= 0.0 || params.gain <= 1.000001)
        return params;

    params.peakPQ = NitsToPQ(PanelPeakNits);
    params.highlightPQ = clamp(highlightPQ, 0.0, params.peakPQ);
    params.highlightTopPQ = params.peakPQ - OUTLIER_HIGHLIGHT_CONTRAST * (params.peakPQ - params.highlightPQ);
    params.fullGainNits = ComputeFullGainLimitNits(params);
    return params;
}

float4 PackBoostParamsRow0(BoostParams params)
{
    return float4(params.gain, params.peakPQ, params.highlightPQ, params.highlightTopPQ);
}

float4 PackBoostParamsRow1(BoostParams params)
{
    return float4(params.fullGainNits, 0.0, 0.0, 0.0);
}

BoostParams UnpackBoostParams(float4 row0, float4 row1)
{
    BoostParams params;
    params.gain = row0.x;
    params.peakPQ = row0.y;
    params.highlightPQ = row0.z;
    params.highlightTopPQ = row0.w;
    params.fullGainNits = row1.x;
    return params;
}

float Remap01(float x, float a, float b)
{
    return saturate((x - a) / max(b - a, 1e-6));
}

float SegmentLerp(float x, float x0, float y0, float x1, float y1)
{
    return lerp(y0, y1, Remap01(x, x0, x1));
}

// Measured APL anchors of the compensation table.
static const int APL_ANCHOR_COUNT = 7;

static const float APL_ANCHOR_POINTS[APL_ANCHOR_COUNT] =
{
    2.000000, 5.000000, 10.000000, 25.000000, 50.000000, 75.000000, 100.000000
};

// 1D compensation: the 1060 nit peak at 2% APL divided by the peak at each anchor,
// measured by TFTCentral on the Dell Alienware AW2725DF (same panel, HDR Peak 1000, FW M2B102).
static const float COMP_APL_1D[APL_ANCHOR_COUNT] =
{
    1.000000, // 2%   (1060 nits)
    1.362468, // 5%   (778 nits)
    2.217573, // 10%  (478 nits)
    2.796834, // 25%  (379 nits)
    3.322884, // 50%  (319 nits)
    3.680556, // 75%  (288 nits)
    3.925926  // 100% (270 nits)
};

int FindAPLAnchorIndex(float aplPct)
{
    int idx = 0;
    [unroll]
    for (int i = 0; i < APL_ANCHOR_COUNT - 1; ++i)
        idx += int(step(APL_ANCHOR_POINTS[i + 1], aplPct));
    return min(idx, APL_ANCHOR_COUNT - 2);
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
    float clampedAPL = clamp(lookupAPL, APL_ANCHOR_POINTS[0], APL_ANCHOR_POINTS[APL_ANCHOR_COUNT - 1]);
    int a0 = FindAPLAnchorIndex(clampedAPL);
    int a1 = min(a0 + 1, APL_ANCHOR_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        APL_ANCHOR_POINTS[a0], COMP_APL_1D[a0],
        APL_ANCHOR_POINTS[a1], COMP_APL_1D[a1]
    );
}

float ComputeTemporalBlendFactor(float smoothingSeconds, float elapsedMs)
{
    if (smoothingSeconds <= 1e-6)
        return 1.0;

    float dtSeconds = max(elapsedMs, 0.0) * 0.001;
    return saturate(1.0 - exp(-dtSeconds / max(smoothingSeconds, 1e-6)));
}

float ComputeSceneLogGainFromAPL(float currentAPL)
{
    float aplPct = saturate(currentAPL) * 100.0;
    return log2(max(LookupMeasuredComp1D(aplPct), 1.0));
}

float ComputeCandidateMaxLogGain()
{
    return ComputeSceneLogGainFromAPL(APL_ANCHOR_POINTS[APL_ANCHOR_COUNT - 1] * 0.01);
}

BoostParams ComputeBoostParamsFromSceneLogGain(float sceneLogGain, float highlightPQ)
{
    return MakeBoostParams(exp2(max(sceneLogGain, 0.0)), highlightPQ);
}

BoostParams MakeCandidateBoostParams(int candidateIndex, float gMax, float highlightPQ)
{
    return ComputeBoostParamsFromSceneLogGain(gMax * float(candidateIndex) / 3.0, highlightPQ);
}

// Luma curve in signal nits: full gain, eased out by the PQ shoulders.
float ApplyBoostCurveToNits(float nits, BoostParams params)
{
    float safeNits = max(nits, 0.0);

    if (params.peakPQ <= 0.0 || safeNits <= params.fullGainNits)
        return safeNits * params.gain;

    float x = NitsToPQ(safeNits);
    if (x >= params.peakPQ)
        return safeNits;

    float gainOffset = NitsToPQUnclamped(safeNits * params.gain) - x;
    float offset = SmoothMinOffset(gainOffset, HighlightShoulderOffset(x, params), PeakShoulderOffset(x, params));
    return PQToLinearBT2100(x + offset) * 10000.0;
}

// One scale for all channels: luma follows the curve, then the brightest channel eases into the panel peak.
float ComputeBoostScale(float lumaNits, float maxChannelNits, BoostParams params)
{
    if (params.peakPQ <= 0.0 || maxChannelNits <= params.fullGainNits)
        return params.gain;

    float lumaScale = ApplyBoostCurveToNits(lumaNits, params) / max(lumaNits, 1e-6);
    float maxChannelPQ = NitsToPQ(maxChannelNits);

    if (maxChannelPQ >= params.peakPQ)
        return 1.0;

    float channelOffset = NitsToPQUnclamped(maxChannelNits * lumaScale) - maxChannelPQ;
    float limitedOffset = SmoothMinOffset(channelOffset, PeakShoulderOffset(maxChannelPQ, params));
    return PQToLinearBT2100(maxChannelPQ + limitedOffset) * 10000.0 / maxChannelNits;
}

float3 ApplyBoostFromPrecomputedParams(float3 color, BoostParams boostParams)
{
    if (boostParams.gain <= 1.000001)
        return color;

    float lumaNits = GetLuma709(color) * SIGNAL_REFERENCE_NITS;
    if (lumaNits <= 1e-6)
        return color;

    float maxChannelNits = Max3(Rec709ToRec2020(color)) * SIGNAL_REFERENCE_NITS;
    return color * ComputeBoostScale(lumaNits, maxChannelNits, boostParams);
}

// Scalar response used by live APL analysis.
float ComputePostBoostNitsForSample(float lumaNits, float maxChannelNits, BoostParams boostParams)
{
    if (lumaNits <= 1e-6)
        return 0.0;
    return lumaNits * ComputeBoostScale(lumaNits, max(maxChannelNits, lumaNits), boostParams);
}

float ComputePostBoostMetricForSample(float lumaNits, float maxChannelNits, BoostParams boostParams)
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

    float aplLo = safeRawAPL;
    float fLo = clamp(ComputeSceneLogGainFromAPL(aplLo), 0.0, gMax);
    if (fLo <= 1e-6)
        return aplLo;

    float aplHi = saturate(responseNodes.z);
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

int APL_GetNextRollingPhase(int currentPhase)
{
    int nextPhase = currentPhase + 1;
    return (nextPhase < APL_FULLFRAME_ROLLING_PHASES) ? nextPhase : 0;
}

int APL_DecodeStoredRollingPhase(float storedPhase)
{
    return clamp(int(floor(storedPhase + 0.5)), 0, APL_FULLFRAME_ROLLING_PHASES - 1);
}

int APL_GetPhysicalRowFromDispatchSlot(int dispatchRowSlot, int rollingPhase)
{
    return rollingPhase + dispatchRowSlot * APL_FULLFRAME_ROLLING_PHASES;
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

// scRGB signal only, so the rolling signature is fixed; a single constant keeps row validity simple.
int APL_GetRollingHistogramSignature()
{
    return clamp(int(SIGNAL_REFERENCE_NITS + 0.5), 1, 200) * 2;
}


// =====================================================================================
// Pass 1: frame setup and rolling-row clear.
// SRV  t0 = APLInstant   t1 = APL (smoothed)
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowMeta u4 = APLPrev
// =====================================================================================
Texture2D<float4>   Setup_APLInstant : register(t0);
Texture2D<float4>   Setup_APL        : register(t1);
RWTexture2D<int>    Setup_RowCount   : register(u0);
RWTexture2D<int>    Setup_RowOffset  : register(u1);
RWTexture2D<int>    Setup_RowMaxNits : register(u2);
RWTexture2D<int>    Setup_RowMeta    : register(u3);
RWTexture2D<float4> Setup_APLPrev    : register(u4);

groupshared int APL_SetupRollingPhase;
groupshared int APL_SetupResumedAfterPause;

[numthreads(APL_SETUP_THREADS, 1, 1)]
void CS_Setup(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    if (localIndex == 0)
    {
        float4 instantData = Setup_APLInstant.Load(int3(0, 0, 0));
        bool resumedAfterPause = (ResetFlag != 0u);
        APL_SetupRollingPhase = APL_DecodeStoredRollingPhase(instantData.b);
        APL_SetupResumedAfterPause = resumedAfterPause ? 1 : 0;

        float4 previousState = (float4)0.0;
        if (!resumedAfterPause)
        {
            previousState = Setup_APL.Load(int3(0, 0, 0));

            // APLInstant keeps the previous run's targets: g = display APL, a = highlight PQ.
            float gapAlpha = ComputeTemporalBlendFactor(TransitionSpeed, GapTime);
            previousState.r = lerp(previousState.r, instantData.g, gapAlpha);
            previousState.g = lerp(previousState.g, instantData.a, gapAlpha);
        }

        // Layout: smoothed APL, this run's rolling phase, history flag, smoothed highlight PQ.
        Setup_APLPrev[int2(0, 0)] = float4(previousState.r, float(APL_SetupRollingPhase), previousState.b, previousState.g);
    }
    GroupMemoryBarrierWithGroupSync();

    int totalEntries = APL_FFH_ROLLING_ROW_SLOTS * APL_FFH_MAX_BINS;
    int signature = APL_GetRollingHistogramSignature();

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_SETUP_THREADS)
    {
        bool rebuiltThisFrame = (rowIndex % APL_FULLFRAME_ROLLING_PHASES) == APL_SetupRollingPhase;
        if (APL_SetupResumedAfterPause != 0 && !rebuiltThisFrame)
            Setup_RowMeta[int2(0, rowIndex)] = 0;
    }

    [loop]
    for (int entry = localIndex; entry < totalEntries; entry += APL_SETUP_THREADS)
    {
        int rowSlot = entry / APL_FFH_MAX_BINS;
        int binIndex = entry - rowSlot * APL_FFH_MAX_BINS;
        int rowIndex = APL_GetPhysicalRowFromDispatchSlot(rowSlot, APL_SetupRollingPhase);
        if (rowIndex < APL_FFH_TILE_COUNT_Y)
        {
            int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
            Setup_RowCount[coord] = 0;
            Setup_RowOffset[coord] = 0;
            Setup_RowMaxNits[coord] = 0;
            if (binIndex == 0)
                Setup_RowMeta[int2(0, rowIndex)] = signature << APL_FFH_ROW_META_COUNT_BITS;
        }
    }
}


// =====================================================================================
// Pass 2: decode source pixels and accumulate row histograms.
// SRV  t0 = CleanCopy  t1 = APLPrev
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowMeta
// =====================================================================================
Texture2D<float4> Build_CleanCopy : register(t0);
Texture2D<float4> Build_APLPrev   : register(t1);
RWTexture2D<int>  Build_RowCount   : register(u0);
RWTexture2D<int>  Build_RowOffset  : register(u1);
RWTexture2D<int>  Build_RowMaxNits : register(u2);
RWTexture2D<int>  Build_RowMeta    : register(u3);

groupshared int APL_TilePackedCountLuma[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxNits[APL_FFH_MAX_BINS];
groupshared int APL_BuildRollingPhase;

void APL_DecodePackedFullFrameSample(int2 pixel, out int binIndex, out int packedContribution, out int maxNits2, out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    maxNits2 = 0;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 color = Build_CleanCopy.Load(int3(pixel, 0)).rgb;
    float sceneNits = max(GetLuma709(color) * SIGNAL_REFERENCE_NITS, 0.0);
    float maxChannelNits = max(Max3(Rec709ToRec2020(color)), 0.0) * SIGNAL_REFERENCE_NITS;

    int lumaQ4 = APL_QuantizeNitsQ4(sceneNits);
    int maxQ4 = APL_QuantizeNitsQ4(maxChannelNits);
    int lumaBin = APL_HistogramLumaBin64(lumaQ4);
    binIndex = lumaBin * APL_FFH_COLOR_RATIO_BINS + APL_HistogramColorRatioBin(lumaQ4, maxQ4);

    int offset10 = APL_EncodeWithinBinOffset10(lumaQ4, lumaBin);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    maxNits2 = APL_QuantizeMaxNits2(maxChannelNits);
    valid = 1;
}

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int maxNits2, int valid)
{
    if (valid == 0)
        return;
    InterlockedAdd(APL_TilePackedCountLuma[binIndex], packedContribution);
    InterlockedAdd(APL_TileMaxNits[binIndex], maxNits2);
}

[numthreads(APL_FFH_THREADS_X, APL_FFH_THREADS_Y, 1)]
void CS_Build(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;

    if (localIndex == 0)
        APL_BuildRollingPhase = APL_DecodeStoredRollingPhase(Build_APLPrev.Load(int3(0, 0, 0)).g);

    if (localIndex < APL_FFH_MAX_BINS)
    {
        APL_TilePackedCountLuma[localIndex] = 0;
        APL_TileMaxNits[localIndex] = 0;
    }
    GroupMemoryBarrierWithGroupSync();

    int physicalRow = APL_GetPhysicalRowFromDispatchSlot(int(groupID.y), APL_BuildRollingPhase);
    bool validPhysicalRow = physicalRow < APL_FFH_TILE_COUNT_Y;

    if (validPhysicalRow)
    {
        int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, physicalRow * APL_FFH_TILE_SIZE) + int2(threadID.xy) * int2(APL_FFH_PIXELS_X, APL_FFH_PIXELS_Y);

        int b0, p0, m0, v0;
        int b1, p1, m1, v1;
        int b2, p2, m2, v2;
        int b3, p3, m3, v3;
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), b0, p0, m0, v0);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), b1, p1, m1, v1);
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), b2, p2, m2, v2);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), b3, p3, m3, v3);

        if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; m0 += m1; v1 = 0; }
        if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; m0 += m2; v2 = 0; }
        if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; m1 += m2; v2 = 0; }
        if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; m0 += m3; v3 = 0; }
        if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; m1 += m3; v3 = 0; }
        if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; m2 += m3; v3 = 0; }

        APL_AtomicAddMergedTileSample(b0, p0, m0, v0);
        APL_AtomicAddMergedTileSample(b1, p1, m1, v1);
        APL_AtomicAddMergedTileSample(b2, p2, m2, v2);
        APL_AtomicAddMergedTileSample(b3, p3, m3, v3);
    }
    GroupMemoryBarrierWithGroupSync();

    if (validPhysicalRow && localIndex < APL_FFH_MAX_BINS)
    {
        int packedValue = APL_TilePackedCountLuma[localIndex];
        int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
        if (count > 0)
        {
            int offsetSum10 = packedValue & APL_FFH_PACK_OFFSET_MASK;
            int2 rowCoord = APL_RowHistogramCoord(physicalRow, int(localIndex));
            InterlockedAdd(Build_RowCount[rowCoord], count);
            InterlockedAdd(Build_RowOffset[rowCoord], offsetSum10);
            InterlockedAdd(Build_RowMaxNits[rowCoord], APL_TileMaxNits[localIndex]);
        }
    }

    if (validPhysicalRow && localIndex == 0)
    {
        int tilePixelCount = APL_GetExpectedTilePixelCount(int(groupID.x), physicalRow);
        if (tilePixelCount > 0)
            InterlockedAdd(Build_RowMeta[int2(0, physicalRow)], tilePixelCount);
    }
}


// =====================================================================================
// Pass 3: reduce valid persistent rows into one global histogram.
// SRV  t0 = RowHistCount t1 = RowHistOffset10 t2 = RowHistMaxNits t3 = RowMeta
// UAV  u0 = GlobalHistCount u1 = GlobalHistOffset10 u2 = GlobalHistMaxNits
// =====================================================================================
Texture2D<int>      Reduce_RowCount   : register(t0);
Texture2D<int>      Reduce_RowOffset  : register(t1);
Texture2D<int>      Reduce_RowMaxNits : register(t2);
Texture2D<int>      Reduce_RowMeta    : register(t3);
RWTexture2D<int>    Reduce_GlobalCount   : register(u0);
RWTexture2D<float>  Reduce_GlobalOffset  : register(u1);
RWTexture2D<float>  Reduce_GlobalMaxNits : register(u2);

groupshared int   APL_ReduceCount[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffset10[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceMaxNits[APL_FFH_REDUCE_THREADS];

bool APL_IsRowValid(int rowIndex, int expectedSignature)
{
    int rowMeta = Reduce_RowMeta.Load(int3(0, rowIndex, 0));
    int rowCount = rowMeta & APL_FFH_ROW_META_COUNT_MASK;
    int rowSignature = rowMeta >> APL_FFH_ROW_META_COUNT_BITS;
    return (rowCount == APL_GetExpectedRowPixelCount(rowIndex)) && (rowSignature == expectedSignature);
}

#define APL_REDUCE_ROW_STAGE(S) \
    if (localIndex < S) { \
        APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + S]; \
        APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + S]; \
        APL_ReduceMaxNits[localIndex] += APL_ReduceMaxNits[localIndex + S]; \
    } \
    GroupMemoryBarrierWithGroupSync();

[numthreads(APL_FFH_REDUCE_THREADS, 1, 1)]
void CS_Reduce(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;
    int expectedSignature = APL_GetRollingHistogramSignature();

    int countSum = 0;
    float offsetSum10 = 0.0;
    float maxSumNits = 0.0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
    {
        if (APL_IsRowValid(rowIndex, expectedSignature))
        {
            int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
            countSum += Reduce_RowCount.Load(int3(sourceCoord, 0));
            offsetSum10 += float(Reduce_RowOffset.Load(int3(sourceCoord, 0)));
            maxSumNits += float(Reduce_RowMaxNits.Load(int3(sourceCoord, 0)));
        }
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceMaxNits[localIndex] = maxSumNits;
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
    }
}

#undef APL_REDUCE_ROW_STAGE


// =====================================================================================
// Pass 4: highlight peak, response solve, smoothing, boost parameters.
// SRV  t0 = GlobalHistCount t1 = GlobalHistOffset10 t2 = GlobalHistMaxNits t3 = APLPrev
// UAV  u0 = APL u1 = APLInstant u2 = BoostParams
// =====================================================================================
Texture2D<int>      Solve_GlobalCount   : register(t0);
Texture2D<float>    Solve_GlobalOffset  : register(t1);
Texture2D<float>    Solve_GlobalMaxNits : register(t2);
Texture2D<float4>   Solve_APLPrev       : register(t3);
RWTexture2D<float4> Solve_APL         : register(u0);
RWTexture2D<float4> Solve_APLInstant  : register(u1);
RWTexture2D<float4> Solve_BoostParams : register(u2);

groupshared float4 APL_EvalWeightedMetrics[APL_FFH_MAX_BINS];
groupshared float  APL_EvalPixelCount[APL_FFH_MAX_BINS];
groupshared float  APL_EvalBinLight[APL_FFH_MAX_BINS];
groupshared float  APL_EvalHighlightPQ;

#define APL_REDUCE_EVAL_STAGE(S) \
    if (localIndex < S) { \
        APL_EvalWeightedMetrics[localIndex] += APL_EvalWeightedMetrics[localIndex + S]; \
        APL_EvalPixelCount[localIndex] += APL_EvalPixelCount[localIndex + S]; \
    } \
    GroupMemoryBarrierWithGroupSync();

// Light-weighted, so small lights in dark scenes still count as highlights.
float APL_FindHighlightPeakNits()
{
    float totalLight = 0.0;
    [loop]
    for (int binIndex = 0; binIndex < APL_FFH_MAX_BINS; ++binIndex)
        totalLight += APL_EvalBinLight[binIndex];

    if (totalLight <= 0.0)
        return 0.0;

    float lightBudget = totalLight * HIGHLIGHT_PEAK_LIGHT_FRACTION;
    float lightAbove = 0.0;

    [loop]
    for (int lumaBin = APL_FFH_LUMA_BINS - 1; lumaBin >= 0; --lumaBin)
    {
        float binLight = 0.0;
        [unroll]
        for (int ratioBin = 0; ratioBin < APL_FFH_COLOR_RATIO_BINS; ++ratioBin)
            binLight += APL_EvalBinLight[lumaBin * APL_FFH_COLOR_RATIO_BINS + ratioBin];

        if (lightAbove + binLight >= lightBudget)
        {
            int lowerQ4 = 0;
            int upperQ4 = 0;
            APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);

            float depthInBin = saturate((lightBudget - lightAbove) / max(binLight, 1e-6));
            float logUpper = log2(float(upperQ4 + 1));
            float logLower = log2(max(float(lowerQ4), 1.0));
            return exp2(lerp(logUpper, logLower, depthInBin)) * 0.25;
        }

        lightAbove += binLight;
    }

    return 0.0;
}

[numthreads(APL_FFH_MAX_BINS, 1, 1)]
void CS_Solve(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    float4 prevData = Solve_APLPrev.Load(int3(0, 0, 0));
    float hasPrev = (prevData.b > 0.0) ? 1.0 : 0.0;
    float alpha = ComputeTemporalBlendFactor(TransitionSpeed, FrameTime);

    float pixelCount = 0.0;
    float sceneNits = 0.0;
    float maxChannelNits = 0.0;

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
    }

    APL_EvalBinLight[localIndex] = sceneNits * pixelCount;
    GroupMemoryBarrierWithGroupSync();

    float currentHighlightPQ = 0.0;
    if (localIndex == 0)
    {
        currentHighlightPQ = NitsToPQ(APL_FindHighlightPeakNits());
        APL_EvalHighlightPQ = lerp(
            currentHighlightPQ,
            lerp(saturate(prevData.a), currentHighlightPQ, alpha),
            hasPrev
        );
    }
    GroupMemoryBarrierWithGroupSync();

    float smoothedHighlightPQ = APL_EvalHighlightPQ;
    float gMax = ComputeCandidateMaxLogGain();
    float4 weighted = (float4)0.0;

    if (pixelCount > 0.0)
    {
        float rawMetric = saturate(sceneNits / max(APLReferenceWhiteNits, 1.0));
        float3 candidateMetrics;
        [unroll]
        for (int k = 1; k <= 3; ++k)
        {
            BoostParams candidateParams = MakeCandidateBoostParams(k, gMax, smoothedHighlightPQ);
            candidateMetrics[k - 1] = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, candidateParams);
        }
        weighted = float4(rawMetric, candidateMetrics) * pixelCount;
    }

    APL_EvalWeightedMetrics[localIndex] = weighted;
    APL_EvalPixelCount[localIndex] = pixelCount;
    GroupMemoryBarrierWithGroupSync();

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
        float rawAPL = 0.0;
        float3 responseNodes = (float3)0.0;
        float totalPixelCount = APL_EvalPixelCount[0];

        if (totalPixelCount > 0.0)
        {
            float4 averages = APL_EvalWeightedMetrics[0] / totalPixelCount;
            rawAPL = saturate(averages.r);
            responseNodes = saturate(averages.gba);
        }

        int currentRollingPhase = APL_DecodeStoredRollingPhase(prevData.g);
        int nextRollingPhase = APL_GetNextRollingPhase(currentRollingPhase);

        float currentDisplayAPL = SolveClosedLoopDisplayAPLFromResponseNodes(rawAPL, responseNodes, gMax);
        float smoothedAPL = lerp(
            currentDisplayAPL,
            lerp(saturate(prevData.r), currentDisplayAPL, alpha),
            hasPrev
        );

        float sceneLogGain = ComputeSceneLogGainFromAPL(smoothedAPL);

        Solve_APLInstant[int2(0, 0)] = float4(rawAPL, currentDisplayAPL, float(nextRollingPhase), currentHighlightPQ);
        Solve_APL[int2(0, 0)] = float4(smoothedAPL, smoothedHighlightPQ, 1.0, sceneLogGain);

        BoostParams boostParams = ComputeBoostParamsFromSceneLogGain(sceneLogGain, smoothedHighlightPQ);
        Solve_BoostParams[int2(0, 0)] = PackBoostParamsRow0(boostParams);
        Solve_BoostParams[int2(0, 1)] = PackBoostParamsRow1(boostParams);
    }
}

#undef APL_REDUCE_EVAL_STAGE


// =====================================================================================
// Pass 5: fullscreen boost. Clean copy -> back buffer.
// SRV  t0 = CleanCopy t1 = APL (smoothed) t2 = BoostParams
// =====================================================================================
Texture2D<float4> Boost_CleanCopy   : register(t0);
Texture2D<float4> Boost_APL         : register(t1);
Texture2D<float4> Boost_BoostParams : register(t2);
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

    float4 aplData = Boost_APL.Load(int3(0, 0, 0));
    if (aplData.a > 1e-6)
    {
        BoostParams params = UnpackBoostParams(
            Boost_BoostParams.Load(int3(0, 0, 0)),
            Boost_BoostParams.Load(int3(0, 1, 0)));
        color = ApplyBoostFromPrecomputedParams(color, params);
    }

    return float4(color, 1.0);
}
