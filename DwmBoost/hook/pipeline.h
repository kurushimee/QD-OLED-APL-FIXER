// The boost's GPU work for one frame: the full-frame histogram, the APL solve and curve fit, and the boosted draw.
// The DWM hook runs it on the desktop, and the verify renderer runs the same code on a saved HDR frame.
#pragma once

#include <d3d11.h>

// Histogram and curve geometry — must match boost.hlsl.
const UINT TILE_SIZE = 32;
const UINT BLOCK_W = 16, BLOCK_H = 16;
const UINT BOOST_CURVE_CELLS = 512;

inline UINT TileCount(UINT px) { return (px + TILE_SIZE - 1) / TILE_SIZE; }

// Runs after a content change that keep DWM composing while the gain settles. Each solve leaves at most 0.765
// of the gain error, the steepest slope of the compensation table, so 22 take the largest possible jump under
// half a 10-bit PQ code.
const int SETTLE_RUNS = 22;

// Seconds after those runs that DWM keeps composing while the shown gain eases in. Once the runs settle the
// ease's gap shrinks as exp(-t / smoothing time), so from any APL 4.08 s bring the gain under half a 10-bit PQ code.
const double SETTLE_SECONDS = 4.08;

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

    Tex clean;               // RGBA16F scRGB frame the passes read (SRV)
    Tex rowCount, rowOffset, rowMaxNits, rowLoad, rowOffsetSq;       // R32_SINT (SRV+UAV)
    Tex globalCount, frameTop;                                       // R32_SINT (SRV+UAV)
    Tex globalOffset, globalMaxNits, globalLoad, globalOffsetSq;     // R32_FLOAT (SRV+UAV)
    Tex aplInstant, aplPrev, boostParams;                            // RGBA32F (SRV+UAV)
    Tex boostCurve;                                                  // R32_FLOAT (SRV+UAV)

    ID3D11ComputeShader* csSetup = nullptr;
    ID3D11ComputeShader* csBuild = nullptr;
    ID3D11ComputeShader* csReduce = nullptr;
    ID3D11ComputeShader* csSolve = nullptr;
    ID3D11VertexShader* vsBoost = nullptr;
    ID3D11PixelShader* psBoost = nullptr;
    ID3D11Buffer* cb = nullptr;

    bool Create(ID3D11Device* dev, UINT w, UINT h);

    // Boosts the clean copy into rtv. reset drops the last frame's load, litFraction is the share of the panel the
    // frame lights, and frameMs is the time since the last run.
    void Run(ID3D11DeviceContext* c, ID3D11RenderTargetView* rtv, bool reset, float litFraction, float frameMs);

    // Pass 4 alone, the APL solve and curve fit on the histogram the last Run built.
    void Solve(ID3D11DeviceContext* c);

    void Release();
};
