// The algorithm of EOTF Boost 3.1, shared by Shaders/EOTF_BoostMod3.1_27M2N6500.fx and DwmBoost/hook/boost.hlsl so
// both run the same code. It holds no textures or uniforms. The includer reads the histogram, passes it in, and
// writes what comes back.
//
// The includer defines, before including:
//   BOOST_TONE_LOOKUP(entry)              entry of the tone curve lookup the solve wrote, needed by ShownLevelNits
//   BOOST_CALIBRATED_LEVEL_NITS(nits)     optional, brightest channel a calibration LUT sends for a gray at nits
// A plain HLSL includer also defines BOOST_BARRIER, BOOST_ATOMIC_ADD and BOOST_ATOMIC_MAX as the intrinsics it has,
// since ReShade's barrier, atomicAdd and atomicMax don't exist there.
//
// One frame:
//   1. Histogram of each pixel's brightest BT.2020 channel, with each bin's mean level and the mean ratio of its
//      pixels' panel load to that level
//   2. The panel's load is filtered by its response, and the gain that cancels the dimming at the filtered load the
//      boosted frame causes is solved by bisection
//   3. Midtones keep that full gain unless most of the frame sits above the ceiling, where a softmin over predicted
//      EOTF error lowers it continuously
//   4. Highlights above the ceiling share the room under it by their smoothed histogram, above a slope floor, from a
//      content top that ignores a few stray pixels and releases slowly
//   5. Pixels scale by one factor, and compressed highlights roll off slightly toward white with the brightest
//      channel kept

#pragma once

#include "PanelModel_27M2N6500.fxh"

#ifndef BOOST_CALIBRATED_LEVEL_NITS
    #define BOOST_CALIBRATED_LEVEL_NITS(nits) (nits)
#endif
#ifndef BOOST_BARRIER
    #define BOOST_BARRIER barrier()
#endif
#ifndef BOOST_ATOMIC_ADD
    #define BOOST_ATOMIC_ADD(destination, value) atomicAdd(destination, value)
#endif
#ifndef BOOST_ATOMIC_MAX
    #define BOOST_ATOMIC_MAX(destination, value) atomicMax(destination, value)
#endif

// Histogram layout. Each 16x16 group bins one 32x32 pixel tile by the pixel's brightest channel, each level bin split
// into quarters by position.
#define HIST_TILE_SIZE          32
#define HIST_THREADS_X          16
#define HIST_THREADS_Y          16
#define HIST_LEVEL_BINS         64
#define HIST_SUB_BINS            4
#define HIST_BINS              256
#define HIST_BLOCK_W            16
#define HIST_BLOCK_H            16
#define HIST_AUX_X              HIST_BLOCK_W
#define HIST_REDUCE_THREADS     64

// Packed tile value: pixel count in the upper bits and summed position within the bin in the lower bits.
#define HIST_PACK_COUNT_SHIFT   20
#define HIST_PACK_OFFSET_MASK   ((1 << HIST_PACK_COUNT_SHIFT) - 1)
#define HIST_PACK_OFFSET_SCALE  1023
#define HIST_PACK_ONE_COUNT     (1 << HIST_PACK_COUNT_SHIFT)

// Fixed point scale at native resolution, and the largest ratio a pixel can add. Wider buffers use a power-of-two
// divisor so even a full row of maximum ratios stays inside int32, up to D3D11's 16384-pixel texture limit.
#define HIST_RATIO_SCALE        8192.0
#define HIST_RATIO_MAX          2.0

// Shown level in PQ for each 10-bit PQ code, interpolated between entries.
#define TONE_CURVE_LUT_SIZE     1024

static const float SCRGB_REFERENCE_NITS = 80.0;
static const float REFERENCE_WHITE_NITS = 203.0;

static const float3x3 REC709_TO_REC2020 = float3x3(
    0.6274040, 0.3292820, 0.0433136,
    0.0690970, 0.9195400, 0.0113612,
    0.0163916, 0.0880132, 0.8955950);

static const float3x3 REC2020_TO_REC709 = float3x3(
     1.660490296, -0.587639106, -0.072851598,
    -0.124549970,  1.132899922, -0.008347964,
    -0.018151119, -0.100578724,  1.118729878);


// ST.2084, in nits.
static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

float NitsToPQ(float nits)
{
    float y = pow(saturate(nits / 10000.0), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0 + PQ_C3 * y), PQ_M2);
}

float3 NitsToPQ(float3 nits)
{
    float3 y = pow(saturate(nits / 10000.0), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0 + PQ_C3 * y), PQ_M2);
}

float PQToNits(float pq)
{
    float e = pow(saturate(pq), 1.0 / PQ_M2);
    return 10000.0 * pow(max(e - PQ_C1, 0.0) / max(PQ_C2 - PQ_C3 * e, 1e-6), 1.0 / PQ_M1);
}

float3 PQToNits(float3 pq)
{
    float3 e = pow(saturate(pq), 1.0 / PQ_M2);
    return 10000.0 * pow(max(e - PQ_C1, 0.0) / max(PQ_C2 - PQ_C3 * e, 1e-6), 1.0 / PQ_M1);
}

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}


// ---------------------------------------------------------------------------------------------------------------------
// Histogram bins
// ---------------------------------------------------------------------------------------------------------------------

int HistQuantizeNitsQ4(float nits)
{
    return clamp(int(floor(max(nits, 0.0) * 4.0 + 0.5)), 0, 40000);
}

// Quarter octave bins of the level in quarter nits.
int HistLevelBin(int levelQ4)
{
    if (levelQ4 <= 0)
        return 0;

    int exponent = firstbithigh(levelQ4);
    int quarter = (exponent >= 2) ? ((levelQ4 >> (exponent - 2)) & 3) : 0;
    return min(exponent * 4 + quarter, HIST_LEVEL_BINS - 1);
}

void HistLevelBinBoundsQ4(int levelBin, out int lowerQ4, out int upperQ4)
{
    int exponent = levelBin >> 2;
    int quarter = levelBin & 3;

    if (exponent < 2)
    {
        lowerQ4 = (exponent == 0) ? 0 : (1 << exponent);
        upperQ4 = (1 << (exponent + 1)) - 1;
    }
    else
    {
        int stepQ4 = 1 << (exponent - 2);
        lowerQ4 = (1 << exponent) + quarter * stepQ4;
        upperQ4 = lowerQ4 + stepQ4 - 1;
    }

    upperQ4 = min(upperQ4, 40000);
    lowerQ4 = min(lowerQ4, upperQ4);
}

