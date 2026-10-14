/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the event
 * log, and stand-ins for the mpv and FFmpeg functions the output's centre
 * and layers module call. Each records what it was asked to do.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libavutil/buffer.h>
#include <libavutil/hwcontext.h>

#include "options/m_config.h"
#include "osdep/timer.h"
#include "sub/osd.h"
#include "video/fmt-conversion.h"
#include "video/hwdec.h"
#include "video/mp_image.h"
#include "video/out/vo.h"

#include "fakes.h"

// ---- event log ----------------------------------------------------------------

#define EV_MAX 1024
#define EV_LEN 96

static char events[EV_MAX][EV_LEN];
static int num_events;

void ev_reset(void)
{
    num_events = 0;
}

void ev_add(const char *fmt, ...)
{
    if (num_events >= EV_MAX)
        return;
    va_list va;
    va_start(va, fmt);
    vsnprintf(events[num_events++], EV_LEN, fmt, va);
    va_end(va);
}

int ev_count(void)
{
    return num_events;
}

const char *ev_at(int i)
{
    return i >= 0 && i < num_events ? events[i] : "";
}

int ev_find(const char *prefix, int from)
{
    for (int i = from < 0 ? 0 : from; i < num_events; i++) {
        if (!strncmp(events[i], prefix, strlen(prefix)))
            return i;
    }
    return -1;
}

int ev_tally(const char *prefix)
{
    int n = 0;
    for (int i = 0; i < num_events; i++)
        n += !strncmp(events[i], prefix, strlen(prefix));
    return n;
}

void ev_dump(void)
{
    for (int i = 0; i < num_events; i++)
        printf("      event %d: %s\n", i, events[i]);
}

// ---- allocations the output frees with talloc_free() --------------------------

struct owned {
    void *ptr;
    void (*release)(void *ptr);
};

static struct owned owned[64];

static void own(void *ptr, void (*release)(void *ptr))
{
    for (int i = 0; i < 64; i++) {
        if (!owned[i].ptr) {
            owned[i] = (struct owned){ ptr, release };
            return;
        }
    }
    abort();
}

void ta_free(void *ptr)
{
    if (!ptr)
        return;
    for (int i = 0; i < 64; i++) {
        if (owned[i].ptr == ptr) {
            struct owned o = owned[i];
            owned[i] = (struct owned){0};
            o.release(o.ptr);
            return;
        }
    }
}

// ---- options ------------------------------------------------------------------

struct stub_state stubs;

// The option types the output's option table names. The stand-in cache never
// parses options, so their contents do not matter.
const m_option_type_t m_option_type_bool = { .name = "Flag" };
const m_option_type_t m_option_type_int = { .name = "Integer" };
const m_option_type_t m_option_type_choice = { .name = "Choice" };

void stubs_reset(void)
{
    free(stubs.pending_opts);
    stubs = (struct stub_state){0};
}

static void release_cache(void *ptr)
{
    struct m_config_cache *c = ptr;
    free(c->opts);
    free(c);
    stubs.cache_live = false;
}

struct m_config_cache *m_config_cache_alloc(void *ta_parent, struct mpv_global *global,
                                            const struct m_sub_options *group)
{
    const void *initial = stubs.initial_opts ? stubs.initial_opts : group->defaults;
    struct m_config_cache *c = calloc(1, sizeof(*c));
    c->opts = calloc(1, group->size);
    memcpy(c->opts, initial, group->size);
    free(stubs.pending_opts);
    stubs.pending_opts = calloc(1, group->size);
    memcpy(stubs.pending_opts, initial, group->size);
    stubs.group = group;
    stubs.cache_live = true;
    own(c, release_cache);
    return c;
}

void m_config_cache_set_wakeup_cb(struct m_config_cache *cache, void (*cb)(void *ctx),
                                  void *cb_ctx)
{
    stubs.wakeup_cb = cb;
    stubs.wakeup_ctx = cb_ctx;
}

bool m_config_cache_update(struct m_config_cache *cache)
{
    if (!stubs.options_changed)
        return false;
    stubs.options_changed = false;
    memcpy(cache->opts, stubs.pending_opts, stubs.group->size);
    return true;
}

// ---- video output core --------------------------------------------------------

void vo_wakeup(struct vo *vo)
{
    stubs.wakeups++;
}

void vo_set_queue_params(struct vo *vo, int64_t offset_ns, int num_req_frames)
{
    stubs.queue_calls++;
    stubs.queue_offset_ns = offset_ns;
    stubs.queue_frames = num_req_frames;
}

