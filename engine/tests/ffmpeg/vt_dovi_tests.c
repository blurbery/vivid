/*
 * Host tests for Lucid Engine's VideoToolbox Dolby Vision module
 * Copyright (C) 2026 blurbery
 *
 * This file is part of Vivid's Lucid Engine test suite for FFmpeg.
 *
 * It is free software; you can redistribute it and/or modify it under the
 * terms of the GNU Lesser General Public License as published by the Free
 * Software Foundation; either version 2.1 of the License, or (at your
 * option) any later version.
 *
 * It is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for
 * more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with it; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/*
 * `engine/lucid.py check` builds this file on the build host together with
 * libavcodec/videotoolbox_dovi.c taken from the FFmpeg tree it has just
 * patched, so the code under test is the code that ships. It is built twice:
 *
 *  - with VT_DOVI_TEST_FAKE_LIBDOVI, against a scripted stand-in for the six
 *    libdovi functions the module calls, to drive every outcome of FFmpeg's
 *    call sequence (including the ones that make unpatched libdovi abort);
 *  - without it, against libdovi 3.3.2 itself, for the byte-identity and
 *    guard tests. argv[1] is then the folder holding the RPU vectors.
 *
 * Every check is counted; the run fails on any failed check or when no
 * check ran.
 */

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <libdovi/rpu_parser.h>

#include "libavutil/log.h"
#include "libavcodec/videotoolbox_dovi.h"

/* ------------------------------------------------------------ counting */

static int checks, failures;

#define CHECK(cond, ...) check(!!(cond), __LINE__, __VA_ARGS__)

