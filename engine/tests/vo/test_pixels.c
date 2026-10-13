/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the direct
 * libass and BGRA blends, the YUV subtitle composite in its pinned evaluation
 * order, and the upload copy kernels (spec 4.3, 4.14.5, 4.14.7, 9.4),
 * compiled from video/out/avfoundation/pixels.c of the patched mpv tree and
 * compared bit for bit with scalar references written from the spec.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "video/out/avfoundation/pixels.h"

#include "harness.h"

// The reference arithmetic is written out exactly; keep the compiler from
// fusing anything that is not an explicit fma().
#pragma STDC FP_CONTRACT OFF

static uint8_t *alloc_fill(struct avf_rng *rng, size_t n, int zero_pct)
{
    uint8_t *p = malloc(n);
    for (size_t i = 0; i < n; i++)
        p[i] = avf_rng_int(rng, 0, 99) < zero_pct ? 0 : (uint8_t)avf_rng_next(rng);
    return p;
}

// ---- libass and BGRA references (4.14.5) ---------------------------------------

static void ref_libass(uint8_t *dst, int stride, int w, int h, const uint8_t *mask,
                       int mstride, int x, int y, int pw, int ph, uint32_t color)
{
    unsigned r = color >> 24, g = (color >> 16) & 255, b = (color >> 8) & 255;
    unsigned a = 255 - (color & 255);
    if (a == 0)
        return;
    for (int j = 0; j < ph; j++) {
        for (int i = 0; i < pw; i++) {
            int px = x + i, py = y + j;
            if (px < 0 || py < 0 || px >= w || py >= h)
                continue;
            unsigned m = mask[j * mstride + i];
            if (m == 0)
                continue;
            uint8_t *d = dst + py * stride + px * 4;
            unsigned A = a * m, I = 65025 - A;
            unsigned nb = (m * b * a + d[0] * I + 32512) / 65025;
            unsigned ng = (m * g * a + d[1] * I + 32512) / 65025;
            unsigned nr = (m * r * a + d[2] * I + 32512) / 65025;
            unsigned na = (A * 255 + d[3] * I + 32512) / 65025;
            d[0] = nb;
            d[1] = ng;
            d[2] = nr;
            d[3] = na;
        }
    }
}

static void ref_bgra(uint8_t *dst, int stride, int w, int h, const uint8_t *src,
                     int sstride, int x, int y, int pw, int ph)
{
    for (int j = 0; j < ph; j++) {
        for (int i = 0; i < pw; i++) {
            int px = x + i, py = y + j;
            if (px < 0 || py < 0 || px >= w || py >= h)
                continue;
            const uint8_t *s = src + j * sstride + i * 4;
            uint8_t *d = dst + py * stride + px * 4;
            if (s[3] == 0)
                continue;
            if (s[3] == 255 || (d[0] == 0 && d[1] == 0 && d[2] == 0 && d[3] == 0)) {
                d[0] = s[0];
                d[1] = s[1];
                d[2] = s[2];
                d[3] = s[3];
                continue;
            }
            for (int c = 0; c < 4; c++) {
                unsigned v = s[c] + (d[c] * (255u - s[3]) + 127) / 255;
                d[c] = v > 255 ? 255 : v;
            }
        }
    }
}