int HistEncodeOffset(int levelQ4, int levelBin)
{
    int lowerQ4, upperQ4;
    HistLevelBinBoundsQ4(levelBin, lowerQ4, upperQ4);

    uint rangeQ4 = uint(upperQ4 - lowerQ4);
    if (rangeQ4 == 0u)
        return 0;

    uint positionQ4 = uint(clamp(levelQ4, lowerQ4, upperQ4) - lowerQ4);
    uint offset = (positionQ4 * uint(HIST_PACK_OFFSET_SCALE) + (rangeQ4 >> 1)) / rangeQ4;
    return int(min(offset, uint(HIST_PACK_OFFSET_SCALE)));
}

float HistMeanLevelNits(int binIndex, float pixelCount, float offsetSum)
{
    int lowerQ4, upperQ4;
    HistLevelBinBoundsQ4(binIndex / HIST_SUB_BINS, lowerQ4, upperQ4);
    float rangeQ4 = float(upperQ4 - lowerQ4);

    if (pixelCount <= 0.0 || rangeQ4 <= 0.0)
        return 0.25 * float(lowerQ4);

    float meanOffset = offsetSum / pixelCount / float(HIST_PACK_OFFSET_SCALE);
    return 0.25 * (float(lowerQ4) + rangeQ4 * meanOffset);
}

int2 HistBlockCoord(int binIndex)
{
    return int2(binIndex & (HIST_BLOCK_W - 1), binIndex / HIST_BLOCK_W);
}

int2 HistRowCoord(int rowIndex, int binIndex)
{
    int2 binCoord = HistBlockCoord(binIndex);
    return int2(binCoord.x, rowIndex * HIST_BLOCK_H + binCoord.y);
}

// A row's brightest level, and the frame's in the global histogram, as float bits in the aux column. Levels are never
// negative, so their bits order like them.
int2 HistRowMaxLevelCoord(int rowIndex)
{
    return int2(HIST_AUX_X, rowIndex * HIST_BLOCK_H);
}

int2 HistGlobalMaxLevelCoord()
{
    return int2(HIST_AUX_X, 0);
}

float HistRatioScale(int widthPx)
{
    // 3840 * 32 * 2 * 8192 < INT_MAX. Round the width's divisor up to a power of two so a ratio of 1 stays exact.
    int partitions = max((widthPx + 3839) / 3840, 1);
    int shift = firstbithigh(uint(2 * partitions - 1));
    return HIST_RATIO_SCALE / float(1 << shift);
}

int HistFixedRatio(float ratio, float ratioScale)
{
    return int(clamp(ratio, 0.0, HIST_RATIO_MAX) * ratioScale + 0.5);
}

// One pixel's histogram entry. The bin follows the brightest BT.2020 channel, the level the signal peak limits. The
// load ratios are the panel subpixel that loads the panel most, its drive and its weighted drive, over that level, so
// a bin's load follows any level its pixels are scaled to.
void HistPixelSample(float3 rec2020Nits, float3 panelNits, float ratioScale, out int binIndex, out int packedCount,
                     out int driveRatio, out int loadRatio, out int levelBits)
{
    float levelNits = Max3(max(rec2020Nits, 0.0));
    levelBits = asint(levelNits);

    int levelQ4 = HistQuantizeNitsQ4(levelNits);
    int levelBin = HistLevelBin(levelQ4);
    int offset = HistEncodeOffset(levelQ4, levelBin);
    binIndex = levelBin * HIST_SUB_BINS + offset * HIST_SUB_BINS / (HIST_PACK_OFFSET_SCALE + 1);
    packedCount = HIST_PACK_ONE_COUNT + offset;

    float3 drive = max(panelNits, 0.0);
    float3 weighted = drive * PANEL_SUBPIXEL_WEIGHTS;
    float loadNits = Max3(weighted);
    float loadDrive = (weighted.r == loadNits) ? drive.r : ((weighted.g == loadNits) ? drive.g : drive.b);
    float perLevel = (levelNits > 1e-6) ? 1.0 / levelNits : 0.0;

    driveRatio = HistFixedRatio(loadDrive * perLevel, ratioScale);
    loadRatio = HistFixedRatio(loadNits * perLevel, ratioScale);
}

// One tile's histogram in groupshared, which the includer adds to its row.
groupshared int Tile_PackedCount[HIST_BINS];
groupshared int Tile_DriveRatio[HIST_BINS];
groupshared int Tile_LoadRatio[HIST_BINS];
groupshared int Tile_MaxLevelBits;

void TileClear(int localIndex)
{
    Tile_PackedCount[localIndex] = 0;
    Tile_DriveRatio[localIndex] = 0;
    Tile_LoadRatio[localIndex] = 0;
    if (localIndex == 0)
        Tile_MaxLevelBits = 0;
}

// Adds one thread's 2x2 pixels. Pixels landing in the same bin are summed first, so a flat area takes a quarter of
// the atomics on one address.
void TileAddQuad(float3 rec2020Nits[4], float3 panelNits[4], bool valid[4], float ratioScale)
{
    int bins[4];
    int packedCounts[4];
    int drive[4];
    int load[4];
    int maxLevelBits = 0;

    [unroll]
    for (int pixel = 0; pixel < 4; ++pixel)
    {
        int levelBits;
        HistPixelSample(rec2020Nits[pixel], panelNits[pixel], ratioScale, bins[pixel], packedCounts[pixel], drive[pixel], load[pixel], levelBits);
        maxLevelBits = valid[pixel] ? max(maxLevelBits, levelBits) : maxLevelBits;
    }

    [unroll]
    for (int later = 1; later < 4; ++later)
    {
        [unroll]
        for (int earlier = 0; earlier < later; ++earlier)
        {
            if (valid[earlier] && valid[later] && bins[earlier] == bins[later])
            {
                packedCounts[earlier] += packedCounts[later];
                drive[earlier] += drive[later];
                load[earlier] += load[later];
                valid[later] = false;
            }
        }
    }

    BOOST_ATOMIC_MAX(Tile_MaxLevelBits, maxLevelBits);

    [unroll]
    for (int entry = 0; entry < 4; ++entry)
    {
        if (valid[entry])
        {
            BOOST_ATOMIC_ADD(Tile_PackedCount[bins[entry]], packedCounts[entry]);
            BOOST_ATOMIC_ADD(Tile_DriveRatio[bins[entry]], drive[entry]);
            BOOST_ATOMIC_ADD(Tile_LoadRatio[bins[entry]], load[entry]);
        }
    }
}


