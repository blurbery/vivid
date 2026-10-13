/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the
 * vectorised pixel kernels (the direct libass and BGRA blends and the 8-,
 * 10- and 12-bit upload copies, spec 4.3 and 4.14.5) against the scalar forms
 * that define their results, bit for bit, plus timings per 4K frame. Compiled
 * from video/out/avfoundation/pixels.c of the patched mpv tree.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/qos.h>
#include <time.h>

#include "video/out/avfoundation/pixels.h"

#include "harness.h"

#define UHD_W 3840
#define UHD_H 2160
// The blends are timed on strips of the frame that stay in cache, as real
// subtitle parts do, and scaled to a whole 4K frame.
#define STRIP_H 72

static uint8_t *random_bytes(struct avf_rng *rng, size_t n)
{
    uint8_t *p = malloc(n);
    for (size_t i = 0; i < n; i++)
        p[i] = (uint8_t)avf_rng_next(rng);
    return p;
}

// Mask or alpha values the blends treat specially (0 and 255) mixed with
// arbitrary ones, in runs, so whole 16-pixel blocks of each kind occur.
static uint8_t pick(struct avf_rng *rng, int *run_left, uint8_t *run_value)
{
    if (*run_left <= 0) {
        *run_left = avf_rng_int(rng, 1, 40);
        int kind = avf_rng_int(rng, 0, 3);
        *run_value = kind == 0 ? 0 : kind == 1 ? 255 : kind == 2 ? 1 : 2;
    }
    (*run_left)--;
    if (*run_value == 1)
        return (uint8_t)avf_rng_next(rng);  // arbitrary values
    if (*run_value == 2)
        return (uint8_t)avf_rng_int(rng, 0, 3) ? (uint8_t)avf_rng_next(rng) : 0;
    return *run_value;
}

static void premultiply(uint8_t *px)
{
    for (int c = 0; c < 3; c++)
        if (px[c] > px[3])
            px[c] = px[3];
}

// ---- bit-identity -------------------------------------------------------------

static void test_libass_identity(void)
{
    struct avf_rng rng = { 0xC0FFEE };
    for (int run = 0; run < 400; run++) {
        CASE("libass-vector-matches-scalar");
        int w = avf_rng_int(&rng, 1, 260), h = avf_rng_int(&rng, 1, 40);
        int stride = w * 4 + avf_rng_int(&rng, 0, 5) * 4;
        uint8_t *a = random_bytes(&rng, (size_t)stride * h);
        for (int i = 0; i < stride * h; i += 4) {
            if (avf_rng_int(&rng, 0, 2) == 0)
                memset(a + i, 0, 4);
        }
        uint8_t *b = malloc((size_t)stride * h);
        memcpy(b, a, (size_t)stride * h);
        struct avf_bgra ca = { a, stride, w, h }, cb = { b, stride, w, h };
        int parts = avf_rng_int(&rng, 1, 5);
        for (int k = 0; k < parts; k++) {
            int pw = avf_rng_int(&rng, 1, 200), ph = avf_rng_int(&rng, 1, 30);
            int x = avf_rng_int(&rng, -50, w), y = avf_rng_int(&rng, -10, h);
            int ms = pw + avf_rng_int(&rng, 0, 17);
            uint8_t *mask = malloc((size_t)ms * ph);
            int left = 0;
            uint8_t value = 0;
            for (int i = 0; i < ms * ph; i++)
                mask[i] = pick(&rng, &left, &value);
            uint32_t color = (uint32_t)avf_rng_next(&rng);
            int alpha_kind = avf_rng_int(&rng, 0, 3);
            if (alpha_kind == 0)
                color &= ~0xFFu;            // opaque: a = 255
            else if (alpha_kind == 1)
                color |= 0xFF;              // transparent: skipped
            avf_blend_libass(&ca, mask, ms, x, y, pw, ph, color);
            avf_blend_libass_scalar(&cb, mask, ms, x, y, pw, ph, color);
            free(mask);
        }
        CHECK(!memcmp(a, b, (size_t)stride * h), "libass blend differs (%dx%d)", w, h);
        free(a);
        free(b);
    }

    // Every mask value over every destination value, for every opacity, with
    // a different colour each time: the division is checked over its whole
    // input range.
    CASE("libass-vector-exhaustive");
    int w = 256 * 16, h = 16;           // 65536 pixels: m = x % 256, d = row-major index / 256
    uint8_t *mask = malloc((size_t)w * h);
    for (int i = 0; i < w * h; i++)
        mask[i] = (uint8_t)i;
    uint8_t *a = malloc((size_t)w * 4 * h), *b = malloc((size_t)w * 4 * h);
    struct avf_bgra ca = { a, w * 4, w, h }, cb = { b, w * 4, w, h };
    int wrong = 0;
    for (int alpha = 1; alpha <= 255; alpha++) {
        for (int i = 0; i < w * h; i++) {
            uint8_t d = (uint8_t)(i >> 8);
            uint8_t *p = a + 4 * i;
            p[0] = d;
            p[1] = (uint8_t)(255 - d);
            p[2] = (uint8_t)(d * 7);
            p[3] = (uint8_t)(d ^ 0x5A);
        }
        memcpy(b, a, (size_t)w * 4 * h);
        uint32_t color = ((uint32_t)(alpha * 37 & 255) << 24) |
                         ((uint32_t)(alpha * 91 & 255) << 16) |
                         ((uint32_t)(255 - alpha) << 8) | (uint32_t)(255 - alpha);
        avf_blend_libass(&ca, mask, w, 0, 0, w, h, color);
        avf_blend_libass_scalar(&cb, mask, w, 0, 0, w, h, color);
        if (memcmp(a, b, (size_t)w * 4 * h))
            wrong++;
    }
    CHECK(wrong == 0, "%d opacities differ", wrong);
    free(mask);
    free(a);
    free(b);
}

