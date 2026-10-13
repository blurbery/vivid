/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the centre
 * built a second time with the tvOS conditionals on, so the tvOS default
 * presentation mode (host) is compiled and checked on the build host. Every
 * system header is included first; only the centre's own code then sees
 * TARGET_OS_TV as 1.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>

#undef TARGET_OS_TV
#define TARGET_OS_TV 1
#define video_out_avfoundation video_out_avfoundation_tv

#include "fake_layers_rename.h"
#include "video/out/vo_avfoundation.m"

#include "fakes.h"
#include "harness.h"

void avf_test_centre_tv(void)
{
    CASE("tvos-default-presentation");
    const struct avf_opts *defaults = avf_conf.defaults;
    CHECK(defaults->presentation == AVF_PRESENT_HOST, "tvOS default is not host");
    CHECK(defaults->queue_lead_ms == 128 && !defaults->pip_composite_osd &&
          !defaults->composite_osd, "other defaults changed");

    // A VO created with the defaults latches host mode: its timebase is
    // seeded at the host time, rate 1, before it reaches the layer.
    CASE("tvos-default-creates-host-mode");
    stubs_reset();
    fake_layers_reset();
    ev_reset();
    struct mp_vo_opts opts = { .WinID = 0x5a5a00 };
    int osd_token = 0;
    struct vo vo = { .driver = &video_out_avfoundation, .opts = &opts,
                     .osd = (struct osd_state *)&osd_token };
    vo.priv = calloc(1, video_out_avfoundation.priv_size);
    @autoreleasepool {
        CHECK(video_out_avfoundation.preinit(&vo) == 0, "creation failed");
        struct priv *p = vo.priv;
        CHECK(p->host_mode, "host mode not latched");
        CHECK(ev_find("attach_timebase rate=1 ", 0) >= 0, "timebase not seeded for host mode");
        video_out_avfoundation.uninit(&vo);
    }
    free(vo.priv);
}
