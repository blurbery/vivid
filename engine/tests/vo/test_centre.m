/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the centre,
 * video/out/vo_avfoundation.m of the patched mpv tree, compiled here with its
 * layer calls going to the fake layers module, a real CoreMedia timebase and
 * the real frame, subtitle, timing and pacing modules. Scripted frames drive
 * it through the driver's entry points (spec 4.8 to 4.16, 9.4).
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include "fake_layers_rename.h"
#include "video/out/vo_avfoundation.m"

#include "fakes.h"
#include "harness.h"

#define MS 1000000LL

struct harness_vo {
    struct vo vo;
    struct mp_vo_opts opts;
    struct mp_image_params params;
    struct avf_opts initial;
    int osd_token;
};

static struct avf_opts make_opts(bool host, bool composite)
{
    struct avf_opts o = *(const struct avf_opts *)avf_conf.defaults;
    o.presentation = host ? AVF_PRESENT_HOST : AVF_PRESENT_MEDIA;
    o.pip_composite_osd = composite;
    return o;
}

// Creates a VO the way mpv does (preinit, then reconfig). Returns preinit's
// result; on success the VO is ready for frames.
static int open_vo(struct harness_vo *h, bool host, bool composite)
{
    memset(h, 0, sizeof(*h));
    stubs_reset();
    fake_layers_reset();
    ev_reset();
    h->initial = make_opts(host, composite);
    stubs.initial_opts = &h->initial;
    h->vo.driver = &video_out_avfoundation;
    h->vo.priv = calloc(1, video_out_avfoundation.priv_size);
    h->vo.opts = &h->opts;
    h->opts.WinID = 0x5a5a00;
    h->vo.osd = (struct osd_state *)&h->osd_token;
    h->params = (struct mp_image_params){ .imgfmt = IMGFMT_VIDEOTOOLBOX, .w = 320,
                                          .h = 180, .p_w = 1, .p_h = 1 };
    int r = video_out_avfoundation.preinit(&h->vo);
    if (r < 0)
        return r;
    h->vo.params = &h->params;
    video_out_avfoundation.reconfig(&h->vo, &h->params);
    return r;
}

static void close_vo(struct harness_vo *h)
{
    video_out_avfoundation.uninit(&h->vo);
    free(h->vo.priv);
    h->vo.priv = NULL;
}

static struct priv *privof(struct harness_vo *h)
{
    return h->vo.priv;
}

struct test_image {
    struct mp_image img;
    CVPixelBufferRef buf;
};

static CVPixelBufferRef new_buffer(int w, int h)
{
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    CVPixelBufferRef buf = NULL;
    CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        (CFDictionaryRef)attrs, &buf);
    return buf;
}

// A VideoToolbox frame at pts seconds (a NULL buffer when `broken`).
static void make_image(struct test_image *t, double pts, bool broken)
{
    memset(t, 0, sizeof(*t));
    t->buf = broken ? NULL : new_buffer(320, 180);
    t->img.imgfmt = IMGFMT_VIDEOTOOLBOX;
    t->img.w = 320;
    t->img.h = 180;
    t->img.planes[3] = (uint8_t *)t->buf;
    t->img.pts = pts;
    t->img.params = (struct mp_image_params){ .imgfmt = IMGFMT_VIDEOTOOLBOX, .w = 320,
                                              .h = 180, .p_w = 1, .p_h = 1 };
}

static void free_image(struct test_image *t)
{
    if (t->buf)
        CVPixelBufferRelease(t->buf);
    t->buf = NULL;
}

// One frame through draw_frame and flip_page, due at target_ns (0: now, as a
// redraw arrives).
static void show(struct harness_vo *h, struct mp_image *img, int64_t target_ns,
                 bool redraw)
{
    struct vo_frame f = { .pts = target_ns, .duration = 40e6, .current = img,
                          .redraw = redraw };
    video_out_avfoundation.draw_frame(&h->vo, &f);
    video_out_avfoundation.flip_page(&h->vo);
}

static int request(struct harness_vo *h, uint32_t what)
{
    return video_out_avfoundation.control(&h->vo, what, NULL);
}

// One libass subtitle object with a single opaque part.
struct cue {
    struct sub_bitmaps imgs;
    struct sub_bitmap part;
    uint8_t mask[64 * 16];
    struct sub_bitmaps *items[1];
    struct sub_bitmap_list list;
};