static void test_bgra_identity(void)
{
    struct avf_rng rng = { 0xBEEF };
    for (int run = 0; run < 400; run++) {
        CASE("bgra-vector-matches-scalar");
        int w = avf_rng_int(&rng, 1, 260), h = avf_rng_int(&rng, 1, 40);
        int stride = w * 4 + avf_rng_int(&rng, 0, 5) * 4;
        uint8_t *a = random_bytes(&rng, (size_t)stride * h);
        for (int i = 0; i < stride * h; i += 4) {
            if (avf_rng_int(&rng, 0, 2) == 0)
                memset(a + i, 0, 4);
        }
        uint8_t *b = malloc((size_t)stride * h);
        memcpy(b, a, (size_t)stride * h);
        struct avf_bgra ca = { a, stride, w, h }, cb = { b, stride, w, h };
        int parts = avf_rng_int(&rng, 1, 5);
        for (int k = 0; k < parts; k++) {
            int pw = avf_rng_int(&rng, 1, 200), ph = avf_rng_int(&rng, 1, 30);
            int x = avf_rng_int(&rng, -50, w), y = avf_rng_int(&rng, -10, h);
            int ps = pw * 4 + avf_rng_int(&rng, 0, 9) * 4;
            uint8_t *src = random_bytes(&rng, (size_t)ps * ph);
            int left = 0;
            uint8_t value = 0;
            for (int j = 0; j < ph; j++) {
                for (int i = 0; i < pw; i++) {
                    uint8_t *px = src + j * ps + i * 4;
                    px[3] = pick(&rng, &left, &value);
                    // Mostly premultiplied, with some colour under zero alpha,
                    // which the blend must leave out.
                    if (avf_rng_int(&rng, 0, 7))
                        premultiply(px);
                }
            }
            avf_blend_bgra(&ca, src, ps, x, y, pw, ph);
            avf_blend_bgra_scalar(&cb, src, ps, x, y, pw, ph);
            free(src);
        }
        CHECK(!memcmp(a, b, (size_t)stride * h), "BGRA blend differs (%dx%d)", w, h);
        free(a);
        free(b);
    }

    // Every source alpha over every destination value, for several source
    // colours per alpha.
    CASE("bgra-vector-exhaustive");
    int w = 256 * 16, h = 16;
    uint8_t *src = malloc((size_t)w * 4 * h);
    uint8_t *a = malloc((size_t)w * 4 * h), *b = malloc((size_t)w * 4 * h);
    struct avf_bgra ca = { a, w * 4, w, h }, cb = { b, w * 4, w, h };
    int wrong = 0;
    for (int shade = 0; shade < 8; shade++) {
        for (int i = 0; i < w * h; i++) {
            uint8_t sa = (uint8_t)i, d = (uint8_t)(i >> 8);
            uint8_t *s = src + 4 * i;
            s[3] = sa;
            s[0] = (uint8_t)(sa * shade / 7);
            s[1] = (uint8_t)(sa * (7 - shade) / 7);
            s[2] = (uint8_t)(sa / 2);
            uint8_t *p = a + 4 * i;
            p[0] = d;
            p[1] = (uint8_t)(d * 3);
            p[2] = (uint8_t)(255 - d);
            p[3] = shade & 1 ? d : 0;   // some all-zero destinations
        }
        memcpy(b, a, (size_t)w * 4 * h);
        avf_blend_bgra(&ca, src, w * 4, 0, 0, w, h);
        avf_blend_bgra_scalar(&cb, src, w * 4, 0, 0, w, h);
        if (memcmp(a, b, (size_t)w * 4 * h))
            wrong++;
    }
    CHECK(wrong == 0, "%d source shades differ", wrong);
    free(src);
    free(a);
    free(b);
}

