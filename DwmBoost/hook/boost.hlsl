// EOTF Boost for DWM, the scRGB desktop path of Shaders/EOTF_BoostMod3.1_27M2N6500.fx.
//
// The algorithm is the same code: both include Shaders/EOTF_BoostCore_27M2N6500.fxh, with the same constants and the
// same passes. Only the scRGB input path is kept, since DWM composes into FP16 scRGB, so the PQ decode table, the
// dither, the OSD and the debug graph go, and so does every runtime uniform. ReShade intrinsics become plain HLSL:
// tex2Dstore is a RWTexture store, tex2Dfetch a Load, and the barriers and atomics are the plain HLSL ones.
//
// DWM runs the boost only when it composes, so the panel filter and the content top advance by the time since the last
// run, the same as the shader does by its frame time.
//
// Five stages, with the shader's sync boundaries:
//   1  CS_Setup          last run's state copy, with the history dropped after a reset, and row histogram clear
//   2  CS_Build          full-frame row histogram build (reads the clean copy)
//   3  CS_Reduce         global histogram reduction
//   4  CS_Solve          gain solve, tone curve and its lookup
//   5  VS_Boost/PS_Boost fullscreen boost (clean copy -> back buffer)

#define BOOST_BARRIER GroupMemoryBarrierWithGroupSync()
#define BOOST_ATOMIC_ADD(destination, value) InterlockedAdd(destination, value)
#define BOOST_ATOMIC_MAX(destination, value) InterlockedMax(destination, value)

// The solve writes the lookup and the boost reads it, so the core needs its reader from the start.
Texture2D<float> Boost_ToneLUT : register(t3);
#define BOOST_TONE_LOOKUP(entry) Boost_ToneLUT.Load(int3(entry, 0, 0))

#include "../../Shaders/EOTF_BoostCore_27M2N6500.fxh"

// Full-frame histogram layout.
#define HIST_TILE_COUNT_Y ((BUFFER_HEIGHT + HIST_TILE_SIZE - 1) / HIST_TILE_SIZE)


cbuffer BoostCB : register(b0)
{
    uint  ResetFlag;       // 1 = resume after a pause: drop the last run's panel state
    uint  BufferWidthPx;   // target back-buffer size; sets the histogram geometry
    uint  BufferHeightPx;
    float LitFraction;     // share of the native panel the buffer covers; the rest is black bars
    float FrameTime;       // milliseconds since the last run
};

#define BUFFER_WIDTH  int(BufferWidthPx)
#define BUFFER_HEIGHT int(BufferHeightPx)


// =====================================================================================
// Pass 1: copy the last run's state and clear the row histograms.
// SRV  t0 = APLState
// UAV  u0 = RowCount u1 = RowOffset u2 = RowDriveRatio u3 = RowLoadRatio u4 = APLPrev
// =====================================================================================
Texture2D<float4>   Setup_APLState     : register(t0);
RWTexture2D<int>    Setup_RowCount     : register(u0);
RWTexture2D<int>    Setup_RowOffset    : register(u1);
RWTexture2D<int>    Setup_RowDrive     : register(u2);
RWTexture2D<int>    Setup_RowLoad      : register(u3);
RWTexture2D<float4> Setup_APLPrev      : register(u4);

[numthreads(HIST_BINS, 1, 1)]
void CS_Setup(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    if (localIndex == 0)
    {
        float4 state = Setup_APLState.Load(int3(0, 0, 0));

        // After a pause the panel showed the frames unboosted, so the last state is stale.
        if (ResetFlag != 0u)
            state.z = 0.0;

        Setup_APLPrev[int2(0, 0)] = state;
        Setup_APLPrev[int2(1, 0)] = 0.0;
    }

    [loop]
    for (int entry = localIndex; entry < HIST_TILE_COUNT_Y * HIST_BINS; entry += HIST_BINS)
    {
        int rowIndex = entry / HIST_BINS;
        int binIndex = entry - rowIndex * HIST_BINS;
        int2 coord = HistRowCoord(rowIndex, binIndex);
        Setup_RowCount[coord] = 0;
        Setup_RowOffset[coord] = 0;
        Setup_RowDrive[coord] = 0;
        Setup_RowLoad[coord] = 0;

        if (binIndex == 0)
            Setup_RowCount[HistRowMaxLevelCoord(rowIndex)] = 0;
    }
}