static void make_cue(struct cue *c, int change_id)
{
    memset(c, 0, sizeof(*c));
    memset(c->mask, 255, sizeof(c->mask));
    c->part = (struct sub_bitmap){ .bitmap = c->mask, .stride = 64, .w = 64, .h = 16,
                                   .x = 20, .y = 30, .dw = 64, .dh = 16 };
    c->part.libass.color = 0xFFFFFF00;
    c->imgs = (struct sub_bitmaps){ .render_index = 0, .format = SUBBITMAP_LIBASS,
                                    .parts = &c->part, .num_parts = 1,
                                    .change_id = change_id };
    c->items[0] = &c->imgs;
    c->list = (struct sub_bitmap_list){ .change_id = change_id, .w = 1280, .h = 720,
                                        .items = c->items, .num_items = 1 };
}

static int64_t timebase_ns(struct harness_vo *h)
{
    CMTime t = CMTimebaseGetTime(privof(h)->timebase);
    return CMTimeConvertScale(t, 1000000000, kCMTimeRoundingMethod_Default).value;
}

static double timebase_rate(struct harness_vo *h)
{
    return CMTimebaseGetRate(privof(h)->timebase);
}

// Whether the events with these prefixes occur in this order.
static bool in_order(const char *const *names, int n, int from)
{
    int at = from;
    for (int i = 0; i < n; i++) {
        at = ev_find(names[i], at);
        if (at < 0)
            return false;
        at++;
    }
    return true;
}

#define IN_ORDER(from, ...) \
    in_order((const char *const[]){ __VA_ARGS__ }, \
             sizeof((const char *const[]){ __VA_ARGS__ }) / sizeof(const char *), from)

// ---- creation and teardown ----------------------------------------------------

