/*
 * Host-side tests for Lucid Engine's AVFoundation video output: subtitle
 * objects drawn together, change tracking, the CoreGraphics path, dirty
 * tracking and subtitle samples (spec 4.14.4 to 4.14.6, 7.3 item 3, 9.4),
 * compiled from video/out/avfoundation/subtitles.c of the patched mpv tree.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <stdlib.h>
#include <string.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

#include "sub/osd.h"
#include "video/out/avfoundation/frame.h"
#include "video/out/avfoundation/pixels.h"
#include "video/out/avfoundation/subtitles.h"

#include "harness.h"

#define CW 320
#define CH 180

struct object {
    struct sub_bitmaps imgs;
    struct sub_bitmap parts[8];
    uint8_t *data[8];
};

static void make_object(struct object *o, struct avf_rng *rng, int index, int fmt,
                        int nparts, bool scaled, int change_id)
{
    memset(o, 0, sizeof(*o));
    o->imgs.render_index = index;
    o->imgs.format = fmt;
    o->imgs.parts = o->parts;
    o->imgs.num_parts = nparts;
    o->imgs.change_id = change_id;
    for (int i = 0; i < nparts; i++) {
        struct sub_bitmap *p = &o->parts[i];
        p->w = avf_rng_int(rng, 4, 90);
        p->h = avf_rng_int(rng, 4, 40);
        p->x = avf_rng_int(rng, -10, CW - 20);
        p->y = avf_rng_int(rng, -10, CH - 10);
        p->dw = scaled ? p->w * 3 / 2 : p->w;
        p->dh = scaled ? p->h * 2 : p->h;
        int bpp = fmt == SUBBITMAP_BGRA ? 4 : 1;
        p->stride = p->w * bpp + avf_rng_int(rng, 0, 3) * 4;
        o->data[i] = malloc((size_t)p->stride * p->h);
        for (int k = 0; k < p->stride * p->h; k++)
            o->data[i][k] = (uint8_t)avf_rng_next(rng);
        if (fmt == SUBBITMAP_BGRA) {
            for (int y = 0; y < p->h; y++)
                for (int x = 0; x < p->w; x++) {
                    uint8_t *px = o->data[i] + y * p->stride + x * 4;
                    for (int c = 0; c < 3; c++)
                        if (px[c] > px[3])
                            px[c] = px[3];
                }
        }
        p->bitmap = o->data[i];
        p->libass.color = (uint32_t)avf_rng_next(rng) & 0xFFFFFF7Fu;
    }
}

static void free_object(struct object *o)
{
    for (int i = 0; i < 8; i++)
        free(o->data[i]);
}

static struct sub_bitmap_list make_list(struct sub_bitmaps **items, int n)
{
    return (struct sub_bitmap_list){ .change_id = 1, .w = CW, .h = CH, .items = items,
                                     .num_items = n };
}

static int imin(int a, int b) { return a < b ? a : b; }
static int imax(int a, int b) { return a > b ? a : b; }
static int iclamp(int v, int hi) { return v < 0 ? 0 : (v > hi ? hi : v); }

// The bounding box of 4.14.5: the union of every drawn part's destination
// rectangle (a dw or dh of 0 or below counting as w or h), from the empty form
// (CW, CH, 0, 0), with each edge then clamped to the canvas on its own.
static void box_add(struct avf_irect *box, const struct sub_bitmap *p)
{
    if (!p->bitmap || p->w <= 0 || p->h <= 0)
        return;
    box->x0 = imin(box->x0, p->x);
    box->y0 = imin(box->y0, p->y);
    box->x1 = imax(box->x1, p->x + (p->dw > 0 ? p->dw : p->w));
    box->y1 = imax(box->y1, p->y + (p->dh > 0 ? p->dh : p->h));
}

static struct avf_irect box_clamped(struct avf_irect b)
{
    return (struct avf_irect){ iclamp(b.x0, CW), iclamp(b.y0, CH), iclamp(b.x1, CW),
                               iclamp(b.y1, CH) };
}

// Reference canvas: every object drawn in order with the direct blends
// (each blend is checked bit for bit in the pixels suite).
static uint8_t *reference_direct(struct object **objs, int n, struct avf_irect *box)
{
    uint8_t *buf = calloc((size_t)CW * CH * 4, 1);
    struct avf_bgra c = { buf, CW * 4, CW, CH };
    struct avf_irect raw = avf_irect_empty_box(CW, CH);
    for (int k = 0; k < n; k++) {
        struct sub_bitmaps *imgs = &objs[k]->imgs;
        for (int i = 0; i < imgs->num_parts; i++) {
            struct sub_bitmap *p = &imgs->parts[i];
            if (!p->bitmap || p->w <= 0 || p->h <= 0)
                continue;               // skipped on both paths
            if (imgs->format == SUBBITMAP_LIBASS)
                avf_blend_libass(&c, p->bitmap, p->stride, p->x, p->y, p->w, p->h,
                                 p->libass.color);
            else
                avf_blend_bgra(&c, p->bitmap, p->stride, p->x, p->y, p->w, p->h);
            box_add(&raw, p);
        }
    }
    *box = box_clamped(raw);
    return buf;
}

// Reference canvas through CoreGraphics itself, with the settings of 4.14.5.
static uint8_t *reference_cg(struct object **objs, int n)
{
    uint8_t *buf = calloc((size_t)CW * CH * 4, 1);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, CW, CH, 8, CW * 4, rgb,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    for (int k = 0; k < n; k++) {
        struct sub_bitmaps *imgs = &objs[k]->imgs;
        for (int i = 0; i < imgs->num_parts; i++) {
            struct sub_bitmap *p = &imgs->parts[i];
            if (!p->bitmap || p->w <= 0 || p->h <= 0)
                continue;
            CGRect rect = CGRectMake(p->x, CH - p->y - p->dh, p->dw, p->dh);
            size_t bpp = imgs->format == SUBBITMAP_BGRA ? 4 : 1;
            CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, p->bitmap,
                (size_t)(p->h - 1) * p->stride + p->w * bpp, NULL);
            if (imgs->format == SUBBITMAP_BGRA) {
                CGImageRef img = CGImageCreate(p->w, p->h, 8, 32, p->stride, rgb,
                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, prov,
                    NULL, false, kCGRenderingIntentDefault);
                CGContextDrawImage(ctx, rect, img);
                CGImageRelease(img);
            } else {
                const CGFloat decode[] = { 1, 0 };
                CGImageRef mask = CGImageMaskCreate(p->w, p->h, 8, 8, p->stride, prov,
                                                    decode, false);
                uint32_t c = p->libass.color;
                CGContextSaveGState(ctx);
                CGContextClipToMask(ctx, rect, mask);
                CGContextSetRGBFillColor(ctx, (c >> 24) / 255.0, ((c >> 16) & 255) / 255.0,
                                         ((c >> 8) & 255) / 255.0, 1.0 - (c & 255) / 255.0);
                CGContextFillRect(ctx, rect);
                CGContextRestoreGState(ctx);
                CGImageRelease(mask);
            }
            CGDataProviderRelease(prov);
        }
    }
    CGContextRelease(ctx);
    CGColorSpaceRelease(rgb);
    return buf;
}

static bool canvas_equals(CVPixelBufferRef buf, const uint8_t *want)
{
    if (!buf || CVPixelBufferGetWidth(buf) != CW || CVPixelBufferGetHeight(buf) != CH)
        return false;
    CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    const uint8_t *d = CVPixelBufferGetBaseAddress(buf);
    size_t stride = CVPixelBufferGetBytesPerRow(buf);
    bool same = true;
    for (int y = 0; y < CH; y++)
        same &= !memcmp(d + y * stride, want + y * CW * 4, CW * 4);
    CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
    return same;
}

static CVPixelBufferRef cached_buffer(struct avf_subs *s)
{
    struct avf_overlay ov = {0};
    avf_subs_overlay(s, &ov);
    return ov.bgra;
}

static void test_several_objects(void)
{
    struct avf_rng rng = { 1001 };
    for (int run = 0; run < 40; run++) {
        CASE("several-objects");
        struct avf_subs *s = avf_subs_create(NULL);
        struct object a, b;
        int fa = run % 3 == 2 ? SUBBITMAP_BGRA : SUBBITMAP_LIBASS;
        int fb = run % 4 == 3 ? SUBBITMAP_BGRA : SUBBITMAP_LIBASS;
        make_object(&a, &rng, 0, fa, avf_rng_int(&rng, 1, 5), false, 10);
        make_object(&b, &rng, 1, fb, avf_rng_int(&rng, 1, 5), false, 20);

        // Both objects: one canvas, the second over the first, one box.
        struct sub_bitmaps *items[2] = { &a.imgs, &b.imgs };
        struct sub_bitmap_list list = make_list(items, 2);
        avf_subs_render(s, &list, CW, CH, false);
        struct object *both[2] = { &a, &b };
        struct avf_irect want_box;
        uint8_t *want = reference_direct(both, 2, &want_box);
        CHECK(canvas_equals(cached_buffer(s), want), "both objects: canvas differs");
        struct avf_irect box = avf_subs_bbox(s);
        CHECK(box.x0 == want_box.x0 && box.y0 == want_box.y0 && box.x1 == want_box.x1 &&
              box.y1 == want_box.y1, "union box %d,%d-%d,%d, expected %d,%d-%d,%d",
              box.x0, box.y0, box.x1, box.y1, want_box.x0, want_box.y0, want_box.x1,
              want_box.y1);
        CHECK(avf_subs_present(s) && avf_subs_pending(s), "not present and pending");
        free(want);

        // Unchanged pair: not rendered again.
        CVPixelBufferRef first = cached_buffer(s);
        unsigned renders = avf_subs_perf(s)->renders;
        avf_subs_sample_enqueued(s);
        avf_subs_render(s, &list, CW, CH, false);
        CHECK(cached_buffer(s) == first && avf_subs_perf(s)->renders == renders,
              "an unchanged pair was rendered again");
        CHECK(!avf_subs_pending(s), "an unchanged pair made a new sample");

        // A change to either one renders again.
        b.imgs.change_id = 21;
        avf_subs_render(s, &list, CW, CH, false);
        CHECK(avf_subs_perf(s)->renders == renders + 1, "secondary change not rendered");
        a.imgs.change_id = 11;
        avf_subs_render(s, &list, CW, CH, false);
        CHECK(avf_subs_perf(s)->renders == renders + 2, "primary change not rendered");

        // The same objects in another order are a change.
        struct sub_bitmaps *swapped[2] = { &b.imgs, &a.imgs };
        struct sub_bitmap_list list2 = make_list(swapped, 2);
        avf_subs_render(s, &list2, CW, CH, false);
        CHECK(avf_subs_perf(s)->renders == renders + 3, "reordered objects not rendered");

        // change_id 0 never counts as a match.
        a.imgs.change_id = b.imgs.change_id = 0;
        avf_subs_render(s, &list, CW, CH, false);
        avf_subs_render(s, &list, CW, CH, false);
        CHECK(avf_subs_perf(s)->renders == renders + 5, "change id 0 matched");

        // One object alone gives exactly the single-object result.
        struct sub_bitmaps *one[1] = { &a.imgs };
        struct sub_bitmap_list list1 = make_list(one, 1);
        avf_subs_render(s, &list1, CW, CH, false);
        struct object *alone[1] = { &a };
        want = reference_direct(alone, 1, &want_box);
        CHECK(canvas_equals(cached_buffer(s), want), "single object differs");
        free(want);

        // Nothing to draw: the cache goes and a transparent sample is due.
        struct sub_bitmap_list empty = make_list(NULL, 0);
        avf_subs_sample_enqueued(s);
        avf_subs_render(s, &empty, CW, CH, false);
        CHECK(!avf_subs_present(s) && !cached_buffer(s), "cache kept");
        CHECK(avf_subs_pending(s), "no transparent sample pending");
        CMSampleBufferRef sample = avf_subs_sample(s, CW, CH, 4242);
        CHECK(sample, "no transparent sample");
        if (sample) {
            CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sample);
            uint8_t *zero = calloc((size_t)CW * CH * 4, 1);
            CHECK(canvas_equals(px, zero), "transparent sample is not clear");
            free(zero);
            CFRelease(sample);
        }

        free_object(&a);
        free_object(&b);
        avf_subs_destroy(s);
    }
}

static void test_cg_path(void)
{
    struct avf_rng rng = { 2002 };
    for (int run = 0; run < 30; run++) {
        CASE("coregraphics-path");
        struct avf_subs *s = avf_subs_create(NULL);
        struct object a;
        make_object(&a, &rng, 0, run & 1 ? SUBBITMAP_BGRA : SUBBITMAP_LIBASS,
                    avf_rng_int(&rng, 1, 4), true, 7);
        struct sub_bitmaps *items[1] = { &a.imgs };
        struct sub_bitmap_list list = make_list(items, 1);
        avf_subs_render(s, &list, CW, CH, false);
        struct object *objs[1] = { &a };
        uint8_t *want = reference_cg(objs, 1);
        CHECK(canvas_equals(cached_buffer(s), want), "CoreGraphics path differs from "
              "CoreGraphics drawing the same parts");
        free(want);
        free_object(&a);
        avf_subs_destroy(s);
    }

    CASE("mixed-paths-in-order");
    struct avf_subs *s = avf_subs_create(NULL);
    struct object a, b;
    make_object(&a, &rng, 0, SUBBITMAP_LIBASS, 3, false, 1);
    make_object(&b, &rng, 1, SUBBITMAP_BGRA, 2, true, 2);
    struct sub_bitmaps *items[2] = { &a.imgs, &b.imgs };
    struct sub_bitmap_list list = make_list(items, 2);
    avf_subs_render(s, &list, CW, CH, true);
    struct avf_overlay ov = {0};
    avf_subs_overlay(s, &ov);
    CHECK(ov.bgra && ov.image, "compositing needs the buffer and the image");
    CHECK(ov.image && CGImageGetWidth(ov.image) == CW && CGImageGetHeight(ov.image) == CH,
          "image size");
    // Direct object first, then the scaled object through CoreGraphics on top.
    struct object *first[1] = { &a };
    struct avf_irect box;
    uint8_t *want = reference_direct(first, 1, &box);
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(want, CW, CH, 8, CW * 4, rgb,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    for (int i = 0; i < b.imgs.num_parts; i++) {
        struct sub_bitmap *p = &b.parts[i];
        CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, p->bitmap,
            (size_t)(p->h - 1) * p->stride + p->w * 4, NULL);
        CGImageRef img = CGImageCreate(p->w, p->h, 8, 32, p->stride, rgb,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, prov, NULL,
            false, kCGRenderingIntentDefault);
        CGContextDrawImage(ctx, CGRectMake(p->x, CH - p->y - p->dh, p->dw, p->dh), img);
        CGImageRelease(img);
        CGDataProviderRelease(prov);
    }
    CGContextRelease(ctx);
    CGColorSpaceRelease(rgb);
    CHECK(canvas_equals(ov.bgra, want), "mixed paths differ");
    free(want);
    free_object(&a);
    free_object(&b);
    avf_subs_destroy(s);
}

static void test_dirty_tracking(void)
{
    // Many renders through a recycling pool: every canvas must equal a fresh
    // rendering, so nothing stale survives the partial clears.
    CASE("dirty-tracking");
    struct avf_rng rng = { 3003 };
    struct avf_subs *s = avf_subs_create(NULL);
    int bad = 0;
    for (int run = 0; run < 120; run++) {
        struct object a;
        make_object(&a, &rng, 0, SUBBITMAP_LIBASS, avf_rng_int(&rng, 1, 6), false, run + 1);
        struct sub_bitmaps *items[1] = { &a.imgs };
        struct sub_bitmap_list list = make_list(items, 1);
        avf_subs_render(s, &list, CW, CH, false);
        struct object *objs[1] = { &a };
        struct avf_irect box;
        uint8_t *want = reference_direct(objs, 1, &box);
        if (!canvas_equals(cached_buffer(s), want))
            bad++;
        // Sometimes the cue ends, so the transparent path recycles buffers too.
        if (run % 7 == 3) {
            struct sub_bitmap_list empty = make_list(NULL, 0);
            avf_subs_render(s, &empty, CW, CH, false);
            CMSampleBufferRef sample = avf_subs_sample(s, CW, CH, run);
            if (sample) {
                uint8_t *zero = calloc((size_t)CW * CH * 4, 1);
                if (!canvas_equals(CMSampleBufferGetImageBuffer(sample), zero))
                    bad++;
                free(zero);
                CFRelease(sample);
            }
            avf_subs_sample_enqueued(s);
        }
        if (run % 30 == 29)
            avf_subs_maintain(s);
        free(want);
        free_object(&a);
    }
    CHECK(bad == 0, "%d canvases kept stale pixels", bad);
    avf_subs_destroy(s);
}

static void test_samples_and_clearing(void)
{
    CASE("subtitle-sample");
    struct avf_rng rng = { 4004 };
    struct avf_subs *s = avf_subs_create(NULL);
    struct object a;
    make_object(&a, &rng, 0, SUBBITMAP_LIBASS, 2, false, 5);
    struct sub_bitmaps *items[1] = { &a.imgs };
    struct sub_bitmap_list list = make_list(items, 1);
    avf_subs_render(s, &list, CW, CH, false);
    CMSampleBufferRef sample = avf_subs_sample(s, CW, CH, 987654321);
    CHECK(sample, "no sample");
    if (sample) {
        CMTime t = CMSampleBufferGetPresentationTimeStamp(sample);
        CHECK(t.value == 987654321 && t.timescale == 1000000000, "pts");
        CVPixelBufferRef px = CMSampleBufferGetImageBuffer(sample);
        CHECK(px == cached_buffer(s), "not the cached canvas");
        CHECK(CVPixelBufferGetPixelFormatType(px) == kCVPixelFormatType_32BGRA, "format");
        // Nothing beyond what CoreVideo gives every new buffer of this kind.
        CVPixelBufferRef plain = NULL;
        CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *keys[] = { kCVPixelBufferIOSurfacePropertiesKey };
        const void *vals[] = { empty };
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CVPixelBufferCreate(NULL, CW, CH, kCVPixelFormatType_32BGRA, attrs, &plain);
        const CVAttachmentMode modes[] = { kCVAttachmentMode_ShouldPropagate,
                                           kCVAttachmentMode_ShouldNotPropagate };
        for (int m = 0; m < 2; m++) {
            CFDictionaryRef got = avf_copy_attachments(px, modes[m]);
            CFDictionaryRef base = avf_copy_attachments(plain, modes[m]);
            bool g0 = !got || !CFDictionaryGetCount(got);
            bool b0 = !base || !CFDictionaryGetCount(base);
            CHECK(g0 == b0 && (g0 || CFEqual(got, base)), "subtitle buffer has attachments");
            if (got) CFRelease(got);
            if (base) CFRelease(base);
        }
        CVPixelBufferRelease(plain);
        CFRelease(attrs);
        CFRelease(empty);
        CFStringRef colour_keys[] = { kCVImageBufferCGColorSpaceKey,
            kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey, kCVImageBufferPixelAspectRatioKey };
        for (int k = 0; k < 5; k++) {
            CFTypeRef v = avf_copy_attachment(px, colour_keys[k], NULL);
            CHECK(!v, "subtitle buffer carries a colour or aspect tag");
            if (v) CFRelease(v);
        }
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sample);
        CFDictionaryRef ext = fd ? CMFormatDescriptionGetExtensions(fd) : NULL;
        CHECK(!ext || (!CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_ColorPrimaries) &&
                       !CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_TransferFunction) &&
                       !CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_YCbCrMatrix)),
              "subtitle format description carries colour tags");
        CFRelease(sample);
    }
    avf_subs_sample_enqueued(s);
    CHECK(!avf_subs_sample(s, CW, CH, 1), "a sample without a pending change");

    CASE("clearing-the-cache");
    avf_subs_render(s, &list, CW, CH, false);
    avf_subs_clear(s);
    CHECK(!avf_subs_present(s) && !avf_subs_pending(s) && !cached_buffer(s), "cache kept");
    struct avf_irect box = avf_subs_bbox(s);
    CHECK(avf_irect_empty(box), "box kept");
    avf_subs_render(s, &list, CW, CH, false);
    CHECK(avf_subs_present(s) && avf_subs_pending(s), "not rendered after clearing");

    CASE("reset-tracking-renders-again");
    unsigned renders = avf_subs_perf(s)->renders;
    avf_subs_render(s, &list, CW, CH, false);
    CHECK(avf_subs_perf(s)->renders == renders, "rendered without a change");
    avf_subs_reset_tracking(s);
    avf_subs_render(s, &list, CW, CH, false);
    CHECK(avf_subs_perf(s)->renders == renders + 1, "tracking reset did not render");
    avf_subs_reset_after_recovery(s);
    CHECK(!avf_subs_pending(s), "pending kept after recovery");
    avf_subs_render(s, &list, CW, CH, false);
    CHECK(avf_subs_pending(s), "not enqueued again after recovery");

    CASE("composite-needs-image");
    avf_subs_clear(s);
    avf_subs_render(s, &list, CW, CH, false);   // separate layer: buffer only
    struct avf_overlay ov = {0};
    avf_subs_overlay(s, &ov);
    CHECK(ov.bgra && !ov.image, "separate layer made an image");
    renders = avf_subs_perf(s)->renders;
    avf_subs_render(s, &list, CW, CH, true);    // compositing needs the image
    avf_subs_overlay(s, &ov);
    CHECK(ov.image && avf_subs_perf(s)->renders == renders + 1, "no image for compositing");

    free_object(&a);
    avf_subs_destroy(s);
}

static bool same_box(struct avf_irect a, struct avf_irect b)
{
    return a.x0 == b.x0 && a.y0 == b.y0 && a.x1 == b.x1 && a.y1 == b.y1;
}

static void test_bounding_box(void)
{
    // Each edge is clamped on its own, so parts that lie wholly off the
    // canvas on opposite sides still span it: the composite then runs over
    // transparent pixels and leaves the frame as it was, instead of falling
    // back to Core Image.
    CASE("bounding-box-edges-clamped-separately");
    struct avf_rng rng = { 5005 };
    struct avf_subs *s = avf_subs_create(NULL);
    struct object a;
    make_object(&a, &rng, 0, SUBBITMAP_LIBASS, 2, false, 3);
    a.parts[0].x = -a.parts[0].w - 10;  // wholly left of the canvas
    a.parts[0].y = 40;
    a.parts[1].x = CW + 5;              // wholly right of it
    a.parts[1].y = 70;
    struct sub_bitmaps *items[1] = { &a.imgs };
    struct sub_bitmap_list list = make_list(items, 1);
    avf_subs_render(s, &list, CW, CH, false);
    struct avf_irect box = avf_subs_bbox(s);
    int y1 = imax(40 + a.parts[0].h, 70 + a.parts[1].h);
    CHECK(same_box(box, (struct avf_irect){ 0, 40, CW, iclamp(y1, CH) }),
          "box %d,%d-%d,%d", box.x0, box.y0, box.x1, box.y1);
    uint8_t *zero = calloc((size_t)CW * CH * 4, 1);
    CHECK(canvas_equals(cached_buffer(s), zero), "off-canvas parts drew something");
    free(zero);

    // Wholly above with another part on the canvas: the box reaches the top.
    CASE("bounding-box-part-above");
    avf_subs_clear(s);
    a.parts[0].x = 30;
    a.parts[0].y = -200;
    a.parts[1].x = 50;
    a.parts[1].y = 90;
    a.imgs.change_id = 4;
    avf_subs_render(s, &list, CW, CH, false);
    box = avf_subs_bbox(s);
    struct object *objs[1] = { &a };
    struct avf_irect want;
    free(reference_direct(objs, 1, &want));
    CHECK(box.y0 == 0 && same_box(box, want), "box %d,%d-%d,%d", box.x0, box.y0, box.x1,
          box.y1);

    // All parts off one side: empty.
    CASE("bounding-box-all-off-one-side");
    avf_subs_clear(s);
    a.parts[0].x = -500;
    a.parts[1].x = -300;
    a.imgs.change_id = 5;
    avf_subs_render(s, &list, CW, CH, false);
    CHECK(avf_irect_empty(avf_subs_bbox(s)), "box not empty");
    free_object(&a);
    avf_subs_destroy(s);
}

static void test_part_rules(void)
{
    // The choice of path ignores parts that are skipped anyway: a scaled part
    // without a bitmap leaves the object on the direct path.
    CASE("path-choice-ignores-skipped-parts");
    struct avf_rng rng = { 6006 };
    struct avf_subs *s = avf_subs_create(NULL);
    struct object a;
    make_object(&a, &rng, 0, SUBBITMAP_LIBASS, 3, false, 8);
    a.parts[2].bitmap = NULL;           // skipped...
    a.parts[2].dw = a.parts[2].w * 3;   // ...and scaled
    struct sub_bitmaps *items[1] = { &a.imgs };
    struct sub_bitmap_list list = make_list(items, 1);
    avf_subs_render(s, &list, CW, CH, false);
    struct object *objs[1] = { &a };
    struct avf_irect box;
    uint8_t *want = reference_direct(objs, 1, &box);
    CHECK(canvas_equals(cached_buffer(s), want), "not drawn on the direct path");
    free(want);
    a.parts[2].bitmap = a.data[2];
    a.parts[2].w = 0;                   // skipped for its size instead
    a.imgs.change_id = 9;
    avf_subs_render(s, &list, CW, CH, false);
    want = reference_direct(objs, 1, &box);
    CHECK(canvas_equals(cached_buffer(s), want), "a zero-width part forced CoreGraphics");
    free(want);
    free_object(&a);

    // On the CoreGraphics path each part is drawn at its own dw and dh as
    // they are: 0 draws nothing (the box still counts it at w x h).
    CASE("coregraphics-raw-size");
    make_object(&a, &rng, 0, SUBBITMAP_LIBASS, 3, true, 10);
    a.parts[1].dw = 0;
    a.parts[1].dh = 0;
    avf_subs_render(s, &list, CW, CH, false);
    want = reference_cg(objs, 1);       // CoreGraphics with the raw sizes
    CHECK(canvas_equals(cached_buffer(s), want), "a zero-size part drew something");
    free(want);
    free(reference_direct(objs, 1, &box));
    CHECK(same_box(avf_subs_bbox(s), box), "box ignores the defaulting rule");
    free_object(&a);
    avf_subs_destroy(s);
}

void avf_test_subtitles(void)
{
    test_several_objects();
    test_cg_path();
    test_dirty_tracking();
    test_samples_and_clearing();
    test_bounding_box();
    test_part_rules();
}