// =====================================================================================
// Pass 2: decode source pixels and accumulate row histograms.
// SRV  t0 = CleanCopy
// UAV  u0 = RowCount u1 = RowOffset u2 = RowDriveRatio u3 = RowLoadRatio
// =====================================================================================
Texture2D<float4> Build_CleanCopy : register(t0);
RWTexture2D<int>  Build_RowCount  : register(u0);
RWTexture2D<int>  Build_RowOffset : register(u1);
RWTexture2D<int>  Build_RowDrive  : register(u2);
RWTexture2D<int>  Build_RowLoad   : register(u3);

[numthreads(HIST_THREADS_X, HIST_THREADS_Y, 1)]
void CS_Build(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.y * HIST_THREADS_X + threadID.x);
    TileClear(localIndex);
    GroupMemoryBarrierWithGroupSync();

    int row = int(groupID.y);
    int2 pixelBase = int2(groupID.xy) * HIST_TILE_SIZE + int2(threadID.xy) * 2;

    float3 rec2020Nits[4];
    float3 panelNits[4];
    bool valid[4];

    [unroll]
    for (int pixel = 0; pixel < 4; ++pixel)
    {
        int2 position = pixelBase + int2(pixel & 1, pixel >> 1);
        valid[pixel] = position.x < BUFFER_WIDTH && position.y < BUFFER_HEIGHT;
        float3 rec709Nits = Build_CleanCopy.Load(int3(min(position, int2(BUFFER_WIDTH, BUFFER_HEIGHT) - 1), 0)).rgb
                          * SCRGB_REFERENCE_NITS;
        rec2020Nits[pixel] = mul(REC709_TO_REC2020, rec709Nits);
        panelNits[pixel] = mul(REC709_TO_PANEL, rec709Nits);
    }

    TileAddQuad(rec2020Nits, panelNits, valid, HistRatioScale(BUFFER_WIDTH));
    GroupMemoryBarrierWithGroupSync();

    if (localIndex == 0)
        InterlockedMax(Build_RowCount[HistRowMaxLevelCoord(row)], Tile_MaxLevelBits);

    int packedCount = Tile_PackedCount[localIndex];
    int count = packedCount >> HIST_PACK_COUNT_SHIFT;
    if (count > 0)
    {
        int2 coord = HistRowCoord(row, localIndex);
        InterlockedAdd(Build_RowCount[coord], count);
        InterlockedAdd(Build_RowOffset[coord], packedCount & HIST_PACK_OFFSET_MASK);
        InterlockedAdd(Build_RowDrive[coord], Tile_DriveRatio[localIndex]);
        InterlockedAdd(Build_RowLoad[coord], Tile_LoadRatio[localIndex]);
    }
}


// =====================================================================================
// Pass 3: reduce the row histograms into one global histogram.
// SRV  t0 = RowCount t1 = RowOffset t2 = RowDriveRatio t3 = RowLoadRatio
// UAV  u0 = GlobalCount u1 = GlobalSums
// =====================================================================================
Texture2D<int>     Reduce_RowCount  : register(t0);
Texture2D<int>     Reduce_RowOffset : register(t1);
Texture2D<int>     Reduce_RowDrive  : register(t2);
Texture2D<int>     Reduce_RowLoad   : register(t3);
RWTexture2D<int>   Reduce_GlobalCount : register(u0);
RWTexture2D<float4> Reduce_GlobalSums : register(u1);

groupshared int   Reduce_Count[HIST_REDUCE_THREADS];
groupshared float3 Reduce_Sums[HIST_REDUCE_THREADS];

[numthreads(HIST_REDUCE_THREADS, 1, 1)]
void CS_Reduce(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);
    int2 binCoord = int2(groupID.xy);
    int binIndex = binCoord.y * HIST_BLOCK_W + binCoord.x;

    int count = 0;
    float3 sums = 0.0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < HIST_TILE_COUNT_Y; rowIndex += HIST_REDUCE_THREADS)
    {
        int3 coord = int3(HistRowCoord(rowIndex, binIndex), 0);
        count += Reduce_RowCount.Load(coord);
        sums += float3(Reduce_RowOffset.Load(coord), Reduce_RowDrive.Load(coord), Reduce_RowLoad.Load(coord));
    }

    Reduce_Count[localIndex] = count;
    Reduce_Sums[localIndex] = sums;
    GroupMemoryBarrierWithGroupSync();

    [unroll]
    for (int stride = HIST_REDUCE_THREADS / 2; stride > 0; stride /= 2)
    {
        if (localIndex < stride)
        {
            Reduce_Count[localIndex] += Reduce_Count[localIndex + stride];
            Reduce_Sums[localIndex] += Reduce_Sums[localIndex + stride];
        }
        GroupMemoryBarrierWithGroupSync();
    }

    if (localIndex != 0)
        return;

    Reduce_GlobalCount[binCoord] = Reduce_Count[0];
    Reduce_GlobalSums[binCoord] = float4(Reduce_Sums[0], 0.0);

    if (binIndex == 0)
    {
        int maxLevelBits = 0;

        [loop]
        for (int maxRow = 0; maxRow < HIST_TILE_COUNT_Y; ++maxRow)
            maxLevelBits = max(maxLevelBits, Reduce_RowCount.Load(int3(HistRowMaxLevelCoord(maxRow), 0)));

        Reduce_GlobalCount[HistGlobalMaxLevelCoord()] = maxLevelBits;
    }
}