void vo_increment_drop_count(struct vo *vo, int64_t n)
{
    ev_add("drop_count +%lld", (long long)n);
    stubs.drops += (int)n;
}

// The whole image, letterboxed at the host layer's size; the OSD covers the
// layer.
void vo_get_src_dst_rects(struct vo *vo, struct mp_rect *out_src,
                          struct mp_rect *out_dst, struct mp_osd_res *out_osd)
{
    int w = vo->params ? vo->params->w : 0, h = vo->params ? vo->params->h : 0;
    *out_src = (struct mp_rect){ 0, 0, w, h };
    *out_dst = (struct mp_rect){ 0, 0, vo->dwidth, vo->dheight };
    *out_osd = (struct mp_osd_res){ .w = vo->dwidth, .h = vo->dheight, .display_par = 1.0 };
}

bool osd_res_equals(struct mp_osd_res a, struct mp_osd_res b)
{
    return a.w == b.w && a.h == b.h && a.ml == b.ml && a.mt == b.mt && a.mr == b.mr &&
           a.mb == b.mb && a.display_par == b.display_par;
}

static void release_list(void *ptr)
{
    free(ptr);
}

struct sub_bitmap_list *osd_render(struct osd_state *osd, struct mp_osd_res res,
                                   double video_pts, int draw_flags,
                                   const bool formats[SUBBITMAP_COUNT])
{
    ev_add("osd_render %dx%d", res.w, res.h);
    stubs.osd_renders++;
    stubs.osd_pts = video_pts;
    struct sub_bitmap_list *list = calloc(1, sizeof(*list));
    if (stubs.osd_list)
        *list = *stubs.osd_list;
    own(list, release_list);
    return list;
}

// ---- images -------------------------------------------------------------------

struct mp_image *mp_image_new_ref(struct mp_image *img)
{
    if (!img)
        return NULL;
    struct mp_image *ref = malloc(sizeof(*ref));
    *ref = *img;
    stubs.image_refs++;
    return ref;
}

void mp_image_unrefp(struct mp_image **p_img)
{
    if (*p_img) {
        free(*p_img);
        stubs.image_refs--;
    }
    *p_img = NULL;
}

// Two distinct formats for the 10-bit and 12-bit planar 4:2:0 software formats.
int pixfmt2imgfmt(enum AVPixelFormat pix_fmt)
{
    if (pix_fmt == AV_PIX_FMT_YUV420P10)
        return IMGFMT_END + 10;
    if (pix_fmt == AV_PIX_FMT_YUV420P12)
        return IMGFMT_END + 12;
    return 0;
}

// ---- time ---------------------------------------------------------------------

int64_t mp_time_ns(void)
{
    return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

void mp_sleep_ns(int64_t ns)
{
    struct timespec ts = { ns / 1000000000, ns % 1000000000 };
    nanosleep(&ts, NULL);
}

// ---- hardware decoding devices --------------------------------------------------

struct mp_hwdec_devices {
    int unused;
};

struct mp_hwdec_devices *hwdec_devices_create(void)
{
    ev_add("hwdec_devices_create");
    stubs.devices_live = true;
    return calloc(1, sizeof(struct mp_hwdec_devices));
}

void hwdec_devices_add(struct mp_hwdec_devices *devs, struct mp_hwdec_ctx *ctx)
{
    ev_add("hwdec_devices_add %s", ctx->driver_name);
    stubs.registered = ctx;
}

void hwdec_devices_remove(struct mp_hwdec_devices *devs, struct mp_hwdec_ctx *ctx)
{
    ev_add("hwdec_devices_remove %s", ctx->driver_name);
    if (stubs.registered == ctx)
        stubs.registered = NULL;
}

void hwdec_devices_destroy(struct mp_hwdec_devices *devs)
{
    ev_add("hwdec_devices_destroy");
    stubs.devices_live = false;
    free(devs);
}

AVBufferRef *av_hwdevice_ctx_alloc(enum AVHWDeviceType type)
{
    stubs.device_type = type;
    if (stubs.device_alloc_fails)
        return NULL;
    stubs.device_refs++;
    return calloc(1, sizeof(AVBufferRef));
}

int av_hwdevice_ctx_init(AVBufferRef *ref)
{
    return stubs.device_init_fails ? -1 : 0;
}

void av_buffer_unref(AVBufferRef **buf)
{
    if (buf && *buf) {
        ev_add("av_buffer_unref");
        free(*buf);
        stubs.device_refs--;
        *buf = NULL;
    }
}