// ---------------------------------------------------------------------------------------------------------------------
// Panel load of a histogram bin
// ---------------------------------------------------------------------------------------------------------------------

// Load in nits of pixels whose brightest channel is sent at levelNits, from their mean load ratios. rolloff is how far
// the boost blends them toward white, which moves their drive toward the level itself.
float BinLoadNits(float levelNits, float driveRatio, float loadRatio, float rolloff)
{
    float weightOfDrive = (driveRatio > 0.0) ? loadRatio / driveRatio : 1.0;
    float driveNits = levelNits * lerp(driveRatio, 1.0, rolloff);
    float weightedNits = levelNits * lerp(loadRatio, weightOfDrive, rolloff);

    if (driveNits <= 0.0)
        return 0.0;

    float clampedDrive = min(driveNits, PANEL_PEAK_NITS);
    return weightedNits * (clampedDrive / driveNits) * PanelTrackingShare(clampedDrive);
}

// Blend of a compressed highlight toward white, from how far the curve pressed it under its level.
float HighlightRolloff(float shownLevelNits, float levelNits)
{
    float compression = saturate(1.0 - shownLevelNits / max(levelNits, 1e-6));
    return 0.25 * compression * compression;
}

// Shares of the way the panel's single-pole response moves toward a higher load and toward a lower one over one frame.
// A zero response time means immediate release, without dividing by zero.
float2 PanelFilterAlpha(float frameTimeMs)
{
    float seconds = clamp(frameTimeMs, 1.0, 250.0) * 0.001;
    float2 response = float2(PANEL_DIM_SECONDS, PANEL_UNDIM_SECONDS);
    float2 alpha = 1.0 - exp(-seconds / max(response, 1e-6));
    return float2((PANEL_DIM_SECONDS > 0.0) ? alpha.x : 1.0,
                  (PANEL_UNDIM_SECONDS > 0.0) ? alpha.y : 1.0);
}

// The panel's load after one frame that sends sentLoad. filter is the load it was at and its shares toward a higher
// and a lower load. Either way it moves monotonically with the sent load, so the gain solve still brackets.
float PanelFilterStep(float sentLoad, float3 filter)
{
    return lerp(filter.x, sentLoad, (sentLoad > filter.x) ? filter.y : filter.z);
}

// The load a frame sent to leave the panel at panelLoad, the inverse of PanelFilterStep.
float PanelFilterSentLoad(float panelLoad, float3 filter)
{
    float alpha = (panelLoad > filter.x) ? filter.y : filter.z;
    return (alpha > 0.0) ? filter.x + (panelLoad - filter.x) / alpha : panelLoad;
}


// ---------------------------------------------------------------------------------------------------------------------
// Tone curve
//
// The curve works on the brightest channel in PQ. Above the shoulder start, BT.2408's reference white or BT.2390's
// knee where that's higher, the levels up to the content top share the room under the ceiling: every bin gets a slope
// floor, and the room left goes to the bins by their smoothed pixel count, never past the source's own contrast (Ward
// Larson, Rushmeier and Piatko 1997, with a floor and a binomial density kernel). The curve runs top down from the
// ceiling, the source below where it meets it, and a bend joins the two.
// ---------------------------------------------------------------------------------------------------------------------

groupshared float Curve_Slope[HIST_LEVEL_BINS];
groupshared float Curve_LowerPQ[HIST_LEVEL_BINS];
groupshared float Curve_UpperPQ[HIST_LEVEL_BINS];
groupshared float Curve_BinIntegral[HIST_LEVEL_BINS];
groupshared float Curve_Above[HIST_LEVEL_BINS];
groupshared float Curve_ContentTopPQ;

groupshared float Level_Count[HIST_LEVEL_BINS];
groupshared float Level_DensityCount[HIST_LEVEL_BINS];
groupshared float Level_SmoothedCount[HIST_LEVEL_BINS];
groupshared float Level_MeanPQ[HIST_LEVEL_BINS];

groupshared float2 Solve_Sum[HIST_BINS];
groupshared float Solve_BinCount[HIST_BINS];
groupshared float Solve_BinPQ[HIST_BINS];
groupshared float2 Solve_LogGainRange;
groupshared float Solve_PickError[9];
groupshared float4 Solve_ToneShape;

// Bins 1-3 and 5-7 never get pixels, and bins past 60 sit above the 10000 nit clamp.
static const int TOP_LEVEL_BIN = 60;

static const int GAIN_SOLVE_STEPS = 14;
static const int KNEE_SOLVE_STEPS = 20;
static const int BEND_MAX_PIECES = 8;

static const float SHOULDER_SLOPE_FLOOR = 0.20;

// State that has reached its target lands on it, so a held frame stops moving in the last bits. Both are far below a
// 10-bit code: 0.001% of the load peak is 0.01 nits, and 1e-5 PQ is under a hundredth of a code.
static const float SETTLED_LOAD_PERCENT = 0.001;
static const float SETTLED_PQ = 1e-5;

// Robust content top: a soft max over the brightest pixels.
static const float CONTENT_TOP_MIN_PIXELS = 64.0;
static const float CONTENT_TOP_FRACTION = 0.0005;
static const float CONTENT_TOP_ATTACK_SECONDS = 0.03;
static const float CONTENT_TOP_RELEASE_SECONDS = 0.16;

// Midtones keep the full gain until this share of the lit pixels sits above the ceiling, and give it up by the next.
static const float WHITEOUT_START_SHARE = 0.55;
static const float WHITEOUT_FULL_SHARE = 0.85;

// Softmin gain pick: 9 gains from 1 to full, cost in units of this log2 error per pixel, less a preference for the
// higher gain.
#define PICK_POINTS 9
static const float PICK_TAU_LOG2 = 0.0035;
static const float PICK_TIE_PREFERENCE = 1.8;

bool IsRealLevelBin(int levelBin)
{
    return levelBin == 0 || levelBin == 4 || (levelBin >= 8 && levelBin <= TOP_LEVEL_BIN);
}

int PreviousRealLevelBin(int levelBin)
{
    if (levelBin == 8)
        return 4;
    if (levelBin == 4)
        return 0;
    return levelBin - 1;
}

int NextRealLevelBin(int levelBin)
{
    if (levelBin == 0)
        return 4;
    if (levelBin == 4)
        return 8;
    return levelBin + 1;
}