static void test_lifecycle(void)
{
    struct harness_vo h;

    CASE("creation-order-media");
    CHECK(open_vo(&h, false, false) == 0, "creation failed");
    CHECK(IN_ORDER(0, "layers_create", "attach_timebase rate=0 time=0", "read_geometry",
                   "create_subtitle_layer", "hwdec_devices_create",
                   "hwdec_devices_add avfoundation", "observe_app_state", "observe_geometry"),
          "creation steps out of order");
    CHECK(stubs.group == &avf_conf && !strcmp(avf_conf.prefix, "avfoundation"),
          "option group");
    CHECK(stubs.wakeup_cb == wakeup_cb && stubs.wakeup_ctx == &h.vo, "option wakeup");
    CHECK(stubs.queue_calls == 1 && stubs.queue_offset_ns == 128 * MS &&
          stubs.queue_frames == 1, "queue parameters");
    CHECK(stubs.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX && stubs.registered &&
          stubs.registered->hw_imgfmt == IMGFMT_VIDEOTOOLBOX &&
          stubs.registered->av_device_ref, "VideoToolbox device entry");
    CHECK(h.vo.dwidth == 1280 && h.vo.dheight == 720 && h.vo.monitor_par == 1.0,
          "host geometry not reported");
    CHECK(fake_layers.sub_timebase == privof(&h)->timebase &&
          fake_layers.host_timebase == privof(&h)->timebase, "timebase not shared");

    CASE("teardown-order");
    ev_reset();
    close_vo(&h);
    CHECK(IN_ORDER(0, "remove_observers", "flush_for_teardown", "detach_timebase",
                   "remove_subtitle_layer", "hwdec_devices_remove avfoundation",
                   "av_buffer_unref", "hwdec_devices_destroy", "layers_destroy"),
          "teardown steps out of order");
    CHECK(!h.vo.hwdec_devs && !stubs.devices_live && stubs.device_refs == 0,
          "device list not freed");
    CHECK(!stubs.cache_live, "option cache not freed");
    CHECK(stubs.image_refs == 0, "image references left");
    if (ev_tally("") && stubs.device_refs)
        ev_dump();

    CASE("creation-order-host");
    CHECK(open_vo(&h, true, false) == 0, "creation failed");
    int at = ev_find("attach_timebase rate=1 ", 0);
    CHECK(at >= 0, "host mode did not seed the timebase at rate 1 before attaching it");
    CHECK(llabs(timebase_ns(&h) - mp_time_ns()) < 50 * MS, "host timebase off the host clock");
    close_vo(&h);

    CASE("creation-failures");
    memset(&h, 0, sizeof(h));
    stubs_reset();
    fake_layers_reset();
    ev_reset();
    h.vo.priv = calloc(1, video_out_avfoundation.priv_size);
    h.vo.opts = &h.opts;
    h.opts.WinID = -1;
    CHECK(video_out_avfoundation.preinit(&h.vo) < 0, "no layer accepted");
    CHECK(stubs.last_level == MSGL_ERR, "no layer: level %d", stubs.last_level);
    CHECK(ev_count() == 0 && !stubs.cache_live, "no layer left something behind");
    h.vo.probing = true;
    CHECK(video_out_avfoundation.preinit(&h.vo) < 0, "no layer accepted while probing");
    CHECK(stubs.last_level == MSGL_V, "probing: level %d", stubs.last_level);
    free(h.vo.priv);

    fake_layers.fail_create = true;
    h.vo.priv = calloc(1, video_out_avfoundation.priv_size);
    h.vo.probing = false;
    h.opts.WinID = 0x5a5a00;
    CHECK(video_out_avfoundation.preinit(&h.vo) < 0, "creation did not fail");
    CHECK(!stubs.cache_live, "option cache left after a failed creation");
    CHECK(ev_find("attach_timebase", 0) < 0 && ev_find("hwdec_devices_create", 0) < 0 &&
          !fake_layers.alive, "a failed creation went on");
    free(h.vo.priv);

    CASE("device-failure-still-registers");
    fake_layers_reset();
    CHECK(open_vo(&h, false, false) == 0, "creation failed");
    close_vo(&h);
    stubs_reset();
    fake_layers_reset();
    stubs.device_init_fails = true;
    struct avf_opts o = make_opts(false, false);
    stubs.initial_opts = &o;
    memset(&h, 0, sizeof(h));
    h.vo.priv = calloc(1, video_out_avfoundation.priv_size);
    h.vo.opts = &h.opts;
    h.opts.WinID = 0x5a5a00;
    h.vo.osd = (struct osd_state *)&h.osd_token;
    CHECK(video_out_avfoundation.preinit(&h.vo) == 0, "creation failed");
    CHECK(stubs.registered && !stubs.registered->av_device_ref && stubs.device_refs == 0,
          "entry without a device not added, or the device kept");
    CHECK(stubs.last_level == MSGL_ERR || ev_find("hwdec_devices_add", 0) >= 0,
          "device failure");
    close_vo(&h);
}

// ---- frames ---------------------------------------------------------------------

