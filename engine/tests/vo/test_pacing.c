/*
 * Host-side tests for Lucid Engine's AVFoundation video output: readiness
 * wait, deadline drops and display layer recovery with a fake renderer (spec
 * 4.10, 4.11, 9.4 item 7), compiled from video/out/avfoundation/pacing.c of
 * the patched mpv tree.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <string.h>

#include "video/out/avfoundation/pacing.h"

#include "harness.h"

#define MS 1000000LL

struct fake {
    int64_t now;
    int64_t ready_at;           // ready from this host time
    bool broken;                // status failed / requires flush
    bool recovery_fixes;        // a recovery clears `broken`
    int64_t break_at;           // becomes broken at this time (0: never)
    int recoveries;
    const char *reason;
    int drops;
    enum avf_drop_kind kind;
};

static int64_t f_now(void *ctx) { return ((struct fake *)ctx)->now; }

static void f_sleep(void *ctx, int64_t ns)
{
    struct fake *f = ctx;
    f->now += ns;
    if (f->break_at && f->now >= f->break_at) {
        f->broken = true;
        f->break_at = 0;
    }
}

static bool f_ready(void *ctx)
{
    struct fake *f = ctx;
    return !f->broken && f->now >= f->ready_at;
}

static bool f_needs(void *ctx) { return ((struct fake *)ctx)->broken; }

static void f_recover(void *ctx, const char *reason)
{
    struct fake *f = ctx;
    f->recoveries++;
    f->reason = reason;
    if (f->recovery_fixes)
        f->broken = false;
}

static void f_dropped(void *ctx, enum avf_drop_kind kind, double remaining)
{
    struct fake *f = ctx;
    f->drops++;
    f->kind = kind;
}

static struct avf_pacing_ops make_ops(struct fake *f)
{
    return (struct avf_pacing_ops){
        .ctx = f, .now = f_now, .sleep = f_sleep, .ready = f_ready,
        .needs_recovery = f_needs, .recover = f_recover, .dropped = f_dropped,
    };
}

static void setup(struct fake *f, struct avf_pacing *p)
{
    memset(f, 0, sizeof(*f));
    f->now = 1000 * MS;
    f->ready_at = INT64_MAX;
    f->recovery_fixes = true;
    avf_pacing_init(p);
}

static void test_boundary(void)
{
    struct fake f;
    struct avf_pacing p;
    struct avf_pacing_ops ops;

    CASE("ready-proceeds");
    setup(&f, &p);
    ops = make_ops(&f);
    f.ready_at = 0;
    CHECK(avf_pacing_wait(&p, &ops, f.now + 50 * MS) == AVF_WAIT_PROCEED, "ready frame");
    CHECK_EQ_I(f.drops, 0);

    CASE("give-up-moment-is-now");
    setup(&f, &p);
    ops = make_ops(&f);
    int64_t target = f.now + 4 * MS;    // give-up moment exactly now
    CHECK(avf_pacing_wait(&p, &ops, target) == AVF_WAIT_DROP, "not dropped at once");
    CHECK_EQ_I(f.drops, 1);
    CHECK(f.kind == AVF_DROP_PAST, "kind %d", f.kind);
    CHECK_EQ_I(f.now, 1000 * MS);       // no waiting

    CASE("give-up-moment-just-ahead");
    setup(&f, &p);
    ops = make_ops(&f);
    target = f.now + 4 * MS + 1;
    CHECK(avf_pacing_wait(&p, &ops, target) == AVF_WAIT_DROP, "not dropped");
    CHECK_EQ_I(f.drops, 1);
    CHECK(f.kind == AVF_DROP_DEADLINE, "kind %d", f.kind);
    CHECK_EQ_I(f.now, 1001 * MS);       // one 1 ms poll

    CASE("waits-until-ready");
    setup(&f, &p);
    ops = make_ops(&f);
    f.ready_at = f.now + 7 * MS + 300;
    target = f.now + 30 * MS;
    CHECK(avf_pacing_wait(&p, &ops, target) == AVF_WAIT_PROCEED, "dropped");
    CHECK_EQ_I(f.drops, 0);
    CHECK_EQ_I(f.now, 1008 * MS);       // polled every 1 ms
    CHECK_EQ_I(p.waits, 1);

    CASE("drop-at-4ms-before-target");
    setup(&f, &p);
    ops = make_ops(&f);
    target = f.now + 20 * MS;
    CHECK(avf_pacing_wait(&p, &ops, target) == AVF_WAIT_DROP, "not dropped");
    CHECK_EQ_I(f.now, target - 4 * MS);
    CHECK_EQ_I(f.drops, 1);

    CASE("redraw-not-ready-drops-at-once");
    setup(&f, &p);
    ops = make_ops(&f);
    CHECK(avf_pacing_wait(&p, &ops, f.now) == AVF_WAIT_DROP, "redraw waited");
    CHECK_EQ_I(f.now, 1000 * MS);
    CHECK_EQ_I(f.drops, 1);

    CASE("one-drop-count-per-frame");
    setup(&f, &p);
    ops = make_ops(&f);
    for (int i = 0; i < 10; i++) {
        avf_pacing_wait(&p, &ops, f.now + 10 * MS);
        avf_pacing_enqueued(&p, f.now); // keep recoveries out of it
    }
    CHECK_EQ_I(f.drops, 10);
}

static void test_recovery(void)
{
    struct fake f;
    struct avf_pacing p;
    struct avf_pacing_ops ops;

    CASE("recovery-before-wait");
    setup(&f, &p);
    ops = make_ops(&f);
    f.broken = true;
    f.ready_at = 0;
    CHECK(avf_pacing_wait(&p, &ops, f.now + 40 * MS) == AVF_WAIT_PROCEED, "dropped");
    CHECK_EQ_I(f.recoveries, 1);
    CHECK(!strcmp(f.reason, "layer recovery request"), "reason %s", f.reason);

    CASE("throttle-500ms");
    setup(&f, &p);
    ops = make_ops(&f);
    f.ready_at = 0;
    f.broken = true;
    avf_pacing_wait(&p, &ops, f.now + 40 * MS);
    CHECK_EQ_I(f.recoveries, 1);
    f.now = 1400 * MS;
    f.broken = true;
    f.recovery_fixes = false;
    // 400 ms after the first: suppressed before the wait, and again at the
    // first poll (401 ms), so the unrecovered layer drops the frame.
    CHECK(avf_pacing_wait(&p, &ops, f.now + 40 * MS) == AVF_WAIT_DROP, "not dropped");
    CHECK_EQ_I(f.recoveries, 1);
    f.now = 1499 * MS;
    avf_pacing_recover(&p, &ops, "x", false);
    CHECK_EQ_I(f.recoveries, 1);        // 499 ms: suppressed
    f.now = 1500 * MS;                  // 500 ms after the first
    avf_pacing_wait(&p, &ops, f.now + 40 * MS);
    CHECK_EQ_I(f.recoveries, 2);

    CASE("forced-not-throttled");
    setup(&f, &p);
    ops = make_ops(&f);
    CHECK(avf_pacing_recover(&p, &ops, "presentation resume", true), "forced");
    CHECK(avf_pacing_recover(&p, &ops, "presentation resume", true), "forced again");
    CHECK(!avf_pacing_recover(&p, &ops, "layer recovery request", false), "throttle");
    CHECK_EQ_I(f.recoveries, 2);

    CASE("reset-lifts-throttle");
    setup(&f, &p);
    ops = make_ops(&f);
    CHECK(avf_pacing_recover(&p, &ops, "x", false), "first");
    CHECK(!avf_pacing_recover(&p, &ops, "x", false), "throttled");
    avf_pacing_reset(&p);
    CHECK(avf_pacing_recover(&p, &ops, "x", false), "after reset");

    CASE("unrecovered-layer-drops");
    setup(&f, &p);
    ops = make_ops(&f);
    f.recovery_fixes = false;
    f.break_at = f.now + 3 * MS;        // breaks while waiting
    int64_t start = f.now;
    CHECK(avf_pacing_wait(&p, &ops, f.now + 40 * MS) == AVF_WAIT_DROP, "not dropped");
    CHECK(f.kind == AVF_DROP_UNRECOVERED, "kind %d", f.kind);
    CHECK_EQ_I(f.recoveries, 1);
    CHECK(!strcmp(f.reason, "not-ready wait"), "reason %s", f.reason);
    CHECK_EQ_I(f.now - start, 3 * MS);

    CASE("throttled-unrecovered-layer-drops");
    setup(&f, &p);
    ops = make_ops(&f);
    avf_pacing_recover(&p, &ops, "x", false);   // throttle armed
    f.recovery_fixes = false;
    f.break_at = f.now + 2 * MS;
    CHECK(avf_pacing_wait(&p, &ops, f.now + 40 * MS) == AVF_WAIT_DROP, "not dropped");
    CHECK(f.kind == AVF_DROP_UNRECOVERED, "kind %d", f.kind);
    CHECK_EQ_I(f.recoveries, 1);        // suppressed, still dropped

    CASE("recovered-layer-keeps-waiting");
    setup(&f, &p);
    ops = make_ops(&f);
    f.break_at = f.now + 2 * MS;
    f.ready_at = f.now + 6 * MS;
    CHECK(avf_pacing_wait(&p, &ops, f.now + 40 * MS) == AVF_WAIT_PROCEED, "dropped");
    CHECK_EQ_I(f.recoveries, 1);
}

static void test_run(void)
{
    struct fake f;
    struct avf_pacing p;
    struct avf_pacing_ops ops;

    CASE("run-recovers-on-every-drop-from-3");
    setup(&f, &p);
    ops = make_ops(&f);
    f.recovery_fixes = false;           // the fake stays not ready either way
    for (int i = 1; i <= 2; i++) {
        avf_pacing_wait(&p, &ops, f.now); // immediate drops
        f.now += 100 * MS;
    }
    CHECK_EQ_I(p.run, 2);
    CHECK_EQ_I(f.recoveries, 0);
    avf_pacing_wait(&p, &ops, f.now);   // third drop: recovery runs, run -> 0
    CHECK_EQ_I(f.recoveries, 1);
    CHECK(!strcmp(f.reason, "repeated not-ready drops"), "reason %s", f.reason);
    CHECK_EQ_I(p.run, 0);

    CASE("run-suppressed-recovery-keeps-run");
    setup(&f, &p);
    ops = make_ops(&f);
    avf_pacing_recover(&p, &ops, "x", false);  // arms the throttle
    for (int i = 0; i < 4; i++) {
        avf_pacing_wait(&p, &ops, f.now);
        f.now += 100 * MS;
    }
    // Drops 3 and 4 (200 and 300 ms after the armed recovery) tried recovery
    // and the throttle suppressed both, so the run kept growing.
    CHECK_EQ_I(f.recoveries, 1);
    CHECK_EQ_I(p.run, 4);
    avf_pacing_wait(&p, &ops, f.now);   // 400 ms: still suppressed
    CHECK_EQ_I(f.recoveries, 1);
    CHECK_EQ_I(p.run, 5);
    f.now += 100 * MS;
    avf_pacing_wait(&p, &ops, f.now);   // 500 ms after the armed recovery
    CHECK_EQ_I(f.recoveries, 2);
    CHECK_EQ_I(p.run, 0);

    CASE("run-restarts-after-gap");
    setup(&f, &p);
    ops = make_ops(&f);
    avf_pacing_wait(&p, &ops, f.now);
    f.now += 100 * MS;
    avf_pacing_wait(&p, &ops, f.now);
    CHECK_EQ_I(p.run, 2);
    f.now += 501 * MS;
    avf_pacing_wait(&p, &ops, f.now);
    CHECK_EQ_I(p.run, 1);               // restarted at 0, then counted
    f.now += 500 * MS;                  // exactly 500 ms: not a restart
    avf_pacing_wait(&p, &ops, f.now);
    CHECK_EQ_I(p.run, 2);

    CASE("run-staleness");
    setup(&f, &p);
    ops = make_ops(&f);
    avf_pacing_enqueued(&p, f.now);
    for (int i = 0; i < 3; i++) {
        f.now += 100 * MS;
        avf_pacing_wait(&p, &ops, f.now); // enqueue 100..300 ms ago
    }
    CHECK_EQ_I(p.run, 3);
    CHECK_EQ_I(f.recoveries, 0);        // a recent enqueue: no recovery
    f.now += 199 * MS;
    avf_pacing_wait(&p, &ops, f.now);   // 499 ms after the enqueue
    CHECK_EQ_I(f.recoveries, 0);
    f.now += 1 * MS;
    avf_pacing_wait(&p, &ops, f.now);   // 500 ms: stale
    CHECK_EQ_I(f.recoveries, 1);
    CHECK_EQ_I(p.run, 0);

    CASE("ready-renderer-clears-run");
    setup(&f, &p);
    ops = make_ops(&f);
    avf_pacing_wait(&p, &ops, f.now);
    avf_pacing_wait(&p, &ops, f.now);
    CHECK_EQ_I(p.run, 2);
    f.ready_at = 0;
    avf_pacing_wait(&p, &ops, f.now + 40 * MS);
    CHECK_EQ_I(p.run, 0);

    CASE("reset-clears-run");
    setup(&f, &p);
    ops = make_ops(&f);
    avf_pacing_wait(&p, &ops, f.now);
    avf_pacing_wait(&p, &ops, f.now);
    avf_pacing_reset(&p);
    CHECK_EQ_I(p.run, 0);
    avf_pacing_wait(&p, &ops, f.now);
    CHECK_EQ_I(p.run, 1);

    CASE("recovery-clears-run-and-times");
    setup(&f, &p);
    ops = make_ops(&f);
    avf_pacing_enqueued(&p, f.now);
    avf_pacing_wait(&p, &ops, f.now);
    CHECK(avf_pacing_recover(&p, &ops, "x", true), "forced");
    CHECK_EQ_I(p.run, 0);
    CHECK(!p.have_last_drop && !p.have_last_enqueue, "times kept");
}

void avf_test_pacing(void)
{
    test_boundary();
    test_recovery();
    test_run();
}
