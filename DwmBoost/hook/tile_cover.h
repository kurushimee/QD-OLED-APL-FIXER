// Dirty-rect coverage of the clean copy of a composed frame.
//
// DWM re-composes only its dirty rects into the back buffer; outside them the back buffer holds the
// previous frame's finished (already boosted) output. A full-frame effect whose global gain drifts
// over time cannot run on the back buffer in place, so the hook keeps a clean copy fed only from
// this present's dirty rects. The copy is trustworthy once every pixel has been refreshed from a
// composed rect since it went stale. Coverage is tracked on square tiles: a tile counts only when a
// single rect covers it completely (two rects that together cover it do not count). A tile clipped
// by the frame edge counts up to the edge.
//
// Pure bookkeeping, no D3D. Reset and Mark never allocate, so the present path stays allocation-free.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

struct TileCover
{
    std::vector<uint8_t> tiles;
    unsigned width = 0, height = 0, tile = 0;
    unsigned cols = 0, rows = 0;
    size_t left = 0;   // tiles not yet refreshed since the last Reset

    void Init(unsigned w, unsigned h, unsigned tilePx)
    {
        width = w;
        height = h;
        tile = tilePx ? tilePx : 1;
        cols = (w + tile - 1) / tile;
        rows = (h + tile - 1) / tile;
        tiles.assign((size_t)cols * rows, 0);
        left = tiles.size();
    }

    void Reset()
    {
        for (uint8_t& t : tiles) t = 0;
        left = tiles.size();
    }

    bool Primed() const { return !tiles.empty() && left == 0; }

    // Record a rect [l,r) x [t,b) already clipped to the frame. Returns how many tiles it newly
    // covered completely.
    size_t Mark(long l, long t, long r, long b)
    {
        if (left == 0 || tiles.empty()) return 0;
        if (l < 0) l = 0;
        if (t < 0) t = 0;
        if (r > (long)width) r = (long)width;
        if (b > (long)height) b = (long)height;
        if (r <= l || b <= t) return 0;

        const unsigned tx0 = ((unsigned)l + tile - 1) / tile;
        const unsigned ty0 = ((unsigned)t + tile - 1) / tile;
        const unsigned tx1 = ((unsigned)r >= width) ? cols : (unsigned)r / tile;
        const unsigned ty1 = ((unsigned)b >= height) ? rows : (unsigned)b / tile;

        size_t newly = 0;
        for (unsigned ty = ty0; ty < ty1; ++ty)
            for (unsigned tx = tx0; tx < tx1; ++tx)
            {
                uint8_t& c = tiles[(size_t)ty * cols + tx];
                if (!c) { c = 1; ++newly; }
            }
        left -= newly;
        return newly;
    }
};