// =====================================================================================
// Pass 4: gain solve, tone curve and its lookup.
// SRV  t0 = GlobalCount t1 = GlobalSums t2 = APLPrev
// UAV  u0 = APLState u1 = ToneCurveShape u2 = ToneCurveLUT
// =====================================================================================
Texture2D<int>      Solve_GlobalCount : register(t0);
Texture2D<float4>   Solve_GlobalSums  : register(t1);
Texture2D<float4>   Solve_APLPrev     : register(t2);
RWTexture2D<float4> Solve_APLState    : register(u0);
RWTexture2D<float4> Solve_OutputShape  : register(u1);
RWTexture2D<float>  Solve_ToneLUT     : register(u2);

[numthreads(HIST_BINS, 1, 1)]
void CS_Solve(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    SolveInput frame;
    int3 binCoord = int3(HistBlockCoord(localIndex), 0);
    float4 sums = Solve_GlobalSums.Load(binCoord);
    frame.binCount = float(Solve_GlobalCount.Load(binCoord));
    frame.offsetSum = sums.x;
    frame.driveRatioSum = sums.y;
    frame.loadRatioSum = sums.z;
    frame.maxLevelNits = asfloat(Solve_GlobalCount.Load(int3(HistGlobalMaxLevelCoord(), 0)));
    frame.state = Solve_APLPrev.Load(int3(0, 0, 0));
    frame.frameTimeMs = FrameTime;
    frame.litFraction = LitFraction;
    frame.widthPx = BUFFER_WIDTH;

    SolveOutput result;
    SolveBoost(localIndex, frame, result);

    [loop]
    for (int entry = localIndex; entry < TONE_CURVE_LUT_SIZE; entry += HIST_BINS)
        Solve_ToneLUT[int2(entry, 0)] = ToneCurveLookupEntry(entry);

    if (localIndex != 0)
        return;

    // (filtered load, content top PQ, has history, log2 gain), (raw, sent and panel load %, full log2 gain), and
    // (bend start nits, ceiling nits, clipped share, whiteout blend) for the stats.
    Solve_APLState[int2(0, 0)] = result.state;
    Solve_APLState[int2(1, 0)] = result.loads;
    Solve_APLState[int2(2, 0)] = result.curve;
    Solve_OutputShape[int2(0, 0)] = result.shape;
}


// =====================================================================================
// Pass 5: fullscreen boost. Clean copy -> back buffer.
// SRV  t0 = CleanCopy t1 = APLState t2 = ToneCurveShape t3 = ToneCurveLUT
// =====================================================================================
Texture2D<float4> Boost_CleanCopy : register(t0);
Texture2D<float4> Boost_APLState  : register(t1);
Texture2D<float4> Boost_ToneShape : register(t2);

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

// Runs the core's boost in nits and returns the buffer's scRGB, so both paths round the same way in the FP16 buffer.
float4 PS_Boost(VSOut i) : SV_Target
{
    float3 color = Boost_CleanCopy.Load(int3(int2(i.pos.xy), 0)).rgb;
    float3 colorNits = mul(REC709_TO_REC2020, color * SCRGB_REFERENCE_NITS);
    float levelNits = Max3(max(colorNits, 0.0));

    if (levelNits <= 1e-6)
        return float4(color, 1.0);

    float gain = exp2(Boost_APLState.Load(int3(0, 0, 0)).w);
    float shownLevelNits = ShownLevelNits(levelNits, Boost_ToneShape.Load(int3(0, 0, 0)));

    if (gain == 1.0 && shownLevelNits == levelNits)
        return float4(color, 1.0);

    float3 boostedNits = BoostRec2020Nits(colorNits, levelNits, shownLevelNits, gain);
    return float4(mul(REC2020_TO_REC709, boostedNits) / SCRGB_REFERENCE_NITS, 1.0);
}
