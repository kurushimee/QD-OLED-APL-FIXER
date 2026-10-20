#include "present_hook.h"
#include "tile_cover.h"
#include "boost_bytecode.h"

#include <d3d11.h>
#include <dxgi.h>
#include <atomic>
#include <cstdint>
#include <cstdio>

#pragma comment(lib, "d3d11.lib")

namespace {

// Histogram geometry — must match boost.hlsl.
const UINT TILE_SIZE = 32;
const UINT BLOCK_W = 16, BLOCK_H = 16;
const UINT ROW_COUNT_W = BLOCK_W + 1;   // 17 (aux column unused here)
const UINT TILE_COUNT_X = (2560 + TILE_SIZE - 1) / TILE_SIZE;   // 80
const UINT TILE_COUNT_Y = (1440 + TILE_SIZE - 1) / TILE_SIZE;   // 45
const UINT ROLLING_PHASES = 6;
const UINT ROLLING_ROW_SLOTS = (TILE_COUNT_Y + ROLLING_PHASES - 1) / ROLLING_PHASES;  // 8
const UINT ROW_TEX_H = TILE_COUNT_Y * BLOCK_H;   // 720

const double SETTLE_HOLD_MS = 1400.0;   // ~5 smoothing time constants + the 6-phase histogram refill
const double PRIME_MIN_GAP_MS = 1000.0;

// Host config mirror (written by the watcher thread, read in the present path).
std::atomic<bool>     g_enabled{false};
std::atomic<uint32_t> g_resetGeneration{0};
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

    Tex clean;               // RGBA16F clean copy (SRV)
    Tex rowCount, rowOffset, rowMaxNits, rowMeta;        // R32_SINT (SRV+UAV)
    Tex globalCount;                                     // R32_SINT (SRV+UAV)
    Tex globalOffset, globalMaxNits;                     // R32_FLOAT (SRV+UAV)
    Tex aplSmoothed, aplInstant, aplPrev, boostParams;   // RGBA32F (SRV+UAV)

    ID3D11ComputeShader* csSetup = nullptr;
    ID3D11ComputeShader* csBuild = nullptr;
    ID3D11ComputeShader* csReduce = nullptr;
    ID3D11ComputeShader* csSolve = nullptr;
    ID3D11VertexShader* vsBoost = nullptr;
    ID3D11PixelShader* psBoost = nullptr;
    ID3D11Buffer* cb = nullptr;

    TileCover cover;
    bool primed = false;

    HANDLE settleEvt = nullptr, contentEvt = nullptr, primeEvt = nullptr;
    unsigned evtOpenTick = 0;

    LARGE_INTEGER freq = {};
    LONGLONG lastRunQpc = 0;
    LONGLONG lastContentQpc = 0;
    LONGLONG lastPrimeQpc = 0;
    uint32_t lastResetGeneration = 0;
    bool initialized = false;

