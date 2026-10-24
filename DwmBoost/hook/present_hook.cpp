#include "present_hook.h"
#include "tile_cover.h"
#include "pipeline.h"

#include <d3d11.h>
#include <dxgi.h>
#include <atomic>
#include <cstdint>
#include <cstdio>

#pragma comment(lib, "d3d11.lib")

namespace {

// Runs after a content change that keep DWM composing while the gain settles. Each solve leaves at most 0.765
// of the gain error, the steepest slope of the compensation table, so 22 take the largest possible jump under
// half a 10-bit PQ code.
const int SETTLE_RUNS = 22;
const double PRIME_MIN_GAP_MS = 1000.0;

// Host config mirror (written by the watcher thread, read in the present path).
std::atomic<bool>     g_enabled{false};
std::atomic<uint32_t> g_resetGeneration{0};
std::atomic<int>      g_monLeft{0}, g_monTop{0};
std::atomic<uint32_t> g_monWidth{0}, g_monHeight{0};
std::atomic<bool>     g_monHdr{false};
std::atomic<float>    g_monLitFraction{1.0f};

std::atomic<long>     g_inFlight{0};
Present_t             g_orig = nullptr;

struct MonitorState
{
    ID3D11Device* dev = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    void* owner = nullptr;
    UINT width = 0, height = 0;

    BoostPipeline pipe;      // its clean copy is fed from the dirty rects
    TileCover cover;
    bool primed = false;

    HANDLE settleEvt = nullptr, contentEvt = nullptr, primeEvt = nullptr;
    unsigned evtOpenTick = 0;

    LARGE_INTEGER freq = {};
    LONGLONG lastPrimeQpc = 0;
    int runsSinceContent = 0;
    uint32_t lastResetGeneration = 0;
    bool initialized = false;

    void Release()
    {
        pipe.Release();
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

    if (!s.pipe.Create(s.dev, w, h)) { s.Release(); return false; }

    s.cover.Init(w, h, TILE_SIZE);
    s.primed = false;
    QueryPerformanceFrequency(&s.freq);
    s.lastPrimeQpc = 0;
    s.runsSinceContent = 0;
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
    ID3D11GeometryShader* gs = nullptr;
    ID3D11PixelShader* ps = nullptr;
    ID3D11RasterizerState* rs = nullptr;
    ID3D11BlendState* blend = nullptr; FLOAT blendFactor[4] = {}; UINT sampleMask = 0;
    ID3D11DepthStencilState* depthStencil = nullptr; UINT stencilRef = 0;
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
    c->GSGetShader(&b.gs, nullptr, nullptr);
    c->PSGetShader(&b.ps, nullptr, nullptr);
    c->PSGetShaderResources(0, 8, b.psSrv);
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
    c->CSSetShaderResources(0, 8, b.csSrv);
    c->CSSetShader(b.cs, nullptr, 0);
    c->CSSetConstantBuffers(0, 1, b.csCb);
    c->CSSetUnorderedAccessViews(0, 8, b.csUav, nullptr);
    c->VSSetShader(b.vs, nullptr, 0);
    c->GSSetShader(b.gs, nullptr, 0);
    c->PSSetShader(b.ps, nullptr, 0);
    c->PSSetShaderResources(0, 8, b.psSrv);
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
    for (auto p : b.csCb) if (p) p->Release();
    if (b.vs) b.vs->Release();
    if (b.gs) b.gs->Release();
    if (b.ps) b.ps->Release();
    if (b.rs) b.rs->Release();
    if (b.blend) b.blend->Release();
    if (b.depthStencil) b.depthStencil->Release();
    for (auto p : b.psSrv) if (p) p->Release();
    if (b.layout) b.layout->Release();
    if (b.vb) b.vb->Release();
    if (b.ib) b.ib->Release();
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
        s.ctx->CopySubresourceRegion(s.pipe.clean.t, 0, (UINT)l, (UINT)t, 0, backBuffer, 0, &box);
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

                        if (s.primed)
                        {
                            ID3D11RenderTargetView* bbRTV = nullptr;
                            D3D11_RENDER_TARGET_VIEW_DESC rd = {};
                            rd.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
                            rd.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
                            if (SUCCEEDED(s.dev->CreateRenderTargetView(bb, &rd, &bbRTV)))
                            {
                                if (s.runsSinceContent < SETTLE_RUNS) ++s.runsSinceContent;

                                StateBlock sb;
                                __try
                                {
                                    SaveState(s.ctx, sb);
                                    s.pipe.Run(s.ctx, bbRTV, resetThisRun, g_monLitFraction.load());
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
                        // not primed or the gain is still settling on the latest content.
                        if (newContent) s.runsSinceContent = 0;
                        bool settlePending = (!s.primed) || (s.runsSinceContent < SETTLE_RUNS);
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
                      int monLeft, int monTop, unsigned int monWidth, unsigned int monHeight, bool monHdr,
                      float monLitFraction)
{
    g_monLeft.store(monLeft); g_monTop.store(monTop);
    g_monWidth.store(monWidth); g_monHeight.store(monHeight);
    g_monHdr.store(monHdr);
    g_monLitFraction.store(monLitFraction);
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