static void check(int ok, int line, const char *fmt, ...)
{
    va_list ap;

    checks++;
    if (ok)
        return;
    failures++;
    fprintf(stderr, "FAIL (line %d): ", line);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* --------------------------------------------------------------- av_log */

/* Substrings Vivid's adapter records as faults (spec 2.8). No message the
 * module logs, libdovi's error texts included, may contain one. */
static const char *const fault_substrings[] = {
    "Too many packets", "queue overflow", "EOF", "End of file", "timed out",
    "Connection reset", "Error decoding", "Invalid data",
};

#define MAX_LOG 32

static struct {
    int  level;
    char text[1024];
} log_lines[MAX_LOG];
static int nb_log, all_log;

void av_log(void *avcl, int level, const char *fmt, ...)
{
    char buf[1024];
    va_list ap;

    (void)avcl;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    all_log++;
    for (size_t i = 0; i < sizeof(fault_substrings) / sizeof(*fault_substrings); i++)
        CHECK(!strstr(buf, fault_substrings[i]),
              "logged line contains the fault substring \"%s\": %s",
              fault_substrings[i], buf);

    if (nb_log < MAX_LOG) {
        log_lines[nb_log].level = level;
        snprintf(log_lines[nb_log].text, sizeof(log_lines[nb_log].text), "%s", buf);
    }
    nb_log++;
}

static void log_reset(void)
{
    nb_log = 0;
}

/* av_log calls at the given level. */
static int log_calls(int level)
{
    int n = 0;
    for (int i = 0; i < nb_log && i < MAX_LOG; i++)
        n += log_lines[i].level == level;
    return n;
}

/* Lines mpv delivers as separate log events: it splits every message on its
 * line breaks. */
static int warn_events(void)
{
    int n = 0;
    for (int i = 0; i < nb_log && i < MAX_LOG; i++) {
        const char *t = log_lines[i].text;
        size_t len = strlen(t);
        if (log_lines[i].level != AV_LOG_WARNING)
            continue;
        for (size_t j = 0; j < len; j++)
            n += t[j] == '\n';
        if (len && t[len - 1] != '\n')
            n++;
    }
    return n;
}

static const char *log_text(int i)
{
    return i < nb_log && i < MAX_LOG ? log_lines[i].text : "";
}

/* ---------------------------------------------------------- sample sink */

/* Collects what the module appends, length-prefixed as VideoToolbox gets it. */
static struct {
    uint8_t buf[16384];
    size_t  len;
    int     calls;
    int     fail;
} sink;

static void sink_reset(void)
{
    memset(&sink, 0, sizeof(sink));
}

static int sink_append(void *opaque, const uint8_t *nal, size_t size)
{
    (void)opaque;
    sink.calls++;
    if (sink.fail)
        return -12;
    if (sink.len + 4 + size > sizeof(sink.buf))
        return -12;
    sink.buf[sink.len + 0] = size >> 24;
    sink.buf[sink.len + 1] = size >> 16;
    sink.buf[sink.len + 2] = size >> 8;
    sink.buf[sink.len + 3] = size;
    memcpy(sink.buf + sink.len + 4, nal, size);
    sink.len += 4 + size;
    return 0;
}

/* --------------------------------------------------------- stream setup */

static FFVTDoviStream stream(int profile, int level, int rpu, int el, int bl,
                             int compat, int compression)
{
    AVDOVIDecoderConfigurationRecord rec = {
        .dv_version_major              = 1,
        .dv_version_minor              = 0,
        .dv_profile                    = profile,
        .dv_level                      = level,
        .rpu_present_flag              = rpu,
        .el_present_flag               = el,
        .bl_present_flag               = bl,
        .dv_bl_signal_compatibility_id = compat,
        .dv_md_compression             = compression,
    };
    FFVTDoviStream s;

    ff_vt_dovi_classify(&s, (const uint8_t *)&rec, sizeof(rec));
    return s;
}

/* The spec's guard vectors (9.4), as complete escaped NAL units. */
static size_t guard_vector(int which, uint8_t *out)
{
    static const uint8_t heads[4][8] = {
        { 0x7c, 0x01, 0x19, 0x08, 0x09 },
        { 0x7c, 0x01, 0x19, 0x08, 0x09, 0x80, 0x80 },
        { 0x7c, 0x01, 0x19, 0x08, 0x09, 0x00, 0x00, 0x03 },
        { 0x7c, 0x01, 0x19, 0x08, 0x09, 0x01, 0x02, 0x80 },
    };
    static const size_t head_len[4] = { 5, 7, 8, 8 };
    static const size_t zeros[4]    = { 20, 18, 17, 17 };

    memset(out, 0, head_len[which] + zeros[which]);
    memcpy(out, heads[which], head_len[which]);
    return head_len[which] + zeros[which];
}

#ifdef VT_DOVI_TEST_FAKE_LIBDOVI

/* -------------------------------------------- scripted libdovi stand-in */

struct DoviRpuOpaque {
    char error[256];
    int  has_error;
};

static struct {
    /* script */
    int         parse_null;
    const char *parse_error;
    const char *convert_error;   /* conversion fails with this text */
    int         convert_fail;
    const char *write_error;     /* writing fails with this text */
    int         write_fail;
    size_t      write_len;       /* reported output length, 0 for the real one */
    /* observations */
    int         parses, converts, writes, data_frees, rpu_frees;
    int         last_mode;
    int         live_rpus, live_data;
} fake;

static const uint8_t fake_output[] = { 0x7c, 0x01, 0x19, 0x08, 0x09, 0xaa, 0xbb, 0x80 };
static DoviData fake_data;

static void fake_reset(void)
{
    memset(&fake, 0, sizeof(fake));
    fake.last_mode = -1;
}

static void fake_set_error(DoviRpuOpaque *rpu, const char *error)
{
    rpu->has_error = !!error;
    snprintf(rpu->error, sizeof(rpu->error), "%s", error ? error : "");
}

DoviRpuOpaque *dovi_parse_unspec62_nalu(const uint8_t *buf, size_t len)
{
    DoviRpuOpaque *rpu;

    (void)buf;
    (void)len;
    fake.parses++;
    if (fake.parse_null)
        return NULL;
    rpu = calloc(1, sizeof(*rpu));
    if (!rpu)
        abort();
    fake.live_rpus++;
    fake_set_error(rpu, fake.parse_error);
    return rpu;
}

const char *dovi_rpu_get_error(const DoviRpuOpaque *rpu)
{
    return rpu && rpu->has_error ? rpu->error : NULL;
}

int32_t dovi_convert_rpu_with_mode(DoviRpuOpaque *rpu, uint8_t mode)
{
    fake.converts++;
    fake.last_mode = mode;
    if (fake.convert_fail) {
        fake_set_error(rpu, fake.convert_error);
        return -1;
    }
    return 0;
}

const DoviData *dovi_write_unspec62_nalu(DoviRpuOpaque *rpu)
{
    fake.writes++;
    if (fake.write_fail) {
        fake_set_error(rpu, fake.write_error);
        return NULL;
    }
    fake.live_data++;
    fake_data.data = fake_output;
    fake_data.len  = fake.write_len ? fake.write_len : sizeof(fake_output);
    return &fake_data;
}

void dovi_data_free(const DoviData *data)
{
    if (data) {
        fake.data_frees++;
        fake.live_data--;
    }
}

void dovi_rpu_free(DoviRpuOpaque *rpu)
{
    if (rpu) {
        /* Poison the error text, so a read after free shows up in a log. */
        snprintf(rpu->error, sizeof(rpu->error), "<freed>");
        fake.rpu_frees++;
        fake.live_rpus--;
        free(rpu);
    }
}

#endif /* VT_DOVI_TEST_FAKE_LIBDOVI */

/* ------------------------------------------------------ classification */

static void test_classification(void)
{
    AVDOVIDecoderConfigurationRecord rec = {
        .dv_profile = 8, .dv_level = 6, .rpu_present_flag = 1,
        .bl_present_flag = 1, .dv_bl_signal_compatibility_id = 1,
    };
    static const struct {
        int profile, rpu, el, bl, compat;
        enum FFVTDoviClass cls;
        int hdr, hlg, effective;
    } cases[] = {
        { 5, 1, 0, 1, 0, FF_VT_DOVI_NATIVE,    0, 0, 5 },
        { 8, 1, 0, 1, 1, FF_VT_DOVI_NATIVE,    1, 0, 8 },
        { 8, 1, 0, 1, 4, FF_VT_DOVI_NATIVE,    1, 1, 8 },
        { 8, 1, 0, 1, 2, FF_VT_DOVI_NATIVE,    1, 0, 8 }, /* SDR base, still PQ (D3) */
        { 8, 1, 0, 1, 0, FF_VT_DOVI_NATIVE,    1, 0, 8 },
        { 8, 1, 0, 1, 6, FF_VT_DOVI_NATIVE,    1, 0, 8 },
        { 7, 1, 1, 1, 6, FF_VT_DOVI_CONVERTED, 1, 0, 8 },
        { 7, 1, 0, 1, 6, FF_VT_DOVI_CONVERTED, 1, 0, 8 },
        { 7, 0, 1, 1, 6, FF_VT_DOVI_PLAIN,     0, 0, 0 }, /* RPU flag clear */
        { 7, 1, 1, 0, 6, FF_VT_DOVI_PLAIN,     0, 0, 0 }, /* BL flag clear */
        { 5, 0, 0, 1, 0, FF_VT_DOVI_PLAIN,     0, 0, 0 },
        { 8, 1, 0, 0, 1, FF_VT_DOVI_PLAIN,     0, 0, 0 },
        { 4, 1, 1, 1, 2, FF_VT_DOVI_PLAIN,     0, 0, 0 },
        { 9, 1, 0, 1, 2, FF_VT_DOVI_PLAIN,     0, 0, 0 },
        { 10, 1, 0, 1, 1, FF_VT_DOVI_PLAIN,    0, 0, 0 },
        { 0, 1, 0, 1, 0, FF_VT_DOVI_PLAIN,     0, 0, 0 },
    };
    FFVTDoviStream s;

    for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
        s = stream(cases[i].profile, 6, cases[i].rpu, cases[i].el, cases[i].bl,
                   cases[i].compat, 0);
        CHECK(s.cls == cases[i].cls, "class of case %zu: %d, expected %d", i, s.cls, cases[i].cls);
        CHECK(s.hdr_base == cases[i].hdr, "HDR base of case %zu", i);
        CHECK(s.hlg_base == cases[i].hlg, "HLG base of case %zu", i);
        CHECK(ff_vt_dovi_effective_profile(&s) == cases[i].effective,
              "effective profile of case %zu", i);
    }

    /* Absent and short records are plain HEVC (D14). */
    ff_vt_dovi_classify(&s, NULL, 0);
    CHECK(s.cls == FF_VT_DOVI_PLAIN, "no record");
    ff_vt_dovi_classify(&s, (const uint8_t *)&rec, sizeof(rec) - 1);
    CHECK(s.cls == FF_VT_DOVI_PLAIN, "record one byte short");
    ff_vt_dovi_classify(&s, (const uint8_t *)&rec, sizeof(rec));
    CHECK(s.cls == FF_VT_DOVI_NATIVE, "complete record");
}