static void test_direct_blends(void)
{
    struct avf_rng rng = { 31337 };
    for (int run = 0; run < 300; run++) {
        CASE(run & 1 ? "bgra-blend" : "libass-blend");
        int w = avf_rng_int(&rng, 1, 200), h = avf_rng_int(&rng, 1, 120);
        int stride = w * 4 + avf_rng_int(&rng, 0, 3) * 4;
        uint8_t *a = alloc_fill(&rng, (size_t)stride * h, 50);
        uint8_t *b = malloc((size_t)stride * h);
        memcpy(b, a, (size_t)stride * h);
        struct avf_bgra canvas = { a, stride, w, h };
        int parts = avf_rng_int(&rng, 1, 6);
        for (int k = 0; k < parts; k++) {
            int pw = avf_rng_int(&rng, 1, 80), ph = avf_rng_int(&rng, 1, 60);
            int x = avf_rng_int(&rng, -40, w + 10), y = avf_rng_int(&rng, -30, h + 10);
            if (run & 1) {
                int ps = pw * 4 + avf_rng_int(&rng, 0, 2) * 4;
                uint8_t *src = alloc_fill(&rng, (size_t)ps * ph, 30);
                // Premultiplied input: no channel above alpha, some opaque.
                for (int i = 0; i < pw * ph; i++) {
                    uint8_t *px = src + (i / pw) * ps + (i % pw) * 4;
                    if (avf_rng_int(&rng, 0, 9) == 0)
                        px[3] = 255;
                    for (int c = 0; c < 3; c++)
                        if (px[c] > px[3])
                            px[c] = px[3];
                }
                avf_blend_bgra(&canvas, src, ps, x, y, pw, ph);
                ref_bgra(b, stride, w, h, src, ps, x, y, pw, ph);
                free(src);
            } else {
                int ms = pw + avf_rng_int(&rng, 0, 7);
                uint8_t *mask = alloc_fill(&rng, (size_t)ms * ph, 30);
                uint32_t color = (uint32_t)avf_rng_next(&rng);
                if (avf_rng_int(&rng, 0, 9) == 0)
                    color |= 0xFF; // fully transparent part: skipped
                if (avf_rng_int(&rng, 0, 9) == 0)
                    color &= ~0xFFu;
                avf_blend_libass(&canvas, mask, ms, x, y, pw, ph, color);
                ref_libass(b, stride, w, h, mask, ms, x, y, pw, ph, color);
                free(mask);
            }
        }
        CHECK(memcmp(a, b, (size_t)stride * h) == 0, "blend differs from the reference");
        free(a);
        free(b);
    }

    CASE("clear-rect");
    uint8_t buf[16 * 10 * 4];
    memset(buf, 0xAB, sizeof(buf));
    struct avf_bgra c = { buf, 64, 16, 10 };
    avf_clear_bgra(&c, (struct avf_irect){ -5, 2, 4, 50 });
    for (int y = 0; y < 10; y++)
        for (int x = 0; x < 16; x++)
            for (int k = 0; k < 4; k++) {
                bool cleared = x < 4 && y >= 2;
                CHECK(buf[y * 64 + x * 4 + k] == (cleared ? 0 : 0xAB), "pixel %d,%d", x, y);
            }
}

// ---- YUV composite reference (4.14.7), in the pinned evaluation order --------------

struct yuv_frame {
    int w, h;
    bool ten, full;
    int matrix;     // 0: BT.709, 1: BT.601, 2: BT.2020
    uint8_t *luma, *chroma;
    int ls, cs;     // strides in bytes
};

static double ref_get(const uint8_t *p, bool ten)
{
    if (!ten)
        return p[0];
    uint16_t v = (uint16_t)(p[0] | p[1] << 8);
    return v >> 6;
}

static void ref_put(uint8_t *p, bool ten, double v, int max)
{
    double t = v + 0.5;
    long long i = (long long)t;
    if (i < 0)
        i = 0;
    if (i > max)
        i = max;
    if (!ten) {
        p[0] = (uint8_t)i;
    } else {
        uint16_t s = (uint16_t)(i << 6);
        p[0] = s & 255;
        p[1] = s >> 8;
    }
}