static void test_upload_identity(void)
{
    struct avf_rng rng = { 0xFACADE };
    for (int run = 0; run < 200; run++) {
        CASE("upload-vector-matches-scalar");
        int samples = avf_rng_int(&rng, 1, 300), rows = avf_rng_int(&rng, 1, 9);
        int shift = run & 1 ? 6 : 4;
        int ss = samples * 2 + avf_rng_int(&rng, 0, 7) * 2;
        int ds = samples * 4 + avf_rng_int(&rng, 0, 7) * 2;
        uint8_t *s1 = random_bytes(&rng, (size_t)ss * rows);
        uint8_t *s2 = random_bytes(&rng, (size_t)ss * rows);
        uint8_t *a = random_bytes(&rng, (size_t)ds * rows);
        uint8_t *b = malloc((size_t)ds * rows);
        memcpy(b, a, (size_t)ds * rows);

        avf_shift_rows16(a, ds, s1, ss, samples, rows, shift);
        avf_shift_rows16_scalar(b, ds, s1, ss, samples, rows, shift);
        CHECK(!memcmp(a, b, (size_t)ds * rows), "16-bit rows differ (shift %d)", shift);

        avf_interleave_uv16(a, ds, s1, ss, s2, ss, samples, rows, shift);
        avf_interleave_uv16_scalar(b, ds, s1, ss, s2, ss, samples, rows, shift);
        CHECK(!memcmp(a, b, (size_t)ds * rows), "16-bit interleave differs (shift %d)", shift);

        avf_interleave_uv8(a, ds, s1, ss, s2, ss, samples, rows);
        avf_interleave_uv8_scalar(b, ds, s1, ss, s2, ss, samples, rows);
        CHECK(!memcmp(a, b, (size_t)ds * rows), "8-bit interleave differs");
        free(s1);
        free(s2);
        free(a);
        free(b);
    }
}

// ---- timings ------------------------------------------------------------------

