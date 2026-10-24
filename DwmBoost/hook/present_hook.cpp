#include "present_hook.h"
#include "tile_cover.h"
#include "boost_bytecode.h"

#include <d3d11.h>
#include <dxgi.h>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <initializer_list>
#include <utility>

#pragma comment(lib, "d3d11.lib")

namespace {

// Histogram geometry — must match boost.hlsl. Each 32-pixel-high screen row keeps a 16x16 histogram block, and
// the count textures carry one more column for the row maximum. The row metadata packs the row's pixel count in
// 20 bits, which holds any width up to 32767.
const UINT TILE_SIZE = 32;
const UINT BLOCK_W = 16, BLOCK_H = 16;
const UINT ROLLING_PHASES = 6;
const UINT FAST_PQ_NODES = 129;

UINT TileCount(UINT px) { return (px + TILE_SIZE - 1) / TILE_SIZE; }
UINT RollingRowSlots(UINT px) { return (TileCount(px) + ROLLING_PHASES - 1) / ROLLING_PHASES; }

// After a content change the histogram takes ROLLING_PHASES runs to cover the new frame, then the smoothed APL
// closes its gap with a 0.5 s time constant. The log gain moves at most 6.36 per unit of APL at the baked
// settings, and half a 10-bit PQ code is 0.0065 of log2 gain at its steepest, so the gain lands within it after
// ln(6.36 / 0.0065) = 6.9 time constants.
const double SMOOTHING_SETTLE_MS = 3450.0;
const double PRIME_MIN_GAP_MS = 1000.0;

// Host config mirror (written by the watcher thread, read in the present path).
std::atomic<bool>     g_enabled{false};
std::atomic<int>      g_monLeft{0}, g_monTop{0};
std::atomic<uint32_t> g_monWidth{0}, g_monHeight{0};
std::atomic<bool>     g_monHdr{false};

std::atomic<long>     g_inFlight{0};
Present_t             g_orig = nullptr;

struct Tex
{
    ID3D11Texture2D* t = nullptr;
    ID3D11ShaderResourceView* srv = nullptr;
    ID3D11UnorderedAccessView* uav = nullptr;
    void Release()
    {
        if (uav) { uav->Release(); uav = nullptr; }
        if (srv) { srv->Release(); srv = nullptr; }
        if (t) { t->Release(); t = nullptr; }
    }
};

bool CreateTex(ID3D11Device* dev, UINT w, UINT h, DXGI_FORMAT fmt, bool wantSRV, bool wantUAV, Tex& out)
{
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = w; d.Height = h; d.MipLevels = 1; d.ArraySize = 1;
    d.Format = fmt; d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = (wantSRV ? D3D11_BIND_SHADER_RESOURCE : 0) | (wantUAV ? D3D11_BIND_UNORDERED_ACCESS : 0);
    if (FAILED(dev->CreateTexture2D(&d, nullptr, &out.t))) return false;
    if (wantSRV && FAILED(dev->CreateShaderResourceView(out.t, nullptr, &out.srv))) return false;
    if (wantUAV && FAILED(dev->CreateUnorderedAccessView(out.t, nullptr, &out.uav))) return false;
    return true;
}

struct MonitorState
{
    ID3D11Device* dev = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    void* owner = nullptr;
    UINT width = 0, height = 0;

    Tex clean;                                                       // RGBA16F clean copy (SRV)
    Tex apl, candidateBoostParams, boostParams, aplInstant, aplPrev; // RGBA32F (SRV+UAV)
    Tex fastPQNits;                                                  // R32_FLOAT (SRV+UAV)
    Tex rowCount, rowOffset10, rowMaxNits, rowMeta, globalCount;     // R32_SINT (SRV+UAV)
    Tex globalOffset10, globalMaxNits;                               // R32_FLOAT (SRV+UAV)