static void ref_yuv(struct yuv_frame *f, const uint8_t *sub, int sstride, int cw, int ch,
                    struct avf_irect rect, struct avf_irect src, struct avf_irect dst,
                    bool fused)
{
    double Kr = f->matrix == 2 ? 0.2627 : f->matrix == 1 ? 0.299 : 0.2126;
    double Kb = f->matrix == 2 ? 0.0593 : f->matrix == 1 ? 0.114 : 0.0722;
    double Kg = (1 - Kr) - Kb;
    double yoff, yrange, cc, crange;
    int max = f->ten ? 1023 : 255;
    if (f->ten) {
        yoff = f->full ? 0 : 64;
        yrange = f->full ? 1023 : 876;
        cc = 512;
        crange = f->full ? 1023 : 896;
    } else {
        yoff = f->full ? 0 : 16;
        yrange = f->full ? 255 : 219;
        cc = 128;
        crange = f->full ? 255 : 224;
    }
    int bps = f->ten ? 2 : 1;
    long long sw = src.x1 - src.x0, sh = src.y1 - src.y0;
    long long dw = dst.x1 - dst.x0, dh = dst.y1 - dst.y0;
    for (int y = rect.y0; y < rect.y1; y++) {
        for (int x = rect.x0; x < rect.x1; x++) {
            long long sx = dst.x0 + ((long long)(x - src.x0) * dw) / sw;
            long long sy = dst.y0 + ((long long)(y - src.y0) * dh) / sh;
            if (sx < 0) sx = 0;
            if (sx > cw - 1) sx = cw - 1;
            if (sy < 0) sy = 0;
            if (sy > ch - 1) sy = ch - 1;
            const uint8_t *s = sub + sy * sstride + sx * 4;
            double B = s[0] / 255.0, G = s[1] / 255.0, R = s[2] / 255.0, A = s[3] / 255.0;
            if (A <= 0)
                continue;
            double inv = 1 - A;
            double Y;
            uint8_t *lp = f->luma + y * f->ls + x * bps;
            double old = ref_get(lp, f->ten);
            double nl;
            if (fused) {
                double kgg = Kg * G;
                Y = fma(Kb, B, fma(Kr, R, kgg));
                double yo = yoff * A;
                nl = fma(yrange, Y, fma(old, inv, yo));
            } else {
                Y = Kr * R + Kg * G + Kb * B;
                nl = old * inv + yoff * A + yrange * Y;
            }
            ref_put(lp, f->ten, nl, max);
            if ((x % 2) || (y % 2))
                continue;
            double Cb = (B - Y) / (2 * (1 - Kb));
            double Cr = (R - Y) / (2 * (1 - Kr));
            uint8_t *cbp = f->chroma + (y / 2) * f->cs + (x / 2) * 2 * bps;
            uint8_t *crp = cbp + bps;
            double ob = ref_get(cbp, f->ten), orr = ref_get(crp, f->ten);
            double nb, nr;
            if (fused) {
                double ca = cc * A;
                nb = fma(crange, Cb, fma(ob, inv, ca));
                nr = fma(crange, Cr, fma(orr, inv, ca));
            } else {
                nb = ob * inv + cc * A + crange * Cb;
                nr = orr * inv + cc * A + crange * Cr;
            }
            ref_put(cbp, f->ten, nb, max);
            ref_put(crp, f->ten, nr, max);
        }
    }
}

static void make_frame(struct avf_rng *rng, struct yuv_frame *f)
{
    int bps = f->ten ? 2 : 1;
    f->ls = f->w * bps + avf_rng_int(rng, 0, 3) * 16;
    f->cs = ((f->w + 1) / 2) * 2 * bps + avf_rng_int(rng, 0, 3) * 16;
    int chh = (f->h + 1) / 2;
    f->luma = malloc((size_t)f->ls * f->h);
    f->chroma = malloc((size_t)f->cs * chh);
    for (int i = 0; i < f->ls * f->h; i++)
        f->luma[i] = (uint8_t)avf_rng_next(rng);
    for (int i = 0; i < f->cs * chh; i++)
        f->chroma[i] = (uint8_t)avf_rng_next(rng);
    if (f->ten) {
        // Valid 10-bit words: the low 6 bits are zero.
        for (int i = 0; i + 1 < f->ls * f->h; i += 2)
            f->luma[i] &= 0xC0;
        for (int i = 0; i + 1 < f->cs * chh; i += 2)
            f->chroma[i] &= 0xC0;
    }
}

static void copy_frame(const struct yuv_frame *a, struct yuv_frame *b)
{
    *b = *a;
    int chh = (a->h + 1) / 2;
    b->luma = malloc((size_t)a->ls * a->h);
    b->chroma = malloc((size_t)a->cs * chh);
    memcpy(b->luma, a->luma, (size_t)a->ls * a->h);
    memcpy(b->chroma, a->chroma, (size_t)a->cs * chh);
}

static bool same_frame(const struct yuv_frame *a, const struct yuv_frame *b)
{
    int chh = (a->h + 1) / 2;
    return !memcmp(a->luma, b->luma, (size_t)a->ls * a->h) &&
           !memcmp(a->chroma, b->chroma, (size_t)a->cs * chh);
}

static void free_frame(struct yuv_frame *f)
{
    free(f->luma);
    free(f->chroma);
}