/* ------------------------------------------- configuration record (5.2) */

static void test_records(void)
{
    static const struct {
        const char *name;
        int major, minor, profile, level, rpu, el, bl, compat, compression;
        const char *key;
        uint8_t expected[5];
    } cases[] = {
        { "profile 5",       1, 0, 5, 6, 1, 0, 1, 0, 0, "dvcC", { 1, 0, 0x0a, 0x35, 0x00 } },
        { "profile 8.1",     1, 0, 8, 6, 1, 0, 1, 1, 0, "dvvC", { 1, 0, 0x10, 0x35, 0x10 } },
        { "profile 8.4",     1, 0, 8, 6, 1, 0, 1, 4, 0, "dvvC", { 1, 0, 0x10, 0x35, 0x40 } },
        { "profile 8.2",     1, 0, 8, 9, 1, 0, 1, 2, 0, "dvvC", { 1, 0, 0x10, 0x4d, 0x20 } },
        { "profile 7 FEL",   1, 0, 7, 6, 1, 1, 1, 6, 0, "dvvC", { 1, 0, 0x10, 0x35, 0x10 } },
        { "profile 7 MEL",   2, 1, 7, 9, 1, 1, 1, 6, 0, "dvvC", { 2, 1, 0x10, 0x4d, 0x10 } },
        { "compression 3",   1, 0, 8, 6, 1, 0, 1, 1, 3, "dvvC", { 1, 0, 0x10, 0x35, 0x10 } },
        { "profile 5 compr", 1, 0, 5, 6, 1, 0, 1, 0, 2, "dvcC", { 1, 0, 0x0a, 0x35, 0x00 } },
        /* Out-of-range values are masked, flags written as 0 or 1. */
        { "masked",          0xff, 7, 8, 0xff, 7, 3, 9, 0x1a, 3, "dvvC", { 0xff, 7, 0x11, 0xff, 0xa0 } },
        { "profile 5 + EL",  1, 0, 5, 1, 1, 1, 1, 0, 0, "dvcC", { 1, 0, 0x0a, 0x0f, 0x00 } },
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
        AVDOVIDecoderConfigurationRecord rec = {
            .dv_version_major              = cases[i].major,
            .dv_version_minor              = cases[i].minor,
            .dv_profile                    = cases[i].profile,
            .dv_level                      = cases[i].level,
            .rpu_present_flag              = cases[i].rpu,
            .el_present_flag               = cases[i].el,
            .bl_present_flag               = cases[i].bl,
            .dv_bl_signal_compatibility_id = cases[i].compat,
            .dv_md_compression             = cases[i].compression,
        };
        uint8_t record[FF_VT_DOVI_RECORD_SIZE], expected[FF_VT_DOVI_RECORD_SIZE] = { 0 };
        CFMutableDictionaryRef ext, atoms;
        CFDataRef data;
        FFVTDoviStream s;
        char key[8] = "";

        ff_vt_dovi_classify(&s, (const uint8_t *)&rec, sizeof(rec));
        memcpy(expected, cases[i].expected, 5);
        memset(record, 0xee, sizeof(record));
        CHECK(ff_vt_dovi_write_record(&s, record) == 0, "%s: record written", cases[i].name);
        CHECK(!memcmp(record, expected, sizeof(record)),
              "%s: record %02x %02x %02x %02x %02x ..., expected %02x %02x %02x %02x %02x",
              cases[i].name, record[0], record[1], record[2], record[3], record[4],
              expected[0], expected[1], expected[2], expected[3], expected[4]);
        CFStringGetCString(ff_vt_dovi_atom_key(&s), key, sizeof(key), kCFStringEncodingASCII);
        CHECK(!strcmp(key, cases[i].key), "%s: atom %s, expected %s", cases[i].name, key, cases[i].key);

        /* The same record lands in the session's sample description atoms. */
        ext   = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                          &kCFTypeDictionaryValueCallBacks);
        atoms = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                          &kCFTypeDictionaryValueCallBacks);
        CHECK(ff_vt_dovi_add_extensions(&s, ext, atoms) == 0, "%s: extensions added", cases[i].name);
        CHECK(CFDictionaryGetCount(atoms) == 1, "%s: one atom", cases[i].name);
        data = CFDictionaryGetValue(atoms, ff_vt_dovi_atom_key(&s));
        CHECK(data && CFDataGetLength(data) == FF_VT_DOVI_RECORD_SIZE &&
              !memcmp(CFDataGetBytePtr(data), expected, FF_VT_DOVI_RECORD_SIZE),
              "%s: atom bytes", cases[i].name);
        CFRelease(ext);
        CFRelease(atoms);
    }

    {
        FFVTDoviStream plain = stream(4, 6, 1, 1, 1, 2, 0);
        uint8_t record[FF_VT_DOVI_RECORD_SIZE];
        CHECK(ff_vt_dovi_write_record(&plain, record) < 0, "plain HEVC has no record");
    }
}

/* -------------------------------------------- colour extensions (5.2) */

