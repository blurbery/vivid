/*
 * End-to-end host tests for Lucid Engine's VideoToolbox glue
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
 * `engine/lucid.py test` builds libavutil, libavcodec and libavformat for the
 * build host from the FFmpeg tree it has just patched, with only the HEVC
 * decoder and parser, the hevc_videotoolbox hwaccel, the raw HEVC demuxer
 * and the file protocol, under AddressSanitizer, and links this file against
 * them and the host build of Vivid's patched libdovi.
 *
 * This file defines VTDecompressionSessionCreate,
 * VTDecompressionSessionDecodeFrame,
 * VTDecompressionSessionWaitForAsynchronousFrames, VTSessionSetProperty and
 * VTDecompressionSessionInvalidate itself, so the linker binds libavcodec's
 * calls to these fakes; VideoToolbox.framework stays linked for its
 * constants. The fakes record every session, property and sample, and answer
 * each sample with a real CoreVideo buffer that already carries attachments
 * of the fake's own, as VideoToolbox's buffers do. So videotoolbox.c and
 * videotoolbox_dovi.c run exactly as on a device, apart from the decoding.
 *
 * The input, main10-64x64.hevc, is eight frames of a moving 10-bit ramp, two
 * IDR pictures each followed by three P pictures, signalled as BT.2020
 * primaries, PQ, BT.2020 non-constant luminance, top-left chroma siting and
 * square pixels. It was made once with x265 4.3:
 *
 *   x265 --input frames.yuv --input-res 64x64 --fps 24 --input-depth 10
 *        --output-depth 10 --profile main10 --frames 8 --keyint 4
 *        --min-keyint 4 --no-scenecut --no-open-gop --bframes 0 --no-info
 *        --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc
 *        --range limited --chromaloc 2 --sar 1:1 --frame-threads 1
 *        --pools none --no-wpp --output main10-64x64.hevc
 *
 * The test adds the Dolby Vision NAL units to each access unit as it reads
 * them: an RPU from libdovi's MIT test assets as the last NAL unit and, for
 * profile 7, a type 63 NAL unit before it. The configuration record goes in
 * the codec context's coded side data, as avcodec_parameters_to_context()
 * puts it there from a container.
 *
 * Every scenario runs at thread_count 1 and 4 with frame threading, as mpv
 * decodes with hwdec-threads 4. Checks are counted; the run fails on any
 * failed check or when none ran.
 *
 * argv[1]: main10-64x64.hevc; argv[2]: the assets/tests folder of libdovi.
 */

#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <libdovi/rpu_parser.h>

#include "libavcodec/avcodec.h"
#include "libavformat/avformat.h"
#include "libavutil/dovi_meta.h"
#include "libavutil/hwcontext.h"
#include "libavutil/hwcontext_videotoolbox.h"
#include "libavutil/log.h"
#include "libavutil/mem.h"
#include "libavutil/pixdesc.h"

#define CODEC_DVH1 ((CMVideoCodecType)0x64766831) /* 'dvh1' */
#define CODEC_HVC1 ((CMVideoCodecType)0x68766331) /* 'hvc1' */
#define STATUS_UNSUPPORTED_FORMAT ((OSStatus)-12910)

/* ------------------------------------------------------------ counting */

static int checks, failures;
static const char *current = "";

#define CHECK(cond, ...) check(!!(cond), __LINE__, __VA_ARGS__)

static int check(int ok, int line, const char *fmt, ...)
{
    va_list ap;

    checks++;
    if (ok)
        return 1;
    failures++;
    fprintf(stderr, "FAIL [%s] (line %d): ", current, line);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    return 0;
}

static void fourcc(CMVideoCodecType t, char out[5])
{
    out[0] = t >> 24;
    out[1] = t >> 16;
    out[2] = t >> 8;
    out[3] = t;
    out[4] = 0;
}

/* --------------------------------------------------------- fake VideoToolbox */

#define MAX_CREATES 8
#define MAX_SAMPLES 64
#define MAX_PROPS   16
#define MAX_BUFFERS 64

typedef struct FakeCreate {
    CMVideoCodecType codec;          /* of the format description */
    CFDictionaryRef spec;            /* decoder specification */
    CFDictionaryRef extensions;      /* the format description's extensions */
    CFDictionaryRef attrs;           /* destination buffer attributes */
    VTDecompressionOutputCallbackRecord cb;
    OSStatus status;
    int session;                     /* 1-based id, 0 when refused */
} FakeCreate;

typedef struct FakeSample {
    int session;
    CMVideoCodecType codec;
    uint8_t *data;
    size_t len, size_entry, size_entries;
    CMItemCount count;
} FakeSample;

typedef struct FakeProp {
    int session;
    CFStringRef key;
    CFTypeRef value;
} FakeProp;

/* The attachments each output buffer had when the fake handed it over. */
typedef struct FakeBuffer {
    CFDictionaryRef propagate;
    int dvh1;
} FakeBuffer;

static pthread_mutex_t vt_lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    /* script */
    OSStatus create_script[4];
    int nb_create_script;
    OSStatus prop_status;
    int null_image_at;               /* sample answered without an image */
    /* records */
    FakeCreate creates[MAX_CREATES];
    int nb_creates;
    FakeSample samples[MAX_SAMPLES];
    int nb_samples;
    FakeProp props[MAX_PROPS];
    int nb_props;
    int invalidated[MAX_CREATES];
    int nb_invalidated;
    FakeBuffer buffers[MAX_BUFFERS];
    int nb_buffers;
    int overflow, bad_session;
} vt;

static CFStringRef const kSerialKey = CFSTR("LucidFakeBufferSerial");
static CFStringRef const kRPUDataKey = CFSTR("DolbyVisionRPUData");

static void fake_reset(void)
{
    for (int i = 0; i < vt.nb_creates; i++) {
        FakeCreate *c = &vt.creates[i];
        if (c->spec)
            CFRelease(c->spec);
        if (c->extensions)
            CFRelease(c->extensions);
        if (c->attrs)
            CFRelease(c->attrs);
    }
    for (int i = 0; i < vt.nb_samples; i++)
        free(vt.samples[i].data);
    for (int i = 0; i < vt.nb_props; i++) {
        CFRelease(vt.props[i].key);
        if (vt.props[i].value)
            CFRelease(vt.props[i].value);
    }
    for (int i = 0; i < vt.nb_buffers; i++)
        CFRelease(vt.buffers[i].propagate);
    memset(&vt, 0, sizeof(vt));
    vt.null_image_at = -1;
}

