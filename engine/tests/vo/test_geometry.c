/*
 * Host-side tests for Lucid Engine's AVFoundation video output: host layer
 * pixel size, frame-space subtitle geometry and the composite's blend
 * rectangle (spec 2.5, 4.14.3, 4.14.7, 9.4), compiled from
 * video/out/avfoundation/geometry.c and pixels.c of the patched mpv tree.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <math.h>

#include "video/out/avfoundation/geometry.h"
#include "video/out/avfoundation/pixels.h"

#include "harness.h"

static void test_pixel_extent(void)
{
    CASE("pixel-extent");
    CHECK_EQ_I(avf_pixel_extent(390, 3), 1170);
    CHECK_EQ_I(avf_pixel_extent(844, 3), 2532);
    CHECK_EQ_I(avf_pixel_extent(1920, 1), 1920);
    CHECK_EQ_I(avf_pixel_extent(100.4, 1), 100);
    CHECK_EQ_I(avf_pixel_extent(100.5, 1), 101);
    CHECK_EQ_I(avf_pixel_extent(0, 3), 1);
    CHECK_EQ_I(avf_pixel_extent(-10, 2), 1);
    CHECK_EQ_I(avf_pixel_extent(0.1, 1), 1);
    CHECK_EQ_I(avf_pixel_extent(NAN, 2), 1);

    CASE("pixel-extent-single-rounding");
    struct avf_rng rng = { 77 };
    int wrong = 0;
    for (int i = 0; i < 200000; i++) {
        double size = avf_rng_int(&rng, 1, 3000) + avf_rng_int(&rng, 0, 1023) / 1024.0;
        double scale = 1.0 + avf_rng_unit(&rng) * 2.0;
        int want = (int)fma(size, scale, 0.5);
        if (avf_pixel_extent(size, scale) != (want < 1 ? 1 : want))
            wrong++;
    }
    CHECK(wrong == 0, "%d sizes differ from the fused rounding", wrong);

    CASE("layer-scale");
    CHECK(avf_layer_scale(3, 2) == 3, "contents scale");
    CHECK(avf_layer_scale(0, 2) == 2, "screen scale for 0");
    CHECK(avf_layer_scale(-1, 2) == 2, "screen scale for negative");
}

static void test_frame_space(void)
{
    struct avf_canvas c;

    CASE("frame-space-canvas");
    avf_frame_space_canvas(1920, 1080, 0, 0, &c);
    CHECK(c.w == 1920 && c.h == 1080, "size %dx%d", c.w, c.h);
    CHECK(c.ml == 0 && c.mt == 0 && c.mr == 0 && c.mb == 0, "margins");
    CHECK(c.src.x0 == 0 && c.src.y0 == 0 && c.src.x1 == 1920 && c.src.y1 == 1080, "src");
    CHECK(c.dst.x0 == 0 && c.dst.y0 == 0 && c.dst.x1 == 1920 && c.dst.y1 == 1080, "dst");
    CHECK(c.display_par == 1.0, "par %f", c.display_par);
    CHECK(!avf_canvas_empty(&c), "empty");

    CASE("frame-space-display-par");
    // osd_res_from_image_params(): display_par = p_h / (double)p_w.
    const int pars[][2] = { { 32, 27 }, { 8, 9 }, { 64, 45 }, { 16, 11 }, { 1, 1 },
                            { 4, 3 } };
    for (size_t i = 0; i < sizeof(pars) / sizeof(pars[0]); i++) {
        avf_frame_space_canvas(720, 576, pars[i][0], pars[i][1], &c);
        CHECK(c.display_par == pars[i][1] / (double)pars[i][0], "par %d:%d gives %.9f",
              pars[i][0], pars[i][1], c.display_par);
        CHECK(c.w == 720 && c.h == 576, "anamorphic canvas keeps the frame grid");
    }
    avf_frame_space_canvas(720, 576, 0, 27, &c);
    CHECK(c.display_par == 1.0, "missing p_w");
    avf_frame_space_canvas(720, 576, 32, 0, &c);
    CHECK(c.display_par == 1.0, "missing p_h");

    CASE("frame-space-empty");
    const int bad[][2] = { { 0, 1080 }, { 1920, 0 }, { -1, 10 }, { 10, -5 }, { 0, 0 } };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        avf_frame_space_canvas(bad[i][0], bad[i][1], 1, 1, &c);
        CHECK(avf_canvas_empty(&c), "%dx%d not empty", bad[i][0], bad[i][1]);
    }
}

// The mapping of 4.14.7, written out with floor() and ceil() on exact
// quotients (all values here are small enough for doubles to be exact).
static bool ref_rect(struct avf_irect box, struct avf_irect src, struct avf_irect dst,
                     int cw, int ch, int fw, int fh, struct avf_irect *out)
{
    int bx0 = box.x0 > dst.x0 ? box.x0 : dst.x0;
    int by0 = box.y0 > dst.y0 ? box.y0 : dst.y0;
    int bx1 = box.x1 < dst.x1 ? box.x1 : dst.x1;
    int by1 = box.y1 < dst.y1 ? box.y1 : dst.y1;
    if (bx0 < 0) bx0 = 0;
    if (by0 < 0) by0 = 0;
    if (bx1 > cw) bx1 = cw;
    if (by1 > ch) by1 = ch;
    if (bx1 <= bx0 || by1 <= by0)
        return false;
    if (src.x1 <= src.x0 || src.y1 <= src.y0 || dst.x1 <= dst.x0 || dst.y1 <= dst.y0)
        return false;
    double sw = src.x1 - src.x0, sh = src.y1 - src.y0;
    double dw = dst.x1 - dst.x0, dh = dst.y1 - dst.y0;
    int x0 = src.x0 + (int)floor((bx0 - dst.x0) * sw / dw) - 1;
    int y0 = src.y0 + (int)floor((by0 - dst.y0) * sh / dh) - 1;
    int x1 = src.x0 + (int)ceil((bx1 - dst.x0) * sw / dw) + 1;
    int y1 = src.y0 + (int)ceil((by1 - dst.y0) * sh / dh) + 1;
    int cx0 = src.x0 < 0 ? 0 : src.x0, cy0 = src.y0 < 0 ? 0 : src.y0;
    int cx1 = src.x1 > fw ? fw : src.x1, cy1 = src.y1 > fh ? fh : src.y1;
    if (cx1 <= cx0 || cy1 <= cy0)
        return false;
    if (x0 < cx0) x0 = cx0;
    if (y0 < cy0) y0 = cy0;
    if (x1 > cx1) x1 = cx1;
    if (y1 > cy1) y1 = cy1;
    if (x1 <= x0 || y1 <= y0)
        return false;
    *out = (struct avf_irect){ x0, y0, x1, y1 };
    return true;
}

static void test_blend_rect(void)
{
    struct avf_rng rng = { 4242 };

    CASE("frame-space-blend-rect");
    int checked = 0;
    for (int i = 0; i < 25000; i++) {
        int width = avf_rng_int(&rng, 8, 4000), fh = avf_rng_int(&rng, 16, 2160);
        struct avf_canvas c;
        avf_frame_space_canvas(width, fh, 1, 1, &c);
        int x0 = avf_rng_int(&rng, -50, width + 50), y0 = avf_rng_int(&rng, -50, fh + 50);
        struct avf_irect box = { x0, y0, x0 + avf_rng_int(&rng, 0, 600),
                                 y0 + avf_rng_int(&rng, 0, 300) };
        struct avf_irect r;
        bool ok = avf_blend_rect(box, c.src, c.dst, c.w, c.h, width, fh, &r);
        struct avf_irect inside = avf_irect_intersect(box, (struct avf_irect){ 0, 0, width, fh });
        if (avf_irect_empty(inside)) {
            CHECK(!ok, "box beyond the frame yielded a rectangle");
            continue;
        }
        CHECK(ok, "box inside the frame yielded nothing");
        if (!ok)
            continue;
        checked++;
        CHECK(r.x0 >= 0 && r.y0 >= 0 && r.x1 <= width && r.y1 <= fh, "outside the frame");
        CHECK(r.x0 >= inside.x0 - 1 && r.x0 <= inside.x0 && r.y0 >= inside.y0 - 1 &&
              r.y0 <= inside.y0 && r.x1 <= inside.x1 + 1 && r.x1 >= inside.x1 &&
              r.y1 <= inside.y1 + 1 && r.y1 >= inside.y1,
              "not within one pixel of the box");
    }
    CHECK(checked > 1000, "too few rectangles checked");

    CASE("blend-rect-mapping");
    for (int i = 0; i < 24000; i++) {
        int frame_w = avf_rng_int(&rng, 12, 4000), fh = avf_rng_int(&rng, 16, 2160);
        int cw = avf_rng_int(&rng, 16, 3000), ch = avf_rng_int(&rng, 16, 2000);
        struct avf_irect src = { avf_rng_int(&rng, -20, frame_w / 2), avf_rng_int(&rng, -20, fh / 2), 0, 0 };
        src.x1 = src.x0 + avf_rng_int(&rng, 0, frame_w);
        src.y1 = src.y0 + avf_rng_int(&rng, 0, fh);
        struct avf_irect dst = { avf_rng_int(&rng, -20, cw / 2), avf_rng_int(&rng, -20, ch / 2), 0, 0 };
        dst.x1 = dst.x0 + avf_rng_int(&rng, 0, cw);
        dst.y1 = dst.y0 + avf_rng_int(&rng, 0, ch);
        int bx = avf_rng_int(&rng, -40, cw), by = avf_rng_int(&rng, -40, ch);
        struct avf_irect box = { bx, by, bx + avf_rng_int(&rng, 0, cw / 2),
                                 by + avf_rng_int(&rng, 0, ch / 2) };
        struct avf_irect a, b;
        bool ra = avf_blend_rect(box, src, dst, cw, ch, frame_w, fh, &a);
        bool rb = ref_rect(box, src, dst, cw, ch, frame_w, fh, &b);
        CHECK(ra == rb, "presence differs (%d, reference %d)", ra, rb);
        if (ra && rb) {
            CHECK(a.x0 == b.x0 && a.y0 == b.y0 && a.x1 == b.x1 && a.y1 == b.y1,
                  "rect %d,%d-%d,%d, reference %d,%d-%d,%d", a.x0, a.y0, a.x1, a.y1,
                  b.x0, b.y0, b.x1, b.y1);
        }
    }

    CASE("empty-box-forms");
    struct avf_irect r;
    struct avf_irect src = { 0, 0, 100, 100 };
    CHECK(!avf_blend_rect((struct avf_irect){ 0 }, src, src, 100, 100, 100, 100, &r),
          "all-zero box");
    CHECK(!avf_blend_rect(avf_irect_empty_box(100, 100), src, src, 100, 100, 100, 100, &r),
          "canonical empty box");
    CHECK(!avf_blend_rect((struct avf_irect){ 10, 10, 5, 50 }, src, src, 100, 100, 100,
                          100, &r), "inverted box");
}

void avf_test_geometry(void)
{
    test_pixel_extent();
    test_frame_space();
    test_blend_rect();
}