static void test_colour_extensions(void)
{
    static const struct {
        const char *name;
        int profile, compat;
        int colour, hlg;
    } cases[] = {
        { "profile 5",   5, 0, 0, 0 },
        { "profile 8.1", 8, 1, 1, 0 },
        { "profile 8.2", 8, 2, 1, 0 },
        { "profile 8.0", 8, 0, 1, 0 },
        { "profile 8.4", 8, 4, 1, 1 },
        { "profile 7",   7, 6, 1, 0 },
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(*cases); i++) {
        FFVTDoviStream s = stream(cases[i].profile, 6, 1, cases[i].profile == 7, 1,
                                  cases[i].compat, 0);
        CFMutableDictionaryRef ext = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                               &kCFTypeDictionaryValueCallBacks);
        CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks);
        ff_vt_dovi_add_extensions(&s, ext, atoms);
        if (!cases[i].colour) {
            CHECK(CFDictionaryGetCount(ext) == 0, "%s: no colour extensions", cases[i].name);
        } else {
            CHECK(CFDictionaryGetCount(ext) == 3, "%s: three colour extensions", cases[i].name);
            CHECK(CFEqual(CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_ColorPrimaries),
                          kCMFormatDescriptionColorPrimaries_ITU_R_2020), "%s: primaries", cases[i].name);
            CHECK(CFEqual(CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_TransferFunction),
                          cases[i].hlg ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG :
                                         kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ),
                  "%s: transfer", cases[i].name);
            CHECK(CFEqual(CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_YCbCrMatrix),
                          kCMFormatDescriptionYCbCrMatrix_ITU_R_2020), "%s: matrix", cases[i].name);
        }
        CFRelease(ext);
        CFRelease(atoms);
    }
}

/* ------------------------------------------------- retry rules (5.3) */

static void test_retry(void)
{
    FFVTDoviStream p5 = stream(5, 6, 1, 0, 1, 0, 0);
    FFVTDoviStream p81 = stream(8, 6, 1, 0, 1, 1, 0);
    FFVTDoviStream p84 = stream(8, 6, 1, 0, 1, 4, 0);
    FFVTDoviStream p82 = stream(8, 6, 1, 0, 1, 2, 0);
    FFVTDoviStream p7 = stream(7, 6, 1, 1, 1, 6, 0);
    FFVTDoviStream plain = stream(7, 6, 1, 1, 0, 6, 0);

    CHECK(!ff_vt_dovi_retry_as_hevc(&p5, -12910), "profile 5 never retries");
    CHECK(!ff_vt_dovi_retry_as_hevc(&p5, -12906), "profile 5 never retries (any status)");
    CHECK(ff_vt_dovi_retry_as_hevc(&p81, -12910), "profile 8.1 retries");
    CHECK(ff_vt_dovi_retry_as_hevc(&p84, -12906), "profile 8.4 retries");
    CHECK(ff_vt_dovi_retry_as_hevc(&p82, -1), "profile 8.2 retries on any status");
    CHECK(ff_vt_dovi_retry_as_hevc(&p7, -12911), "profile 7 retries");
    CHECK(!ff_vt_dovi_retry_as_hevc(&p81, 0), "no retry after success");
    CHECK(!ff_vt_dovi_retry_as_hevc(&plain, -12910), "plain HEVC never retries");

    /* Frame flags follow the session: a retried session counts as plain. */
    CHECK(ff_vt_dovi_frame_flags(&p5, 1) == FF_VT_DOVI_FRAME_DVH1, "profile 5 flags");
    CHECK(ff_vt_dovi_frame_flags(&p81, 1) == (FF_VT_DOVI_FRAME_DVH1 | FF_VT_DOVI_FRAME_HDR_BASE),
          "profile 8.1 flags");
    CHECK(ff_vt_dovi_frame_flags(&p84, 1) ==
          (FF_VT_DOVI_FRAME_DVH1 | FF_VT_DOVI_FRAME_HDR_BASE | FF_VT_DOVI_FRAME_HLG_BASE),
          "profile 8.4 flags");
    CHECK(ff_vt_dovi_frame_flags(&p7, 1) == (FF_VT_DOVI_FRAME_DVH1 | FF_VT_DOVI_FRAME_HDR_BASE),
          "profile 7 flags");
    CHECK(ff_vt_dovi_frame_flags(&p81, 0) == 0, "retried session flags");
    CHECK(ff_vt_dovi_frame_flags(&plain, 0) == 0, "plain flags");
}

/* --------------------------------------- NAL filter and RPU selection */

static void test_nal_rules(void)
{
    FFVTDoviStream p7 = stream(7, 6, 1, 1, 1, 6, 0);
    FFVTDoviStream p8 = stream(8, 6, 1, 0, 1, 1, 0);
    FFVTDoviStream plain = stream(0, 0, 0, 0, 0, 0, 0);
    static const uint8_t rpu[]   = { 0x7c, 0x01, 0x19 };
    static const uint8_t el[]    = { 0x7e, 0x01, 0x00 };
    static const uint8_t slice[] = { 0x02, 0x01, 0xd0 };
    static const uint8_t vps[]   = { 0x40, 0x01, 0x0c };
    static const uint8_t fbit[]  = { 0xfc, 0x01 };       /* forbidden bit set, type 62 */
    static const uint8_t one[]   = { 0x7c };

    CHECK(ff_vt_dovi_drop_nal(&p7, rpu, sizeof(rpu)), "profile 7 drops type 62");
    CHECK(ff_vt_dovi_drop_nal(&p7, el, sizeof(el)), "profile 7 drops type 63");
    CHECK(ff_vt_dovi_drop_nal(&p7, fbit, sizeof(fbit)), "type read from the 6 bits after the first");
    CHECK(!ff_vt_dovi_drop_nal(&p7, slice, sizeof(slice)), "profile 7 keeps slices");
    CHECK(!ff_vt_dovi_drop_nal(&p7, vps, sizeof(vps)), "profile 7 keeps parameter sets");
    CHECK(!ff_vt_dovi_drop_nal(&p7, one, sizeof(one)), "NAL units under 2 bytes pass");
    CHECK(!ff_vt_dovi_drop_nal(&p8, rpu, sizeof(rpu)), "profile 8 keeps everything");
    CHECK(!ff_vt_dovi_drop_nal(&p8, el, sizeof(el)), "profile 8 keeps type 63");
    CHECK(!ff_vt_dovi_drop_nal(&plain, rpu, sizeof(rpu)), "plain HEVC keeps everything");

    CHECK(ff_vt_dovi_is_rpu(62, 3), "type 62 of 3 bytes is forwarded");
    CHECK(!ff_vt_dovi_is_rpu(62, 2), "type 62 of 2 bytes is not");
    CHECK(!ff_vt_dovi_is_rpu(63, 300), "type 63 is not");
    CHECK(!ff_vt_dovi_is_rpu(1, 300), "slices are not");
}