// Levels round to the nearest quarter nit, so each bin edge sits half a step out.
float LevelBinLowerNits(int levelBin)
{
    int lowerQ4, upperQ4;
    HistLevelBinBoundsQ4(levelBin, lowerQ4, upperQ4);
    return max(float(lowerQ4) - 0.5, 0.0) * 0.25;
}

float LevelBinUpperNits(int levelBin)
{
    int lowerQ4, upperQ4;
    HistLevelBinBoundsQ4(levelBin, lowerQ4, upperQ4);
    return (float(upperQ4) + 0.5) * 0.25;
}

int LevelBinOfPQ(float pq)
{
    return HistLevelBin(HistQuantizeNitsQ4(PQToNits(pq)));
}

float ShoulderStartPQ(float ceilingPQ)
{
    float bt2390KneePQ = 1.5 * ceilingPQ - 0.5 * NitsToPQ(PANEL_SIGNAL_PEAK_NITS);
    return max(bt2390KneePQ, min(NitsToPQ(REFERENCE_WHITE_NITS), ceilingPQ));
}

float CurveCenterPQ(int levelBin)
{
    return 0.5 * (Curve_LowerPQ[levelBin] + Curve_UpperPQ[levelBin]);
}

// Slope at pq, which lies between levelBin's center and a neighbor's.
float CurveSlopeAt(float pq, int levelBin)
{
    float center = CurveCenterPQ(levelBin);
    int neighbor = (pq < center) ? PreviousRealLevelBin(levelBin) : NextRealLevelBin(levelBin);

    float slope = Curve_Slope[levelBin];
    if (neighbor >= 0 && neighbor <= TOP_LEVEL_BIN)
        slope = lerp(slope, Curve_Slope[neighbor], (pq - center) / (CurveCenterPQ(neighbor) - center));

    return slope;
}

// Slope integral from the bin's lower edge up to pq.
float CurveIntegralInBin(int levelBin, float pq)
{
    float lower = Curve_LowerPQ[levelBin];
    float center = CurveCenterPQ(levelBin);
    float lowerSlope = CurveSlopeAt(lower, levelBin);
    float pqSlope = CurveSlopeAt(pq, levelBin);

    if (pq <= center)
        return 0.5 * (pq - lower) * (lowerSlope + pqSlope);

    float centerSlope = Curve_Slope[levelBin];
    return 0.5 * (center - lower) * (lowerSlope + centerSlope) + 0.5 * (pq - center) * (centerSlope + pqSlope);
}

// Slope integral from pq up to the content top.
float CurveIntegralAbove(float pq)
{
    int levelBin = LevelBinOfPQ(pq);
    return Curve_Above[levelBin] - CurveIntegralInBin(levelBin, pq);
}

// Integral of slope times a ramp rising from 0 at bendStart to 1 one bend width up, from bendStart to pq. Both are
// linear between bin centers, so Simpson's rule is exact.
float CurveRampIntegral(float bendStart, float bendWidth, float pq)
{
    float total = 0.0;
    float pieceStart = bendStart;

    [loop]
    for (int piece = 0; piece < BEND_MAX_PIECES && pieceStart < pq; ++piece)
    {
        int levelBin = LevelBinOfPQ(pieceStart);
        int nextBin = NextRealLevelBin(levelBin);
        float center = CurveCenterPQ(levelBin);
        float breakPQ = pq;

        if (pieceStart < center)
            breakPQ = center;
        else if (nextBin <= TOP_LEVEL_BIN)
            breakPQ = CurveCenterPQ(nextBin);

        float pieceEnd = min(breakPQ, pq);
        float pieceMid = 0.5 * (pieceStart + pieceEnd);
        float startValue = (pieceStart - bendStart) * CurveSlopeAt(pieceStart, levelBin);
        float midValue = (pieceMid - bendStart) * CurveSlopeAt(pieceMid, levelBin);
        float endValue = (pieceEnd - bendStart) * CurveSlopeAt(pieceEnd, levelBin);

        total += (pieceEnd - pieceStart) * (startValue + 4.0 * midValue + endValue) / 6.0;
        pieceStart = pieceEnd;
    }

    return (bendWidth > 0.0) ? total / bendWidth : 0.0;
}

// The bend spans a quarter octave around the knee, about one histogram bin, never less than at 1 nit. It never spans
// more than the gain lowered the ceiling, so an unboosted frame keeps the panel's own clip, more than the content
// rises past the ceiling, so a frame that fits keeps its source levels, or reaches under the shoulder start, so every
// level under it stays exact. The compiler folds the signal peak's PQ a few ulps under the ceiling the GPU computes
// at gain 1, so the headroom never goes negative.
float BendWidthPQ(float kneePQ, float ceilingPQ, float shoulderStartPQ)
{
    float kneeNits = max(PQToNits(kneePQ), 1.0);
    float halfWidth = exp2(0.125);
    float quarterOctavePQ = NitsToPQ(kneeNits * halfWidth) - NitsToPQ(kneeNits / halfWidth);
    float headroomPQ = max(NitsToPQ(PANEL_SIGNAL_PEAK_NITS) - ceilingPQ, 0.0);
    float overshootPQ = max(Curve_ContentTopPQ - ceilingPQ, 0.0);
    float aboveShoulderPQ = 2.0 * max(kneePQ - shoulderStartPQ, 0.0);
    return min(min(quarterOctavePQ, aboveShoulderPQ), min(headroomPQ, overshootPQ));
}

// Bent curve minus top-down curve where the bend ends. It grows with the knee and is 0 at the right one.
float KneeMismatch(float kneePQ, float ceilingPQ, float shoulderStartPQ)
{
    float bendWidth = BendWidthPQ(kneePQ, ceilingPQ, shoulderStartPQ);
    float bendStart = kneePQ - 0.5 * bendWidth;
    float bendEnd = bendStart + bendWidth;
    float bentEndPQ = kneePQ + CurveRampIntegral(bendStart, bendWidth, bendEnd);
    // The top-down curve never rises past the source, which it would on a frame that fits under the ceiling.
    return bentEndPQ - min(ceilingPQ - CurveIntegralAbove(bendEnd), bendEnd);
}

// Where the curve leaves the source, from the shoulder start up to the ceiling. Without a bend the mismatch stays 0
// below that point, so 0 moves the knee up.
float SolveKneePQ(float ceilingPQ, float shoulderStartPQ)
{
    float2 range = float2(min(shoulderStartPQ, ceilingPQ), ceilingPQ);

    [loop]
    for (int step = 0; step < KNEE_SOLVE_STEPS; ++step)
    {
        float midPQ = 0.5 * (range.x + range.y);
        range = (KneeMismatch(midPQ, ceilingPQ, shoulderStartPQ) <= 0.0) ? float2(midPQ, range.y) : float2(range.x, midPQ);
    }

    return 0.5 * (range.x + range.y);
}