static void test_frame_order(void)
{
    struct harness_vo h;
    struct test_image a, b;
    struct cue cue;

    CASE("subtitle-sample-just-before-video");
    CHECK(open_vo(&h, false, false) == 0, "creation failed");
    make_cue(&cue, 7);
    stubs.osd_list = &cue.list;
    make_image(&a, 1.5, false);
    ev_reset();
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    int sub_at = ev_find("enqueue_subtitles", 0), host_at = ev_find("enqueue_host", 0);
    CHECK(sub_at >= 0 && host_at == sub_at + 1, "subtitle sample not just before the video");
    CHECK(!strcmp(ev_at(sub_at), "enqueue_subtitles pts=1500000000") &&
          !strcmp(ev_at(host_at), "enqueue_host pts=1500000000"),
          "samples at %s / %s", ev_at(sub_at), ev_at(host_at));
    CHECK(ev_find("osd_render", 0) >= 0 && ev_find("osd_render", 0) < sub_at,
          "subtitles not rendered first");
    CHECK(stubs.osd_pts == 1.5, "osd_render pts %f", stubs.osd_pts);
    CHECK(stubs.image_refs == 0, "held image not released after the flip");

    CASE("unchanged-cue-no-new-sample");
    ev_reset();
    make_image(&b, 1.54, false);
    show(&h, &b.img, mp_time_ns() + 30 * MS, false);
    CHECK(ev_tally("enqueue_subtitles") == 0 && ev_tally("enqueue_host") == 1,
          "unchanged cue enqueued again");

    CASE("drop-enqueues-nothing");
    fake_layers.host_ready = false;
    make_cue(&cue, 8);                  // a new cue is due with the dropped frame
    unsigned renders = avf_subs_perf(privof(&h)->subs)->renders;
    ev_reset();
    show(&h, &a.img, 0, true);          // a redraw: its target is now
    CHECK(ev_tally("enqueue_") == 0, "something enqueued on a drop");
    CHECK(stubs.drops == 1 && ev_tally("drop_count +1") == 1, "drop count %d", stubs.drops);
    CHECK(timebase_rate(&h) == 1.0, "timebase touched on a drop");
    // The cue that missed its frame is rendered again with the next one.
    fake_layers.host_ready = true;
    ev_reset();
    show(&h, &b.img, mp_time_ns() + 30 * MS, false);
    CHECK(avf_subs_perf(privof(&h)->subs)->renders == renders + 2,
          "the dropped frame's cue was not rendered again (%u renders)",
          avf_subs_perf(privof(&h)->subs)->renders - renders);
    CHECK(ev_tally("enqueue_subtitles") == 1 && ev_tally("enqueue_host") == 1,
          "the cue did not follow on the next frame");

    CASE("one-drop-count-per-deadline-drop");
    fake_layers.host_ready = false;
    stubs.drops = 0;
    ev_reset();
    for (int i = 0; i < 4; i++)
        show(&h, &a.img, mp_time_ns() + 2 * MS, false);   // already past the give-up
    CHECK(stubs.drops == 4 && ev_tally("drop_count +1") == 4, "drop count %d", stubs.drops);
    fake_layers.host_ready = true;

    CASE("failed-frame-resets-tracking");
    make_cue(&cue, 9);
    struct test_image broken;
    make_image(&broken, 1.6, true);
    renders = avf_subs_perf(privof(&h)->subs)->renders;
    ev_reset();
    show(&h, &broken.img, mp_time_ns() + 30 * MS, false);
    CHECK(ev_tally("enqueue_") == 0, "a frame without a buffer enqueued something");
    show(&h, &b.img, mp_time_ns() + 30 * MS, false);
    CHECK(avf_subs_perf(privof(&h)->subs)->renders == renders + 2,
          "a due cue was not rendered again after a failed frame");
    CHECK(ev_tally("enqueue_subtitles") == 1, "the cue was not enqueued with the next frame");

    stubs.osd_list = NULL;
    close_vo(&h);
    free_image(&a);
    free_image(&b);
}

// ---- seeks, pauses and the timebase ---------------------------------------------

static void test_reset_and_pause(void)
{
    struct harness_vo h;
    struct test_image a;
    make_image(&a, 12.0, false);

    for (int host = 0; host < 2; host++) {
        CASE(host ? "reset-order-host" : "reset-order-media");
        CHECK(open_vo(&h, host, false) == 0, "creation failed");
        show(&h, &a.img, mp_time_ns() + 30 * MS, false);
        ev_reset();
        CHECK(request(&h, VOCTRL_RESET) == VO_TRUE, "reset");
        CHECK(IN_ORDER(0, "flush_subtitles_async", "flush_host remove=0",
                       "flush_subtitles remove=1"), "reset steps out of order");
        CHECK(ev_tally("enqueue_") == 0, "reset enqueued something");
        if (host) {
            CHECK(timebase_rate(&h) == 1.0, "host reseed rate %f", timebase_rate(&h));
            CHECK(llabs(timebase_ns(&h) - mp_time_ns()) < 50 * MS, "host reseed time");
        } else {
            CHECK(timebase_rate(&h) == 0.0, "media reseed rate %f", timebase_rate(&h));
            CHECK(timebase_ns(&h) == 0, "media reseed time %lld", (long long)timebase_ns(&h));
            CHECK(!privof(&h)->clock.anchor_valid, "anchor survived the reset");
        }
        close_vo(&h);
    }

    CASE("pause-and-resume-media");
    CHECK(open_vo(&h, false, false) == 0, "creation failed");
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    CHECK(timebase_rate(&h) == 1.0, "playing rate %f", timebase_rate(&h));
    CHECK(request(&h, VOCTRL_PAUSE) == VO_TRUE, "pause");
    CHECK(timebase_rate(&h) == 0.0, "paused rate %f", timebase_rate(&h));
    show(&h, &a.img, 0, true);          // the paused redraw holds the frame
    CHECK(timebase_rate(&h) == 0.0, "redraw while paused moved the timebase");
    CHECK(llabs(timebase_ns(&h) - 12 * 1000 * MS) < 5 * MS, "paused at %lld",
          (long long)timebase_ns(&h));
    CHECK(request(&h, VOCTRL_RESUME) == VO_TRUE, "resume");
    CHECK(!privof(&h)->clock.anchor_valid, "resume kept the anchor");
    struct test_image b;
    make_image(&b, 12.04, false);
    show(&h, &b.img, mp_time_ns() + 30 * MS, false);
    CHECK(timebase_rate(&h) == 1.0, "resumed rate %f", timebase_rate(&h));
    close_vo(&h);
    free_image(&b);

    CASE("pause-ignored-in-host-mode");
    CHECK(open_vo(&h, true, false) == 0, "creation failed");
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    CHECK(request(&h, VOCTRL_PAUSE) == VO_TRUE && timebase_rate(&h) == 1.0,
          "host mode paused the timebase");
    CHECK(request(&h, VOCTRL_RESUME) == VO_TRUE && timebase_rate(&h) == 1.0, "resume");
    // Host mode presents at mpv's target host time.
    int64_t target = mp_time_ns() + 30 * MS;
    ev_reset();
    show(&h, &a.img, target, false);
    char want[64];
    snprintf(want, sizeof(want), "enqueue_host pts=%lld", (long long)target);
    CHECK(ev_find(want, 0) >= 0, "host mode did not present at the target time");
    close_vo(&h);
    free_image(&a);
}