/* -------------------------------------------------- the guard (5.6) */

static void test_guard_decisions(void)
{
    uint8_t buf[64];
    size_t n;
    static const uint8_t several_ep[] = {
        0x7c, 0x01, 0x19, 0x08, 0x09, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    static const uint8_t seven_left[] = {
        0x7c, 0x01, 0x19, 0x08, 0x09, 0x01, 0x00, 0x00, 0x03, 0x01,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    static const uint8_t kept_03[] = {   /* 0x03 after a single zero is data */
        0x7c, 0x01, 0x19, 0x08, 0x09, 0x01, 0x00, 0x03,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    static const uint8_t wrong_start[] = {
        0x7c, 0x01, 0x19, 0x08, 0x08,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };

    for (int v = 0; v < 3; v++) {
        n = guard_vector(v, buf);
        CHECK(n == 25, "guard vector %d is 25 bytes", v);
        CHECK(ff_vt_dovi_rpu_is_empty(buf, n), "guard vector %d is skipped", v);
    }
    n = guard_vector(3, buf);
    CHECK(n == 25 && !ff_vt_dovi_rpu_is_empty(buf, n), "0x01 0x02 0x80 vector is not skipped");

    /* 24 bytes: below the guard's length, so libdovi rejects it itself. */
    n = guard_vector(0, buf);
    CHECK(!ff_vt_dovi_rpu_is_empty(buf, n - 1), "24-byte RPU is left to libdovi");
    CHECK(ff_vt_dovi_rpu_is_empty(several_ep, sizeof(several_ep)), "every emulation prevention byte removed");
    CHECK(!ff_vt_dovi_rpu_is_empty(seven_left, sizeof(seven_left)),
          "seven bytes left after removing an emulation prevention byte is not skipped");
    CHECK(!ff_vt_dovi_rpu_is_empty(kept_03, sizeof(kept_03)),
          "a 0x03 not preceded by two zeros is kept, leaving six bytes");
    CHECK(!ff_vt_dovi_rpu_is_empty(wrong_start, sizeof(wrong_start)), "other start bytes go to libdovi");
}

/* ---------------------------------------- frame attachments (5.7) */

static CFTypeRef attachment(CVPixelBufferRef pb, CFStringRef key, CVAttachmentMode *mode)
{
    CVAttachmentMode m = kCVAttachmentMode_ShouldNotPropagate;
    CFTypeRef value = CVBufferCopyAttachment(pb, key, &m);
    if (mode)
        *mode = m;
    if (value)
        CFAutorelease(value);
    return value;
}

static CVPixelBufferRef new_buffer(void)
{
    CVPixelBufferRef pb = NULL;
    CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                       kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                       NULL, &pb);
    if (ret != kCVReturnSuccess || !pb) {
        fprintf(stderr, "could not create a pixel buffer (%d)\n", ret);
        exit(1);
    }
    CVBufferRemoveAllAttachments(pb);
    return pb;
}

static int attachment_count(CVPixelBufferRef pb)
{
    CFDictionaryRef a = CVBufferCopyAttachments(pb, kCVAttachmentMode_ShouldPropagate);
    CFDictionaryRef b = CVBufferCopyAttachments(pb, kCVAttachmentMode_ShouldNotPropagate);
    int n = (a ? (int)CFDictionaryGetCount(a) : 0) + (b ? (int)CFDictionaryGetCount(b) : 0);
    if (a)
        CFRelease(a);
    if (b)
        CFRelease(b);
    return n;
}

static void test_frame_tags(void)
{
    const int p81 = FF_VT_DOVI_FRAME_DVH1 | FF_VT_DOVI_FRAME_HDR_BASE;
    const int p84 = p81 | FF_VT_DOVI_FRAME_HLG_BASE;
    CFStringRef rpu_key = CFSTR("DolbyVisionRPUData");
    CVPixelBufferRef pb;
    CVAttachmentMode mode;
    CGColorSpaceRef srgb;
    CFDataRef rpu_data;
    static const uint8_t rpu_bytes[] = { 1, 2, 3 };

    /* Profile 8.1: everything filled, propagated, colour space derived. */
    pb = new_buffer();
    rpu_data = CFDataCreate(NULL, rpu_bytes, sizeof(rpu_bytes));
    CVBufferSetAttachment(pb, rpu_key, rpu_data, kCVAttachmentMode_ShouldPropagate);
    ff_vt_dovi_tag_frame(pb, p81);
    CHECK(CFEqual(attachment(pb, kCVImageBufferColorPrimariesKey, &mode),
                  kCVImageBufferColorPrimaries_ITU_R_2020) &&
          mode == kCVAttachmentMode_ShouldPropagate, "8.1: BT.2020 primaries, propagated");
    CHECK(CFEqual(attachment(pb, kCVImageBufferTransferFunctionKey, &mode),
                  kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) &&
          mode == kCVAttachmentMode_ShouldPropagate, "8.1: PQ transfer, propagated");
    CHECK(CFEqual(attachment(pb, kCVImageBufferYCbCrMatrixKey, &mode),
                  kCVImageBufferYCbCrMatrix_ITU_R_2020) &&
          mode == kCVAttachmentMode_ShouldPropagate, "8.1: BT.2020 matrix, propagated");
    CHECK(attachment(pb, kCVImageBufferCGColorSpaceKey, &mode) &&
          mode == kCVAttachmentMode_ShouldPropagate, "8.1: colour space derived");
    CHECK(CFEqual(attachment(pb, rpu_key, NULL), rpu_data), "8.1: DolbyVisionRPUData kept");
    CHECK(!attachment(pb, kCVImageBufferPixelAspectRatioKey, NULL) &&
          !attachment(pb, kCVImageBufferChromaLocationTopFieldKey, NULL) &&
          !attachment(pb, kCVImageBufferGammaLevelKey, NULL),
          "8.1: no pixel aspect, chroma location or gamma from FFmpeg");
    CFRelease(pb);

    /* Profile 8.4: HLG. */
    pb = new_buffer();
    ff_vt_dovi_tag_frame(pb, p84);
    CHECK(CFEqual(attachment(pb, kCVImageBufferTransferFunctionKey, NULL),
                  kCVImageBufferTransferFunction_ITU_R_2100_HLG), "8.4: HLG transfer");
    CFRelease(pb);

    /* Only where absent: VideoToolbox's own values are never replaced. */
    pb = new_buffer();
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                          kCVAttachmentMode_ShouldNotPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    ff_vt_dovi_tag_frame(pb, p81);
    CHECK(CFEqual(attachment(pb, kCVImageBufferTransferFunctionKey, &mode),
                  kCVImageBufferTransferFunction_ITU_R_2100_HLG) &&
          mode == kCVAttachmentMode_ShouldNotPropagate, "existing transfer kept");
    CHECK(CFEqual(attachment(pb, kCVImageBufferYCbCrMatrixKey, NULL),
                  kCVImageBufferYCbCrMatrix_ITU_R_709_2), "existing matrix kept");
    CHECK(CFEqual(attachment(pb, kCVImageBufferColorPrimariesKey, NULL),
                  kCVImageBufferColorPrimaries_ITU_R_2020), "missing primaries filled");
    CFRelease(pb);

    /* An existing colour space is kept, though one could be derived. */
    pb = new_buffer();
    srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, srgb, kCVAttachmentMode_ShouldPropagate);
    ff_vt_dovi_tag_frame(pb, p81);
    CHECK(attachment(pb, kCVImageBufferCGColorSpaceKey, NULL) == (CFTypeRef)srgb,
          "existing colour space kept");
    CHECK(CFEqual(attachment(pb, kCVImageBufferTransferFunctionKey, NULL),
                  kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ), "tags filled beside it");
    CFRelease(srgb);
    CFRelease(pb);

    /* Profile 5: nothing added or removed. */
    pb = new_buffer();
    CVBufferSetAttachment(pb, rpu_key, rpu_data, kCVAttachmentMode_ShouldPropagate);
    ff_vt_dovi_tag_frame(pb, FF_VT_DOVI_FRAME_DVH1);
    CHECK(attachment_count(pb) == 1 && attachment(pb, rpu_key, NULL),
          "profile 5: only VideoToolbox's attachments");
    CFRelease(pb);

    /* Not a Dolby Vision session: the module does nothing. */
    pb = new_buffer();
    ff_vt_dovi_tag_frame(pb, 0);
    CHECK(attachment_count(pb) == 0, "plain session: untouched");
    CFRelease(pb);

    CFRelease(rpu_data);
}

#ifdef VT_DOVI_TEST_FAKE_LIBDOVI

/* ----------------------- RPU forwarding with scripted libdovi (5.5, 5.6) */

static int forward(const FFVTDoviStream *s, const uint8_t *nal, size_t size)
{
    return ff_vt_dovi_forward_rpu(NULL, s, nal, size, sink_append, NULL);
}

static void expect_skip(const char *name, int ret, int warnings, int events,
                        const char *stage, const char *stripped)
{
    CHECK(ret == 0, "%s: skipped", name);
    CHECK(sink.len == 0, "%s: nothing appended", name);
    CHECK(log_calls(AV_LOG_WARNING) == warnings, "%s: %d warnings, expected %d",
          name, log_calls(AV_LOG_WARNING), warnings);
    CHECK(nb_log == warnings, "%s: only warnings logged", name);
    CHECK(warn_events() == events, "%s: %d warn events, expected %d", name, warn_events(), events);
    if (stage)
        CHECK(strstr(log_text(0), stage) != NULL, "%s: stage line \"%s\" has \"%s\"",
              name, log_text(0), stage);
    CHECK(strstr(log_text(warnings - 1), stripped) != NULL, "%s: stripped line \"%s\" has \"%s\"",
          name, log_text(warnings - 1), stripped);
    CHECK(fake.live_rpus == 0 && fake.live_data == 0, "%s: libdovi objects freed", name);
    CHECK(!strstr(log_text(0), "<freed>"), "%s: error text read before the RPU was freed", name);
}

static void begin(void)
{
    fake_reset();
    sink_reset();
    log_reset();
}

static void test_forwarding(void)
{
    FFVTDoviStream p7 = stream(7, 6, 1, 1, 1, 6, 0);
    FFVTDoviStream p8 = stream(8, 6, 1, 0, 1, 1, 0);
    FFVTDoviStream p5 = stream(5, 6, 1, 0, 1, 0, 0);
    uint8_t nal[64];
    size_t n;
    int ret;
    static const uint8_t rpu[] = { 0x7c, 0x01, 0x19, 0x08, 0x09, 0x00, 0x00, 0x03, 0x01,
                                   0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa,
                                   0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x12, 0x34, 0x80 };

    /* The guard vectors: skipped without calling libdovi, two warnings. */
    for (int v = 0; v < 3; v++) {
        begin();
        n = guard_vector(v, nal);
        ret = forward(&p7, nal, n);
        expect_skip("guard vector", ret, 2, 2, "not passed to libdovi", "(could not convert)");
        CHECK(fake.parses == 0, "guard vector %d: libdovi not called", v);
    }

    /* The fourth vector is not the guard's to skip: it reaches libdovi. */
    begin();
    n = guard_vector(3, nal);
    ret = forward(&p7, nal, n);
    CHECK(ret == 1 && fake.parses == 1, "0x01 0x02 0x80 vector reaches libdovi");

    /* Success: libdovi's bytes, length-prefixed, mode 2, everything freed. */
    begin();
    ret = forward(&p7, rpu, sizeof(rpu));
    CHECK(ret == 1, "conversion appended");
    CHECK(fake.parses == 1 && fake.converts == 1 && fake.writes == 1, "parse, convert, write once");
    CHECK(fake.last_mode == 2, "conversion mode %d, expected 2", fake.last_mode);
    CHECK(sink.len == 4 + sizeof(fake_output) && sink.buf[3] == sizeof(fake_output) &&
          !memcmp(sink.buf + 4, fake_output, sizeof(fake_output)), "libdovi's output appended");
    CHECK(fake.live_rpus == 0 && fake.live_data == 0 && fake.rpu_frees == 1 && fake.data_frees == 1,
          "conversion frees its RPU and data");
    CHECK(nb_log == 0, "no log on success");

    /* Parsing returns nothing: only the stripped line. */
    begin();
    fake.parse_null = 1;
    expect_skip("parse returns null", forward(&p7, rpu, sizeof(rpu)), 1, 1, NULL, "(could not convert)");

    /* Parsing reports an error: stage line with libdovi's text, then stripped. */
    begin();
    fake.parse_error = "Invalid RPU last byte: 0";
    expect_skip("parse error", forward(&p7, rpu, sizeof(rpu)), 2, 2,
                "Invalid RPU last byte: 0", "(could not convert)");
    CHECK(fake.converts == 0 && fake.writes == 0, "parse error: no conversion");

    /* libdovi's start-bytes error has a line break: three warn events. */
    begin();
    fake.parse_error = "Invalid RPU data start bytes\n[124, 1, 25, 8, 0]";
    expect_skip("start bytes error", forward(&p7, rpu, sizeof(rpu)), 2, 3,
                "Invalid RPU data start bytes\n[124, 1, 25, 8, 0]", "(could not convert)");

    /* An error text from Vivid's patched libdovi: one line, two events. */
    begin();
    fake.parse_error = "reshaping mapping method 2 is not supported";
    expect_skip("patched libdovi error", forward(&p7, rpu, sizeof(rpu)), 2, 2,
                "reshaping mapping method 2 is not supported", "(could not convert)");

    /* Conversion fails, with and without a text. */
    begin();
    fake.convert_fail  = 1;
    fake.convert_error = "Failed converting with mode To 8.1: Invalid profile for mode To 8.1 conversion!";
    expect_skip("conversion error", forward(&p7, rpu, sizeof(rpu)), 2, 2,
                "Invalid profile for mode To 8.1 conversion!", "(could not convert)");
    CHECK(fake.writes == 0, "conversion error: nothing written");
    begin();
    fake.convert_fail = 1;
    expect_skip("conversion error, no text", forward(&p7, rpu, sizeof(rpu)), 2, 2,
                "unknown error", "(could not convert)");

    /* Writing fails. */
    begin();
    fake.write_fail  = 1;
    fake.write_error = "Failed writing byte buffer: mixed mapping methods";
    expect_skip("write error", forward(&p7, rpu, sizeof(rpu)), 2, 2,
                "Failed writing byte buffer: mixed mapping methods", "(could not convert)");
    begin();
    fake.write_fail = 1;
    expect_skip("write error, no text", forward(&p7, rpu, sizeof(rpu)), 2, 2,
                "unknown error", "(could not convert)");

    /* Too long for the 4-byte length prefix: only the stripped line. */
    begin();
    fake.write_len = (size_t)UINT32_MAX + 1;
    expect_skip("output too long", forward(&p7, rpu, sizeof(rpu)), 1, 1, NULL, "(could not convert)");
    CHECK(sink.calls == 0, "too long: append not attempted");

    /* Appending the converted RPU fails: only the stripped line. */
    begin();
    sink.fail = 1;
    expect_skip("converted append fails", forward(&p7, rpu, sizeof(rpu)), 1, 1, NULL,
                "(could not convert)");

    /* Native profiles: forwarded unchanged, libdovi never called. */
    begin();
    ret = forward(&p8, rpu, sizeof(rpu));
    CHECK(ret == 1 && sink.len == 4 + sizeof(rpu) && !memcmp(sink.buf + 4, rpu, sizeof(rpu)),
          "profile 8 RPU forwarded unchanged");
    CHECK(fake.parses == 0 && nb_log == 0, "profile 8: no libdovi, no log");
    begin();
    ret = forward(&p5, rpu, sizeof(rpu));
    CHECK(ret == 1 && sink.len == 4 + sizeof(rpu), "profile 5 RPU forwarded unchanged");
    begin();
    n = guard_vector(0, nal);
    ret = forward(&p8, nal, n);
    CHECK(ret == 1 && sink.len == 4 + n && fake.parses == 0,
          "the guard is for profile 7 only (D23)");
    begin();
    sink.fail = 1;
    expect_skip("native append fails", forward(&p8, rpu, sizeof(rpu)), 1, 1, NULL, "(could not append)");

    /* Several RPUs in one packet: a failed one drops only itself (D9). */
    begin();
    n = guard_vector(1, nal);
    CHECK(forward(&p7, nal, n) == 0, "first RPU (guard class) skipped");
    CHECK(forward(&p7, rpu, sizeof(rpu)) == 1, "second RPU still converted");
    CHECK(sink.len == 4 + sizeof(fake_output), "only the second RPU appended");
    CHECK(log_calls(AV_LOG_WARNING) == 2, "two warnings for the first RPU only");

    /* A plain stream forwards nothing. */
    begin();
    {
        FFVTDoviStream plain = stream(4, 6, 1, 1, 1, 2, 0);
        CHECK(forward(&plain, rpu, sizeof(rpu)) == 0 && sink.calls == 0 && nb_log == 0,
              "plain HEVC forwards nothing");
    }
}

#else /* real libdovi */

/* ------------------------------------------ byte identity with libdovi */

static uint8_t *read_file(const char *dir, const char *name, size_t *size)
{
    char path[4096];
    FILE *f;
    uint8_t *data;
    long len;

    snprintf(path, sizeof(path), "%s/%s", dir, name);
    f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        exit(1);
    }
    fseek(f, 0, SEEK_END);
    len = ftell(f);
    rewind(f);
    data = malloc(len > 0 ? len : 1);
    if (!data || fread(data, 1, len, f) != (size_t)len) {
        fprintf(stderr, "cannot read %s\n", path);
        exit(1);
    }
    fclose(f);
    *size = len;
    return data;
}

