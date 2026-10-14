/*
 * Host-side tests for Lucid Engine's AVFoundation video output: a fake of
 * video/out/avfoundation/layers.h that records every call in the event log
 * and answers from struct fake_layers_ctl, for the centre's tests.
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

#include "fake_layers_rename.h"
#include "video/out/avfoundation/layers.h"

#include "fakes.h"

struct fake_layers_ctl fake_layers;

struct avf_layers {
    int unused;
};

void fake_layers_reset(void)
{
    if (fake_layers.last_host)
        CFRelease(fake_layers.last_host);
    if (fake_layers.last_sub)
        CFRelease(fake_layers.last_sub);
    fake_layers = (struct fake_layers_ctl){
        .host_ready = true, .sub_ready = true, .width = 1280, .height = 720,
    };
}

static int64_t sample_pts(CMSampleBufferRef s)
{
    return CMSampleBufferGetPresentationTimeStamp(s).value;
}

static void keep(CMSampleBufferRef *slot, CMSampleBufferRef s)
{
    if (*slot)
        CFRelease(*slot);
    *slot = (CMSampleBufferRef)CFRetain(s);
}

struct avf_layers *avf_layers_create(struct mp_log *log, void *host_layer)
{
    ev_add("layers_create");
    if (fake_layers.fail_create)
        return NULL;
    fake_layers.alive = true;
    return calloc(1, sizeof(struct avf_layers));
}

void avf_layers_destroy(struct avf_layers *l)
{
    if (!l)
        return;
    ev_add("layers_destroy");
    fake_layers.alive = false;
    free(l);
}

void avf_layers_attach_timebase(struct avf_layers *l, CMTimebaseRef tb)
{
    CMTime t = CMTimebaseGetTime(tb);
    ev_add("attach_timebase rate=%g time=%lld", CMTimebaseGetRate(tb),
           (long long)CMTimeConvertScale(t, 1000000000, kCMTimeRoundingMethod_Default).value);
    fake_layers.host_timebase = tb;
}

void avf_layers_read_geometry(struct avf_layers *l, int *w, int *h)
{
    ev_add("read_geometry");
    *w = fake_layers.width;
    *h = fake_layers.height;
}

void avf_layers_create_subtitle_layer(struct avf_layers *l, CMTimebaseRef tb)
{
    ev_add("create_subtitle_layer");
    fake_layers.has_sub_layer = true;
    fake_layers.sub_timebase = tb;
}

void avf_layers_observe_app_state(struct avf_layers *l, struct vo *vo)
{
    ev_add("observe_app_state");
}

void avf_layers_observe_geometry(struct avf_layers *l, struct vo *vo)
{
    ev_add("observe_geometry");
}

bool avf_layers_take_resync(struct avf_layers *l)
{
    bool v = fake_layers.resync;
    fake_layers.resync = false;
    return v;
}

bool avf_layers_take_resize(struct avf_layers *l)
{
    bool v = fake_layers.resize;
    fake_layers.resize = false;
    return v;
}

bool avf_layers_has_subtitle_layer(struct avf_layers *l)
{
    return fake_layers.has_sub_layer;
}

void avf_layers_copy_frame_async(struct avf_layers *l)
{
    ev_add("copy_frame_async");
}

void avf_layers_flush_subtitles_async(struct avf_layers *l)
{
    ev_add("flush_subtitles_async");
}

void avf_layers_flush_subtitles(struct avf_layers *l, bool remove_image)
{
    ev_add("flush_subtitles remove=%d", remove_image);
}

bool avf_layers_subtitles_ready(struct avf_layers *l)
{
    return fake_layers.has_sub_layer && fake_layers.sub_ready;
}

void avf_layers_enqueue_subtitles(struct avf_layers *l, CMSampleBufferRef s)
{
    ev_add("enqueue_subtitles pts=%lld", (long long)sample_pts(s));
    keep(&fake_layers.last_sub, s);
    fake_layers.sub_enqueues++;
}

void avf_layers_flush_host(struct avf_layers *l, bool remove_image)
{
    ev_add("flush_host remove=%d", remove_image);
}

bool avf_layers_host_ready(struct avf_layers *l)
{
    return fake_layers.host_ready;
}

bool avf_layers_host_needs_recovery(struct avf_layers *l)
{
    return fake_layers.host_needs_recovery;
}

void avf_layers_enqueue_host(struct avf_layers *l, CMSampleBufferRef s)
{
    ev_add("enqueue_host pts=%lld", (long long)sample_pts(s));
    keep(&fake_layers.last_host, s);
    fake_layers.host_enqueues++;
}

void avf_layers_recover(struct avf_layers *l, CMTimebaseRef tb,
                        struct avf_recovery_state *out)
{
    ev_add("recover");
    fake_layers.recoveries++;
    fake_layers.host_needs_recovery = false;
    *out = (struct avf_recovery_state){ .status = 1, .ready = fake_layers.host_ready,
                                        .timebase_s = NAN, .timebase_rate = 0 };
}

void avf_layers_remove_observers(struct avf_layers *l)
{
    ev_add("remove_observers");
}

void avf_layers_flush_for_teardown(struct avf_layers *l)
{
    ev_add("flush_for_teardown");
}

void avf_layers_detach_timebase(struct avf_layers *l)
{
    ev_add("detach_timebase");
    fake_layers.host_timebase = NULL;
    fake_layers.sub_timebase = NULL;
}

void avf_layers_remove_subtitle_layer(struct avf_layers *l)
{
    ev_add("remove_subtitle_layer");
    fake_layers.has_sub_layer = false;
}
