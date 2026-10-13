/*
 * Host-side tests for Lucid Engine's AVFoundation video output: software
 * uploads and colour tags, pixel aspect, the Dolby Vision transfer repair,
 * samples and the Picture in Picture composites with real CoreVideo buffers
 * (spec 4.3 to 4.6, 4.14.7, 7.3, 9.4), compiled from
 * video/out/avfoundation/frame.m of the patched mpv tree.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdlib.h>
#include <string.h>

#include "video/mp_image.h"
#include "video/out/avfoundation/frame.h"
#include "video/out/avfoundation/pixels.h"

#include "harness.h"

static CVPixelBufferRef make_buffer(int w, int h, OSType fmt)
{
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef buf = NULL;
    CVPixelBufferCreate(NULL, w, h, fmt, (CFDictionaryRef)attrs, &buf);
    return buf;
}

static void fill_random(CVPixelBufferRef buf, struct avf_rng *rng, bool ten)
{
    CVPixelBufferLockBaseAddress(buf, 0);
    size_t planes = CVPixelBufferGetPlaneCount(buf);
    for (size_t n = 0; n < (planes ? planes : 1); n++) {
        uint8_t *p = planes ? CVPixelBufferGetBaseAddressOfPlane(buf, n)
                            : CVPixelBufferGetBaseAddress(buf);
        size_t stride = planes ? CVPixelBufferGetBytesPerRowOfPlane(buf, n)
                               : CVPixelBufferGetBytesPerRow(buf);
        size_t rows = planes ? CVPixelBufferGetHeightOfPlane(buf, n)
                             : CVPixelBufferGetHeight(buf);
        for (size_t i = 0; i < stride * rows; i++) {
            p[i] = (uint8_t)avf_rng_next(rng);
            if (ten && !(i & 1))
                p[i] &= 0xC0;
        }
    }
    CVPixelBufferUnlockBaseAddress(buf, 0);
}

// Compares the visible pixels of two biplanar buffers.
static bool same_pixels(CVPixelBufferRef a, CVPixelBufferRef b)
{
    if (CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(b) ||
        CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(b) ||
        CVPixelBufferGetPixelFormatType(a) != CVPixelBufferGetPixelFormatType(b))
        return false;
    bool same = true;
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    OSType f = CVPixelBufferGetPixelFormatType(a);
    int bps = (f == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
               f == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) ? 2 : 1;
    for (size_t n = 0; n < CVPixelBufferGetPlaneCount(a); n++) {
        size_t row = CVPixelBufferGetWidthOfPlane(a, n) * bps * (n ? 2 : 1);
        for (size_t y = 0; y < CVPixelBufferGetHeightOfPlane(a, n); y++) {
            const uint8_t *pa = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, n) +
                                y * CVPixelBufferGetBytesPerRowOfPlane(a, n);
            const uint8_t *pb = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, n) +
                                y * CVPixelBufferGetBytesPerRowOfPlane(b, n);
            same &= !memcmp(pa, pb, row);
        }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return same;
}

static CVPixelBufferRef clone_pixels(CVPixelBufferRef src)
{
    CVPixelBufferRef dst = make_buffer((int)CVPixelBufferGetWidth(src),
                                       (int)CVPixelBufferGetHeight(src),
                                       CVPixelBufferGetPixelFormatType(src));
    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);
    for (size_t n = 0; n < CVPixelBufferGetPlaneCount(src); n++) {
        avf_copy_plane(CVPixelBufferGetBaseAddressOfPlane(dst, n),
                       CVPixelBufferGetBytesPerRowOfPlane(dst, n),
                       CVPixelBufferGetBaseAddressOfPlane(src, n),
                       CVPixelBufferGetBytesPerRowOfPlane(src, n),
                       (int)CVPixelBufferGetHeightOfPlane(dst, n));
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return dst;
}

static CFTypeRef attachment(CVBufferRef b, CFStringRef key, CVAttachmentMode *mode)
{
    CFTypeRef v = avf_copy_attachment(b, key, mode);
    if (v)
        CFAutorelease(v);
    return v;
}

// ---- uploads -----------------------------------------------------------------------

struct sw_case {
    enum avf_sw_format fmt;
    const char *name;
    int bps;        // bytes per source sample
    bool planar;    // three planes
    int shift;
};

static void test_uploads(void)
{
    const struct sw_case cases[] = {
        { AVF_SW_NV12, "nv12", 1, false, 0 },
        { AVF_SW_420P, "yuv420p", 1, true, 0 },
        { AVF_SW_P010, "p010", 2, false, 0 },
        { AVF_SW_420P10, "yuv420p10", 2, true, 6 },
        { AVF_SW_420P12, "yuv420p12", 2, true, 4 },
    };
    struct avf_rng rng = { 5150 };
    struct avf_frame *f = avf_frame_create(NULL);
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        for (int run = 0; run < 6; run++) {
            CASE("upload");
            const struct sw_case *sc = &cases[c];
            int w = avf_rng_int(&rng, 2, 130) | (run & 1), h = avf_rng_int(&rng, 2, 70) | 1;
            int cw = (w + 1) / 2, ch = (h + 1) / 2;
            struct mp_image img = {0};
            img.w = w;
            img.h = h;
            img.params.w = w;
            img.params.h = h;
            img.params.imgfmt_name = sc->name;
            uint8_t *planes[3] = {0};
            if (sc->planar) {
                img.stride[0] = w * sc->bps + avf_rng_int(&rng, 0, 4) * 16;
                img.stride[1] = img.stride[2] = cw * sc->bps + avf_rng_int(&rng, 0, 4) * 16;
                planes[0] = malloc((size_t)img.stride[0] * h);
                planes[1] = malloc((size_t)img.stride[1] * ch);
                planes[2] = malloc((size_t)img.stride[2] * ch);
                for (int i = 0; i < img.stride[0] * h; i++)
                    planes[0][i] = (uint8_t)avf_rng_next(&rng);
                for (int p = 1; p < 3; p++)
                    for (int i = 0; i < img.stride[p] * ch; i++)
                        planes[p][i] = (uint8_t)avf_rng_next(&rng);
            } else {
                img.stride[0] = w * sc->bps + avf_rng_int(&rng, 0, 4) * 16;
                img.stride[1] = cw * 2 * sc->bps + avf_rng_int(&rng, 0, 4) * 16;
                planes[0] = malloc((size_t)img.stride[0] * h);
                planes[1] = malloc((size_t)img.stride[1] * ch);
                for (int i = 0; i < img.stride[0] * h; i++)
                    planes[0][i] = (uint8_t)avf_rng_next(&rng);
                for (int i = 0; i < img.stride[1] * ch; i++)
                    planes[1][i] = (uint8_t)avf_rng_next(&rng);
            }
            for (int p = 0; p < 3; p++)
                img.planes[p] = planes[p];

            CVPixelBufferRef buf = avf_frame_upload(f, sc->fmt, &img);
            CHECK(buf, "%s: no buffer", sc->name);
            if (!buf)
                goto next;
            OSType want = sc->bps == 1 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                       : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
            CHECK(CVPixelBufferGetPixelFormatType(buf) == want, "%s: format", sc->name);
            CHECK((int)CVPixelBufferGetWidth(buf) == w && (int)CVPixelBufferGetHeight(buf) == h,
                  "%s: size", sc->name);
            CHECK(CVPixelBufferGetIOSurface(buf) != NULL, "%s: not IOSurface-backed", sc->name);

            CVPixelBufferLockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
            const uint8_t *d0 = CVPixelBufferGetBaseAddressOfPlane(buf, 0);
            const uint8_t *d1 = CVPixelBufferGetBaseAddressOfPlane(buf, 1);
            size_t s0 = CVPixelBufferGetBytesPerRowOfPlane(buf, 0);
            size_t s1 = CVPixelBufferGetBytesPerRowOfPlane(buf, 1);
            bool ok = true;
            for (int y = 0; y < h && ok; y++) {
                for (int x = 0; x < w; x++) {
                    if (sc->bps == 1) {
                        ok &= d0[y * s0 + x] == planes[0][y * img.stride[0] + x];
                    } else {
                        uint16_t s = (uint16_t)(planes[0][y * img.stride[0] + 2 * x] |
                                                planes[0][y * img.stride[0] + 2 * x + 1] << 8);
                        uint16_t d = (uint16_t)(d0[y * s0 + 2 * x] | d0[y * s0 + 2 * x + 1] << 8);
                        ok &= d == (uint16_t)(s << sc->shift);
                    }
                }
            }
            CHECK(ok, "%s: luma", sc->name);
            ok = true;
            for (int y = 0; y < ch && ok; y++) {
                for (int x = 0; x < cw; x++) {
                    for (int k = 0; k < 2; k++) {
                        uint16_t s, d;
                        if (sc->planar) {
                            const uint8_t *sp = planes[1 + k] + y * img.stride[1 + k];
                            s = sc->bps == 1 ? sp[x] : (uint16_t)(sp[2 * x] | sp[2 * x + 1] << 8);
                        } else {
                            const uint8_t *sp = planes[1] + y * img.stride[1];
                            s = sc->bps == 1 ? sp[2 * x + k]
                                             : (uint16_t)(sp[4 * x + 2 * k] | sp[4 * x + 2 * k + 1] << 8);
                        }
                        const uint8_t *dp = d1 + y * s1;
                        d = sc->bps == 1 ? dp[2 * x + k]
                                         : (uint16_t)(dp[4 * x + 2 * k] | dp[4 * x + 2 * k + 1] << 8);
                        ok &= d == (uint16_t)(s << sc->shift);
                    }
                }
            }
            CHECK(ok, "%s: chroma", sc->name);
            CVPixelBufferUnlockBaseAddress(buf, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferRelease(buf);
        next:
            for (int p = 0; p < 3; p++)
                free(planes[p]);
        }
    }

    CASE("upload-unsupported");
    struct mp_image img = { .w = 16, .h = 16 };
    img.params.imgfmt_name = "rgb24";
    CHECK(avf_frame_upload(f, AVF_SW_NONE, &img) == NULL, "unsupported format uploaded");
    avf_frame_destroy(f);
}

// ---- colour tags ---------------------------------------------------------------------

static void test_tags(void)
{
    CASE("colour-tags");
    struct { enum pl_color_primaries v; CFStringRef want; } prims[] = {
        { PL_COLOR_PRIM_BT_709, kCVImageBufferColorPrimaries_ITU_R_709_2 },
        { PL_COLOR_PRIM_BT_2020, kCVImageBufferColorPrimaries_ITU_R_2020 },
        { PL_COLOR_PRIM_BT_601_525, NULL }, { PL_COLOR_PRIM_DCI_P3, NULL },
        { PL_COLOR_PRIM_UNKNOWN, NULL },
    };
    struct { enum pl_color_transfer v; CFStringRef want; } trcs[] = {
        { PL_COLOR_TRC_SRGB, kCVImageBufferTransferFunction_sRGB },
        { PL_COLOR_TRC_BT_1886, kCVImageBufferTransferFunction_ITU_R_709_2 },
        { PL_COLOR_TRC_PQ, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ },
        { PL_COLOR_TRC_HLG, kCVImageBufferTransferFunction_ITU_R_2100_HLG },
        { PL_COLOR_TRC_LINEAR, NULL }, { PL_COLOR_TRC_GAMMA22, NULL },
        { PL_COLOR_TRC_UNKNOWN, NULL },
    };
    struct { enum pl_color_system v; CFStringRef want; } syss[] = {
        { PL_COLOR_SYSTEM_BT_601, kCVImageBufferYCbCrMatrix_ITU_R_601_4 },
        { PL_COLOR_SYSTEM_BT_709, kCVImageBufferYCbCrMatrix_ITU_R_709_2 },
        { PL_COLOR_SYSTEM_BT_2020_NC, kCVImageBufferYCbCrMatrix_ITU_R_2020 },
        { PL_COLOR_SYSTEM_BT_2020_C, kCVImageBufferYCbCrMatrix_ITU_R_2020 },
        { PL_COLOR_SYSTEM_BT_2100_PQ, kCVImageBufferYCbCrMatrix_ITU_R_2020 },
        { PL_COLOR_SYSTEM_BT_2100_HLG, kCVImageBufferYCbCrMatrix_ITU_R_2020 },
        { PL_COLOR_SYSTEM_SMPTE_240M, NULL }, { PL_COLOR_SYSTEM_DOLBYVISION, NULL },
        { PL_COLOR_SYSTEM_UNKNOWN, NULL },
    };
    for (size_t a = 0; a < sizeof(prims) / sizeof(prims[0]); a++)
    for (size_t b = 0; b < sizeof(trcs) / sizeof(trcs[0]); b++)
    for (size_t c = 0; c < sizeof(syss) / sizeof(syss[0]); c++) {
        CVPixelBufferRef buf = make_buffer(16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        struct mp_image_params p = {0};
        p.color.primaries = prims[a].v;
        p.color.transfer = trcs[b].v;
        p.repr.sys = syss[c].v;
        avf_frame_tag_software(buf, &p);
        CVAttachmentMode m;
        CFTypeRef v = attachment(buf, kCVImageBufferColorPrimariesKey, &m);
        CHECK(prims[a].want ? (v && CFEqual(v, prims[a].want) &&
                               m == kCVAttachmentMode_ShouldPropagate) : !v,
              "primaries %d", prims[a].v);
        v = attachment(buf, kCVImageBufferTransferFunctionKey, &m);
        CHECK(trcs[b].want ? (v && CFEqual(v, trcs[b].want) &&
                              m == kCVAttachmentMode_ShouldPropagate) : !v,
              "transfer %d", trcs[b].v);
        v = attachment(buf, kCVImageBufferYCbCrMatrixKey, &m);
        CHECK(syss[c].want ? (v && CFEqual(v, syss[c].want) &&
                              m == kCVAttachmentMode_ShouldPropagate) : !v,
              "matrix %d", syss[c].v);
        bool any = prims[a].want || trcs[b].want || syss[c].want;
        v = attachment(buf, kCVImageBufferCGColorSpaceKey, &m);
        if (!any)
            CHECK(!v, "colour space without tags");
        if (any && v)
            CHECK(m == kCVAttachmentMode_ShouldPropagate, "colour space mode");
        CHECK(!attachment(buf, kCVImageBufferMasteringDisplayColorVolumeKey, NULL) &&
              !attachment(buf, kCVImageBufferContentLightLevelInfoKey, NULL) &&
              !attachment(buf, kCVImageBufferChromaLocationTopFieldKey, NULL),
              "HDR or siting metadata added");
        CVPixelBufferRelease(buf);
    }

    CASE("colour-space-for-hdr10");
    CVPixelBufferRef buf = make_buffer(16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    struct mp_image_params p = {0};
    p.color.primaries = PL_COLOR_PRIM_BT_2020;
    p.color.transfer = PL_COLOR_TRC_PQ;
    p.repr.sys = PL_COLOR_SYSTEM_BT_2020_NC;
    avf_frame_tag_software(buf, &p);
    CHECK(attachment(buf, kCVImageBufferCGColorSpaceKey, NULL) != NULL,
          "no colour space for a fully tagged frame");
    CVPixelBufferRelease(buf);

    CASE("tags-only-added");
    buf = make_buffer(16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_EBU_3213, kCVAttachmentMode_ShouldPropagate);
    p = (struct mp_image_params){0};
    p.color.transfer = PL_COLOR_TRC_BT_1886;
    avf_frame_tag_software(buf, &p);
    CFTypeRef v = attachment(buf, kCVImageBufferColorPrimariesKey, NULL);
    CHECK(v && CFEqual(v, kCVImageBufferColorPrimaries_EBU_3213), "an unmapped tag was removed");
    CVPixelBufferRelease(buf);
}

// ---- pixel aspect and Dolby Vision repair --------------------------------------------

static void test_aspect_and_repair(void)
{
    CASE("pixel-aspect");
    CVPixelBufferRef buf = make_buffer(720, 576, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    struct mp_image_params vp = { .w = 720, .h = 576, .p_w = 64, .p_h = 45 };
    avf_frame_pixel_aspect(buf, &vp);
    CVAttachmentMode m;
    CFDictionaryRef par = attachment(buf, kCVImageBufferPixelAspectRatioKey, &m);
    CHECK(par && m == kCVAttachmentMode_ShouldPropagate, "no pixel aspect");
    if (par) {
        int h = 0, v = 0;
        CFNumberGetValue(CFDictionaryGetValue(par, kCVImageBufferPixelAspectRatioHorizontalSpacingKey),
                         kCFNumberIntType, &h);
        CFNumberGetValue(CFDictionaryGetValue(par, kCVImageBufferPixelAspectRatioVerticalSpacingKey),
                         kCFNumberIntType, &v);
        CHECK(h == 64 && v == 45, "spacing %d:%d", h, v);
    }
    avf_frame_pixel_aspect(buf, NULL);
    CHECK(attachment(buf, kCVImageBufferPixelAspectRatioKey, NULL), "NULL params changed it");
    vp.p_w = vp.p_h = 1;
    avf_frame_pixel_aspect(buf, &vp);
    CHECK(!attachment(buf, kCVImageBufferPixelAspectRatioKey, NULL), "square pixels kept it");
    vp = (struct mp_image_params){ .w = 720, .h = 480, .p_w = 32, .p_h = 27 };
    avf_frame_pixel_aspect(buf, &vp);
    CHECK(!attachment(buf, kCVImageBufferPixelAspectRatioKey, NULL), "size mismatch attached it");
    vp = (struct mp_image_params){ .w = 720, .h = 576, .p_w = 0, .p_h = 27 };
    avf_frame_pixel_aspect(buf, &vp);
    CHECK(!attachment(buf, kCVImageBufferPixelAspectRatioKey, NULL), "zero p_w attached it");
    CVPixelBufferRelease(buf);

    CASE("dolby-vision-repair");
    CFDataRef rpu = CFDataCreate(NULL, (const UInt8 *)"\x7c\x01", 2);
    const CVAttachmentMode modes[] = { kCVAttachmentMode_ShouldPropagate,
                                       kCVAttachmentMode_ShouldNotPropagate };
    for (int i = 0; i < 2; i++) {
        buf = make_buffer(64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
        CVBufferSetAttachment(buf, AVF_DOLBY_VISION_RPU_KEY, rpu, modes[i]);
        struct mp_image_params ip = {0};
        ip.repr.sys = PL_COLOR_SYSTEM_DOLBYVISION;
        ip.color.transfer = PL_COLOR_TRC_PQ;
        ip.color.primaries = PL_COLOR_PRIM_BT_2020;
        CHECK(avf_frame_dolby_vision_repair(buf, &ip), "not repaired");
        CFTypeRef v = attachment(buf, kCVImageBufferTransferFunctionKey, &m);
        CHECK(v && CFEqual(v, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) &&
              m == kCVAttachmentMode_ShouldPropagate, "PQ tag");
        CHECK(!attachment(buf, kCVImageBufferColorPrimariesKey, NULL) &&
              !attachment(buf, kCVImageBufferYCbCrMatrixKey, NULL),
              "primaries or matrix touched");
        // An existing transfer is never replaced.
        CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                              kCVAttachmentMode_ShouldPropagate);
        CHECK(!avf_frame_dolby_vision_repair(buf, &ip), "repaired over a transfer");
        CVPixelBufferRelease(buf);
    }
    buf = make_buffer(64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    struct mp_image_params ip = {0};
    ip.repr.sys = PL_COLOR_SYSTEM_DOLBYVISION;
    ip.color.transfer = PL_COLOR_TRC_PQ;
    CHECK(!avf_frame_dolby_vision_repair(buf, &ip), "repaired without the RPU key");
    CVBufferSetAttachment(buf, AVF_DOLBY_VISION_RPU_KEY, rpu, kCVAttachmentMode_ShouldPropagate);
    ip.repr.sys = PL_COLOR_SYSTEM_BT_2020_NC;
    CHECK(!avf_frame_dolby_vision_repair(buf, &ip), "repaired a non Dolby Vision image");
    ip.repr.sys = PL_COLOR_SYSTEM_DOLBYVISION;
    ip.color.transfer = PL_COLOR_TRC_LINEAR;
    CHECK(!avf_frame_dolby_vision_repair(buf, &ip), "unmapped transfer set");
    CHECK(!attachment(buf, kCVImageBufferTransferFunctionKey, NULL), "transfer appeared");
    // The key must match exactly.
    CVPixelBufferRelease(buf);
    buf = make_buffer(64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    CVBufferSetAttachment(buf, CFSTR("DolbyVisionRpuData"), rpu, kCVAttachmentMode_ShouldPropagate);
    ip.color.transfer = PL_COLOR_TRC_PQ;
    CHECK(!avf_frame_dolby_vision_repair(buf, &ip), "matched a different key");
    CVPixelBufferRelease(buf);
    CFRelease(rpu);
}

// ---- samples -------------------------------------------------------------------------

static void test_samples(void)
{
    CASE("video-sample");
    struct avf_frame *f = avf_frame_create(NULL);
    CVPixelBufferRef a = make_buffer(64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CVPixelBufferRef b = make_buffer(64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CMSampleBufferRef sa = avf_frame_sample(f, a, 1234567891);
    CMSampleBufferRef sb = avf_frame_sample(f, b, -5);
    CHECK(sa && sb, "no sample");
    if (sa && sb) {
        CMTime t = CMSampleBufferGetPresentationTimeStamp(sa);
        CHECK(t.value == 1234567891 && t.timescale == 1000000000, "pts");
        CHECK(CMTIME_IS_INVALID(CMSampleBufferGetDuration(sa)), "duration set");
        CHECK(CMTIME_IS_INVALID(CMSampleBufferGetDecodeTimeStamp(sa)), "decode time set");
        CHECK(CMSampleBufferGetFormatDescription(sa) == CMSampleBufferGetFormatDescription(sb),
              "format description not reused");
        CFArrayRef sat = CMSampleBufferGetSampleAttachmentsArray(sa, false);
        bool none = !sat;
        if (sat) {
            none = true;
            for (CFIndex i = 0; i < CFArrayGetCount(sat); i++)
                none &= CFDictionaryGetCount(CFArrayGetValueAtIndex(sat, i)) == 0;
        }
        CHECK(none, "sample attachments set");
    }
    CVPixelBufferRef c = make_buffer(32, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    CMSampleBufferRef sc = avf_frame_sample(f, c, 0);
    CHECK(sc && sb && CMSampleBufferGetFormatDescription(sc) != CMSampleBufferGetFormatDescription(sb),
          "format description not replaced for a new size");
    if (sa) CFRelease(sa);
    if (sb) CFRelease(sb);
    if (sc) CFRelease(sc);
    CVPixelBufferRelease(a);
    CVPixelBufferRelease(b);
    CVPixelBufferRelease(c);
    avf_frame_destroy(f);
}

// ---- composites ------------------------------------------------------------------------

// A subtitle canvas with one opaque-edged cue box at (x, y).
static CVPixelBufferRef make_cue(int cw, int ch, int x, int y, int w, int h, uint8_t shade,
                                 struct avf_irect *bbox)
{
    CVPixelBufferRef s = make_buffer(cw, ch, kCVPixelFormatType_32BGRA);
    CVPixelBufferLockBaseAddress(s, 0);
    uint8_t *d = CVPixelBufferGetBaseAddress(s);
    size_t stride = CVPixelBufferGetBytesPerRow(s);
    memset(d, 0, stride * ch);
    *bbox = avf_irect_intersect((struct avf_irect){ x, y, x + w, y + h },
                                (struct avf_irect){ 0, 0, cw, ch });
    for (int py = bbox->y0; py < bbox->y1; py++) {
        for (int px = bbox->x0; px < bbox->x1; px++) {
            uint8_t a = (px + py) % 3 == 0 ? 255 : 160;
            uint8_t *p = d + py * stride + px * 4;
            p[0] = (uint8_t)(shade * a / 255);
            p[1] = (uint8_t)((255 - shade) * a / 255);
            p[2] = (uint8_t)(a / 2);
            p[3] = a;
        }
    }
    CVPixelBufferUnlockBaseAddress(s, 0);
    return s;
}

static void set_decoder_attachments(CVPixelBufferRef b)
{
    CFDataRef rpu = CFDataCreate(NULL, (const UInt8 *)"\x7c\x01\x19", 3);
    CVBufferSetAttachment(b, AVF_DOLBY_VISION_RPU_KEY, rpu, kCVAttachmentMode_ShouldNotPropagate);
    CFRelease(rpu);
    CVBufferSetAttachment(b, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_2020, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(b, CFSTR("VividTestNote"), CFSTR("kept"),
                          kCVAttachmentMode_ShouldNotPropagate);
}

// Both attachment dictionaries of a buffer, to compare later.
struct attachments { CFDictionaryRef prop, noprop; };

static struct attachments snapshot(CVBufferRef b)
{
    return (struct attachments){
        avf_copy_attachments(b, kCVAttachmentMode_ShouldPropagate),
        avf_copy_attachments(b, kCVAttachmentMode_ShouldNotPropagate),
    };
}

static bool dict_same(CFDictionaryRef a, CFDictionaryRef b)
{
    bool ea = !a || CFDictionaryGetCount(a) == 0, eb = !b || CFDictionaryGetCount(b) == 0;
    return ea == eb && (ea || CFEqual(a, b));
}

static bool unchanged(CVBufferRef b, const struct attachments *before)
{
    struct attachments now = snapshot(b);
    bool same = dict_same(now.prop, before->prop) && dict_same(now.noprop, before->noprop);
    if (now.prop) CFRelease(now.prop);
    if (now.noprop) CFRelease(now.noprop);
    return same;
}

static void release_snapshot(struct attachments *a)
{
    if (a->prop) CFRelease(a->prop);
    if (a->noprop) CFRelease(a->noprop);
}

static struct avf_overlay frame_overlay(CVPixelBufferRef cue, struct avf_irect box, int w, int h)
{
    return (struct avf_overlay){
        .bgra = cue, .bbox = box, .image = NULL, .canvas_w = w, .canvas_h = h,
        .src = { 0, 0, w, h }, .dst = { 0, 0, w, h },
    };
}

// What the output does with a hardware frame before it is enqueued while
// compositing is on: earlier rows back, then the composite.
static CVPixelBufferRef present_composite(struct avf_frame *f, CVPixelBufferRef decoder,
                                          CVPixelBufferRef cue, struct avf_irect box,
                                          enum avf_composite_kind *kind)
{
    int w = (int)CVPixelBufferGetWidth(decoder), h = (int)CVPixelBufferGetHeight(decoder);
    avf_frame_restore(f, decoder);
    struct avf_overlay ov = frame_overlay(cue, box, w, h);
    return avf_frame_composite(f, decoder, false, &ov, kind);
}

// The original picture with one cue blended once, through a writable copy.
static CVPixelBufferRef blended_once(CVPixelBufferRef original, CVPixelBufferRef cue,
                                     struct avf_irect box)
{
    int w = (int)CVPixelBufferGetWidth(original), h = (int)CVPixelBufferGetHeight(original);
    CVPixelBufferRef fresh = clone_pixels(original);
    set_decoder_attachments(fresh); // the same matrix as the decoder buffer
    struct avf_frame *g = avf_frame_create(NULL);
    struct avf_overlay ov = frame_overlay(cue, box, w, h);
    enum avf_composite_kind kind;
    CVPixelBufferRef out = avf_frame_composite(g, fresh, true, &ov, &kind);
    CHECK(out == fresh && kind == AVF_COMPOSITE_IN_PLACE, "writable buffer not blended in place");
    if (out)
        CVPixelBufferRelease(out);
    avf_frame_destroy(g);
    return fresh;
}

static void test_blend_once(void)
{
    const struct { OSType fmt; const char *name; } formats[] = {
        { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "420v" },
        { kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "420f" },
        { kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "x420" },
        { kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, "xf20" },
    };
    struct avf_rng rng = { 8086 };
    for (int fi = 0; fi < 4; fi++) {
        CASE("blend-once");
        OSType fmt = formats[fi].fmt;
        const char *name = formats[fi].name;
        bool ten = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                   fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
        int w = 322, h = 182;
        struct avf_frame *f = avf_frame_create(NULL);
        CVPixelBufferRef decoder = make_buffer(w, h, fmt);
        fill_random(decoder, &rng, ten);
        set_decoder_attachments(decoder);
        CVPixelBufferRef original = clone_pixels(decoder);
        CFIndex base_retains = CFGetRetainCount(decoder);
        struct attachments before = snapshot(decoder);

        // Odd edges, so the kept rows include partial chroma pairs.
        struct avf_irect box_a, box_b;
        CVPixelBufferRef cue_a = make_cue(w, h, 41, 131, 201, 31, 30, &box_a);
        CVPixelBufferRef cue_b = make_cue(w, h, 61, 21, 151, 25, 220, &box_b);
        CVPixelBufferRef want_a = blended_once(original, cue_a, box_a);
        CVPixelBufferRef want_b = blended_once(original, cue_b, box_b);
        enum avf_composite_kind k1, k2, k3;

        // First presentation: blended into the decoder buffer itself, with
        // nothing frame-sized made.
        CVPixelBufferRef s1 = present_composite(f, decoder, cue_a, box_a, &k1);
        CHECK(s1 == decoder && k1 == AVF_COMPOSITE_DECODER,
              "%s: not blended into the decoder buffer (kind %d)", name, k1);
        CHECK(same_pixels(decoder, want_a), "%s: first composite is not the cue blended once", name);
        CHECK(unchanged(decoder, &before), "%s: composite changed the decoder's attachments", name);
        size_t kept_bytes = 0;
        CHECK(avf_frame_kept_buffer(f, &kept_bytes) == decoder, "%s: no rows kept", name);
        size_t frame_bytes = (size_t)w * h * (ten ? 2 : 1) * 3 / 2;
        CHECK(kept_bytes > 0 && kept_bytes < frame_bytes / 2,
              "%s: %zu bytes kept for a %zu-byte frame", name, kept_bytes, frame_bytes);
        if (s1)
            CVPixelBufferRelease(s1);

        // A redraw of the same image with the same cue: blended once, not
        // twice.
        CVPixelBufferRef s2 = present_composite(f, decoder, cue_a, box_a, &k2);
        CHECK(s2 == decoder && k2 == AVF_COMPOSITE_DECODER, "%s: redraw kind %d", name, k2);
        CHECK(same_pixels(decoder, want_a), "%s: the redraw blended the cue twice", name);
        if (s2)
            CVPixelBufferRelease(s2);

        // A redraw with another cue: only the new one, no trace of the old.
        CVPixelBufferRef s3 = present_composite(f, decoder, cue_b, box_b, &k3);
        CHECK(s3 == decoder && k3 == AVF_COMPOSITE_DECODER, "%s: new cue kind %d", name, k3);
        CHECK(same_pixels(decoder, want_b), "%s: a stale cue under the new one", name);
        if (s3)
            CVPixelBufferRelease(s3);

        // A redraw after the cue ended, compositing still on: the picture
        // alone, and nothing kept any more.
        avf_frame_restore(f, decoder);
        CHECK(same_pixels(decoder, original), "%s: the ended cue stayed in the picture", name);
        CHECK(!avf_frame_kept_buffer(f, NULL), "%s: rows kept after the restore", name);
        CHECK(CFGetRetainCount(decoder) == base_retains, "%s: decoder buffer still retained", name);

        // Compositing switched off: the rows go back and nothing stays held.
        CVPixelBufferRef s4 = present_composite(f, decoder, cue_a, box_a, &k1);
        if (s4)
            CVPixelBufferRelease(s4);
        avf_frame_end_composites(f);
        CHECK(same_pixels(decoder, original), "%s: burned-in cue after compositing off", name);
        CHECK(!avf_frame_kept_buffer(f, &kept_bytes) && kept_bytes == 0,
              "%s: %zu bytes still held with compositing off", name, kept_bytes);
        CHECK(CFGetRetainCount(decoder) == base_retains,
              "%s: decoder buffer retained with compositing off", name);

        // The next frame is another buffer: the composited one is let go
        // untouched (mpv never presents it again).
        CVPixelBufferRef s5 = present_composite(f, decoder, cue_b, box_b, &k1);
        if (s5)
            CVPixelBufferRelease(s5);
        CVPixelBufferRef next = make_buffer(w, h, fmt);
        avf_frame_restore(f, next);
        CHECK(!avf_frame_kept_buffer(f, NULL), "%s: rows of an old frame kept", name);
        CHECK(same_pixels(decoder, want_b), "%s: an old frame was rewritten", name);
        CHECK(CFGetRetainCount(decoder) == base_retains, "%s: old frame still retained", name);
        CVPixelBufferRelease(next);

        // The decoder's attachments are still exactly its own; the pixel
        // aspect and the Dolby Vision repair act on the same buffer.
        CHECK(unchanged(decoder, &before), "%s: attachments changed", name);
        struct mp_image_params vp = { .w = w, .h = h, .p_w = 4, .p_h = 3 };
        struct mp_image_params ip = {0};
        ip.repr.sys = PL_COLOR_SYSTEM_DOLBYVISION;
        ip.color.transfer = PL_COLOR_TRC_PQ;
        avf_frame_pixel_aspect(decoder, &vp);
        CHECK(avf_frame_dolby_vision_repair(decoder, &ip), "%s: repair did not fire", name);
        CHECK(CVPixelBufferGetWidth(decoder) == (size_t)w &&
              CVPixelBufferGetHeight(decoder) == (size_t)h, "%s: size changed", name);

        release_snapshot(&before);
        CVPixelBufferRelease(cue_a);
        CVPixelBufferRelease(cue_b);
        CVPixelBufferRelease(want_a);
        CVPixelBufferRelease(want_b);
        CVPixelBufferRelease(original);
        avf_frame_destroy(f);
        CHECK(CFGetRetainCount(decoder) == 1, "%s: destroy left a retain", name);
        CVPixelBufferRelease(decoder);
    }
}

static void test_composite_size(void)
{
    // Frame space: the sample keeps the frame's size whatever the cue's
    // position (any sub-pos, including partly or wholly off the frame).
    struct avf_rng rng = { 1234 };
    const int sizes[][2] = { { 1920, 1080 }, { 720, 576 }, { 853, 480 }, { 3840, 2160 } };
    for (int s = 0; s < 4; s++) {
        CASE("composite-keeps-frame-size");
        int w = sizes[s][0], h = sizes[s][1];
        struct avf_frame *f = avf_frame_create(NULL);
        CVPixelBufferRef video = make_buffer(w, h, s & 1 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                                                         : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        fill_random(video, &rng, s & 1);
        for (int pos = -20; pos <= 160; pos += 15) {
            int y = h * pos / 100;
            struct avf_irect box;
            CVPixelBufferRef cue = make_cue(w, h, w / 6, y, w * 2 / 3, h / 12, 90, &box);
            enum avf_composite_kind k;
            CVPixelBufferRef out = present_composite(f, video, cue, box, &k);
            CVPixelBufferRef shown = out ? out : video;
            CHECK(CVPixelBufferGetWidth(shown) == (size_t)w &&
                  CVPixelBufferGetHeight(shown) == (size_t)h, "sub-pos %d%%: size changed", pos);
            if (out)
                CVPixelBufferRelease(out);
            CVPixelBufferRelease(cue);
        }
        CVPixelBufferRelease(video);
        avf_frame_destroy(f);
    }
}

static void test_transparent_span(void)
{
    // Parts wholly off the frame on opposite sides give a bounding box across
    // it (4.14.5). The blend then meets only transparent pixels, so the frame
    // passes through untouched instead of going to Core Image.
    const OSType formats[] = { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                               kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                               kCVPixelFormatType_420YpCbCr10BiPlanarFullRange };
    struct avf_rng rng = { 2024 };
    for (int fi = 0; fi < 4; fi++) {
        CASE("transparent-box-leaves-frame");
        int w = 200, h = 120;
        struct avf_frame *f = avf_frame_create(NULL);
        CVPixelBufferRef video = make_buffer(w, h, formats[fi]);
        fill_random(video, &rng, fi >= 2);
        CVPixelBufferRef original = clone_pixels(video);
        CVPixelBufferRef cue = make_buffer(w, h, kCVPixelFormatType_32BGRA);
        CVPixelBufferLockBaseAddress(cue, 0);
        memset(CVPixelBufferGetBaseAddress(cue), 0, CVPixelBufferGetBytesPerRow(cue) * h);
        CVPixelBufferUnlockBaseAddress(cue, 0);
        enum avf_composite_kind k;
        CVPixelBufferRef out = present_composite(f, video, cue,
                                                 (struct avf_irect){ 0, 30, w, 90 }, &k);
        CHECK(out == video && k == AVF_COMPOSITE_DECODER, "not blended in place (kind %d)", k);
        CHECK(same_pixels(video, original), "transparent pixels changed the frame");
        if (out)
            CVPixelBufferRelease(out);
        avf_frame_destroy(f);
        CVPixelBufferRelease(cue);
        CVPixelBufferRelease(original);
        CVPixelBufferRelease(video);
    }
}

// A frame-sized subtitle image with one filled box.
static CGImageRef make_cue_image(int w, int h)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, rgb,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextSetRGBFillColor(ctx, 1, 1, 0, 1);
    CGContextFillRect(ctx, CGRectMake(10, 10, w / 2, 20));
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(rgb);
    return img;
}

static void test_core_image(void)
{
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) {
        printf("  (no Metal device on this host: Core Image composites not run)\n");
        return;
    }
    [dev release];
    CASE("core-image-fallback");
    struct avf_frame *f = avf_frame_create(NULL);
    int w = 256, h = 144;
    CVPixelBufferRef video = make_buffer(w, h, kCVPixelFormatType_32BGRA); // not biplanar
    struct avf_rng rng = { 7 };
    fill_random(video, &rng, false);
    CVBufferSetAttachment(video, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(video, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CGImageRef img = make_cue_image(w, h);
    struct avf_overlay ov = { .bgra = NULL, .bbox = {0}, .image = img, .canvas_w = w,
                              .canvas_h = h, .src = { 0, 0, w, h }, .dst = { 0, 0, w, h } };
    enum avf_composite_kind k;
    CVPixelBufferRef out = avf_frame_composite(f, video, false, &ov, &k);
    CHECK(out && k == AVF_COMPOSITE_CORE_IMAGE, "no Core Image composite");
    if (out) {
        CHECK(CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_32BGRA, "format");
        CHECK(CVPixelBufferGetWidth(out) == (size_t)w && CVPixelBufferGetHeight(out) == (size_t)h,
              "size");
        CHECK(!attachment(out, kCVImageBufferYCbCrMatrixKey, NULL), "matrix kept on RGB output");
        CFTypeRef pr = attachment(out, kCVImageBufferColorPrimariesKey, NULL);
        CHECK(pr && CFEqual(pr, kCVImageBufferColorPrimaries_ITU_R_709_2), "primaries not copied");
        CVPixelBufferRelease(out);
    }

    CASE("core-image-size-guard");
    ov.canvas_w = w / 2; // a composite of another size is discarded
    ov.dst = (struct avf_irect){ 0, 0, w / 2, h };
    out = avf_frame_composite(f, video, false, &ov, &k);
    CHECK(!out && k == AVF_COMPOSITE_NONE, "a resized composite was kept");
    if (out)
        CVPixelBufferRelease(out);
    CGImageRelease(img);
    CVPixelBufferRelease(video);

    // Output format by source: half float only for 10-bit 4:2:0, 8-bit BGRA
    // for everything else.
    CASE("core-image-output-format");
    const struct { OSType in; OSType out; const char *name; } formats[] = {
        { kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_64RGBAHalf, "x420" },
        { kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_64RGBAHalf, "xf20" },
        { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA, "420v" },
        { kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA, "x422" },
        { kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_32BGRA, "xf22" },
        { kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA, "x444" },
        { kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_32BGRA, "xf44" },
        { kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA, "422v" },
        { kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, kCVPixelFormatType_32BGRA, "sv22" },
        { kCVPixelFormatType_64RGBALE, kCVPixelFormatType_32BGRA, "l64r" },
    };
    w = 128;
    h = 72;
    img = make_cue_image(w, h);
    int checked = 0;
    for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
        video = make_buffer(w, h, formats[i].in);
        if (!video)
            continue;
        // Without a BGRA canvas the YUV blend produces nothing, so 4:2:0
        // sources reach Core Image too.
        ov = (struct avf_overlay){ .image = img, .canvas_w = w, .canvas_h = h,
                                   .src = { 0, 0, w, h }, .dst = { 0, 0, w, h } };
        out = avf_frame_composite(f, video, false, &ov, &k);
        if (out) {
            checked++;
            CHECK(k == AVF_COMPOSITE_CORE_IMAGE, "%s: kind %d", formats[i].name, k);
            CHECK(CVPixelBufferGetPixelFormatType(out) == formats[i].out,
                  "%s: Core Image output format", formats[i].name);
            CVPixelBufferRelease(out);
        }
        CVPixelBufferRelease(video);
    }
    CHECK(checked >= 8, "only %d source formats composited", checked);

    // A source Core Image cannot read gets no composite at all: the frame
    // goes out without the subtitle, never as the subtitle over an empty
    // picture.
    CASE("core-image-unreadable-source");
    video = make_buffer(w, h, kCVPixelFormatType_4444AYpCbCr16);
    CHECK(video != NULL, "no y416 buffer");
    if (video) {
        CIImage *probe = [CIImage imageWithCVPixelBuffer:video];
        if (probe) {
            printf("  (Core Image reads y416 on this host: unreadable source not run)\n");
        } else {
            ov = (struct avf_overlay){ .image = img, .canvas_w = w, .canvas_h = h,
                                       .src = { 0, 0, w, h }, .dst = { 0, 0, w, h } };
            out = avf_frame_composite(f, video, false, &ov, &k);
            CHECK(!out && k == AVF_COMPOSITE_NONE, "a composite of an unreadable source");
            if (out)
                CVPixelBufferRelease(out);
        }
        CVPixelBufferRelease(video);
    }
    CGImageRelease(img);
    avf_frame_destroy(f);
}

void avf_test_frame(void)
{
    @autoreleasepool {
        test_uploads();
        test_tags();
        test_aspect_and_repair();
        test_samples();
        test_blend_once();
        test_composite_size();
        test_transparent_span();
        test_core_image();
    }
}
