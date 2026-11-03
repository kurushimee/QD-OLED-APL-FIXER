// The boost's GPU work for one frame: the full-frame histogram, the gain solve and tone curve, and the boosted draw.
// The DWM hook runs it on the desktop, and the verify renderer runs the same code on a saved HDR frame.
#pragma once

#include <d3d11.h>

// Histogram and tone curve geometry, which must match boost.hlsl.
const UINT TILE_SIZE = 32;
const UINT BLOCK_W = 16, BLOCK_H = 16;
const UINT TONE_CURVE_LUT_SIZE = 1024;

inline UINT TileCount(UINT px) { return (px + TILE_SIZE - 1) / TILE_SIZE; }

// Runs after a content change that keep DWM composing while the panel filter and the content top settle. Each run
// advances both by the time since the last one, so one run lands on the new content.
const int SETTLE_RUNS = 1;

// Seconds after those runs that DWM keeps composing. Gain feedback slows the load response by up to
// 1 / (1 - peak elasticity); the content top releases directly in PQ. The conservative bounds are 3.47 s for load
// and 1.85 s for the top. Four seconds leave margin for discrete refresh steps, including 60 Hz.
const double SETTLE_SECONDS = 4.0;

struct Tex
{
    ID3D11Texture2D* t = nullptr;
    ID3D11ShaderResourceView* srv = nullptr;
    ID3D11UnorderedAccessView* uav = nullptr;
    void Release();
};

struct BoostPipeline
{
    UINT width = 0, height = 0;

    Tex clean;                     // RGBA16F scRGB frame the passes read (SRV)
    // R32_SINT (SRV+UAV), the counts with an aux column for the brightest level, and each bin's summed level position
    // and load ratios
    Tex rowCount, rowOffset, rowDrive, rowLoad;
    Tex globalCount;               // R32_SINT (SRV+UAV), with the same aux column
    Tex globalSums;                // RGBA32F (SRV+UAV), the summed level position and load ratios
    Tex aplState, aplPrev;         // RGBA32F (SRV+UAV), aplState 3x1: the state, the loads and the curve's stats
    Tex toneShape;                 // 1x1 RGBA32F (SRV+UAV): (bend start PQ, bend width PQ, ceiling PQ, lookup start nits)
    Tex toneLUT;                   // R32_FLOAT (SRV+UAV)

    ID3D11ComputeShader* csSetup = nullptr;
    ID3D11ComputeShader* csBuild = nullptr;
    ID3D11ComputeShader* csReduce = nullptr;
    ID3D11ComputeShader* csSolve = nullptr;
    ID3D11VertexShader* vsBoost = nullptr;
    ID3D11PixelShader* psBoost = nullptr;
    ID3D11Buffer* cb = nullptr;

    bool Create(ID3D11Device* dev, UINT w, UINT h);

    // Boosts the clean copy into rtv. reset drops the last run's gain, litFraction is the share of the panel the
    // frame lights, and frameMs is the time since the last run.
    void Run(ID3D11DeviceContext* c, ID3D11RenderTargetView* rtv, bool reset, float litFraction, float frameMs);

    // Pass 4 alone, the gain solve and tone curve on the histogram the last Run built.
    void Solve(ID3D11DeviceContext* c);

    void Release();
};