static int64_t now_ns(void)
{
    return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

struct bench {
    const char *name;
    void (*prepare)(void *ctx);         // untimed
    void (*run)(void *ctx, bool vectorised);
    void *ctx;
    double scale;                       // runs per 4K frame
};

// The best of several runs, in milliseconds per 4K frame.
static double time_ms(const struct bench *b, bool vectorised)
{
    double best = 1e30;
    for (int i = 0; i < 15; i++) {
        if (b->prepare)
            b->prepare(b->ctx);
        int64_t t0 = now_ns();
        b->run(b->ctx, vectorised);
        double ms = (now_ns() - t0) / 1e6;
        if (ms < best)
            best = ms;
    }
    return best * b->scale;
}

static void report(const struct bench *b)
{
    double scalar = time_ms(b, false), vec = time_ms(b, true);
    printf("bench %-40s %6.2f ms scalar, %5.2f ms vectorised per 4K frame (%.1fx)\n",
           b->name, scalar, vec, vec > 0 ? scalar / vec : 0.0);
}

struct blend_ctx {
    uint8_t *canvas, *work, *part;
    uint32_t color;
};

static void restore_canvas(void *p)
{
    struct blend_ctx *c = p;
    memcpy(c->work, c->canvas, (size_t)UHD_W * 4 * STRIP_H);
}

static void run_libass(void *p, bool vectorised)
{
    struct blend_ctx *c = p;
    struct avf_bgra dst = { c->work, UHD_W * 4, UHD_W, STRIP_H };
    (vectorised ? avf_blend_libass : avf_blend_libass_scalar)(
        &dst, c->part, UHD_W, 0, 0, UHD_W, STRIP_H, c->color);
}

static void run_bgra(void *p, bool vectorised)
{
    struct blend_ctx *c = p;
    struct avf_bgra dst = { c->work, UHD_W * 4, UHD_W, STRIP_H };
    (vectorised ? avf_blend_bgra : avf_blend_bgra_scalar)(
        &dst, c->part, UHD_W * 4, 0, 0, UHD_W, STRIP_H);
}

// Coverage in runs: empty gaps, anti-aliased edges and solid strokes. Short
// runs look like rasterised text; long ones like a bitmap subtitle's flat
// areas, or its empty surroundings.
static void coverage(struct avf_rng *rng, uint8_t *out, size_t n, size_t step,
                     int gap_scale, int stroke_scale)
{
    size_t i = 0;
    while (i < n) {
        int gap = avf_rng_int(rng, 6, 90) * gap_scale, edge = avf_rng_int(rng, 1, 3);
        int stroke = avf_rng_int(rng, 3, 24) * stroke_scale;
        for (int k = 0; k < gap && i < n; k++, i++)
            out[i * step] = 0;
        for (int k = 0; k < edge && i < n; k++, i++)
            out[i * step] = (uint8_t)avf_rng_int(rng, 1, 254);
        for (int k = 0; k < stroke && i < n; k++, i++)
            out[i * step] = 255;
        for (int k = 0; k < edge && i < n; k++, i++)
            out[i * step] = (uint8_t)avf_rng_int(rng, 1, 254);
    }
}

struct upload_ctx {
    uint8_t *y, *u, *v, *dy, *duv;
    int shift;
};

// One planar 4:2:0 frame of 16-bit samples into a biplanar buffer, as the
// upload of a 10- or 12-bit software frame does.
static void run_upload(void *p, bool vectorised)
{
    struct upload_ctx *c = p;
    int cw = UHD_W / 2, ch = UHD_H / 2;
    if (vectorised) {
        avf_shift_rows16(c->dy, UHD_W * 2, c->y, UHD_W * 2, UHD_W, UHD_H, c->shift);
        avf_interleave_uv16(c->duv, cw * 4, c->u, cw * 2, c->v, cw * 2, cw, ch, c->shift);
    } else {
        avf_shift_rows16_scalar(c->dy, UHD_W * 2, c->y, UHD_W * 2, UHD_W, UHD_H, c->shift);
        avf_interleave_uv16_scalar(c->duv, cw * 4, c->u, cw * 2, c->v, cw * 2, cw, ch,
                                   c->shift);
    }
}

// Timings per 4K frame (3840x2160): the blends over strips of it with one part
// covering each strip, the uploads over a whole frame. Informational: they
// print, and fail nothing.
static void test_benchmarks(void)
{
    if (getenv("LUCID_VO_NO_BENCH")) {
        printf("  (timings skipped)\n");
        return;
    }
    if (!avf_pixels_vectorised())
        printf("  (this build has no vectorised kernels: both columns are scalar)\n");
    struct avf_rng rng = { 4096 };
    const double STRIPS = (double)UHD_H / STRIP_H;
    size_t pixels = (size_t)UHD_W * STRIP_H, canvas_bytes = pixels * 4;
    struct blend_ctx bc = {
        .canvas = random_bytes(&rng, canvas_bytes),
        .work = malloc(canvas_bytes),
        .part = malloc(canvas_bytes),
    };
    for (size_t i = 0; i < canvas_bytes; i += 8)
        memset(bc.canvas + i, 0, 4);    // half the pixels empty

    coverage(&rng, bc.part, pixels, 1, 1, 1);
    bc.color = 0xF0E0D000;
    report(&(struct bench){ "libass, text, opaque colour", restore_canvas, run_libass, &bc, STRIPS });
    bc.color = 0x20304080;
    report(&(struct bench){ "libass, text, translucent colour", restore_canvas, run_libass, &bc, STRIPS });
    for (size_t i = 0; i < pixels; i++)
        bc.part[i] = (uint8_t)avf_rng_next(&rng);
    bc.color = 0xF0E0D000;
    report(&(struct bench){ "libass, dense random mask", restore_canvas, run_libass, &bc, STRIPS });

    // Premultiplied BGRA (bitmap subtitles): text-like alpha over a drawn and
    // over a cleared canvas, flat areas, then dense.
    static const struct { int gaps, strokes; const char *name; } shapes[] = {
        { 1, 1, "BGRA, text over cleared canvas" },
        { 8, 8, "BGRA, flat areas over cleared canvas" },
        { 24, 2, "BGRA, sparse bitmap over cleared canvas" },
    };
    for (int k = 0; k < 3; k++) {
        coverage(&rng, bc.part + 3, pixels, 4, shapes[k].gaps, shapes[k].strokes);
        for (size_t i = 0; i < pixels; i++) {
            uint8_t *px = bc.part + 4 * i;
            px[0] = (uint8_t)avf_rng_next(&rng);
            px[1] = (uint8_t)avf_rng_next(&rng);
            px[2] = (uint8_t)avf_rng_next(&rng);
            premultiply(px);
        }
        uint8_t *drawn = bc.canvas;
        if (k == 0) {
            report(&(struct bench){ "BGRA, text over drawn canvas", restore_canvas,
                                    run_bgra, &bc, STRIPS });
        }
        bc.canvas = calloc(canvas_bytes, 1);
        report(&(struct bench){ shapes[k].name, restore_canvas, run_bgra, &bc, STRIPS });
        free(bc.canvas);
        bc.canvas = drawn;
    }
    for (size_t i = 0; i < pixels; i++) {
        uint8_t *px = bc.part + 4 * i;
        px[3] = (uint8_t)avf_rng_next(&rng);
        premultiply(px);
    }
    report(&(struct bench){ "BGRA, dense random alpha", restore_canvas, run_bgra, &bc, STRIPS });
    free(bc.canvas);
    free(bc.work);
    free(bc.part);

    size_t luma = (size_t)UHD_W * UHD_H * 2, chroma = luma / 4;
    struct upload_ctx uc = {
        .y = random_bytes(&rng, luma), .u = random_bytes(&rng, chroma),
        .v = random_bytes(&rng, chroma), .dy = malloc(luma), .duv = malloc(chroma * 2),
    };
    uc.shift = 6;
    report(&(struct bench){ "10-bit planar upload", NULL, run_upload, &uc, 1 });
    uc.shift = 4;
    report(&(struct bench){ "12-bit planar upload", NULL, run_upload, &uc, 1 });
    free(uc.y);
    free(uc.u);
    free(uc.v);
    free(uc.dy);
    free(uc.duv);
}

void avf_test_kernels(void)
{
    test_libass_identity();
    test_bgra_identity();
    test_upload_identity();
    test_benchmarks();
}