// Source below the bend, the top-down curve above it, and a slope easing from 1 to the curve's across it.
float EvaluateToneCurvePQ(float pq, float bendStart, float bendWidth, float ceilingPQ)
{
    if (pq <= bendStart)
        return pq;

    if (pq >= bendStart + bendWidth)
        return min(ceilingPQ - CurveIntegralAbove(pq), pq);

    float bendOffset = pq - bendStart;
    return pq - bendOffset * bendOffset / (2.0 * bendWidth) + CurveRampIntegral(bendStart, bendWidth, pq);
}

// The curve's output in nits for a level, without the bend, held at the ceiling past the content top.
float CurveLevelNits(int levelBin, float levelPQ, float ceilingPQ)
{
    float topDownPQ = ceilingPQ - (Curve_Above[levelBin] - CurveIntegralInBin(levelBin, levelPQ));
    return PQToNits(min(levelPQ, min(topDownPQ, ceilingPQ)));
}


// ---------------------------------------------------------------------------------------------------------------------
// Group reductions. Every thread calls them and gets the total.
// ---------------------------------------------------------------------------------------------------------------------

float2 ReduceSolveSum(int localIndex, float2 value)
{
    Solve_Sum[localIndex] = value;
    BOOST_BARRIER;

    [unroll]
    for (int stride = HIST_BINS / 2; stride > 0; stride /= 2)
    {
        if (localIndex < stride)
            Solve_Sum[localIndex] += Solve_Sum[localIndex + stride];
        BOOST_BARRIER;
    }

    // Every thread reads the total before any writes the next sum, or a fast warp would overwrite it first.
    float2 total = Solve_Sum[0];
    BOOST_BARRIER;
    return total;
}

float SubBinsOfLevel(int levelBin)
{
    int first = levelBin * HIST_SUB_BINS;
    return Solve_BinCount[first] + Solve_BinCount[first + 1] + Solve_BinCount[first + 2] + Solve_BinCount[first + 3];
}

// 5-tap binomial kernel over neighboring level bins.
float SmoothLevelCount(int levelBin)
{
    int b0 = max(levelBin - 2, 0);
    int b1 = max(levelBin - 1, 0);
    int b3 = min(levelBin + 1, TOP_LEVEL_BIN);
    int b4 = min(levelBin + 2, TOP_LEVEL_BIN);
    return 0.0625 * Level_DensityCount[b0] + 0.25 * Level_DensityCount[b1] + 0.375 * Level_DensityCount[levelBin]
         + 0.25 * Level_DensityCount[b3] + 0.0625 * Level_DensityCount[b4];
}

// Deposit each sub-bin's mean level between neighboring PQ centers before smoothing. A flat object's density then
// moves continuously as it crosses a histogram edge, instead of moving a whole bin's kernel in one frame.
float LevelDensityCount(int levelBin)
{
    float center = CurveCenterPQ(levelBin);
    int previous = PreviousRealLevelBin(levelBin);
    int next = NextRealLevelBin(levelBin);
    float lower = (previous >= 0) ? CurveCenterPQ(previous) : center;
    float upper = (next <= TOP_LEVEL_BIN) ? CurveCenterPQ(next) : center;
    float inverseLowerWidth = (center > lower) ? 1.0 / (center - lower) : 0.0;
    float inverseUpperWidth = (upper > center) ? 1.0 / (upper - center) : 0.0;
    float count = 0.0;

    [loop]
    for (int binIndex = 0; binIndex < HIST_BINS; ++binIndex)
    {
        float pq = Solve_BinPQ[binIndex];
        float weight = (pq < center)
            ? ((previous >= 0) ? saturate((pq - lower) * inverseLowerWidth) : 1.0)
            : ((next <= TOP_LEVEL_BIN) ? saturate((upper - pq) * inverseUpperWidth) : 1.0);
        count += Solve_BinCount[binIndex] * weight;
    }

    return count;
}


// ---------------------------------------------------------------------------------------------------------------------
// Building the curve for one gain
// ---------------------------------------------------------------------------------------------------------------------

// Fills Curve_Slope, Curve_BinIntegral and Curve_Above for the ceiling one gain leaves. Each thread under
// HIST_LEVEL_BINS handles its own level bin.
void BuildToneCurve(int localIndex, float ceilingPQ)
{
    float shoulderStartPQ = ShoulderStartPQ(ceilingPQ);
    float topPQ = Curve_ContentTopPQ;
    bool isLevelBin = localIndex < HIST_LEVEL_BINS;

    // The part of each bin between the shoulder start and the content top, and its smoothed pixels there.
    float spanWidth = 0.0;
    float shoulderCount = 0.0;
    float density = 0.0;
    if (isLevelBin && IsRealLevelBin(localIndex))
    {
        float width = Curve_UpperPQ[localIndex] - Curve_LowerPQ[localIndex];
        spanWidth = max(min(Curve_UpperPQ[localIndex], topPQ) - max(Curve_LowerPQ[localIndex], shoulderStartPQ), 0.0);
        density = Level_SmoothedCount[localIndex] / width;
        shoulderCount = density * spanWidth;
    }

    float2 shoulder = ReduceSolveSum(localIndex, float2(spanWidth, shoulderCount));
    float spanPQ = shoulder.x;
    float availPQ = max(ceilingPQ - shoulderStartPQ, 0.0);
    float slopeFloor = (spanPQ > 0.0) ? min(SHOULDER_SLOPE_FLOOR, availPQ / spanPQ) : 0.0;
    float extraCap = 1.0 - slopeFloor;
    float roomPQ = max(availPQ - slopeFloor * spanPQ, 0.0);

    // The room left goes by smoothed count in two passes, the second sharing what capped bins couldn't take.
    float extra = 0.0;
    if (shoulder.y > 0.0)
        extra = min(extraCap, roomPQ * density / shoulder.y);

    bool capped = extra >= extraCap;
    float2 firstPass = ReduceSolveSum(localIndex, float2(extra * spanWidth, capped ? 0.0 : shoulderCount));
    float roomLeftPQ = max(roomPQ - firstPass.x, 0.0);

    if (!capped && firstPass.y > 0.0)
        extra = min(extraCap, extra + roomLeftPQ * density / firstPass.y);

    // With no pixels in the shoulder at all, it rises evenly.
    float evenSlope = (spanPQ > 0.0) ? min(availPQ / spanPQ, 1.0) : 0.0;
    float slope = (shoulder.y > 0.0) ? slopeFloor + extra : evenSlope;

    // Keep the slope at centers just outside the clipped span too. Interpolation reads those centers before the
    // content top reaches them; turning them on at a bin edge would jump the integral in the preceding bin.
    if (isLevelBin)
        Curve_Slope[localIndex] = IsRealLevelBin(localIndex) ? slope : 0.0;
    BOOST_BARRIER;

    if (isLevelBin)
    {
        bool holdsContent = IsRealLevelBin(localIndex) && Curve_LowerPQ[localIndex] < topPQ;
        float binTopPQ = min(Curve_UpperPQ[localIndex], topPQ);
        Curve_BinIntegral[localIndex] = holdsContent ? CurveIntegralInBin(localIndex, binTopPQ) : 0.0;
    }
    BOOST_BARRIER;

    if (isLevelBin)
    {
        float above = 0.0;

        [loop]
        for (int levelBin = localIndex; levelBin < HIST_LEVEL_BINS; ++levelBin)
            above += Curve_BinIntegral[levelBin];

        Curve_Above[localIndex] = above;
    }
    BOOST_BARRIER;

    // Slopes interpolate between bin centers, so the shoulder can take a little more than its room. Scaling every
    // slope by the same factor scales every integral, and puts the top-down curve back on the shoulder start.
    float takenPQ = CurveIntegralAbove(shoulderStartPQ);
    float fit = (takenPQ > availPQ && takenPQ > 0.0) ? availPQ / takenPQ : 1.0;
    BOOST_BARRIER;

    if (isLevelBin && fit < 1.0)
    {
        Curve_Slope[localIndex] *= fit;
        Curve_BinIntegral[localIndex] *= fit;
        Curve_Above[localIndex] *= fit;
    }
    BOOST_BARRIER;
}