// ---- geometry, options and events -----------------------------------------------

static void test_geometry_and_options(void)
{
    struct harness_vo h;
    struct test_image a;
    make_image(&a, 3.0, false);

    CASE("geometry-read-after-sync");
    CHECK(open_vo(&h, false, false) == 0, "creation failed");
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    ev_reset();
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    CHECK(ev_tally("read_geometry") == 0, "the cached canvas was read again");
    ev_reset();
    CHECK(request(&h, VOCTRL_SET_PANSCAN) == VO_TRUE, "panscan");
    CHECK(IN_ORDER(0, "read_geometry", "copy_frame_async"), "panscan sync");
    CHECK(ev_tally("flush_") == 0, "panscan flushed a layer");
    fake_layers.width = 1920;
    fake_layers.height = 1080;
    ev_reset();
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    CHECK(IN_ORDER(0, "read_geometry", "osd_render 1920x1080", "enqueue_host"),
          "geometry not read again before rendering after the sync");
    CHECK(h.vo.dwidth == 1920 && h.vo.dheight == 1080, "new geometry not reported");

    CASE("options-changed");
    ev_reset();
    CHECK(request(&h, VOCTRL_VO_OPTS_CHANGED) == VO_TRUE, "options changed");
    CHECK(IN_ORDER(0, "read_geometry", "copy_frame_async"), "options sync");
    CHECK(ev_tally("flush_") == 0, "an options refresh without a composite change flushed");

    CASE("composite-toggle");
    struct avf_opts *pending = stubs.pending_opts;
    pending->pip_composite_osd = true;
    pending->queue_lead_ms = 96;
    stubs.options_changed = true;
    stubs.queue_calls = 0;
    ev_reset();
    CHECK(request(&h, VOCTRL_CHECK_EVENTS) == VO_TRUE, "check events");
    CHECK(stubs.queue_calls == 1 && stubs.queue_offset_ns == 96 * MS, "queue lead");
    CHECK(IN_ORDER(0, "flush_subtitles remove=1", "read_geometry"), "composite on steps");
    CHECK(ev_tally("copy_frame_async") == 0, "the subtitle layer was synced while compositing");
    CHECK(privof(&h)->composite, "compositing not on");
    // A frame with a cue now carries it in the picture: no subtitle sample.
    struct cue cue;
    make_cue(&cue, 3);
    stubs.osd_list = &cue.list;
    ev_reset();
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    CHECK(ev_tally("enqueue_subtitles") == 0 && ev_tally("enqueue_host") == 1,
          "compositing enqueued a subtitle sample");
    CHECK(fake_layers.last_host &&
          CMSampleBufferGetImageBuffer(fake_layers.last_host) == a.buf,
          "the decoder buffer was not presented");
    CHECK(avf_frame_kept_buffer(privof(&h)->frame, NULL) == a.buf, "no rows kept");
    pending->pip_composite_osd = false;
    stubs.options_changed = true;
    ev_reset();
    request(&h, VOCTRL_CHECK_EVENTS);
    CHECK(IN_ORDER(0, "flush_subtitles remove=1", "read_geometry", "copy_frame_async"),
          "composite off steps");
    size_t kept = 1;
    CHECK(!avf_frame_kept_buffer(privof(&h)->frame, &kept) && kept == 0,
          "rows still kept with compositing off");
    CHECK(!privof(&h)->composite, "compositing still on");
    stubs.osd_list = NULL;

    CASE("resync-and-resize");
    fake_layers.resync = true;
    ev_reset();
    request(&h, VOCTRL_CHECK_EVENTS);
    CHECK(ev_tally("recover") == 1, "no forced recovery after becoming active");
    fake_layers.resize = true;
    h.vo.want_redraw = false;
    ev_reset();
    request(&h, VOCTRL_CHECK_EVENTS);
    CHECK(IN_ORDER(0, "flush_subtitles remove=1", "read_geometry", "copy_frame_async"),
          "resize resync steps");
    CHECK(h.vo.want_redraw, "no redraw requested after a resize");
    // A resync raised between flips runs before the next frame's enqueue.
    fake_layers.resync = true;
    ev_reset();
    show(&h, &a.img, mp_time_ns() + 30 * MS, false);
    CHECK(IN_ORDER(0, "recover", "enqueue_host"), "resync not run before the enqueue");
    close_vo(&h);

    CASE("resize-ignored-while-compositing");
    CHECK(open_vo(&h, false, true) == 0, "creation failed");
    fake_layers.resize = true;
    h.vo.want_redraw = false;
    ev_reset();
    request(&h, VOCTRL_CHECK_EVENTS);
    CHECK(ev_count() == 0 && !h.vo.want_redraw, "a resize while compositing did something");
    close_vo(&h);
    free_image(&a);
}