/* libdovi's test assets start with a 4-byte start code; the NAL unit as it
 * appears in a packet is the 2-byte header followed by the rest. */
static uint8_t *nal_from_asset(const char *dir, const char *name, size_t *size)
{
    size_t len;
    uint8_t *asset = read_file(dir, name, &len), *nal;

    if (len < 5 || memcmp(asset, "\x00\x00\x00\x01\x19", 5)) {
        fprintf(stderr, "%s: unexpected start\n", name);
        exit(1);
    }
    nal = malloc(len - 2);
    nal[0] = 0x7c;
    nal[1] = 0x01;
    memcpy(nal + 2, asset + 4, len - 4);
    *size = len - 2;
    free(asset);
    return nal;
}

static void test_conversion_identity(const char *dir)
{
    static const char *const samples[] = { "fel_orig.bin", "mel_orig.bin" };
    FFVTDoviStream p7 = stream(7, 6, 1, 1, 1, 6, 0);

    for (size_t i = 0; i < sizeof(samples) / sizeof(*samples); i++) {
        size_t size;
        uint8_t *nal = nal_from_asset(dir, samples[i], &size);
        DoviRpuOpaque *rpu = dovi_parse_unspec62_nalu(nal, size);
        const DoviData *expected;

        CHECK(rpu && !dovi_rpu_get_error(rpu), "%s: libdovi parses the sample", samples[i]);
        CHECK(dovi_convert_rpu_with_mode(rpu, 2) == 0, "%s: libdovi converts with mode 2", samples[i]);
        expected = dovi_write_unspec62_nalu(rpu);
        CHECK(expected && expected->len > 2, "%s: libdovi writes the conversion", samples[i]);

        sink_reset();
        log_reset();
        CHECK(!ff_vt_dovi_rpu_is_empty(nal, size), "%s: not the guard's class", samples[i]);
        CHECK(ff_vt_dovi_forward_rpu(NULL, &p7, nal, size, sink_append, NULL) == 1,
              "%s: FFmpeg appends the converted RPU", samples[i]);
        CHECK(nb_log == 0, "%s: no warnings", samples[i]);
        if (expected) {
            CHECK(sink.len == 4 + expected->len &&
                  !memcmp(sink.buf + 4, expected->data, expected->len),
                  "%s: appended bytes identical to libdovi 3.3.2 mode 2 (%zu vs %zu bytes)",
                  samples[i], sink.len >= 4 ? sink.len - 4 : 0, expected->len);
            CHECK(sink.buf[4] == 0x7c && sink.buf[5] == 0x01, "%s: output begins 0x7C 0x01", samples[i]);
            CHECK(expected->len != size || memcmp(expected->data, nal, size),
                  "%s: the conversion changed the RPU", samples[i]);
            dovi_data_free(expected);
        }
        dovi_rpu_free(rpu);
        free(nal);
    }
}