static int session_id(CFTypeRef session)
{
    int id = 0;

    if (session && CFGetTypeID(session) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)session, kCFNumberIntType, &id);
    return id;
}

OSStatus VTDecompressionSessionCreate(CFAllocatorRef allocator,
                                      CMVideoFormatDescriptionRef format,
                                      CFDictionaryRef spec,
                                      CFDictionaryRef attrs,
                                      const VTDecompressionOutputCallbackRecord *cb,
                                      VTDecompressionSessionRef *out)
{
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(format);
    FakeCreate *c;
    OSStatus status;

    (void)allocator;
    *out = NULL;
    pthread_mutex_lock(&vt_lock);
    if (vt.nb_creates == MAX_CREATES) {
        vt.overflow = 1;
        pthread_mutex_unlock(&vt_lock);
        return kVTVideoDecoderMalfunctionErr;
    }
    status = vt.nb_creates < vt.nb_create_script ? vt.create_script[vt.nb_creates] : noErr;
    c = &vt.creates[vt.nb_creates++];
    c->codec      = CMFormatDescriptionGetMediaSubType(format);
    c->spec       = spec ? CFDictionaryCreateCopy(NULL, spec) : NULL;
    c->extensions = extensions ? CFDictionaryCreateCopy(NULL, extensions) : NULL;
    c->attrs      = attrs ? CFDictionaryCreateCopy(NULL, attrs) : NULL;
    if (cb)
        c->cb = *cb;
    c->status  = status;
    c->session = status == noErr ? vt.nb_creates : 0;
    if (c->session)
        *out = (VTDecompressionSessionRef)CFNumberCreate(NULL, kCFNumberIntType, &c->session);
    pthread_mutex_unlock(&vt_lock);
    return status;
}

OSStatus VTSessionSetProperty(VTSessionRef session, CFStringRef key, CFTypeRef value)
{
    OSStatus status;

    pthread_mutex_lock(&vt_lock);
    if (vt.nb_props < MAX_PROPS) {
        FakeProp *p = &vt.props[vt.nb_props++];
        p->session = session_id(session);
        p->key     = CFRetain(key);
        p->value   = value ? CFRetain(value) : NULL;
    } else {
        vt.overflow = 1;
    }
    status = vt.prop_status;
    pthread_mutex_unlock(&vt_lock);
    return status;
}

void VTDecompressionSessionInvalidate(VTDecompressionSessionRef session)
{
    pthread_mutex_lock(&vt_lock);
    if (vt.nb_invalidated < MAX_CREATES)
        vt.invalidated[vt.nb_invalidated++] = session_id(session);
    pthread_mutex_unlock(&vt_lock);
}

OSStatus VTDecompressionSessionWaitForAsynchronousFrames(VTDecompressionSessionRef session)
{
    return session_id(session) ? noErr : kVTInvalidSessionErr;
}

static int dict_int(CFDictionaryRef dict, CFStringRef key, int fallback)
{
    CFNumberRef n = dict ? CFDictionaryGetValue(dict, key) : NULL;
    int v = fallback;

    if (n && CFGetTypeID(n) == CFNumberGetTypeID())
        CFNumberGetValue(n, kCFNumberIntType, &v);
    return v;
}

static void set_par(CVBufferRef buffer, int h, int v)
{
    CFNumberRef nh = CFNumberCreate(NULL, kCFNumberIntType, &h);
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &v);
    const void *keys[] = { kCVImageBufferPixelAspectRatioHorizontalSpacingKey,
                           kCVImageBufferPixelAspectRatioVerticalSpacingKey };
    const void *values[] = { nh, nv };
    CFDictionaryRef par = CFDictionaryCreate(NULL, keys, values, 2,
                                             &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
    CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, par,
                          kCVAttachmentMode_ShouldPropagate);
    CFRelease(par);
    CFRelease(nh);
    CFRelease(nv);
}

/* A decoded buffer as VideoToolbox would return it: the requested format and
 * size, with attachments of its own that differ from the stream's signalling,
 * so FFmpeg's set, replace and remove paths all show. 'dvh1' sessions add
 * DolbyVisionRPUData, as Apple's Dolby Vision decoder does. */