static void test_yuv(void)
{
    struct avf_rng rng = { 2718281828ULL };
    long long naive_diffs = 0;
    for (int run = 0; run < 240; run++) {
        CASE("yuv-composite");
        struct yuv_frame f = {
            .w = avf_rng_int(&rng, 2, 160), .h = avf_rng_int(&rng, 2, 90),
            .ten = run & 1, .full = (run >> 1) & 1, .matrix = (run >> 2) % 3,
        };
        make_frame(&rng, &f);
        struct yuv_frame want, naive;
        copy_frame(&f, &want);
        copy_frame(&f, &naive);

        // Frame space (src = dst = frame) or a scaled mapping.
        int cw = f.w, ch = f.h;
        struct avf_irect src = { 0, 0, f.w, f.h }, dst = src;
        if (run % 5 == 4) {
            cw = avf_rng_int(&rng, 4, 300);
            ch = avf_rng_int(&rng, 4, 200);
            dst = (struct avf_irect){ avf_rng_int(&rng, 0, cw / 4), avf_rng_int(&rng, 0, ch / 4),
                                      0, 0 };
            dst.x1 = dst.x0 + avf_rng_int(&rng, 1, cw - dst.x0);
            dst.y1 = dst.y0 + avf_rng_int(&rng, 1, ch - dst.y0);
        }
        int ss = cw * 4 + 8;
        uint8_t *sub = alloc_fill(&rng, (size_t)ss * ch, 40);
        for (int i = 0; i < cw * ch; i++) {
            uint8_t *p = sub + (i / cw) * ss + (i % cw) * 4;
            if (avf_rng_int(&rng, 0, 7) == 0)
                p[3] = 255;
            for (int c = 0; c < 3; c++)
                if (p[c] > p[3])
                    p[c] = p[3];
        }
        int bx = avf_rng_int(&rng, -5, cw), by = avf_rng_int(&rng, -5, ch);
        struct avf_irect box = { bx, by, bx + avf_rng_int(&rng, 0, cw),
                                 by + avf_rng_int(&rng, 0, ch) };
        struct avf_irect rect;
        if (avf_blend_rect(box, src, dst, cw, ch, f.w, f.h, &rect)) {
            struct avf_yuv y = {
                .luma = f.luma, .luma_stride = f.ls, .chroma = f.chroma,
                .chroma_stride = f.cs, .w = f.w, .h = f.h, .ten_bit = f.ten,
                .full_range = f.full,
                .matrix = f.matrix == 2 ? AVF_MATRIX_BT2020 :
                          f.matrix == 1 ? AVF_MATRIX_BT601 : AVF_MATRIX_BT709,
            };
            struct avf_bgra canvas = { sub, ss, cw, ch };
            avf_yuv_blend(&y, &canvas, rect, src, dst);
            ref_yuv(&want, sub, ss, cw, ch, rect, src, dst, true);
            ref_yuv(&naive, sub, ss, cw, ch, rect, src, dst, false);
        }
        CHECK(same_frame(&f, &want), "composite differs from the reference "
              "(%dx%d, %s, %s range, matrix %d)", f.w, f.h, f.ten ? "10-bit" : "8-bit",
              f.full ? "full" : "video", f.matrix);
        if (!same_frame(&want, &naive))
            naive_diffs++;
        free(sub);
        free_frame(&f);
        free_frame(&want);
        free_frame(&naive);
    }
    // The fused order matters: unfused evaluation must differ somewhere, or
    // these vectors would not tell the two apart.
    CASE("yuv-composite-order-is-observable");
    CHECK(naive_diffs > 0, "no vector separates fused from unfused evaluation");

    CASE("yuv-composite-chroma-on-even-pixels");
    struct yuv_frame f = { .w = 6, .h = 4, .ten = false, .full = false, .matrix = 0 };
    make_frame(&rng, &f);
    struct yuv_frame orig;
    copy_frame(&f, &orig);
    uint8_t sub[6 * 4 * 4];
    for (int i = 0; i < 6 * 4; i++) {
        sub[i * 4 + 0] = 200;
        sub[i * 4 + 1] = 100;
        sub[i * 4 + 2] = 50;
        sub[i * 4 + 3] = 255;
    }
    struct avf_yuv y = { f.luma, f.ls, f.chroma, f.cs, f.w, f.h, false, false,
                         AVF_MATRIX_BT709 };
    struct avf_bgra canvas = { sub, 24, 6, 4 };
    // Starting on odd x and y: the chroma pair at (2, 2) is written by pixel
    // (4, 2) only; the pair at (0..1, *) and rows 1 and 3 are never touched.
    avf_yuv_blend(&y, &canvas, (struct avf_irect){ 1, 1, 5, 3 },
                  (struct avf_irect){ 0, 0, 6, 4 }, (struct avf_irect){ 0, 0, 6, 4 });
    CHECK(!memcmp(f.chroma, orig.chroma, 6), "chroma row 0 changed");
    CHECK(!memcmp(f.chroma + f.cs, orig.chroma + orig.cs, 2), "chroma pair 0 of row 1 changed");
    CHECK(memcmp(f.chroma + f.cs + 2, orig.chroma + orig.cs + 2, 2) != 0 ||
          memcmp(f.chroma + f.cs + 4, orig.chroma + orig.cs + 4, 2) != 0,
          "no chroma written");
    free_frame(&f);
    free_frame(&orig);
}