// ---------------------------------------------------------------------------------------------------------------------
// The solve
// ---------------------------------------------------------------------------------------------------------------------

struct SolveInput
{
    float binCount;          // this thread's histogram bin
    float offsetSum;
    float driveRatioSum;     // fixed point, HistRatioScale(widthPx)
    float loadRatioSum;
    float maxLevelNits;      // the frame's brightest channel
    float4 state;            // last frame's (filtered load 0..1, content top PQ, has history, log2 gain)
    float frameTimeMs;
    float litFraction;       // share of the panel the frame covers, the rest black
    int widthPx;
};

struct SolveOutput
{
    float4 state;            // (filtered load 0..1, content top PQ, 1, log2 gain)
    float4 loads;            // (raw load %, sent load %, filtered panel load %, full log2 gain)
    float4 curve;            // (bend start nits, ceiling nits, clipped share, whiteout blend)
    float4 shape;            // (bend start PQ, bend width PQ, ceiling PQ, nits where the lookup takes over)
};

struct BinSample
{
    float count;
    float levelNits;
    float levelPQ;
    float driveRatio;
    float loadRatio;
};

// Summed panel load in nits of the frame boosted by one gain, with the curve already built for its ceiling.
float SumBoostedLoadNits(int localIndex, BinSample bin, float gain, float ceilingPQ)
{
    float load = 0.0;
    if (bin.count > 0.0)
    {
        float curveNits = CurveLevelNits(localIndex / HIST_SUB_BINS, bin.levelPQ, ceilingPQ);
        float sentNits = BOOST_CALIBRATED_LEVEL_NITS(gain * curveNits);
        load = bin.count * BinLoadNits(sentNits, bin.driveRatio, bin.loadRatio, HighlightRolloff(curveNits, bin.levelNits));
    }

    return ReduceSolveSum(localIndex, float2(load, 0.0)).x;
}

// Filtered panel load in percent the frame boosted by one gain leaves the panel at.
float FilteredLoadPercent(int localIndex, BinSample bin, float logGain, float fullLoadNits, float3 filter)
{
    float gain = exp2(logGain);
    float ceilingPQ = NitsToPQ(PANEL_SIGNAL_PEAK_NITS / gain);
    BuildToneCurve(localIndex, ceilingPQ);
    float sentLoad = 100.0 * SumBoostedLoadNits(localIndex, bin, gain, ceilingPQ) / fullLoadNits;
    return PanelFilterStep(sentLoad, filter);
}

// Pixels times the log2 error of what the panel shows against the target, at the filtered load the gain causes.
float SumLogError(int localIndex, BinSample bin, float logGain, float loadPercent)
{
    float error = 0.0;
    if (bin.count > 0.0 && bin.levelNits > 1e-6)
    {
        float gain = exp2(logGain);
        float ceilingPQ = NitsToPQ(PANEL_SIGNAL_PEAK_NITS / gain);
        float shownNits = gain * CurveLevelNits(localIndex / HIST_SUB_BINS, bin.levelPQ, ceilingPQ) / EvaluatePanelCompensation(loadPercent);
        float targetNits = min(bin.levelNits, PANEL_SIGNAL_PEAK_NITS);
        error = bin.count * abs(log2(max(shownNits, 1e-6) / targetNits));
    }

    return ReduceSolveSum(localIndex, float2(error, 0.0)).x;
}

// Integrals over one step of log gain of exp(-cost) and of log gain times it, with the cost running linearly from c0
// to c1 across the width w from x0. Both exponentials stay at or under 1.
float2 SoftStep(float x0, float w, float c0, float c1)
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

// Gain for a frame most of whose pixels sit above the ceiling: the Boltzmann average over the gains from 1 to full,
// weighted by exp(-cost), the cost running linearly between grid points, so it moves continuously with the frame.
float SoftPickLogGain(int localIndex, BinSample bin, float fullLogGain, float fullLoadNits, float3 filter, float litPixels)
{
    float spacing = fullLogGain / float(PICK_POINTS - 1);

    [loop]
    for (int gridIndex = 0; gridIndex < PICK_POINTS; ++gridIndex)
    {
        float logGain = spacing * float(gridIndex);
        float loadPercent = FilteredLoadPercent(localIndex, bin, logGain, fullLoadNits, filter);
        float error = SumLogError(localIndex, bin, logGain, loadPercent);
        if (localIndex == 0)
            Solve_PickError[gridIndex] = error;
        BOOST_BARRIER;
    }

    float cost[PICK_POINTS];
    float least = 1e30;

    [unroll]
    for (int index = 0; index < PICK_POINTS; ++index)
    {
        cost[index] = Solve_PickError[index] / (max(litPixels, 1.0) * PICK_TAU_LOG2)
                    - PICK_TIE_PREFERENCE * float(index) / float(PICK_POINTS - 1);
        least = min(least, cost[index]);
    }

    float2 sums = 0.0;

    [unroll]
    for (int segment = 0; segment < PICK_POINTS - 1; ++segment)
        sums += SoftStep(spacing * float(segment), spacing, cost[segment] - least, cost[segment + 1] - least);

    return (sums.x > 0.0) ? sums.y / sums.x : fullLogGain;
}