static CVPixelBufferRef fake_output_buffer(const FakeCreate *c)
{
    OSType format = (OSType)dict_int(c->attrs, kCVPixelBufferPixelFormatTypeKey,
                                     kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    int width = dict_int(c->attrs, kCVPixelBufferWidthKey, 64);
    int height = dict_int(c->attrs, kCVPixelBufferHeightKey, 64);
    float gamma = 2.2f;
    CFNumberRef gamma_n, serial_n;
    CGColorSpaceRef srgb;
    CVPixelBufferRef pb = NULL;
    FakeBuffer *b;
    int serial;

    if (CVPixelBufferCreate(NULL, width, height, format, NULL, &pb) != kCVReturnSuccess || !pb) {
        fprintf(stderr, "could not create a %dx%d pixel buffer\n", width, height);
        exit(1);
    }
    CVBufferRemoveAllAttachments(pb);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey,
                          kCVImageBufferChromaLocation_Bottom, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey,
                          kCVImageBufferChromaLocation_Bottom, kCVAttachmentMode_ShouldPropagate);
    gamma_n = CFNumberCreate(NULL, kCFNumberFloat32Type, &gamma);
    CVBufferSetAttachment(pb, kCVImageBufferGammaLevelKey, gamma_n, kCVAttachmentMode_ShouldPropagate);
    CFRelease(gamma_n);
    srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CVBufferSetAttachment(pb, kCVImageBufferCGColorSpaceKey, srgb, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRelease(srgb);
    set_par(pb, 4, 3);
    if (c->codec == CODEC_DVH1) {
        static const uint8_t rpu[] = { 0x01, 0x02, 0x03, 0x04 };
        CFDataRef data = CFDataCreate(NULL, rpu, sizeof(rpu));
        CVBufferSetAttachment(pb, kRPUDataKey, data, kCVAttachmentMode_ShouldPropagate);
        CFRelease(data);
    }

    pthread_mutex_lock(&vt_lock);
    if (vt.nb_buffers == MAX_BUFFERS) {
        vt.overflow = 1;
        serial = MAX_BUFFERS - 1;
    } else {
        serial = vt.nb_buffers++;
        b = &vt.buffers[serial];
        b->propagate = CVBufferCopyAttachments(pb, kCVAttachmentMode_ShouldPropagate);
        b->dvh1      = c->codec == CODEC_DVH1;
    }
    pthread_mutex_unlock(&vt_lock);
    serial_n = CFNumberCreate(NULL, kCFNumberIntType, &serial);
    CVBufferSetAttachment(pb, kSerialKey, serial_n, kCVAttachmentMode_ShouldNotPropagate);
    CFRelease(serial_n);
    return pb;
}

OSStatus VTDecompressionSessionDecodeFrame(VTDecompressionSessionRef session,
                                           CMSampleBufferRef sample,
                                           VTDecodeFrameFlags flags,
                                           void *frame_refcon,
                                           VTDecodeInfoFlags *info_out)
{
    int id = session_id(session), index;
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    CMItemCount size_entries = 0;
    FakeCreate *c = NULL;
    CVPixelBufferRef pb;

    (void)flags;
    if (info_out)
        *info_out = 0;
    pthread_mutex_lock(&vt_lock);
    if (id >= 1 && id <= vt.nb_creates && vt.creates[id - 1].session == id)
        c = &vt.creates[id - 1];
    else
        vt.bad_session = 1;
    index = vt.nb_samples;
    if (vt.nb_samples < MAX_SAMPLES) {
        /* Copied now: the block wraps FFmpeg's bitstream buffer, which is
         * reused once this call returns. */
        FakeSample *s = &vt.samples[vt.nb_samples++];
        s->session = id;
        s->codec   = CMFormatDescriptionGetMediaSubType(CMSampleBufferGetFormatDescription(sample));
        s->len     = block ? CMBlockBufferGetDataLength(block) : 0;
        s->data    = malloc(s->len ? s->len : 1);
        if (!s->data)
            abort();
        if (s->len && CMBlockBufferCopyDataBytes(block, 0, s->len, s->data) != kCMBlockBufferNoErr)
            s->len = 0;
        s->size_entry = CMSampleBufferGetSampleSize(sample, 0);
        s->count      = CMSampleBufferGetNumSamples(sample);
        CMSampleBufferGetSampleSizeArray(sample, 0, NULL, &size_entries);
        s->size_entries = size_entries;
    } else {
        vt.overflow = 1;
    }
    pthread_mutex_unlock(&vt_lock);

    if (!c || !c->cb.decompressionOutputCallback)
        return kVTInvalidSessionErr;
    if (index == vt.null_image_at) {
        c->cb.decompressionOutputCallback(c->cb.decompressionOutputRefCon, frame_refcon,
                                          kVTVideoDecoderBadDataErr, 0, NULL,
                                          kCMTimeInvalid, kCMTimeInvalid);
        return noErr;
    }
    pb = fake_output_buffer(c);
    c->cb.decompressionOutputCallback(c->cb.decompressionOutputRefCon, frame_refcon, noErr, 0,
                                      pb, kCMTimeInvalid, kCMTimeInvalid);
    CVPixelBufferRelease(pb);
    return noErr;
}

/* --------------------------------------------------------------- av_log */

#define MAX_LOG 512

static struct {
    int  level;
    char text[512];
} logs[MAX_LOG];
static int nb_logs;
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

static const char *const fault_substrings[] = {
    "Too many packets", "queue overflow", "EOF", "End of file", "timed out",
    "Connection reset", "Error decoding", "Invalid data",
};

static void log_callback(void *avcl, int level, const char *fmt, va_list vl)
{
    char line[512];

    (void)avcl;
    if (level > AV_LOG_VERBOSE)
        return;
    vsnprintf(line, sizeof(line), fmt, vl);
    pthread_mutex_lock(&log_lock);
    if (nb_logs < MAX_LOG) {
        logs[nb_logs].level = level;
        snprintf(logs[nb_logs].text, sizeof(logs[nb_logs].text), "%s", line);
    }
    nb_logs++;
    pthread_mutex_unlock(&log_lock);
}

static int count_logs(int level, const char *needle)
{
    int n = 0;
    for (int i = 0; i < nb_logs && i < MAX_LOG; i++)
        n += logs[i].level == level && strstr(logs[i].text, needle) != NULL;
    return n;
}

/* ------------------------------------------------------------- inputs */

static uint8_t *read_file(const char *path, size_t *size)
{
    FILE *f = fopen(path, "rb");
    uint8_t *data;
    long len;

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

typedef struct Nal {
    uint8_t *data;
    size_t size;
} Nal;

/* An RPU from libdovi's assets (a 4-byte start code, then the NAL unit
 * without its header) as the escaped type 62 NAL unit a packet carries. */
static Nal rpu_asset(const char *dir, const char *name)
{
    char path[4096];
    size_t len;
    uint8_t *asset;
    Nal nal;

    snprintf(path, sizeof(path), "%s/%s", dir, name);
    asset = read_file(path, &len);
    if (len < 6 || memcmp(asset, "\x00\x00\x00\x01\x19", 5)) {
        fprintf(stderr, "%s: unexpected start\n", name);
        exit(1);
    }
    nal.size = len - 2;
    nal.data = malloc(nal.size);
    nal.data[0] = 0x7c;
    nal.data[1] = 0x01;
    memcpy(nal.data + 2, asset + 4, len - 4);
    free(asset);
    return nal;
}

/* A zero-filled profile 7 RPU of the class FFmpeg's guard keeps away from
 * libdovi (patch spec 9.4). Ending in zeros, it is the packet's last NAL. */
static const uint8_t guard_rpu[25] = { 0x7c, 0x01, 0x19, 0x08, 0x09, 0x80, 0x80 };

/* A type 63 (enhancement layer) NAL unit, as profile 7 dual-layer streams
 * interleave them. */
static const uint8_t el_nal[] = { 0x7e, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60, 0x80 };

/* libdovi's own profile 7 to 8.1 conversion of an RPU (mode 2). */
static Nal libdovi_convert(const Nal *in)
{
    DoviRpuOpaque *rpu = dovi_parse_unspec62_nalu(in->data, in->size);
    const DoviData *out = NULL;
    Nal nal = { 0 };

    if (rpu && !dovi_rpu_get_error(rpu) && dovi_convert_rpu_with_mode(rpu, 2) == 0)
        out = dovi_write_unspec62_nalu(rpu);
    if (out) {
        nal.size = out->len;
        nal.data = malloc(out->len);
        memcpy(nal.data, out->data, out->len);
        dovi_data_free(out);
    }
    dovi_rpu_free(rpu);
    return nal;
}

/* The access units of the stream, read with libavformat's raw HEVC demuxer. */
#define MAX_AUS 16
static AVPacket *aus[MAX_AUS];
static int nb_aus;

static void read_stream(const char *path)
{
    AVFormatContext *fmt = NULL;
    AVPacket *pkt = av_packet_alloc();

    if (avformat_open_input(&fmt, path, av_find_input_format("hevc"), NULL) < 0) {
        fprintf(stderr, "cannot open %s with the hevc demuxer\n", path);
        exit(1);
    }
    while (av_read_frame(fmt, pkt) >= 0) {
        if (nb_aus < MAX_AUS)
            aus[nb_aus++] = av_packet_clone(pkt);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    avformat_close_input(&fmt);
    CHECK(nb_aus == 8, "the stream has 8 access units (read %d)", nb_aus);
    for (int i = 0; i < nb_aus; i++)
        CHECK(!!(aus[i]->flags & AV_PKT_FLAG_KEY) == (i % 4 == 0), "access unit %d keyframe flag", i);
}

/* ------------------------------------------------------------ scenarios */

typedef struct Scenario {
    const char *name;
    int record;                         /* a configuration record is present */
    int profile, level, compat, el_flag, compression;
    const char *rpu;                    /* asset injected in every access unit */
    const char *second_rpu;             /* also in access unit 2, after the first */
    int guard_at;                       /* access unit whose RPU is guard_rpu */
    int el_nal;                         /* add a type 63 NAL unit */
    OSStatus create_script[2];
    int nb_create_script;
    OSStatus prop_status;
    int null_image_at;
    /* expectations */
    int dv;                             /* the first attempt is a 'dvh1' session */
    int final_dvh1;                     /* the session that decodes is 'dvh1' */
    int retried;                        /* exactly one plain HEVC retry */
    int refused;                        /* no session at all: software decoding */
    int restarts;                       /* session starts after the first */
    uint8_t record_bytes[5];            /* the expected record's first bytes */
    const char *atom;                   /* "dvcC", "dvvC" or NULL */
    int colour;                         /* 0 none, 1 PQ, 2 HLG */
} Scenario;

static Nal expected_rpu[MAX_AUS][2];
static int expected_rpus[MAX_AUS];

static AVPacket *inject(const Scenario *sc, int au, const Nal *first, const Nal *second)
{
    static const uint8_t start[3] = { 0, 0, 1 };
    AVPacket *src = aus[au], *pkt = av_packet_alloc();
    size_t size = src->size;
    Nal nals[3];
    int n = 0;
    uint8_t *p;

    if (sc->el_nal)
        nals[n++] = (Nal){ (uint8_t *)el_nal, sizeof(el_nal) };
    if (sc->rpu) {
        if (au == sc->guard_at)
            nals[n++] = (Nal){ (uint8_t *)guard_rpu, sizeof(guard_rpu) };
        else
            nals[n++] = *first;
    }
    if (sc->second_rpu && au == 2)
        nals[n++] = *second;
    for (int i = 0; i < n; i++)
        size += sizeof(start) + nals[i].size;
    if (av_new_packet(pkt, (int)size) < 0)
        abort();
    p = pkt->data;
    memcpy(p, src->data, src->size);
    p += src->size;
    for (int i = 0; i < n; i++) {
        memcpy(p, start, sizeof(start));
        memcpy(p + sizeof(start), nals[i].data, nals[i].size);
        p += sizeof(start) + nals[i].size;
    }
    pkt->pts   = src->pts;
    pkt->dts   = src->dts;
    pkt->flags = src->flags;
    return pkt;
}

static enum AVPixelFormat get_format(AVCodecContext *avctx, const enum AVPixelFormat *fmts)
{
    (void)avctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX)
            return *p;
    /* VideoToolbox could not be set up: decode in software, as mpv does. */
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (!(av_pix_fmt_desc_get(*p)->flags & AV_PIX_FMT_FLAG_HWACCEL))
            return *p;
    return AV_PIX_FMT_NONE;
}

/* ------------------------------------------------- attachment comparison */

static int same_value(CFTypeRef a, CFTypeRef b)
{
    if (CFGetTypeID(a) != CFGetTypeID(b))
        return 0;
    if (CFGetTypeID(a) == CGColorSpaceGetTypeID()) {
        CFStringRef na = CGColorSpaceCopyName((CGColorSpaceRef)a);
        CFStringRef nb = CGColorSpaceCopyName((CGColorSpaceRef)b);
        CFDataRef ia = CGColorSpaceCopyICCData((CGColorSpaceRef)a);
        CFDataRef ib = CGColorSpaceCopyICCData((CGColorSpaceRef)b);
        int same = (na == nb || (na && nb && CFEqual(na, nb))) &&
                   (ia == ib || (ia && ib && CFEqual(ia, ib)));
        if (na)
            CFRelease(na);
        if (nb)
            CFRelease(nb);
        if (ia)
            CFRelease(ia);
        if (ib)
            CFRelease(ib);
        return same;
    }
    return CFEqual(a, b);
}

static int same_attachments(CVBufferRef a, CVBufferRef b, CVAttachmentMode mode, char *why, size_t why_size)
{
    CFDictionaryRef da = CVBufferCopyAttachments(a, mode);
    CFDictionaryRef db = CVBufferCopyAttachments(b, mode);
    CFIndex na = da ? CFDictionaryGetCount(da) : 0, nb = db ? CFDictionaryGetCount(db) : 0;
    int same = na == nb;

    snprintf(why, why_size, "%ld keys against %ld", (long)na, (long)nb);
    if (same && na) {
        const void **keys = calloc(na, sizeof(*keys));
        const void **values = calloc(na, sizeof(*values));
        CFDictionaryGetKeysAndValues(da, keys, values);
        for (CFIndex i = 0; i < na && same; i++) {
            CFTypeRef other = CFDictionaryGetValue(db, keys[i]);
            if (!other || !same_value(values[i], other)) {
                char key[128] = "";
                CFStringGetCString(keys[i], key, sizeof(key), kCFStringEncodingUTF8);
                snprintf(why, why_size, "%s differs", key);
                same = 0;
            }
        }
        free(keys);
        free(values);
    }
    if (da)
        CFRelease(da);
    if (db)
        CFRelease(db);
    return same;
}

/* An attachment, autoreleased into the pool of the frame check. */
static CFTypeRef attachment(CVBufferRef buffer, CFStringRef key)
{
    CFTypeRef value = CVBufferCopyAttachment(buffer, key, NULL);
    return value ? CFAutorelease(value) : NULL;
}

/* What pristine FFmpeg makes of the same buffer: a twin with the attachments
 * the fake gave the decoded buffer, tagged by libavutil's own (unpatched)
 * av_vt_pixbuf_set_attachments() from the output frame. */
static void check_frame_attachments(const AVFrame *frame, int expect_dvh1)
{
    CVPixelBufferRef pb = (CVPixelBufferRef)frame->data[3], twin = NULL;
    CFNumberRef serial_n;
    int serial = -1, ret;
    char why[256];
    FakeBuffer *b;
    CFTypeRef v;

    if (!CHECK(pb != NULL, "frame has a pixel buffer"))
        return;
    serial_n = attachment(pb, kSerialKey);
    if (serial_n)
        CFNumberGetValue(serial_n, kCFNumberIntType, &serial);
    if (!CHECK(serial >= 0 && serial < vt.nb_buffers, "frame buffer came from the fake (%d)", serial))
        return;
    b = &vt.buffers[serial];
    CHECK(b->dvh1 == expect_dvh1, "frame decoded by a %s session", expect_dvh1 ? "'dvh1'" : "plain HEVC");

    CVPixelBufferCreate(NULL, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                        CVPixelBufferGetPixelFormatType(pb), NULL, &twin);
    if (!twin)
        abort();
    CVBufferRemoveAllAttachments(twin);
    CVBufferSetAttachments(twin, b->propagate, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(twin, kSerialKey, serial_n, kCVAttachmentMode_ShouldNotPropagate);
    ret = av_vt_pixbuf_set_attachments(NULL, twin, frame);
    CHECK(ret == 0, "pristine attachments for the twin");
    CHECK(same_attachments(pb, twin, kCVAttachmentMode_ShouldPropagate, why, sizeof(why)),
          "propagated attachments equal pristine FFmpeg's: %s", why);
    CHECK(same_attachments(pb, twin, kCVAttachmentMode_ShouldNotPropagate, why, sizeof(why)),
          "other attachments equal pristine FFmpeg's: %s", why);
    CVPixelBufferRelease(twin);

    /* The same outcome spelled out, as pristine produces it on macOS (the
     * colour space comes from pristine's macOS and iOS branch; on tvOS the
     * same function removes it). */
    v = attachment(pb, kCVImageBufferTransferFunctionKey);
    CHECK(v && CFEqual(v, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ), "transfer is the stream's PQ");
    v = attachment(pb, kCVImageBufferColorPrimariesKey);
    CHECK(v && CFEqual(v, kCVImageBufferColorPrimaries_ITU_R_2020), "primaries are the stream's BT.2020");
    v = attachment(pb, kCVImageBufferYCbCrMatrixKey);
    CHECK(v && CFEqual(v, kCVImageBufferYCbCrMatrix_ITU_R_2020), "matrix is the stream's BT.2020");
    v = attachment(pb, kCVImageBufferChromaLocationTopFieldKey);
    CHECK(v && CFEqual(v, kCVImageBufferChromaLocation_TopLeft), "chroma location is the stream's top left");
    v = attachment(pb, kCVImageBufferPixelAspectRatioKey);
    CHECK(v && CFGetTypeID(v) == CFDictionaryGetTypeID() &&
          dict_int(v, kCVImageBufferPixelAspectRatioHorizontalSpacingKey, 0) == 1 &&
          dict_int(v, kCVImageBufferPixelAspectRatioVerticalSpacingKey, 0) == 1,
          "pixel aspect is the stream's 1:1");
    CHECK(!attachment(pb, kCVImageBufferGammaLevelKey), "gamma removed");
    CHECK(attachment(pb, kCVImageBufferCGColorSpaceKey) != NULL, "colour space derived");
    v = attachment(pb, kCVImageBufferChromaLocationBottomFieldKey);
    CHECK(v && CFEqual(v, kCVImageBufferChromaLocation_Bottom), "bottom field chroma location untouched");
    CHECK(!!attachment(pb, kRPUDataKey) == expect_dvh1,
          "DolbyVisionRPUData %s", expect_dvh1 ? "kept" : "absent");
}

/* -------------------------------------------------------- sample checks */

static uint32_t be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3];
}

/* One sample: 4-byte length prefixes that end exactly at the block's end,
 * parameter sets and slices first, then exactly the expected RPUs, never a
 * type 63 NAL unit, and one sample size equal to the block length. */
static void check_sample(const FakeSample *s, int au, int with_rpus)
{
    size_t pos = 0;
    int nals = 0, vcl = 0, rpus = 0, el = 0, rpu_before_vcl = 0, last_vcl = -1;
    const uint8_t *rpu_data[4];
    size_t rpu_size[4];

    CHECK(s->count == 1, "AU %d: one sample (%ld)", au, (long)s->count);
    CHECK(s->size_entries == 1, "AU %d: one sample size entry (%zu)", au, s->size_entries);
    CHECK(s->size_entry == s->len && s->len > 0,
          "AU %d: CMSampleBufferGetSampleSize %zu equals the block length %zu", au, s->size_entry, s->len);
    while (pos + 4 <= s->len) {
        uint32_t size = be32(s->data + pos);
        const uint8_t *nal = s->data + pos + 4;
        int type;

        if (size < 2 || pos + 4 + size > s->len)
            break;
        type = (nal[0] >> 1) & 0x3f;
        if (type < 32) {
            vcl++;
            last_vcl = nals;
            rpu_before_vcl |= rpus > 0;
        } else if (type == 62) {
            if (rpus < 4) {
                rpu_data[rpus] = nal;
                rpu_size[rpus] = size;
            }
            rpus++;
        } else if (type == 63) {
            el++;
        }
        nals++;
        pos += 4 + size;
    }
    CHECK(pos == s->len, "AU %d: length prefixes end at the block length (%zu of %zu)", au, pos, s->len);
    CHECK(vcl >= 1, "AU %d: the sample holds its slice", au);
    CHECK(el == 0, "AU %d: no type 63 NAL unit (%d)", au, el);
    CHECK(!rpu_before_vcl && (rpus == 0 || last_vcl < nals - rpus),
          "AU %d: RPUs only after the slices", au);
    if (!with_rpus) {
        CHECK(rpus == 0, "AU %d: no RPU (%d)", au, rpus);
        return;
    }
    CHECK(rpus == expected_rpus[au], "AU %d: %d RPUs, expected %d", au, rpus, expected_rpus[au]);
    for (int i = 0; i < rpus && i < expected_rpus[au] && i < 2; i++)
        CHECK(rpu_size[i] == expected_rpu[au][i].size &&
              !memcmp(rpu_data[i], expected_rpu[au][i].data, rpu_size[i]),
              "AU %d: RPU %d has the expected bytes (%zu against %zu)", au, i, rpu_size[i],
              expected_rpu[au][i].size);
}

/* ------------------------------------------------------------- one run */

static void check_create(const FakeCreate *c, const Scenario *sc, int dv)
{
    CFDictionaryRef atoms;
    CFTypeRef v;
    char got[5];

    fourcc(c->codec, got);
    CHECK(c->codec == (dv ? CODEC_DVH1 : CODEC_HVC1), "session codec type %s", got);
    CHECK(c->spec && CFDictionaryGetValue(c->spec, kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder) == kCFBooleanTrue,
          "Enable-hardware key set");
    CHECK(c->spec && !CFDictionaryGetValue(c->spec, kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder),
          "no Require-hardware key");
    atoms = c->spec ? CFDictionaryGetValue(c->spec, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) : NULL;
    CHECK(atoms && CFGetTypeID(atoms) == CFDictionaryGetTypeID(), "atoms present");
    if (!atoms)
        return;
    v = CFDictionaryGetValue(atoms, CFSTR("hvcC"));
    CHECK(v && CFDataGetLength(v) > 23, "hvcC atom present");
    CHECK(CFDictionaryGetCount(atoms) == (dv ? 2 : 1), "%d atoms", (int)CFDictionaryGetCount(atoms));
    for (int k = 0; k < 2; k++) {
        CFStringRef key = k ? CFSTR("dvvC") : CFSTR("dvcC");
        CFDataRef data = CFDictionaryGetValue(atoms, key);
        int wanted = dv && sc->atom && !strcmp(sc->atom, k ? "dvvC" : "dvcC");
        uint8_t expected[24] = { 0 };

        if (!wanted) {
            CHECK(!data, "no %s atom", k ? "dvvC" : "dvcC");
            continue;
        }
        memcpy(expected, sc->record_bytes, 5);
        CHECK(data && CFDataGetLength(data) == 24 && !memcmp(CFDataGetBytePtr(data), expected, 24),
              "%s atom is the 24-byte record", sc->atom);
    }
    /* The colour extensions sit beside the atoms, and VideoToolbox sees them
     * in the format description too. */
    for (int k = 0; k < 2; k++) {
        CFDictionaryRef dict = k ? c->extensions : c->spec;
        int colour = dv ? sc->colour : 0;
        CFTypeRef pri = dict ? CFDictionaryGetValue(dict, kCMFormatDescriptionExtension_ColorPrimaries) : NULL;
        CFTypeRef trc = dict ? CFDictionaryGetValue(dict, kCMFormatDescriptionExtension_TransferFunction) : NULL;
        CFTypeRef mat = dict ? CFDictionaryGetValue(dict, kCMFormatDescriptionExtension_YCbCrMatrix) : NULL;
        const char *where = k ? "format description" : "decoder specification";

        if (!colour) {
            CHECK(!pri && !trc && !mat, "no colour extensions in the %s", where);
            continue;
        }
        CHECK(pri && CFEqual(pri, kCMFormatDescriptionColorPrimaries_ITU_R_2020), "BT.2020 primaries in the %s", where);
        CHECK(trc && CFEqual(trc, colour == 2 ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG :
                                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ),
              "%s transfer in the %s", colour == 2 ? "HLG" : "PQ", where);
        CHECK(mat && CFEqual(mat, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020), "BT.2020 matrix in the %s", where);
    }
}

static void run(const Scenario *sc, int threads, const char *assets)
{
    char name[128];
    AVCodecContext *avctx;
    AVBufferRef *device = NULL;
    AVFrame *frame = av_frame_alloc();
    Nal first = { 0 }, second = { 0 }, converted_first = { 0 }, converted_second = { 0 };
    int frames = 0, hw_frames = 0, errors = 0, ret;
    int converted = sc->record && sc->profile == 7;

    snprintf(name, sizeof(name), "%s, %d thread%s", sc->name, threads, threads == 1 ? "" : "s");
    current = name;
    fake_reset();
    nb_logs = 0;
    for (int i = 0; i < sc->nb_create_script; i++)
        vt.create_script[i] = sc->create_script[i];
    vt.nb_create_script = sc->nb_create_script;
    vt.prop_status      = sc->prop_status;
    vt.null_image_at    = sc->null_image_at;

    /* What VideoToolbox must receive after each access unit's slices. */
    if (sc->rpu)
        first = rpu_asset(assets, sc->rpu);
    if (sc->second_rpu)
        second = rpu_asset(assets, sc->second_rpu);
    if (converted) {
        converted_first = libdovi_convert(&first);
        CHECK(converted_first.size > 2, "libdovi converts %s", sc->rpu);
    }
    if (converted && sc->second_rpu)
        converted_second = libdovi_convert(&second);
    for (int au = 0; au < nb_aus; au++) {
        expected_rpus[au] = 0;
        if (!sc->rpu || au == sc->guard_at)
            ;
        else
            expected_rpu[au][expected_rpus[au]++] = converted ? converted_first : first;
        if (sc->second_rpu && au == 2)
            expected_rpu[au][expected_rpus[au]++] = converted ? converted_second : second;
    }

    avctx = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_HEVC));
    if (sc->record) {
        AVPacketSideData *sd = av_packet_side_data_new(&avctx->coded_side_data,
                                                       &avctx->nb_coded_side_data,
                                                       AV_PKT_DATA_DOVI_CONF,
                                                       sizeof(AVDOVIDecoderConfigurationRecord), 0);
        AVDOVIDecoderConfigurationRecord *rec = (AVDOVIDecoderConfigurationRecord *)sd->data;
        memset(rec, 0, sizeof(*rec));
        rec->dv_version_major              = 1;
        rec->dv_version_minor              = 0;
        rec->dv_profile                    = sc->profile;
        rec->dv_level                      = sc->level;
        rec->rpu_present_flag              = 1;
        rec->el_present_flag               = sc->el_flag;
        rec->bl_present_flag               = 1;
        rec->dv_bl_signal_compatibility_id = sc->compat;
        rec->dv_md_compression             = sc->compression;
    }
    if (av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) < 0)
        abort();
    avctx->hw_device_ctx = av_buffer_ref(device);
    avctx->get_format    = get_format;
    avctx->thread_count  = threads;
    avctx->thread_type   = FF_THREAD_FRAME;
    if (avcodec_open2(avctx, NULL, NULL) < 0)
        abort();

    /* Every access unit, then a flush; frames are taken whenever the
     * decoder has them, and always before a packet is sent again. */
    for (int au = 0, eof = 0; au <= nb_aus && !eof; au++) {
        AVPacket *pkt = au < nb_aus ? inject(sc, au, &first, &second) : NULL;
        int sent = 0;

        while (!sent && !eof) {
            ret = avcodec_send_packet(avctx, pkt);
            sent = ret != AVERROR(EAGAIN);
            if (ret < 0 && sent)
                errors++;
            while ((ret = avcodec_receive_frame(avctx, frame)) != AVERROR(EAGAIN)) {
                if (ret == AVERROR_EOF) {
                    eof = 1;
                    break;
                }
                if (ret < 0) {
                    errors++;
                    continue;
                }
                frames++;
                if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
                    hw_frames++;
                    @autoreleasepool {
                        check_frame_attachments(frame, sc->final_dvh1);
                    }
                }
                av_frame_unref(frame);
            }
        }
        av_packet_free(&pkt);
    }
    avcodec_free_context(&avctx);
    av_buffer_unref(&device);
    av_frame_free(&frame);

    /* Sessions. */
    CHECK(!vt.overflow && !vt.bad_session, "fake records complete, every sample on a live session");
    if (sc->refused) {
        CHECK(vt.nb_creates == 1, "one session attempt, no retry (%d)", vt.nb_creates);
        if (vt.nb_creates)
            check_create(&vt.creates[0], sc, sc->dv);
        CHECK(vt.nb_samples == 0, "no sample reaches VideoToolbox (%d)", vt.nb_samples);
        CHECK(vt.nb_invalidated == 0, "no session to invalidate (%d)", vt.nb_invalidated);
        CHECK(frames == nb_aus && hw_frames == 0, "%d software frames (%d from VideoToolbox)", frames, hw_frames);
        CHECK(vt.nb_props == 0, "no session properties");
    } else if (sc->retried) {
        CHECK(vt.nb_creates == 2, "two session attempts (%d)", vt.nb_creates);
        if (vt.nb_creates == 2) {
            check_create(&vt.creates[0], sc, 1);
            check_create(&vt.creates[1], sc, 0);
            CHECK(vt.creates[0].status == STATUS_UNSUPPORTED_FORMAT && vt.creates[1].status == noErr,
                  "refused first, then created");
            CHECK(vt.creates[0].attrs && vt.creates[1].attrs && CFEqual(vt.creates[0].attrs, vt.creates[1].attrs),
                  "same destination buffer attributes");
            CHECK(vt.creates[0].cb.decompressionOutputCallback == vt.creates[1].cb.decompressionOutputCallback &&
                  vt.creates[0].cb.decompressionOutputRefCon == vt.creates[1].cb.decompressionOutputRefCon,
                  "same output callback");
        }
        CHECK(vt.nb_props == 0, "no session properties after a retry (%d)", vt.nb_props);
        CHECK(vt.nb_invalidated == 1, "only the retried session invalidated (%d)", vt.nb_invalidated);
        CHECK(count_logs(AV_LOG_WARNING, "refused the Dolby Vision HEVC session (status -12910)") == 1,
              "one retry warning");
    } else {
        CHECK(vt.nb_creates == 1 + sc->restarts, "%d session starts (%d)", 1 + sc->restarts, vt.nb_creates);
        for (int i = 0; i < vt.nb_creates; i++)
            check_create(&vt.creates[i], sc, sc->dv);
        CHECK(vt.nb_invalidated == vt.nb_creates, "%d sessions invalidated (%d)",
              vt.nb_creates, vt.nb_invalidated);
        if (sc->final_dvh1) {
            /* Propagate on every OS the module builds for; Generate where the
             * running OS has it (macOS 14, iOS and tvOS 17). */
            CFStringRef keys[2] = { kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata };
            int per_session = 1;
            if (@available(macOS 14.0, *)) {
                keys[1] = kVTDecompressionPropertyKey_GeneratePerFrameHDRDisplayMetadata;
                per_session = 2;
            }
            CHECK(vt.nb_props == per_session * vt.nb_creates, "%d properties per session (%d)",
                  per_session, vt.nb_props);
            for (int i = 0; i < vt.nb_props; i++) {
                const FakeProp *p = &vt.props[i];
                CHECK(p->session == i / per_session + 1, "property %d on session %d", i, p->session);
                CHECK(CFEqual(p->key, keys[i % per_session]) && p->value == kCFBooleanTrue,
                      "per-frame HDR metadata property %d", i);
            }
            CHECK(count_logs(AV_LOG_VERBOSE, "Could not ask VideoToolbox to") == (sc->prop_status ? vt.nb_props : 0),
                  "a refused property is logged at verbose and ignored");
        } else {
            CHECK(vt.nb_props == 0, "no session properties for plain HEVC (%d)", vt.nb_props);
        }
        CHECK(count_logs(AV_LOG_WARNING, "refused the Dolby Vision HEVC session") == 0, "no retry warning");
    }
    CHECK(count_logs(AV_LOG_VERBOSE, "opening a Dolby Vision HEVC session") ==
          (sc->dv ? 1 + sc->restarts : 0), "path line once per session start");

    /* Samples and frames. */
    if (!sc->refused) {
        int expected_samples = nb_aus;
        CHECK(vt.nb_samples == expected_samples, "%d samples (%d)", expected_samples, vt.nb_samples);
        for (int i = 0; i < vt.nb_samples && i < nb_aus; i++) {
            const FakeSample *s = &vt.samples[i];
            char got[5];
            fourcc(s->codec, got);
            CHECK(s->codec == (sc->final_dvh1 ? CODEC_DVH1 : CODEC_HVC1), "sample %d described as %s", i, got);
            check_sample(s, i, sc->final_dvh1);
        }
        CHECK(hw_frames == frames && frames == nb_aus - (sc->null_image_at >= 0),
              "%d VideoToolbox frames out of %d", hw_frames, frames);
        /* An image-less callback fails that frame's decode and, as in
         * pristine FFmpeg, its output later ("No frame decoded?"). */
        CHECK(errors == 2 * (sc->null_image_at >= 0), "%d decoding errors", errors);
        CHECK(count_logs(AV_LOG_ERROR, "No frame decoded?") == (sc->null_image_at >= 0),
              "an image-less frame is reported once at output");
    }
    /* Every session that was created is invalidated exactly once, in order:
     * by a restart or when the decoder closes. */
    for (int i = 0, id = 0; i < vt.nb_creates; i++) {
        if (!vt.creates[i].session)
            continue;
        CHECK(id < vt.nb_invalidated && vt.invalidated[id] == vt.creates[i].session,
              "session %d invalidated in order", vt.creates[i].session);
        id++;
    }

    /* Warnings from the Dolby Vision code. */
    if (sc->guard_at >= 0 && sc->final_dvh1) {
        CHECK(count_logs(AV_LOG_WARNING, "not passed to libdovi") == 1, "one guard warning");
        CHECK(count_logs(AV_LOG_WARNING, "Dolby Vision RPU stripped (could not convert)") == 1,
              "one stripped warning");
    } else {
        CHECK(count_logs(AV_LOG_WARNING, "Dolby Vision RPU stripped") == 0, "no RPU stripped");
    }
    for (int i = 0; i < nb_logs && i < MAX_LOG; i++) {
        if (!strstr(logs[i].text, "Dolby Vision") && !strstr(logs[i].text, "VideoToolbox refused"))
            continue;
        for (size_t k = 0; k < sizeof(fault_substrings) / sizeof(*fault_substrings); k++)
            CHECK(!strstr(logs[i].text, fault_substrings[k]), "line has a fault substring: %s", logs[i].text);
    }

    free(first.data);
    free(second.data);
    free(converted_first.data);
    free(converted_second.data);
    fake_reset();
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        static const Scenario scenarios[] = {
            { .name = "profile 5", .record = 1, .profile = 5, .level = 6, .compat = 0,
              .rpu = "profile5.bin", .guard_at = -1, .null_image_at = -1,
              .dv = 1, .final_dvh1 = 1, .record_bytes = { 1, 0, 0x0a, 0x35, 0x00 }, .atom = "dvcC" },
            { .name = "profile 8.1, two RPUs in one access unit, compression 3", .record = 1,
              .profile = 8, .level = 6, .compat = 1, .compression = 3,
              .rpu = "profile8.bin", .second_rpu = "profile84.bin", .guard_at = -1, .null_image_at = -1,
              .dv = 1, .final_dvh1 = 1, .record_bytes = { 1, 0, 0x10, 0x35, 0x10 }, .atom = "dvvC",
              .colour = 1 },
            { .name = "profile 8.4, properties refused", .record = 1, .profile = 8, .level = 6, .compat = 4,
              .rpu = "profile84.bin", .guard_at = -1, .null_image_at = -1, .prop_status = -12900,
              .dv = 1, .final_dvh1 = 1, .record_bytes = { 1, 0, 0x10, 0x35, 0x40 }, .atom = "dvvC",
              .colour = 2 },
            { .name = "profile 7 FEL, guard-class RPU in access unit 5", .record = 1, .profile = 7,
              .level = 6, .compat = 6, .el_flag = 1, .rpu = "fel_orig.bin", .el_nal = 1, .guard_at = 5,
              .null_image_at = -1, .dv = 1, .final_dvh1 = 1,
              .record_bytes = { 1, 0, 0x10, 0x35, 0x10 }, .atom = "dvvC", .colour = 1 },
            { .name = "profile 8.1, restart after an image-less callback", .record = 1, .profile = 8,
              .level = 6, .compat = 1, .rpu = "profile8.bin", .guard_at = -1, .null_image_at = 2,
              .restarts = 1, .dv = 1, .final_dvh1 = 1, .record_bytes = { 1, 0, 0x10, 0x35, 0x10 },
              .atom = "dvvC", .colour = 1 },
            { .name = "plain HEVC with RPUs but no record", .rpu = "profile8.bin", .guard_at = -1,
              .null_image_at = -1 },
            { .name = "profile 8.1 refused, plain HEVC retry", .record = 1, .profile = 8, .level = 6,
              .compat = 1, .rpu = "profile8.bin", .guard_at = -1, .null_image_at = -1,
              .create_script = { STATUS_UNSUPPORTED_FORMAT }, .nb_create_script = 1,
              .dv = 1, .retried = 1, .record_bytes = { 1, 0, 0x10, 0x35, 0x10 }, .atom = "dvvC",
              .colour = 1 },
            { .name = "profile 7 refused, plain HEVC retry", .record = 1, .profile = 7, .level = 6,
              .compat = 6, .el_flag = 1, .rpu = "fel_orig.bin", .el_nal = 1, .guard_at = -1,
              .null_image_at = -1, .create_script = { STATUS_UNSUPPORTED_FORMAT }, .nb_create_script = 1,
              .dv = 1, .retried = 1, .record_bytes = { 1, 0, 0x10, 0x35, 0x10 }, .atom = "dvvC",
              .colour = 1 },
            { .name = "profile 5 refused, software decoding", .record = 1, .profile = 5, .level = 6,
              .rpu = "profile5.bin", .guard_at = -1, .null_image_at = -1,
              .create_script = { STATUS_UNSUPPORTED_FORMAT }, .nb_create_script = 1,
              .dv = 1, .refused = 1, .record_bytes = { 1, 0, 0x0a, 0x35, 0x00 }, .atom = "dvcC" },
        };
        static const int thread_counts[] = { 1, 4 };

        if (argc < 3) {
            fprintf(stderr, "usage: %s <main10-64x64.hevc> <libdovi assets/tests folder>\n", argv[0]);
            return 2;
        }
        av_log_set_callback(log_callback);
        read_stream(argv[1]);
        if (nb_aus != 8)
            return 1;
        for (size_t t = 0; t < sizeof(thread_counts) / sizeof(*thread_counts); t++)
            for (size_t i = 0; i < sizeof(scenarios) / sizeof(*scenarios); i++)
                run(&scenarios[i], thread_counts[t], argv[2]);
        for (int i = 0; i < nb_aus; i++)
            av_packet_free(&aus[i]);
    }
    printf("VideoToolbox glue tests (host libavcodec, fake VideoToolbox): %d checks, %d failed\n",
           checks, failures);
    if (!checks) {
        fprintf(stderr, "no checks ran\n");
        return 1;
    }
    return failures ? 1 : 0;
}