    ID3D11ComputeShader* csSetup = nullptr;
    ID3D11ComputeShader* csBuild = nullptr;
    ID3D11ComputeShader* csReduce = nullptr;
    ID3D11ComputeShader* csSolve = nullptr;
    ID3D11VertexShader* vsBoost = nullptr;
    ID3D11PixelShader* psBoost = nullptr;
    ID3D11SamplerState* pointClamp = nullptr;
    ID3D11SamplerState* linearClamp = nullptr;
    ID3D11RasterizerState* noCull = nullptr;
    ID3D11Buffer* cb = nullptr;

    TileCover cover;
    bool primed = false;

    HANDLE settleEvt = nullptr, contentEvt = nullptr, primeEvt = nullptr;
    unsigned evtOpenTick = 0;

    LARGE_INTEGER freq = {};
    LONGLONG lastPrimeQpc = 0;
    LONGLONG lastRunQpc = 0;
    LONGLONG histogramCoveredQpc = 0;
    UINT runsSinceContent = 0;
    bool initialized = false;

    void Release()
    {
        clean.Release();
        apl.Release(); candidateBoostParams.Release(); boostParams.Release(); aplInstant.Release(); aplPrev.Release();
        fastPQNits.Release();
        rowCount.Release(); rowOffset10.Release(); rowMaxNits.Release(); rowMeta.Release(); globalCount.Release();
        globalOffset10.Release(); globalMaxNits.Release();
        if (csSetup) { csSetup->Release(); csSetup = nullptr; }
        if (csBuild) { csBuild->Release(); csBuild = nullptr; }
        if (csReduce) { csReduce->Release(); csReduce = nullptr; }
        if (csSolve) { csSolve->Release(); csSolve = nullptr; }
        if (vsBoost) { vsBoost->Release(); vsBoost = nullptr; }
        if (psBoost) { psBoost->Release(); psBoost = nullptr; }
        if (pointClamp) { pointClamp->Release(); pointClamp = nullptr; }
        if (linearClamp) { linearClamp->Release(); linearClamp = nullptr; }
        if (noCull) { noCull->Release(); noCull = nullptr; }
        if (cb) { cb->Release(); cb = nullptr; }
        if (settleEvt) { CloseHandle(settleEvt); settleEvt = nullptr; }
        if (contentEvt) { CloseHandle(contentEvt); contentEvt = nullptr; }
        if (primeEvt) { CloseHandle(primeEvt); primeEvt = nullptr; }
        if (ctx) { ctx->Release(); ctx = nullptr; }
        if (dev) { dev->Release(); dev = nullptr; }
        owner = nullptr;
        initialized = false;
    }
};

MonitorState g_state;

bool BuildState(MonitorState& s, ID3D11Texture2D* backBuffer, void* owner, UINT w, UINT h)
{
    s.Release();
    backBuffer->GetDevice(&s.dev);
    if (!s.dev) return false;
    s.dev->GetImmediateContext(&s.ctx);
    if (!s.ctx) { s.Release(); return false; }
    s.owner = owner; s.width = w; s.height = h;

    const UINT tileCountY = TileCount(h);
    const UINT rowTexH = tileCountY * BLOCK_H;
    const DXGI_FORMAT RGBA32F = DXGI_FORMAT_R32G32B32A32_FLOAT;

    bool ok = true;
    ok &= CreateTex(s.dev, w, h, DXGI_FORMAT_R16G16B16A16_FLOAT, true, false, s.clean);
    ok &= CreateTex(s.dev, 1, 1, RGBA32F, true, true, s.apl);
    ok &= CreateTex(s.dev, 3, 1, RGBA32F, true, true, s.candidateBoostParams);
    ok &= CreateTex(s.dev, 1, 1, RGBA32F, true, true, s.boostParams);
    ok &= CreateTex(s.dev, 1, 1, RGBA32F, true, true, s.aplInstant);
    ok &= CreateTex(s.dev, 1, 1, RGBA32F, true, true, s.aplPrev);
    ok &= CreateTex(s.dev, FAST_PQ_NODES, 1, DXGI_FORMAT_R32_FLOAT, true, true, s.fastPQNits);
    ok &= CreateTex(s.dev, BLOCK_W + 1, rowTexH, DXGI_FORMAT_R32_SINT, true, true, s.rowCount);
    ok &= CreateTex(s.dev, BLOCK_W, rowTexH, DXGI_FORMAT_R32_SINT, true, true, s.rowOffset10);
    ok &= CreateTex(s.dev, BLOCK_W, rowTexH, DXGI_FORMAT_R32_SINT, true, true, s.rowMaxNits);
    ok &= CreateTex(s.dev, 1, tileCountY, DXGI_FORMAT_R32_SINT, true, true, s.rowMeta);
    ok &= CreateTex(s.dev, BLOCK_W + 1, BLOCK_H, DXGI_FORMAT_R32_SINT, true, true, s.globalCount);
    ok &= CreateTex(s.dev, BLOCK_W, BLOCK_H, DXGI_FORMAT_R32_FLOAT, true, true, s.globalOffset10);
    ok &= CreateTex(s.dev, BLOCK_W, BLOCK_H, DXGI_FORMAT_R32_FLOAT, true, true, s.globalMaxNits);

    ok &= SUCCEEDED(s.dev->CreateComputeShader(g_CS_Setup, sizeof(g_CS_Setup), nullptr, &s.csSetup));
    ok &= SUCCEEDED(s.dev->CreateComputeShader(g_CS_Build, sizeof(g_CS_Build), nullptr, &s.csBuild));
    ok &= SUCCEEDED(s.dev->CreateComputeShader(g_CS_Reduce, sizeof(g_CS_Reduce), nullptr, &s.csReduce));
    ok &= SUCCEEDED(s.dev->CreateComputeShader(g_CS_Solve, sizeof(g_CS_Solve), nullptr, &s.csSolve));
    ok &= SUCCEEDED(s.dev->CreateVertexShader(g_VS_Boost, sizeof(g_VS_Boost), nullptr, &s.vsBoost));
    ok &= SUCCEEDED(s.dev->CreatePixelShader(g_PS_Boost, sizeof(g_PS_Boost), nullptr, &s.psBoost));

    D3D11_BUFFER_DESC cbd = {};
    cbd.ByteWidth = 16; cbd.Usage = D3D11_USAGE_DYNAMIC;
    cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER; cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ok &= SUCCEEDED(s.dev->CreateBuffer(&cbd, nullptr, &s.cb));

    D3D11_SAMPLER_DESC sd = {};
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    ok &= SUCCEEDED(s.dev->CreateSamplerState(&sd, &s.pointClamp));
    sd.Filter = D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
    ok &= SUCCEEDED(s.dev->CreateSamplerState(&sd, &s.linearClamp));

    // ReShade draws with culling off, and its fullscreen triangle winds counter-clockwise.
    D3D11_RASTERIZER_DESC rd = {};
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    ok &= SUCCEEDED(s.dev->CreateRasterizerState(&rd, &s.noCull));

    if (!ok) { s.Release(); return false; }

    // ReShade creates its textures zeroed, which the shader reads as no history.
    const UINT zeroU[4] = {};
    const FLOAT zeroF[4] = {};
    for (Tex* t : { &s.apl, &s.candidateBoostParams, &s.boostParams, &s.aplInstant, &s.aplPrev, &s.fastPQNits,
                    &s.globalOffset10, &s.globalMaxNits })
        s.ctx->ClearUnorderedAccessViewFloat(t->uav, zeroF);
    for (Tex* t : { &s.rowCount, &s.rowOffset10, &s.rowMaxNits, &s.rowMeta, &s.globalCount })
        s.ctx->ClearUnorderedAccessViewUint(t->uav, zeroU);

    s.cover.Init(w, h, TILE_SIZE);
    s.primed = false;
    QueryPerformanceFrequency(&s.freq);
    s.lastPrimeQpc = 0;
    s.lastRunQpc = 0;
    s.histogramCoveredQpc = 0;
    s.runsSinceContent = 0;
    s.initialized = true;
    return true;
}

// -------- DWM immediate-context state save / restore --------

const UINT SRV_SLOTS = 14, UAV_SLOTS = 7, SAMPLER_SLOTS = 2;

struct StateBlock
{
    ID3D11RenderTargetView* rtv[8] = {};
    ID3D11DepthStencilView* dsv = nullptr;
    ID3D11ComputeShader* cs = nullptr;
    ID3D11ShaderResourceView* csSrv[SRV_SLOTS] = {};
    ID3D11UnorderedAccessView* csUav[8] = {};
    ID3D11SamplerState* csSamp[SAMPLER_SLOTS] = {};
    ID3D11Buffer* csCb[1] = {};
    ID3D11VertexShader* vs = nullptr;
    ID3D11GeometryShader* gs = nullptr;
    ID3D11PixelShader* ps = nullptr;
    ID3D11RasterizerState* rs = nullptr;
    ID3D11BlendState* blend = nullptr; FLOAT blendFactor[4] = {}; UINT sampleMask = 0;
    ID3D11DepthStencilState* depthStencil = nullptr; UINT stencilRef = 0;
    ID3D11ShaderResourceView* psSrv[SRV_SLOTS] = {};
    ID3D11SamplerState* psSamp[SAMPLER_SLOTS] = {};
    ID3D11Buffer* psCb[1] = {};
    ID3D11InputLayout* layout = nullptr;
    D3D11_PRIMITIVE_TOPOLOGY topo = D3D11_PRIMITIVE_TOPOLOGY_UNDEFINED;
    ID3D11Buffer* vb = nullptr; UINT vbStride = 0, vbOffset = 0;
    ID3D11Buffer* ib = nullptr; DXGI_FORMAT ibFmt = DXGI_FORMAT_UNKNOWN; UINT ibOffset = 0;
    UINT numViewports = 0;
    D3D11_VIEWPORT viewports[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE] = {};
};

void SaveState(ID3D11DeviceContext* c, StateBlock& b)
{
    c->OMGetRenderTargets(8, b.rtv, &b.dsv);
    c->CSGetShader(&b.cs, nullptr, nullptr);
    c->CSGetShaderResources(0, SRV_SLOTS, b.csSrv);
    c->CSGetUnorderedAccessViews(0, 8, b.csUav);
    c->CSGetSamplers(0, SAMPLER_SLOTS, b.csSamp);
    c->CSGetConstantBuffers(0, 1, b.csCb);
    c->VSGetShader(&b.vs, nullptr, nullptr);
    c->GSGetShader(&b.gs, nullptr, nullptr);
    c->PSGetShader(&b.ps, nullptr, nullptr);
    c->PSGetShaderResources(0, SRV_SLOTS, b.psSrv);
    c->PSGetSamplers(0, SAMPLER_SLOTS, b.psSamp);
    c->PSGetConstantBuffers(0, 1, b.psCb);
    c->RSGetState(&b.rs);
    c->OMGetBlendState(&b.blend, b.blendFactor, &b.sampleMask);
    c->OMGetDepthStencilState(&b.depthStencil, &b.stencilRef);
    c->IAGetInputLayout(&b.layout);
    c->IAGetPrimitiveTopology(&b.topo);
    c->IAGetVertexBuffers(0, 1, &b.vb, &b.vbStride, &b.vbOffset);
    c->IAGetIndexBuffer(&b.ib, &b.ibFmt, &b.ibOffset);
    b.numViewports = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    c->RSGetViewports(&b.numViewports, b.viewports);
}

void RestoreState(ID3D11DeviceContext* c, StateBlock& b)
{
    ID3D11UnorderedAccessView* nullUav[8] = {};
    c->CSSetUnorderedAccessViews(0, 8, nullUav, nullptr);
    c->CSSetShaderResources(0, SRV_SLOTS, b.csSrv);
    c->CSSetShader(b.cs, nullptr, 0);
    c->CSSetSamplers(0, SAMPLER_SLOTS, b.csSamp);
    c->CSSetConstantBuffers(0, 1, b.csCb);
    c->CSSetUnorderedAccessViews(0, 8, b.csUav, nullptr);
    c->VSSetShader(b.vs, nullptr, 0);
    c->GSSetShader(b.gs, nullptr, 0);
    c->PSSetShader(b.ps, nullptr, 0);
    c->PSSetShaderResources(0, SRV_SLOTS, b.psSrv);
    c->PSSetSamplers(0, SAMPLER_SLOTS, b.psSamp);
    c->PSSetConstantBuffers(0, 1, b.psCb);
    c->RSSetState(b.rs);
    c->OMSetBlendState(b.blend, b.blendFactor, b.sampleMask);
    c->OMSetDepthStencilState(b.depthStencil, b.stencilRef);
    c->IASetInputLayout(b.layout);
    c->IASetPrimitiveTopology(b.topo);
    c->IASetVertexBuffers(0, 1, &b.vb, &b.vbStride, &b.vbOffset);
    c->IASetIndexBuffer(b.ib, b.ibFmt, b.ibOffset);
    c->OMSetRenderTargets(8, b.rtv, b.dsv);
    if (b.numViewports) c->RSSetViewports(b.numViewports, b.viewports);

    for (auto p : b.rtv) if (p) p->Release();
    if (b.dsv) b.dsv->Release();
    if (b.cs) b.cs->Release();
    for (auto p : b.csSrv) if (p) p->Release();
    for (auto p : b.csUav) if (p) p->Release();
    for (auto p : b.csSamp) if (p) p->Release();
    for (auto p : b.csCb) if (p) p->Release();
    if (b.vs) b.vs->Release();
    if (b.gs) b.gs->Release();
    if (b.ps) b.ps->Release();
    if (b.rs) b.rs->Release();
    if (b.blend) b.blend->Release();
    if (b.depthStencil) b.depthStencil->Release();
    for (auto p : b.psSrv) if (p) p->Release();
    for (auto p : b.psSamp) if (p) p->Release();
    for (auto p : b.psCb) if (p) p->Release();
    if (b.layout) b.layout->Release();
    if (b.vb) b.vb->Release();
    if (b.ib) b.ib->Release();
}

// Binds one compute pass: SRVs at their fixed slots in boost.hlsl, UAVs at the pass's own slots, nulls elsewhere.
void RunCS(ID3D11DeviceContext* c, ID3D11ComputeShader* cs,
           std::initializer_list<std::pair<UINT, ID3D11ShaderResourceView*>> srvs,
           std::initializer_list<std::pair<UINT, ID3D11UnorderedAccessView*>> uavs,
           UINT groupsX, UINT groupsY)
{
    ID3D11ShaderResourceView* srv[SRV_SLOTS] = {};
    ID3D11UnorderedAccessView* uav[UAV_SLOTS] = {};
    for (auto& p : srvs) srv[p.first] = p.second;
    for (auto& p : uavs) uav[p.first] = p.second;

    // The last pass's SRVs go first, so no texture is bound as both an SRV and a UAV while the slots change.
    ID3D11ShaderResourceView* nSrv[SRV_SLOTS] = {};
    c->CSSetShaderResources(0, SRV_SLOTS, nSrv);
    c->CSSetUnorderedAccessViews(0, UAV_SLOTS, uav, nullptr);
    c->CSSetShaderResources(0, SRV_SLOTS, srv);
    c->CSSetShader(cs, nullptr, 0);
    c->Dispatch(groupsX, groupsY, 1);
}

void ClearCS(ID3D11DeviceContext* c)
{
    ID3D11ShaderResourceView* nSrv[SRV_SLOTS] = {};
    ID3D11UnorderedAccessView* nUav[UAV_SLOTS] = {};
    c->CSSetShaderResources(0, SRV_SLOTS, nSrv);
    c->CSSetUnorderedAccessViews(0, UAV_SLOTS, nUav, nullptr);
}

void RunPipeline(MonitorState& s, ID3D11RenderTargetView* bbRTV, float frameTimeMs)
{
    ID3D11DeviceContext* c = s.ctx;

    D3D11_MAPPED_SUBRESOURCE map;
    if (SUCCEEDED(c->Map(s.cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &map)))
    {
        struct CB { uint32_t width, height; float frameTime; float pad; } cb = {};
        cb.width = s.width; cb.height = s.height;
        cb.frameTime = frameTimeMs;
        memcpy(map.pData, &cb, sizeof(cb));
        c->Unmap(s.cb, 0);
    }

    ID3D11SamplerState* samplers[SAMPLER_SLOTS] = { s.pointClamp, s.linearClamp };
    c->CSSetConstantBuffers(0, 1, &s.cb);
    c->CSSetSamplers(0, SAMPLER_SLOTS, samplers);

    RunCS(c, s.csSetup,
          { { 1, s.apl.srv }, { 4, s.aplInstant.srv } },
          { { 0, s.candidateBoostParams.uav }, { 1, s.fastPQNits.uav }, { 2, s.aplPrev.uav },
            { 3, s.rowCount.uav }, { 4, s.rowOffset10.uav }, { 5, s.rowMaxNits.uav }, { 6, s.rowMeta.uav } },
          1, 1);

    RunCS(c, s.csBuild,
          { { 0, s.clean.srv }, { 5, s.aplPrev.srv }, { 6, s.fastPQNits.srv } },
          { { 3, s.rowCount.uav }, { 4, s.rowOffset10.uav }, { 5, s.rowMaxNits.uav }, { 6, s.rowMeta.uav } },
          TileCount(s.width), RollingRowSlots(s.height));

    RunCS(c, s.csReduce,
          { { 7, s.rowCount.srv }, { 8, s.rowOffset10.srv }, { 9, s.rowMaxNits.srv }, { 10, s.rowMeta.srv } },
          { { 0, s.globalCount.uav }, { 1, s.globalOffset10.uav }, { 2, s.globalMaxNits.uav } },
          BLOCK_W, BLOCK_H);

    RunCS(c, s.csSolve,
          { { 2, s.candidateBoostParams.srv }, { 5, s.aplPrev.srv },
            { 11, s.globalCount.srv }, { 12, s.globalOffset10.srv }, { 13, s.globalMaxNits.srv } },
          { { 0, s.aplInstant.uav }, { 1, s.apl.uav }, { 2, s.boostParams.uav } },
          1, 1);
    ClearCS(c);

    // Pass 5: fullscreen boost, clean copy -> back buffer.
    c->OMSetRenderTargets(1, &bbRTV, nullptr);
    D3D11_VIEWPORT vp = { 0.0f, 0.0f, (float)s.width, (float)s.height, 0.0f, 1.0f };
    c->RSSetViewports(1, &vp);
    c->IASetInputLayout(nullptr);
    c->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    c->VSSetShader(s.vsBoost, nullptr, 0);
    c->GSSetShader(nullptr, nullptr, 0);
    c->PSSetShader(s.psBoost, nullptr, 0);

    // No scissor, no culling, no blend, no depth, so the whole frame is replaced whatever DWM left bound.
    c->RSSetState(s.noCull);
    c->OMSetBlendState(nullptr, nullptr, 0xFFFFFFFF);
    c->OMSetDepthStencilState(nullptr, 0);
    {
        ID3D11ShaderResourceView* srv[5] = { s.clean.srv, s.apl.srv, nullptr, s.boostParams.srv, s.aplInstant.srv };
        c->PSSetShaderResources(0, 5, srv);
        c->PSSetSamplers(0, SAMPLER_SLOTS, samplers);
        c->PSSetConstantBuffers(0, 1, &s.cb);
    }
    c->Draw(3, 0);
}

bool RectInKickZone(const RECT& rc, long w, long h)
{
    const long kz = DWMBOOST_KICK_ZONE_PX;
    const bool inLeft = rc.right <= kz, inRight = rc.left >= w - kz;
    const bool inTop = rc.bottom <= kz, inBottom = rc.top >= h - kz;
    return (inLeft || inRight) && (inTop || inBottom);
}

// Feed the clean copy from this present's dirty rects, track coverage, and classify new content.
void UpdateCleanCopy(MonitorState& s, ID3D11Texture2D* backBuffer, const RECT* rects, int numRects, bool& newContent)
{
    newContent = false;
    const long w = (long)s.width, h = (long)s.height;
    for (int i = 0; i < numRects; ++i)
    {
        const RECT& rc = rects[i];
        if (!RectInKickZone(rc, w, h)) newContent = true;

        long l = rc.left > 0 ? rc.left : 0;
        long t = rc.top > 0 ? rc.top : 0;
        long r = rc.right < w ? rc.right : w;
        long b = rc.bottom < h ? rc.bottom : h;
        if (r <= l || b <= t) continue;

        D3D11_BOX box = { (UINT)l, (UINT)t, 0, (UINT)r, (UINT)b, 1 };
        s.ctx->CopySubresourceRegion(s.clean.t, 0, (UINT)l, (UINT)t, 0, backBuffer, 0, &box);
        s.cover.Mark(l, t, r, b);
    }
}

void OpenEventsLazily(MonitorState& s)
{
    if (s.settleEvt && s.contentEvt && s.primeEvt) return;
    if ((s.evtOpenTick++ % 120u) != 0u) return;
    wchar_t name[96];
    if (!s.settleEvt)
    {
        swprintf_s(name, DWMBOOST_SETTLE_FMT, g_monLeft.load(), g_monTop.load());
        s.settleEvt = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
    }
    if (!s.contentEvt)
    {
        swprintf_s(name, DWMBOOST_CONTENT_FMT, g_monLeft.load(), g_monTop.load());
        s.contentEvt = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
    }
    if (!s.primeEvt)
        s.primeEvt = OpenEventW(EVENT_MODIFY_STATE, FALSE, DWMBOOST_PRIME_NAME);
}

double MsSince(const MonitorState& s, LONGLONG qpc)
{
    if (!qpc || s.freq.QuadPart == 0) return 1e9;
    LARGE_INTEGER now; QueryPerformanceCounter(&now);
    return (double)(now.QuadPart - qpc) * 1000.0 / (double)s.freq.QuadPart;
}

// SEH-guarded vtable walk: overlaySwapChain->vt[24]() -> buffer->vt2[19]() -> QI(ID3D11Texture2D).
ID3D11Texture2D* GetBackBuffer(void* overlaySwapChain)
{
    __try
    {
        if (!overlaySwapChain) return nullptr;
        void** vt = *(void***)overlaySwapChain;
        if (!vt) return nullptr;
        typedef void* (__fastcall * Fn)(void*);
        Fn f1 = (Fn)vt[24];
        if (!f1) return nullptr;
        void* r1 = f1(overlaySwapChain);
        if (!r1) return nullptr;
        void** vt2 = *(void***)r1;
        if (!vt2) return nullptr;
        Fn f2 = (Fn)vt2[19];
        if (!f2) return nullptr;
        void* r2 = f2(r1);
        if (!r2) return nullptr;
        ID3D11Texture2D* tex = nullptr;
        if (FAILED(((IUnknown*)r2)->QueryInterface(__uuidof(ID3D11Texture2D), (void**)&tex)) || !tex)
            return nullptr;
        return tex;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return nullptr;
    }
}

struct RectVec { RECT* start; RECT* end; RECT* cap; };

__int64 __fastcall PresentDetour(void* self, void* overlaySwapChain, unsigned int a3, void* rectVecRaw,
                                 unsigned int a5, void* a6, bool a7)
{
    g_inFlight.fetch_add(1);

    if (g_enabled.load() && rectVecRaw)
    {
        RectVec* rv = (RectVec*)rectVecRaw;
        if (rv->start && rv->end >= rv->start)
        {
            ID3D11Texture2D* bb = GetBackBuffer(overlaySwapChain);
            if (bb)
            {
                D3D11_TEXTURE2D_DESC bd = {};
                bb->GetDesc(&bd);
                const UINT tw = g_monWidth.load(), th = g_monHeight.load();
                if (bd.Format == DXGI_FORMAT_R16G16B16A16_FLOAT && tw && bd.Width == tw && bd.Height == th && g_monHdr.load())
                {
                    if (!g_state.initialized || g_state.owner != self || g_state.width != bd.Width || g_state.height != bd.Height)
                        BuildState(g_state, bb, self, bd.Width, bd.Height);

                    if (g_state.initialized)
                    {
                        MonitorState& s = g_state;
                        const int numRects = (int)(rv->end - rv->start);

                        bool newContent = false;
                        UpdateCleanCopy(s, bb, rv->start, numRects, newContent);
                        if (!s.primed && s.cover.Primed()) s.primed = true;

                        LARGE_INTEGER now; QueryPerformanceCounter(&now);

                        if (s.primed)
                        {
                            ID3D11RenderTargetView* bbRTV = nullptr;
                            D3D11_RENDER_TARGET_VIEW_DESC rd = {};
                            rd.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
                            rd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
                            if (SUCCEEDED(s.dev->CreateRenderTargetView(bb, &rd, &bbRTV)))
                            {
                                const float frameTimeMs = s.lastRunQpc ? (float)MsSince(s, s.lastRunQpc) : 0.0f;
                                s.lastRunQpc = now.QuadPart;

                                if (newContent) s.runsSinceContent = 0;
                                if (s.runsSinceContent < ROLLING_PHASES && ++s.runsSinceContent == ROLLING_PHASES)
                                    s.histogramCoveredQpc = now.QuadPart;

                                StateBlock sb;
                                __try
                                {
                                    SaveState(s.ctx, sb);
                                    RunPipeline(s, bbRTV, frameTimeMs);
                                    RestoreState(s.ctx, sb);
                                }
                                __except (EXCEPTION_EXECUTE_HANDLER)
                                {
                                    ID3D11ShaderResourceView* nSrv[SRV_SLOTS] = {};
                                    ID3D11UnorderedAccessView* nUav[8] = {};
                                    s.ctx->CSSetUnorderedAccessViews(0, 8, nUav, nullptr);
                                    s.ctx->CSSetShaderResources(0, SRV_SLOTS, nSrv);
                                    s.ctx->PSSetShaderResources(0, SRV_SLOTS, nSrv);
                                    s.ctx->CSSetShader(nullptr, nullptr, 0);
                                    s.ctx->VSSetShader(nullptr, nullptr, 0);
                                    s.ctx->PSSetShader(nullptr, nullptr, 0);
                                    s.ctx->OMSetRenderTargets(0, nullptr, nullptr);
                                }
                                bbRTV->Release();
                            }
                        }
                        else
                        {
                            // Not primed: pass through unboosted and ask the host for a full recomposition.
                            if (MsSince(s, s.lastPrimeQpc) >= PRIME_MIN_GAP_MS)
                            {
                                s.lastPrimeQpc = now.QuadPart;
                                OpenEventsLazily(s);
                                if (s.primeEvt) SetEvent(s.primeEvt);
                            }
                        }

                        // Settle/content signalling: keep DWM composing this monitor while the clean copy is
                        // not primed or the gain is still settling on the latest content.
                        bool settlePending = !s.primed || s.runsSinceContent < ROLLING_PHASES ||
                                             MsSince(s, s.histogramCoveredQpc) < SMOOTHING_SETTLE_MS;
                        if (settlePending || newContent)
                        {
                            OpenEventsLazily(s);
                            if (newContent && s.contentEvt) SetEvent(s.contentEvt);
                            if (settlePending && s.settleEvt) SetEvent(s.settleEvt);
                        }
                    }
                }
                bb->Release();
            }
        }
    }

    __int64 r = g_orig ? g_orig(self, overlaySwapChain, a3, rectVecRaw, a5, a6, a7) : 0;
    g_inFlight.fetch_sub(1);
    return r;
}

} // namespace

void PresentSetOrig(Present_t orig) { g_orig = orig; }
Present_t PresentGetDetour() { return (Present_t)PresentDetour; }

void PresentSetTarget(bool enabled, int monLeft, int monTop, unsigned int monWidth, unsigned int monHeight, bool monHdr)
{
    g_monLeft.store(monLeft); g_monTop.store(monTop);
    g_monWidth.store(monWidth); g_monHeight.store(monHeight);
    g_monHdr.store(monHdr);
    g_enabled.store(enabled);
}

void PresentWaitIdle()
{
    for (int i = 0; i < 2000 && g_inFlight.load() != 0; ++i)
        Sleep(1);
}

void PresentReleaseResources()
{
    g_enabled.store(false);
    PresentWaitIdle();
    g_state.Release();
}