// Mean PQ of the brightest pixels, taken from the sub-bins. The raw maximum is deliberately excluded: even inside
// a well-populated bin, a single pixel can only move that bin's mean by its share.
float RobustContentTopPQ(float litPixels)
{
    if (litPixels <= 0.0)
        return NitsToPQ(0.0);

    float wanted = max(CONTENT_TOP_MIN_PIXELS, CONTENT_TOP_FRACTION * litPixels);
    float remaining = wanted;
    float weightedPQ = 0.0;
    float taken = 0.0;

    [loop]
    for (int binIndex = HIST_BINS - 1; binIndex >= 0 && remaining > 0.0; --binIndex)
    {
        float count = Solve_BinCount[binIndex];
        if (count <= 0.0)
            continue;

        float take = min(count, remaining);
        weightedPQ += take * Solve_BinPQ[binIndex];
        taken += take;
        remaining -= take;
    }

    return (taken > 0.0) ? weightedPQ / taken : NitsToPQ(0.0);
}

// The content top rises at once and falls with a release, so a highlight that leaves doesn't snap the curve. Like the
// panel filter, it lands on its target so a held frame stops moving in the last bits.
float SmoothedContentTopPQ(float robustTopPQ, float4 state, float frameTimeMs)
{
    if (state.z <= 0.0)
        return robustTopPQ;

    float seconds = (robustTopPQ >= state.y) ? CONTENT_TOP_ATTACK_SECONDS : CONTENT_TOP_RELEASE_SECONDS;
    float alpha = 1.0 - exp(-clamp(frameTimeMs, 1.0, 250.0) * 0.001 / seconds);
    float easedTopPQ = lerp(state.y, robustTopPQ, alpha);
    return (abs(easedTopPQ - robustTopPQ) < SETTLED_PQ) ? robustTopPQ : max(robustTopPQ, easedTopPQ);
}

void LoadBinSample(int localIndex, SolveInput frame, out BinSample bin)
{
    bin.count = frame.binCount;
    bin.levelNits = (bin.count > 0.0) ? HistMeanLevelNits(localIndex, bin.count, frame.offsetSum) : 0.0;
    bin.levelPQ = NitsToPQ(bin.levelNits);
    float perPixel = (bin.count > 0.0) ? 1.0 / (bin.count * HistRatioScale(frame.widthPx)) : 0.0;
    bin.driveRatio = frame.driveRatioSum * perPixel;
    bin.loadRatio = frame.loadRatioSum * perPixel;
}

// Level bin counts, their smoothed density and mean PQ, and the curve's bin edges.
void LoadLevelBins(int localIndex, BinSample bin)
{
    Solve_BinCount[localIndex] = bin.count;
    Solve_BinPQ[localIndex] = bin.levelPQ;
    BOOST_BARRIER;

    if (localIndex < HIST_LEVEL_BINS)
    {
        Level_Count[localIndex] = SubBinsOfLevel(localIndex);
        Curve_LowerPQ[localIndex] = NitsToPQ(LevelBinLowerNits(localIndex));
        Curve_UpperPQ[localIndex] = NitsToPQ(LevelBinUpperNits(localIndex));
    }
    Solve_Sum[localIndex] = float2(bin.count * bin.levelPQ, 0.0);
    BOOST_BARRIER;

    if (localIndex < HIST_LEVEL_BINS)
    {
        int first = localIndex * HIST_SUB_BINS;
        float pqSum = Solve_Sum[first].x + Solve_Sum[first + 1].x + Solve_Sum[first + 2].x + Solve_Sum[first + 3].x;
        Level_MeanPQ[localIndex] = (Level_Count[localIndex] > 0.0) ? pqSum / Level_Count[localIndex] : Curve_LowerPQ[localIndex];
        Level_DensityCount[localIndex] = IsRealLevelBin(localIndex) ? LevelDensityCount(localIndex) : 0.0;
    }
    BOOST_BARRIER;

    if (localIndex < HIST_LEVEL_BINS)
        Level_SmoothedCount[localIndex] = IsRealLevelBin(localIndex) ? SmoothLevelCount(localIndex) : 0.0;
    BOOST_BARRIER;
}

// Share of the lit pixels whose level bin sits above the ceiling full compensation leaves.
float ClippedShare(int localIndex, float fullLogGain, float litPixels)
{
    float fullCeilingPQ = NitsToPQ(PANEL_PEAK_NITS / exp2(fullLogGain));
    float clipped = 0.0;
    if (localIndex < HIST_LEVEL_BINS && localIndex > 0 && Level_MeanPQ[localIndex] > fullCeilingPQ)
        clipped = Level_Count[localIndex];

    return ReduceSolveSum(localIndex, float2(clipped, 0.0)).x / max(litPixels, 1.0);
}