// ---- upload kernels (4.3) --------------------------------------------------------

static void test_upload_kernels(void)
{
    struct avf_rng rng = { 99 };
    for (int run = 0; run < 60; run++) {
        CASE("upload-kernels");
        int w = avf_rng_int(&rng, 1, 97), h = avf_rng_int(&rng, 1, 61);
        int cw = (w + 1) / 2, chh = (h + 1) / 2;
        int sstride = w * 2 + avf_rng_int(&rng, 0, 9) * 2;
        int dstride = w * 2 + avf_rng_int(&rng, 0, 9) * 2;
        if (run % 4 == 0)
            dstride = sstride;
        uint8_t *src = alloc_fill(&rng, (size_t)sstride * h, 0);
        uint8_t *u = alloc_fill(&rng, (size_t)sstride * chh, 0);
        uint8_t *v = alloc_fill(&rng, (size_t)sstride * chh, 0);
        uint8_t *dst = calloc((size_t)dstride * h, 1);
        uint8_t *dc = calloc((size_t)dstride * 2 * chh, 1);

        // 8-bit luma rows and U/V interleave.
        avf_copy_rows(dst, dstride, src, sstride, w, h);
        bool ok = true;
        for (int y = 0; y < h; y++)
            ok &= !memcmp(dst + y * dstride, src + y * sstride, w);
        CHECK(ok, "8-bit rows");
        avf_interleave_uv8(dc, dstride * 2, u, sstride, v, sstride, cw, chh);
        ok = true;
        for (int y = 0; y < chh; y++)
            for (int x = 0; x < cw; x++)
                ok &= dc[y * dstride * 2 + 2 * x] == u[y * sstride + x] &&
                      dc[y * dstride * 2 + 2 * x + 1] == v[y * sstride + x];
        CHECK(ok, "8-bit interleave");

        // 10- and 12-bit shifts.
        for (int shift = 4; shift <= 6; shift += 2) {
            avf_shift_rows16(dst, dstride, src, sstride, w / 2 ? w / 2 : 1, h, shift);
            ok = true;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < (w / 2 ? w / 2 : 1); x++) {
                    uint16_t s = (uint16_t)(src[y * sstride + 2 * x] |
                                            src[y * sstride + 2 * x + 1] << 8);
                    uint16_t d = (uint16_t)(dst[y * dstride + 2 * x] |
                                            dst[y * dstride + 2 * x + 1] << 8);
                    ok &= d == (uint16_t)(s << shift);
                }
            CHECK(ok, "16-bit shift %d", shift);
            int cs = cw / 2 ? cw / 2 : 1;
            avf_interleave_uv16(dc, dstride * 2, u, sstride, v, sstride, cs, chh, shift);
            ok = true;
            for (int y = 0; y < chh; y++)
                for (int x = 0; x < cs; x++) {
                    uint16_t su = (uint16_t)(u[y * sstride + 2 * x] | u[y * sstride + 2 * x + 1] << 8);
                    uint16_t sv = (uint16_t)(v[y * sstride + 2 * x] | v[y * sstride + 2 * x + 1] << 8);
                    const uint8_t *d = dc + y * dstride * 2 + 4 * x;
                    ok &= (uint16_t)(d[0] | d[1] << 8) == (uint16_t)(su << shift) &&
                          (uint16_t)(d[2] | d[3] << 8) == (uint16_t)(sv << shift);
                }
            CHECK(ok, "16-bit interleave shift %d", shift);
        }

        // Plane copy: min stride per row, or one block when equal.
        memset(dst, 0x5A, (size_t)dstride * h);
        avf_copy_plane(dst, dstride, src, sstride, h);
        ok = true;
        int n = dstride < sstride ? dstride : sstride;
        for (int y = 0; y < h; y++)
            ok &= !memcmp(dst + y * dstride, src + y * sstride, n);
        CHECK(ok, "plane copy");

        free(src);
        free(u);
        free(v);
        free(dst);
        free(dc);
    }
}

void avf_test_pixels(void)
{
    test_direct_blends();
    test_yuv();
    test_upload_kernels();
}
