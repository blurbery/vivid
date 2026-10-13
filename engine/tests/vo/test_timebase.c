/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the CoreMedia
 * timebase wrapper (spec 4.8), compiled from
 * video/out/avfoundation/timebase.c of the patched mpv tree and run against a
 * real timebase on the host time clock.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <stdlib.h>
#include <time.h>

#include "video/out/avfoundation/timebase.h"

#include "harness.h"

#define MS 1000000LL

static int64_t host_ns(void)
{
    return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static int host_reads;

static int64_t counted_host_ns(void)
{
    host_reads++;
    return host_ns();
}

// Takes the time, then stalls for 30 ms before handing it back.
static int64_t stalled_host_ns(void)
{
    int64_t t = host_ns();
    struct timespec ts = { 0, 30 * MS };
    nanosleep(&ts, NULL);
    return t;
}

void avf_test_timebase(void)
{
    CASE("timebase-create-and-seed");
    CMTimebaseRef tb = avf_timebase_create();
    CHECK(tb != NULL, "no timebase");
    if (!tb)
        return;
    avf_timebase_seed(tb, false, host_ns());
    int64_t t;
    CHECK(avf_timebase_read(tb, &t) && t == 0, "media seed time %lld", (long long)t);
    CHECK(CMTimebaseGetRate(tb) == 0.0, "media seed rate %f", CMTimebaseGetRate(tb));
    int64_t now = host_ns();
    avf_timebase_seed(tb, true, now);
    CHECK(CMTimebaseGetRate(tb) == 1.0, "host seed rate %f", CMTimebaseGetRate(tb));
    CHECK(avf_timebase_read(tb, &t) && llabs(t - host_ns()) < 20 * MS,
          "host seed time %lld, host %lld", (long long)t, (long long)host_ns());

    // An anchor puts the media time at the target host time: read at the
    // target, the timebase shows the media time.
    CASE("timebase-anchor-at-target");
    host_reads = 0;
    int64_t target = host_ns() + 40 * MS;
    CHECK(avf_timebase_anchor(tb, 1.0, 5000 * MS, target, counted_host_ns) == noErr,
          "anchor failed");
    CHECK(host_reads == 1, "host clock read %d times for the offset", host_reads);
    int64_t before = host_ns();
    avf_timebase_read(tb, &t);
    int64_t expect = 5000 * MS - (target - before);
    CHECK(llabs(t - expect) < 5 * MS, "anchored time %lld, expected about %lld",
          (long long)t, (long long)expect);
    CHECK(CMTimebaseGetRate(tb) == 1.0, "anchor rate");

    // The host clock is read after the source clock. A host reading that
    // stalls after taking its value shows the order: read first, the stall
    // would land between the two readings and put the anchor that much late.
    CASE("timebase-host-read-after-source");
    target = host_ns() + 40 * MS;
    CHECK(avf_timebase_anchor(tb, 1.0, 9000 * MS, target, stalled_host_ns) == noErr,
          "anchor failed");
    before = host_ns();
    avf_timebase_read(tb, &t);
    expect = 9000 * MS - (target - before);
    CHECK(llabs(t - expect) < 8 * MS, "anchored time %lld, expected about %lld "
          "(%lld ms late: the host clock was read before the source clock)",
          (long long)t, (long long)expect, (long long)((expect - t) / MS));

    // Without a host clock the anchor is at the source clock's time itself
    // (the pause anchor), and rate 0 holds the time.
    CASE("timebase-pause-anchor");
    CHECK(avf_timebase_anchor(tb, 0.0, 7000 * MS, 0, NULL) == noErr, "pause anchor failed");
    avf_timebase_read(tb, &t);
    CHECK(t == 7000 * MS, "paused time %lld", (long long)t);
    struct timespec ts = { 0, 10 * MS };
    nanosleep(&ts, NULL);
    avf_timebase_read(tb, &t);
    CHECK(t == 7000 * MS, "time moved at rate 0: %lld", (long long)t);

    CASE("timebase-set-rate");
    CHECK(avf_timebase_set_rate(tb, 1.01) == noErr && CMTimebaseGetRate(tb) == 1.01,
          "rate %f", CMTimebaseGetRate(tb));

    CASE("timebase-read-rounds-to-nanoseconds");
    CMTimebaseSetRate(tb, 0.0);
    CMTimebaseSetTime(tb, CMTimeMake(1, 3));    // a third of a second
    CHECK(avf_timebase_read(tb, &t) && t == 333333333, "1/3 s read as %lld", (long long)t);
    CFRelease(tb);
}