// Solves the frame's gain and builds its tone curve. Every thread of the 256 calls it with its own histogram bin.
// Afterwards Solve_ToneShape and the curve in groupshared are ready for ToneCurveLookupEntry.
void SolveBoost(int localIndex, SolveInput frame, out SolveOutput result)
{
    BinSample bin;
    LoadBinSample(localIndex, frame, bin);
    LoadLevelBins(localIndex, bin);

    bool lit = bin.count > 0.0 && bin.levelNits > 1e-6;
    float rawLoad = BinLoadNits(bin.levelNits, bin.driveRatio, bin.loadRatio, 0.0);
    float2 rawFrame = ReduceSolveSum(localIndex, float2(bin.count * rawLoad, bin.count));
    float litPixels = ReduceSolveSum(localIndex, float2(lit ? bin.count : 0.0, 0.0)).x;
    float fullLoadNits = max(rawFrame.y * PANEL_LOAD_PEAK_NITS / clamp(frame.litFraction, 0.01, 1.0), 1e-6);

    // The panel's response: the load it's at moves toward the frame's by one frame's share, a larger one when the load
    // falls. With no history it starts at the frame's own load.
    bool hasHistory = frame.state.z > 0.0;
    float3 filter = float3(100.0 * frame.state.x, hasHistory ? PanelFilterAlpha(frame.frameTimeMs) : float2(1.0, 1.0));

    if (localIndex == 0)
    {
        float robustTopPQ = RobustContentTopPQ(litPixels);
        Curve_ContentTopPQ = SmoothedContentTopPQ(robustTopPQ, frame.state, frame.frameTimeMs);
        Solve_LogGainRange = float2(0.0, log2(EvaluatePanelCompensation(100.0)));
    }
    BOOST_BARRIER;

    [loop]
    for (int step = 0; step < GAIN_SOLVE_STEPS; ++step)
    {
        float2 range = Solve_LogGainRange;
        float midLogGain = 0.5 * (range.x + range.y);
        float loadPercent = FilteredLoadPercent(localIndex, bin, midLogGain, fullLoadNits, filter);

        if (localIndex == 0)
        {
            bool needsMoreGain = log2(EvaluatePanelCompensation(loadPercent)) > midLogGain;
            Solve_LogGainRange = needsMoreGain ? float2(midLogGain, range.y) : float2(range.x, midLogGain);
        }
        BOOST_BARRIER;
    }

    // A range that never moved up means the frame needs no gain, and the midpoint would only add the solve's
    // resolution, which the boost and the dither would then apply to every pixel.
    float2 solvedRange = Solve_LogGainRange;
    float fullLogGain = (solvedRange.x > 0.0) ? 0.5 * (solvedRange.x + solvedRange.y) : 0.0;

    // Midtones stay at full compensation unless most of the frame can't fit, and then the gain eases continuously
    // toward the one with the least predicted error. The pick runs on every frame, since its barriers can't sit under
    // a branch the compiler can't prove uniform.
    float clippedShare = ClippedShare(localIndex, fullLogGain, litPixels);
    float whiteoutBlend = smoothstep(WHITEOUT_START_SHARE, WHITEOUT_FULL_SHARE, clippedShare);
    float softLogGain = SoftPickLogGain(localIndex, bin, fullLogGain, fullLoadNits, filter, litPixels);
    float logGain = lerp(fullLogGain, softLogGain, whiteoutBlend);

    // Bisection resolves gain to one interval. Retain the previous positive gain inside that interval (with a small
    // float-rounding margin), so its last-bit limit cycle cannot keep a held HDR10 frame's dither changing forever.
    // The load still follows the actual sent frame below, and a frame needing no gain always lands exactly on 1.
    float solveInterval = log2(EvaluatePanelCompensation(100.0)) * exp2(-float(GAIN_SOLVE_STEPS));
    if (hasHistory && logGain > 0.0 && abs(logGain - frame.state.w) <= 1.01 * solveInterval)
        logGain = frame.state.w;

    float panelLoad = FilteredLoadPercent(localIndex, bin, logGain, fullLoadNits, filter);
    float sentLoad = PanelFilterSentLoad(panelLoad, filter);
    // Compare the remaining gap, not this frame's increment, and land on the target instead of freezing the old load.
    if (hasHistory && abs(sentLoad - panelLoad) < SETTLED_LOAD_PERCENT)
        panelLoad = sentLoad;
    float ceilingPQ = NitsToPQ(PANEL_SIGNAL_PEAK_NITS / exp2(logGain));

    if (localIndex == 0)
    {
        float shoulderStartPQ = ShoulderStartPQ(ceilingPQ);
        float kneePQ = SolveKneePQ(ceilingPQ, shoulderStartPQ);
        float bendWidth = BendWidthPQ(kneePQ, ceilingPQ, shoulderStartPQ);
        float bendStart = kneePQ - 0.5 * bendWidth;

        // The lookup takes over at its last entry before the bend, so it continues the source exactly.
        float lookupStartPQ = floor(bendStart * (TONE_CURVE_LUT_SIZE - 1)) / (TONE_CURVE_LUT_SIZE - 1);
        Solve_ToneShape = float4(bendStart, bendWidth, ceilingPQ, PQToNits(lookupStartPQ));
    }
    BOOST_BARRIER;

    float4 shape = Solve_ToneShape;
    result.state = float4(0.01 * panelLoad, Curve_ContentTopPQ, 1.0, logGain);
    result.loads = float4(100.0 * rawFrame.x / fullLoadNits, sentLoad, panelLoad, fullLogGain);
    result.curve = float4(PQToNits(shape.x), PQToNits(shape.z), clippedShare, whiteoutBlend);
    result.shape = shape;
}

// Lookup entry of the curve SolveBoost built, before the clamp at the ceiling. Entries past the content top stay
// unclamped, so the ones around it interpolate onto the ceiling instead of under it.
float ToneCurveLookupEntry(int entry)
{
    float4 shape = Solve_ToneShape;
    float inputPQ = float(entry) / float(TONE_CURVE_LUT_SIZE - 1);
    return max(EvaluateToneCurvePQ(inputPQ, shape.x, shape.y, shape.z), 0.0);
}


// ---------------------------------------------------------------------------------------------------------------------
// The boost on a pixel
// ---------------------------------------------------------------------------------------------------------------------

// Shown brightest channel under the tone curve, before the gain. The lookup entries are interpolated in full
// precision, which hardware filtering's 8-bit weights would round.
float ShownLevelNits(float levelNits, float4 shape)
{
    if (levelNits <= shape.w)
        return levelNits;

    float position = NitsToPQ(levelNits) * (TONE_CURVE_LUT_SIZE - 1);
    int entry = min(int(position), TONE_CURVE_LUT_SIZE - 2);
    float lower = BOOST_TONE_LOOKUP(entry);
    float upper = BOOST_TONE_LOOKUP(entry + 1);
    float shownPQ = min(lerp(lower, upper, saturate(position - float(entry))), shape.z);
    return PQToNits(shownPQ);
}

// Boosted color in BT.2020 nits. Every channel scales by the gain times the curve's shown brightest channel over its
// own, and a compressed highlight blends slightly toward white, which leaves the brightest channel, so the load and
// the ceiling stay exact.
float3 BoostRec2020Nits(float3 colorNits, float levelNits, float shownLevelNits, float gain)
{
    float3 ratioScaled = colorNits * (shownLevelNits / levelNits);
    return gain * lerp(ratioScaled, shownLevelNits.xxx, HighlightRolloff(shownLevelNits, levelNits));
}
