/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the ordered
 * event log, the fake layers module and the stand-ins for the mpv functions
 * the output's centre calls (vo_avfoundation.m).
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 *
 * The centre is compiled into the tests with every avf_layers_* call renamed
 * to fake_layers_* (fake_layers_rename.h), so it drives the fake below while
 * the real layers module is tested on its own (test_layers.m).
 */

#ifndef LUCID_VO_TEST_FAKES_H
#define LUCID_VO_TEST_FAKES_H

#include <stdbool.h>
#include <stdint.h>

#include <CoreMedia/CoreMedia.h>

struct mp_hwdec_ctx;
struct sub_bitmap_list;
struct m_sub_options;
struct mp_osd_res;

// ---- event log ----------------------------------------------------------------

void ev_reset(void);
void ev_add(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int ev_count(void);
const char *ev_at(int i);
// The index of the first event at or after `from` that starts with prefix,
// or -1.
int ev_find(const char *prefix, int from);
// How many events start with prefix.
int ev_tally(const char *prefix);
void ev_dump(void);

// ---- fake layers --------------------------------------------------------------

struct fake_layers_ctl {
    bool fail_create;
    bool host_ready;            // the host renderer's isReadyForMoreMediaData
    bool host_needs_recovery;
    bool sub_ready;
    bool has_sub_layer;
    int width, height;          // the host layer's pixel size
    bool resync, resize;        // raised by the observers, taken by the output
    CMTimebaseRef host_timebase;
    CMTimebaseRef sub_timebase;
    CMSampleBufferRef last_host, last_sub;  // the newest samples (retained)
    int host_enqueues, sub_enqueues, recoveries;
    bool alive;
};

extern struct fake_layers_ctl fake_layers;
void fake_layers_reset(void);

// ---- mpv stand-ins ------------------------------------------------------------

struct stub_state {
    int wakeups;
    int drops;
    int queue_calls;
    int64_t queue_offset_ns;
    int queue_frames;
    // osd_render() returns a copy of this list (or an empty one).
    const struct sub_bitmap_list *osd_list;
    int osd_renders;
    double osd_pts;
    // Option cache: the group the output registered, and new values the
    // next m_config_cache_update() takes when `options_changed` is set.
    const struct m_sub_options *group;
    const void *initial_opts;           // used instead of the defaults if set
    void *pending_opts;
    bool options_changed;
    bool cache_live;
    void (*wakeup_cb)(void *ctx);
    void *wakeup_ctx;
    // mp_image references made by the output and not yet released.
    int image_refs;
    // VideoToolbox device.
    bool device_alloc_fails, device_init_fails;
    int device_refs;
    int device_type;
    struct mp_hwdec_ctx *registered;
    bool devices_live;
    // The last message logged, and its level.
    int last_level;
    char last_message[256];
};

extern struct stub_state stubs;
void stubs_reset(void);

#endif