// ---- pacing summary -------------------------------------------------------------

// Ends the summary window at once, so the next flip decides about the line.
static void end_window(struct harness_vo *h)
{
    privof(h)->pacing.window_start_ns = mp_time_ns() - AVF_PACING_WINDOW_NS - MS;
}

static void test_pacing_summary(void)
{
    struct harness_vo h;

    CASE("pacing-summary-window-opens-at-first-flip");
    CHECK(open_vo(&h, false, false) == 0, "creation failed");
    CHECK(!privof(&h)->pacing.window_started, "window open before any flip");
    int64_t before = mp_time_ns();
    show(&h, NULL, 0, false);
    CHECK(privof(&h)->pacing.window_started &&
          privof(&h)->pacing.window_start_ns >= before, "window not opened by the first flip");

    // A window whose only non-zero figure is the largest phase error is
    // still reported.
    CASE("pacing-summary-on-phase-error-alone");
    struct avf_pacing *pc = &privof(&h)->pacing;
    struct avf_clock *c = &privof(&h)->clock;
    pc->waits = pc->drops = pc->recoveries = 0;
    c->anchors = c->rate_writes = 0;
    c->max_abs_error_ns = 3 * MS;
    end_window(&h);
    stubs.last_message[0] = '\0';
    show(&h, NULL, 0, false);
    CHECK(!strncmp(stubs.last_message, "Pacing:", 7), "no summary: last line \"%s\"",
          stubs.last_message);
    CHECK(c->max_abs_error_ns == 0, "phase error not cleared with the window");

    CASE("pacing-summary-quiet-window");
    end_window(&h);
    stubs.last_message[0] = '\0';
    show(&h, NULL, 0, false);
    CHECK(!stubs.last_message[0], "a quiet window was reported: \"%s\"", stubs.last_message);
    close_vo(&h);
}

void avf_test_centre(void)
{
    @autoreleasepool {
        test_lifecycle();
        test_frame_order();
        test_reset_and_pause();
        test_geometry_and_options();
        test_pacing_summary();
    }
}