static void test_native_identity(const char *dir)
{
    static const struct { const char *name; int profile, compat; } samples[] = {
        { "profile5.bin", 5, 0 }, { "profile8.bin", 8, 1 }, { "profile84.bin", 8, 4 },
    };

    for (size_t i = 0; i < sizeof(samples) / sizeof(*samples); i++) {
        size_t size;
        uint8_t *nal = nal_from_asset(dir, samples[i].name, &size);
        FFVTDoviStream s = stream(samples[i].profile, 6, 1, 0, 1, samples[i].compat, 0);

        sink_reset();
        log_reset();
        CHECK(ff_vt_dovi_forward_rpu(NULL, &s, nal, size, sink_append, NULL) == 1 &&
              sink.len == 4 + size && !memcmp(sink.buf + 4, nal, size) && nb_log == 0,
              "%s: forwarded unchanged", samples[i].name);
        free(nal);
    }
}

static void test_guard_real(void)
{
    FFVTDoviStream p7 = stream(7, 6, 1, 1, 1, 6, 0);
    uint8_t nal[64];

    /* With unpatched libdovi 3.3.2 these would abort the process; the guard
     * keeps them away from it. */
    for (int v = 0; v < 3; v++) {
        size_t n = guard_vector(v, nal);
        sink_reset();
        log_reset();
        CHECK(ff_vt_dovi_forward_rpu(NULL, &p7, nal, n, sink_append, NULL) == 0 &&
              sink.len == 0 && log_calls(AV_LOG_WARNING) == 2,
              "guard vector %d skipped with two warnings", v);
    }
}

#endif

int main(int argc, char **argv)
{
    test_classification();
    test_records();
    test_colour_extensions();
    test_retry();
    test_nal_rules();
    test_guard_decisions();
    test_frame_tags();
#ifdef VT_DOVI_TEST_FAKE_LIBDOVI
    (void)argc;
    (void)argv;
    test_forwarding();
    printf("VideoToolbox Dolby Vision tests (scripted libdovi): ");
#else
    if (argc < 2) {
        fprintf(stderr, "usage: %s <vector folder>\n", argv[0]);
        return 2;
    }
    test_conversion_identity(argv[1]);
    test_native_identity(argv[1]);
    test_guard_real();
    printf("VideoToolbox Dolby Vision tests (libdovi 3.3.2): ");
#endif
    printf("%d checks, %d failed, %d messages logged\n", checks, failures, all_log);
    if (!checks) {
        fprintf(stderr, "no checks ran\n");
        return 1;
    }
    return failures ? 1 : 0;
}