    void Release()
    {
        clean.Release();
        rowCount.Release(); rowOffset.Release(); rowMaxNits.Release(); rowMeta.Release();
        globalCount.Release(); globalOffset.Release(); globalMaxNits.Release();
        aplSmoothed.Release(); aplInstant.Release(); aplPrev.Release(); boostParams.Release();
        if (csSetup) { csSetup->Release(); csSetup = nullptr; }
        if (csBuild) { csBuild->Release(); csBuild = nullptr; }
        if (csReduce) { csReduce->Release(); csReduce = nullptr; }
        if (csSolve) { csSolve->Release(); csSolve = nullptr; }
        if (vsBoost) { vsBoost->Release(); vsBoost = nullptr; }
        if (psBoost) { psBoost->Release(); psBoost = nullptr; }
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

    bool ok = true;
    ok &= CreateTex(s.dev, w, h, DXGI_FORMAT_R16G16B16A16_FLOAT, true, false, s.clean);
    ok &= CreateTex(s.dev, ROW_COUNT_W, ROW_TEX_H, DXGI_FORMAT_R32_SINT, true, true, s.rowCount);
    ok &= CreateTex(s.dev, BLOCK_W, ROW_TEX_H, DXGI_FORMAT_R32_SINT, true, true, s.rowOffset);
    ok &= CreateTex(s.dev, BLOCK_W, ROW_TEX_H, DXGI_FORMAT_R32_SINT, true, true, s.rowMaxNits);
    ok &= CreateTex(s.dev, 1, TILE_COUNT_Y, DXGI_FORMAT_R32_SINT, true, true, s.rowMeta);
    ok &= CreateTex(s.dev, ROW_COUNT_W, BLOCK_H, DXGI_FORMAT_R32_SINT, true, true, s.globalCount);
    ok &= CreateTex(s.dev, BLOCK_W, BLOCK_H, DXGI_FORMAT_R32_FLOAT, true, true, s.globalOffset);
    ok &= CreateTex(s.dev, BLOCK_W, BLOCK_H, DXGI_FORMAT_R32_FLOAT, true, true, s.globalMaxNits);
    ok &= CreateTex(s.dev, 1, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, true, true, s.aplSmoothed);
    ok &= CreateTex(s.dev, 1, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, true, true, s.aplInstant);
    ok &= CreateTex(s.dev, 1, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, true, true, s.aplPrev);
    ok &= CreateTex(s.dev, 1, 2, DXGI_FORMAT_R32G32B32A32_FLOAT, true, true, s.boostParams);

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

    if (!ok) { s.Release(); return false; }

    s.cover.Init(w, h, TILE_SIZE);
    s.primed = false;
    QueryPerformanceFrequency(&s.freq);
    s.lastRunQpc = 0; s.lastContentQpc = 0; s.lastPrimeQpc = 0;
    s.lastResetGeneration = g_resetGeneration.load();
    s.initialized = true;
    return true;
}

// -------- DWM immediate-context state save / restore --------

struct StateBlock
{
    ID3D11RenderTargetView* rtv[8] = {};
    ID3D11DepthStencilView* dsv = nullptr;
    ID3D11ComputeShader* cs = nullptr;
    ID3D11ShaderResourceView* csSrv[8] = {};
    ID3D11UnorderedAccessView* csUav[8] = {};
    ID3D11Buffer* csCb[1] = {};
    ID3D11VertexShader* vs = nullptr;
    ID3D11PixelShader* ps = nullptr;
    ID3D11ShaderResourceView* psSrv[8] = {};
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
    c->CSGetShaderResources(0, 8, b.csSrv);
    c->CSGetUnorderedAccessViews(0, 8, b.csUav);
    c->CSGetConstantBuffers(0, 1, b.csCb);
    c->VSGetShader(&b.vs, nullptr, nullptr);
    c->PSGetShader(&b.ps, nullptr, nullptr);
    c->PSGetShaderResources(0, 8, b.psSrv);
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
    c->CSSetShaderResources(0, 8, b.csSrv);
    c->CSSetShader(b.cs, nullptr, 0);
    c->CSSetConstantBuffers(0, 1, b.csCb);
    c->CSSetUnorderedAccessViews(0, 8, b.csUav, nullptr);
    c->VSSetShader(b.vs, nullptr, 0);
    c->PSSetShader(b.ps, nullptr, 0);
    c->PSSetShaderResources(0, 8, b.psSrv);
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
    for (auto p : b.csCb) if (p) p->Release();
    if (b.vs) b.vs->Release();
    if (b.ps) b.ps->Release();
    for (auto p : b.psSrv) if (p) p->Release();
    if (b.layout) b.layout->Release();
    if (b.vb) b.vb->Release();
    if (b.ib) b.ib->Release();
}

void ClearCS(ID3D11DeviceContext* c)
{
    ID3D11ShaderResourceView* nSrv[8] = {};
    ID3D11UnorderedAccessView* nUav[8] = {};
    c->CSSetShaderResources(0, 8, nSrv);
    c->CSSetUnorderedAccessViews(0, 8, nUav, nullptr);
}

void RunPipeline(MonitorState& s, ID3D11RenderTargetView* bbRTV, float dtMs, bool resetThisRun)
{
    ID3D11DeviceContext* c = s.ctx;

    D3D11_MAPPED_SUBRESOURCE map;
    if (SUCCEEDED(c->Map(s.cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &map)))
    {
        struct CB { float frameTime; uint32_t reset; float pad0, pad1; } cb;
        cb.frameTime = dtMs; cb.reset = resetThisRun ? 1u : 0u; cb.pad0 = cb.pad1 = 0.0f;
        memcpy(map.pData, &cb, sizeof(cb));
        c->Unmap(s.cb, 0);
    }

    // Pass 1: setup / rolling-row clear.
    ClearCS(c);
    c->CSSetConstantBuffers(0, 1, &s.cb);
    {
        ID3D11ShaderResourceView* srv[2] = { s.aplInstant.srv, s.aplSmoothed.srv };
        ID3D11UnorderedAccessView* uav[5] = { s.rowCount.uav, s.rowOffset.uav, s.rowMaxNits.uav, s.rowMeta.uav, s.aplPrev.uav };
        c->CSSetShaderResources(0, 2, srv);
        c->CSSetUnorderedAccessViews(0, 5, uav, nullptr);
        c->CSSetShader(s.csSetup, nullptr, 0);
        c->Dispatch(1, 1, 1);
    }

    // Pass 2: row histogram build from the clean copy.
    ClearCS(c);
    {
        ID3D11ShaderResourceView* srv[2] = { s.clean.srv, s.aplPrev.srv };
        ID3D11UnorderedAccessView* uav[4] = { s.rowCount.uav, s.rowOffset.uav, s.rowMaxNits.uav, s.rowMeta.uav };
        c->CSSetShaderResources(0, 2, srv);
        c->CSSetUnorderedAccessViews(0, 4, uav, nullptr);
        c->CSSetShader(s.csBuild, nullptr, 0);
        c->Dispatch(TILE_COUNT_X, ROLLING_ROW_SLOTS, 1);
    }

    // Pass 3: reduce to the global histogram.
    ClearCS(c);
    {
        ID3D11ShaderResourceView* srv[4] = { s.rowCount.srv, s.rowOffset.srv, s.rowMaxNits.srv, s.rowMeta.srv };
        ID3D11UnorderedAccessView* uav[3] = { s.globalCount.uav, s.globalOffset.uav, s.globalMaxNits.uav };
        c->CSSetShaderResources(0, 4, srv);
        c->CSSetUnorderedAccessViews(0, 3, uav, nullptr);
        c->CSSetShader(s.csReduce, nullptr, 0);
        c->Dispatch(BLOCK_W, BLOCK_H, 1);
    }

    // Pass 4: solve, smooth, boost parameters.
    ClearCS(c);
    {
        ID3D11ShaderResourceView* srv[4] = { s.globalCount.srv, s.globalOffset.srv, s.globalMaxNits.srv, s.aplPrev.srv };
        ID3D11UnorderedAccessView* uav[3] = { s.aplSmoothed.uav, s.aplInstant.uav, s.boostParams.uav };
        c->CSSetShaderResources(0, 4, srv);
        c->CSSetUnorderedAccessViews(0, 3, uav, nullptr);
        c->CSSetShader(s.csSolve, nullptr, 0);
        c->Dispatch(1, 1, 1);
    }
    ClearCS(c);

    // Pass 5: fullscreen boost, clean copy -> back buffer.
    c->OMSetRenderTargets(1, &bbRTV, nullptr);
    D3D11_VIEWPORT vp = { 0.0f, 0.0f, (float)s.width, (float)s.height, 0.0f, 1.0f };
    c->RSSetViewports(1, &vp);
    c->IASetInputLayout(nullptr);
    c->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    c->VSSetShader(s.vsBoost, nullptr, 0);
    c->PSSetShader(s.psBoost, nullptr, 0);
    {
        ID3D11ShaderResourceView* srv[3] = { s.clean.srv, s.aplSmoothed.srv, s.boostParams.srv };
        c->PSSetShaderResources(0, 3, srv);
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

                        bool wasPrimed = s.cover.Primed();
                        bool newContent = false;
                        UpdateCleanCopy(s, bb, rv->start, numRects, newContent);
                        if (!s.primed && s.cover.Primed()) s.primed = true;

                        bool resetThisRun = false;
                        uint32_t gen = g_resetGeneration.load();
                        if (gen != s.lastResetGeneration) { resetThisRun = true; s.lastResetGeneration = gen; }
                        if (!wasPrimed && s.primed) resetThisRun = true;   // history restarts on a fresh clean copy

                        LARGE_INTEGER now; QueryPerformanceCounter(&now);
                        if (newContent) s.lastContentQpc = now.QuadPart;

                        if (s.primed)
                        {
                            ID3D11RenderTargetView* bbRTV = nullptr;
                            D3D11_RENDER_TARGET_VIEW_DESC rd = {};
                            rd.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
                            rd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
                            if (SUCCEEDED(s.dev->CreateRenderTargetView(bb, &rd, &bbRTV)))
                            {
                                float dtMs = (float)MsSince(s, s.lastRunQpc);
                                if (dtMs < 0.0f) dtMs = 0.0f;
                                if (dtMs > 100.0f) dtMs = 100.0f;
                                s.lastRunQpc = now.QuadPart;

                                StateBlock sb;
                                __try
                                {
                                    SaveState(s.ctx, sb);
                                    RunPipeline(s, bbRTV, dtMs, resetThisRun);
                                    RestoreState(s.ctx, sb);
                                }
                                __except (EXCEPTION_EXECUTE_HANDLER)
                                {
                                    ID3D11ShaderResourceView* nSrv[8] = {};
                                    ID3D11UnorderedAccessView* nUav[8] = {};
                                    s.ctx->CSSetUnorderedAccessViews(0, 8, nUav, nullptr);
                                    s.ctx->CSSetShaderResources(0, 8, nSrv);
                                    s.ctx->PSSetShaderResources(0, 8, nSrv);
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
                        // not primed or content changed within the settle window.
                        bool settlePending = (!s.primed) || (MsSince(s, s.lastContentQpc) < SETTLE_HOLD_MS);
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

void PresentSetTarget(bool enabled, unsigned int resetGeneration,
                      int monLeft, int monTop, unsigned int monWidth, unsigned int monHeight, bool monHdr)
{
    g_monLeft.store(monLeft); g_monTop.store(monTop);
    g_monWidth.store(monWidth); g_monHeight.store(monHeight);
    g_monHdr.store(monHdr);
    g_resetGeneration.store(resetGeneration);
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
