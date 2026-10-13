/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the playback
 * rate estimator and the media-mode timebase servo (spec 4.8, 9.4 items 1 to
 * 6), compiled from video/out/avfoundation/clock.c of the patched mpv tree.
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

#include "video/out/avfoundation/clock.h"

#include "harness.h"

#define MS 1000000LL
#define SEC 1000000000LL
#define MP_NOPTS (-0x1p+63)

// ---------------------------------------------------------------------------
// An independent, straightforward model of 4.8.2 and 4.8.3. It keeps the
// windows as lists of samples and recomputes their sums, and follows the
// spec's wording step by step, so the shipped code can be compared with it
// value for value.

#define REF_MAX 4096

struct ref_est {
    bool has_prev;
    int64_t m0, d0;
    int nfast, navg;
    int64_t fast_m[REF_MAX], fast_d[REF_MAX];
    int64_t avg_m[REF_MAX], avg_d[REF_MAX];
};

static int64_t sum64(const int64_t *v, int n)
{
    int64_t s = 0;
    for (int i = 0; i < n; i++)
        s += v[i];
    return s;
}

static bool ref_in_range(double r)
{
    return r >= 0.05 && r <= 8.0;
}

static bool ref_avg_add(struct ref_est *e, int64_t dm, int64_t dd, double *out)
{
    e->avg_m[e->navg] = dm;
    e->avg_d[e->navg] = dd;
    e->navg++;
    if (sum64(e->avg_d, e->navg) >= 500 * MS) {
        double r = (double)sum64(e->avg_m, e->navg) / (double)sum64(e->avg_d, e->navg);
        e->navg = 0;
        if (ref_in_range(r)) {
            *out = r;
            return true;
        }
    }
    return false;
}

static bool ref_est_push(struct ref_est *e, int64_t m, int64_t d, double nominal,
                         double *out)
{
    double n = nominal <= 0 ? 1.0 : nominal;
    if (d <= 0)
        return false;                       // unusable duration
    if (!e->has_prev) {                     // first sample
        e->has_prev = true;
        e->m0 = m;
        e->d0 = d;
        return false;
    }
    int64_t delta = m - e->m0;
    if (delta == 0)
        return false;                       // no media step
    int64_t prev_d = e->d0;
    double r = (double)delta / (double)prev_d;
    int64_t gate = llabs(prev_d) / 100;
    if (gate < 250000)
        gate = 250000;
    e->m0 = m;
    e->d0 = d;
    if (delta < 0 || llabs(d - prev_d) > gate || !ref_in_range(r)) {
        e->nfast = e->navg = 0;             // discontinuity
        return false;
    }
    if (fabs(r - n) <= 0.04 * n) {          // near nominal
        e->nfast = 0;
        return ref_avg_add(e, delta, prev_d, out);
    }
    if (e->nfast) {                         // far from nominal
        double wr = (double)sum64(e->fast_m, e->nfast) / (double)sum64(e->fast_d, e->nfast);
        if (fabs(wr - r) > 0.04 * wr)
            e->nfast = 0;
    }
    e->fast_m[e->nfast] = delta;
    e->fast_d[e->nfast] = prev_d;
    e->nfast++;
    if (e->nfast >= 2) {
        double fr = (double)sum64(e->fast_m, e->nfast) / (double)sum64(e->fast_d, e->nfast);
        e->nfast = e->navg = 0;
        if (ref_in_range(fr)) {
            *out = fr;
            return true;
        }
        return false;
    }
    return ref_avg_add(e, delta, prev_d, out);
}

struct ref_servo {
    double nominal, applied;
    bool has_applied, anchor, paused, tb_paused, has_eval;
    double integral;
    int64_t eval_t, write_t;
};

enum { REF_KEEP, REF_ANCHOR, REF_RATE };

static double ref_clamp(double v, double l)
{
    if (v < -l)
        return -l;
    if (v > l)
        return l;
    return v;
}

static int ref_step(struct ref_servo *s, int64_t media, int64_t target, int64_t now,
                    int64_t tb, bool has_est, double est, double *rate)
{
    double nominal = s->nominal <= 0 ? 1.0 : s->nominal;
    bool changed = false;
    if (has_est && !s->paused && fabs(est - nominal) > 0.01 * nominal) {
        s->nominal = nominal = est;
        changed = true;
    }
    double a = s->has_applied ? s->applied : nominal;
    int64_t proj = (int64_t)((double)(target - now) * a);
    int64_t e = media - (tb + proj);
    if (!s->anchor || s->paused || s->tb_paused || changed || llabs(e) > 50 * MS) {
        *rate = (s->paused || s->tb_paused) ? 0.0 : nominal;
        s->integral = 0;
        s->has_eval = false;
        s->write_t = now;
        s->nominal = s->applied = *rate;
        s->has_applied = true;
        s->anchor = true;
        s->tb_paused = s->paused;
        return REF_ANCHOR;
    }
    double p = ref_clamp(((double)e / 1e9) / 2.0, 0.015);
    if (s->has_eval && now - s->eval_t > 0 && now - s->eval_t <= 500 * MS)
        s->integral = ref_clamp(s->integral + p * ((double)(now - s->eval_t) / 1e9) / 8.0,
                                0.015);
    s->has_eval = true;
    s->eval_t = now;
    double r = nominal * (1.0 + ref_clamp(p + s->integral, 0.015));
    if (fabs(r - a) > 0.0001 * nominal && now - s->write_t >= 200 * MS) {
        s->applied = r;
        s->has_applied = true;
        s->write_t = now;
        *rate = r;
        return REF_RATE;
    }
    return REF_KEEP;
}

// ---------------------------------------------------------------------------
// Conversions.

static void test_conversions(void)
{
    int64_t ns;
    CASE("seconds-to-ns");
    CHECK(avf_media_seconds_to_ns(1.5, &ns) && ns == 1500000000, "1.5 s");
    CHECK(avf_media_seconds_to_ns(-1.5, &ns) && ns == -1500000000, "-1.5 s");
    CHECK(avf_media_seconds_to_ns(0.1, &ns) && ns == 100000000, "0.1 s");
    CHECK(avf_media_seconds_to_ns(1e-9, &ns) && ns == 1, "1 ns");
    CHECK(avf_media_seconds_to_ns(-1e-9, &ns) && ns == -1, "-1 ns");
    CHECK(avf_media_seconds_to_ns(0.4e-9, &ns) && ns == 0, "0.4 ns");
    CHECK(avf_media_seconds_to_ns(0.6e-9, &ns) && ns == 1, "0.6 ns");
    CHECK(avf_media_seconds_to_ns(-0.6e-9, &ns) && ns == -1, "-0.6 ns");

    CASE("seconds-to-ns-invalid");
    CHECK(!avf_media_seconds_to_ns(MP_NOPTS, &ns), "no pts");
    CHECK(!avf_media_seconds_to_ns(NAN, &ns), "nan");
    CHECK(!avf_media_seconds_to_ns(INFINITY, &ns), "inf");
    CHECK(!avf_media_seconds_to_ns(-INFINITY, &ns), "-inf");

    CASE("seconds-to-ns-single-rounding");
    // pts * 1e9 +/- 0.5 as one fused multiply-add, truncated.
    struct avf_rng rng = { 0x9E3779B97F4A7C15ULL };
    int wrong = 0;
    for (int i = 0; i < 200000; i++) {
        double pts = (avf_rng_unit(&rng) - 0.25) * 200000.0;
        double fused = fma(pts, 1e9, pts < 0 ? -0.5 : 0.5);
        if (!avf_media_seconds_to_ns(pts, &ns) || ns != (int64_t)fused)
            wrong++;
    }
    CHECK(wrong == 0, "%d values differ from the fused conversion", wrong);

    CASE("frame-duration");
    CHECK_EQ_I(avf_frame_duration_ns(true, 0.04, 1e6), 40000000);
    CHECK_EQ_I(avf_frame_duration_ns(true, 0.0, 41666666.6), 41666667);
    CHECK_EQ_I(avf_frame_duration_ns(true, 1e-10, 5e6), 5000000);   // 0.1 ns truncates to 0
    CHECK_EQ_I(avf_frame_duration_ns(false, 0.04, 40000000.5), 40000000); // ties to even
    CHECK_EQ_I(avf_frame_duration_ns(false, 0.04, 40000001.5), 40000002);
    CHECK_EQ_I(avf_frame_duration_ns(false, 0, -1), 0);
    CHECK_EQ_I(avf_frame_duration_ns(false, 0, 0), 0);
    CHECK_EQ_I(avf_frame_duration_ns(true, -0.04, -1), 0);
}

// ---------------------------------------------------------------------------
// Estimator vectors (9.4 item 6), through the shipped estimator and the
// shipped clock (for adoption), with nominal 1.0 unless stated.

struct ev_frame { int64_t m, d; };

struct ev_run {
    struct avf_clock clock;
    int estimates;
    int last_est_frame;
    double last_est;
};

static void ev_feed(struct ev_run *r, const struct ev_frame *f, int n, bool adopt)
{
    for (int i = 0; i < n; i++) {
        double est;
        bool has = avf_estimator_push(&r->clock.est, f[i].m, f[i].d,
                                      avf_clock_nominal(&r->clock), &est);
        if (has) {
            r->estimates++;
            r->last_est = est;
            r->last_est_frame = i + 1;
        }
        if (adopt && has) {
            // The frame reaches the timebase step, playing.
            struct avf_clock_frame in = {
                .media_ns = f[i].m, .target_ns = 0, .now_ns = 0,
                .timebase_ns = f[i].m, .has_estimate = true, .estimate = est,
            };
            struct avf_clock_result res;
            r->clock.anchor_valid = true;
            avf_clock_step(&r->clock, &in, &res);
        }
    }
}

static void test_estimator_vectors(void)
{
    struct ev_run r;

    CASE("EV1");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 40 * MS } }, 1, true);
    CHECK_EQ_I(r.estimates, 0);

    CASE("EV2");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    struct ev_frame ev2[14];
    for (int i = 0; i < 14; i++)
        ev2[i] = (struct ev_frame){ i * 40 * MS, 40 * MS };
    ev_feed(&r, ev2, 14, true);
    CHECK_EQ_I(r.estimates, 1);
    CHECK_EQ_I(r.last_est_frame, 14);
    CHECK(r.last_est == 1.0, "estimate %.9f", r.last_est);
    CHECK(avf_clock_nominal(&r.clock) == 1.0, "nominal changed");

    CASE("EV3");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    struct ev_frame ev3[] = {
        { 0, 40 * MS }, { 40 * MS, 40 * MS }, { 80 * MS, 40 * MS },
        { 120 * MS, 20 * MS }, { 160 * MS, 20 * MS }, { 200 * MS, 20 * MS },
    };
    ev_feed(&r, ev3, 4, true);
    CHECK_EQ_I(r.estimates, 0);
    ev_feed(&r, ev3 + 4, 2, true);
    CHECK_EQ_I(r.estimates, 1);
    CHECK_EQ_I(r.last_est_frame, 2); // the 6th frame overall
    CHECK(r.last_est == 2.0, "estimate %.9f", r.last_est);
    CHECK(avf_clock_nominal(&r.clock) == 2.0, "not adopted");

    CASE("EV4");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 40 * MS }, { 40 * MS, 40 * MS },
                                     { 40 * MS, 40 * MS } }, 3, true);
    CHECK(r.clock.est.prev_media == 40 * MS, "repeated time changed the sample");
    CHECK_EQ_I(r.clock.est.avg_duration, 40 * MS);
    ev_feed(&r, (struct ev_frame[]){ { 80 * MS, 40 * MS } }, 1, true);
    CHECK_EQ_I(r.estimates, 0);
    CHECK_EQ_I(r.clock.est.avg_media, 80 * MS); // last step measured from 40
    CHECK_EQ_I(r.clock.est.avg_duration, 80 * MS);

    CASE("EV5");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 40 * MS }, { 40 * MS, 40 * MS },
                                     { 80 * MS, 40 * MS }, { 40 * MS, 40 * MS } }, 4, true);
    CHECK_EQ_I(r.estimates, 0);
    CHECK_EQ_I(r.clock.est.avg_duration, 0);
    CHECK_EQ_I(r.clock.est.fast_count, 0);
    CHECK(r.clock.est.prev_media == 40 * MS && r.clock.est.prev_duration == 40 * MS,
          "previous sample");

    CASE("EV6");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 40 * MS }, { 40 * MS, 40 * MS },
                                     { 440 * MS, 40 * MS } }, 3, true);
    CHECK_EQ_I(r.estimates, 0);
    CHECK_EQ_I(r.clock.est.avg_duration, 0);
    CHECK_EQ_I(r.clock.est.fast_count, 0);

    CASE("EV7");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    struct ev_frame ev7[15];
    int64_t m = 0;
    ev7[0] = (struct ev_frame){ 0, 40 * MS };
    for (int i = 1; i <= 12; i++) {
        m += 41200000;
        ev7[i] = (struct ev_frame){ m, 40 * MS };
    }
    m += 44 * MS;
    ev7[13] = (struct ev_frame){ m, 40 * MS };
    m += 44 * MS;
    ev7[14] = (struct ev_frame){ m, 40 * MS };
    ev_feed(&r, ev7, 14, true);
    CHECK_EQ_I(r.estimates, 1);
    CHECK_EQ_I(r.last_est_frame, 14);
    CHECK_NEAR(r.last_est, 1.035385, 0.0000005);
    CHECK_NEAR(avf_clock_nominal(&r.clock), 1.035385, 0.0000005);
    ev_feed(&r, ev7 + 14, 1, true);
    CHECK_EQ_I(r.estimates, 2);
    CHECK(r.last_est == 1.1, "fast window estimate %.9f", r.last_est);
    CHECK(avf_clock_nominal(&r.clock) == 1.1, "fast estimate not adopted");

    CASE("EV8");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 40 * MS }, { 60 * MS, 40 * MS },
                                     { 140 * MS, 40 * MS }, { 220 * MS, 40 * MS } }, 4, true);
    CHECK_EQ_I(r.estimates, 1);
    CHECK_EQ_I(r.last_est_frame, 4);
    CHECK(r.last_est == 2.0, "estimate %.9f", r.last_est);

    CASE("EV9");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 40 * MS }, { 40 * MS, 40300000 },
                                     { 80 * MS, 40 * MS } }, 3, true);
    CHECK_EQ_I(r.estimates, 0);
    CHECK_EQ_I(r.clock.est.avg_duration, 80300000);

    CASE("EV10");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 40 * MS }, { 40 * MS, 40 * MS },
                                     { 80 * MS, 40450000 } }, 3, true);
    CHECK_EQ_I(r.estimates, 0);
    CHECK_EQ_I(r.clock.est.avg_duration, 0);
    CHECK_EQ_I(r.clock.est.fast_count, 0);

    CASE("EV11");
    memset(&r, 0, sizeof(r));
    avf_clock_init(&r.clock);
    ev_feed(&r, (struct ev_frame[]){ { 0, 0 }, { 40 * MS, -5 } }, 2, true);
    CHECK_EQ_I(r.estimates, 0);
    CHECK(!r.clock.est.has_prev, "a sample was stored");

    CASE("EV12");
    // An estimate produced while paused is not used by its frame.
    struct avf_clock c;
    avf_clock_init(&c);
    avf_clock_pause(&c);
    struct avf_clock_frame in = { .media_ns = 0, .timebase_ns = 0,
                                  .has_estimate = true, .estimate = 2.0 };
    struct avf_clock_result res;
    avf_clock_step(&c, &in, &res);
    CHECK(!res.nominal_changed, "estimate used while paused");
    CHECK(res.op == AVF_CLOCK_ANCHOR && res.rate == 0.0, "paused frame anchors at 0");
    avf_clock_resume(&c);
    in = (struct avf_clock_frame){ .media_ns = 40 * MS, .timebase_ns = 40 * MS };
    avf_clock_step(&c, &in, &res);
    CHECK(!res.nominal_changed && avf_clock_nominal(&c) == 1.0,
          "a discarded estimate came back");
    // The anchor while paused stored 0, which reads as 1.0.
    CHECK(res.rate == 1.0, "resume anchors at %.3f", res.rate);
}

// ---------------------------------------------------------------------------
// Servo simulation: a timebase that follows the clock's instructions while a
// player schedules frames against the host clock.

struct seg {
    int64_t start;      // host time the instruction took effect
    double media;       // timebase time at host time `host`
    double host;
    double rate;
};

struct sim_tb {
    struct seg *segs;
    int n, cap;
};

static void tb_push(struct sim_tb *t, struct seg s)
{
    if (t->n == t->cap) {
        t->cap = t->cap ? t->cap * 2 : 256;
        t->segs = realloc(t->segs, t->cap * sizeof(*t->segs));
    }
    t->segs[t->n++] = s;
}

static double tb_at(const struct sim_tb *t, int64_t host)
{
    int lo = 0;
    for (int i = t->n - 1; i >= 0; i--) {
        if (t->segs[i].start <= host) {
            lo = i;
            break;
        }
    }
    const struct seg *s = &t->segs[lo];
    return s->media + ((double)host - s->host) * s->rate;
}

struct scenario {
    double fps;
    int frames;
    double speed0, speed1;
    int change_frame;           // first frame at speed1 (frames to disable)
    double offset;              // schedule rate offset (fraction)
    double offset_period_s;     // 0: constant
    double noise_ms;            // uniform +/- noise on the presented target
    int64_t jump_ns;            // schedule jump at jump_frame
    int jump_frame;
    uint64_t seed;
};

#define MAX_ANCHORS 4096

struct outcome {
    int anchors;
    int anchor_frame[MAX_ANCHORS];
    int64_t anchor_host[MAX_ANCHORS];
    int adopt_frame;            // first frame whose estimate was adopted
    int adoptions;
    double final_nominal;
    double max_err_ms_after_30s;
    double max_phase_err_ms;    // between anchors, at evaluation
    bool rate_bounds_ok, write_gap_ok, write_size_ok, integral_ok;
    int writes;
    int64_t *due;
    int64_t *media;
};

static void run_scenario(const struct scenario *sc, struct outcome *o)
{
    memset(o, 0, sizeof(*o));
    o->adopt_frame = -1;
    o->rate_bounds_ok = o->write_gap_ok = o->write_size_ok = o->integral_ok = true;
    o->due = calloc(sc->frames, sizeof(int64_t));
    o->media = calloc(sc->frames, sizeof(int64_t));

    struct avf_rng rng = { sc->seed ? sc->seed : 1 };
    struct avf_clock c;
    avf_clock_init(&c);
    struct sim_tb tb = {0};
    tb_push(&tb, (struct seg){ .start = 0, .media = 0, .host = 0, .rate = 0 });

    const int64_t frame = (int64_t)llround(1e9 / sc->fps);
    const int64_t t0 = 10 * SEC;
    double due = t0;
    int64_t last_write = -1;
    double prev_applied = 0;

    for (int k = 0; k < sc->frames; k++) {
        double speed = k < sc->change_frame ? sc->speed0 : sc->speed1;
        int64_t m = k * frame;
        if (k > 0) {
            double eps = sc->offset;
            if (sc->offset_period_s > 0)
                eps = sc->offset * sin(2 * M_PI * (due - t0) / (sc->offset_period_s * 1e9));
            due += (double)frame / speed * (1.0 + eps);
        }
        if (sc->jump_ns && k == sc->jump_frame)
            due += sc->jump_ns;
        int64_t due_i = (int64_t)llround(due);
        double noise = (avf_rng_unit(&rng) * 2 - 1) * sc->noise_ms * MS;
        int64_t target = due_i + (int64_t)llround(noise);
        int64_t now = target - 128 * MS + (int64_t)(avf_rng_unit(&rng) * MS);
        o->due[k] = due_i;
        o->media[k] = m;

        double est;
        double vo_duration = (double)frame / speed;
        bool has = avf_estimator_push(&c.est, m, avf_frame_duration_ns(false, 0, vo_duration),
                                      avf_clock_nominal(&c), &est);
        int64_t tb_now = (int64_t)llround(tb_at(&tb, now));
        struct avf_clock_frame in = {
            .media_ns = m, .target_ns = target, .now_ns = now,
            .timebase_ns = tb_now, .has_estimate = has, .estimate = est,
        };
        bool valid_before = c.anchor_valid;
        struct avf_clock_result res;
        avf_clock_step(&c, &in, &res);

        if (valid_before && res.op != AVF_CLOCK_ANCHOR) {
            double pe = fabs(res.error_ns / 1e6);
            if (pe > o->max_phase_err_ms)
                o->max_phase_err_ms = pe;
        }
        if (res.nominal_changed) {
            o->adoptions++;
            if (o->adopt_frame < 0)
                o->adopt_frame = k;
        }
        if (fabs(c.integral) > AVF_SERVO_LIMIT + 1e-15)
            o->integral_ok = false;

        if (res.op == AVF_CLOCK_ANCHOR) {
            if (o->anchors < MAX_ANCHORS) {
                o->anchor_frame[o->anchors] = k;
                o->anchor_host[o->anchors] = now;
            }
            o->anchors++;
            tb_push(&tb, (struct seg){ .start = now, .media = (double)m,
                                       .host = (double)target, .rate = res.rate });
            last_write = now;
            prev_applied = res.rate;
        } else if (res.op == AVF_CLOCK_SET_RATE) {
            double nominal = avf_clock_nominal(&c);
            if (fabs(res.rate / nominal - 1.0) > AVF_SERVO_LIMIT + 1e-12)
                o->rate_bounds_ok = false;
            if (last_write >= 0 && now - last_write < 200 * MS)
                o->write_gap_ok = false;
            if (fabs(res.rate - prev_applied) <= 0.0001 * nominal)
                o->write_size_ok = false;
            tb_push(&tb, (struct seg){ .start = now, .media = tb_at(&tb, now),
                                       .host = (double)now, .rate = res.rate });
            last_write = now;
            prev_applied = res.rate;
            o->writes++;
        }
    }

    // Error against the schedule before noise: the timebase's time when each
    // frame was due, against that frame's media time.
    int64_t first_anchor = o->anchors ? o->anchor_host[0] : 0;
    for (int k = 0; k < sc->frames; k++) {
        if (o->due[k] < first_anchor + 30 * SEC)
            continue;
        double err = fabs(tb_at(&tb, o->due[k]) - (double)o->media[k]) / 1e6;
        if (err > o->max_err_ms_after_30s)
            o->max_err_ms_after_30s = err;
    }
    o->final_nominal = avf_clock_nominal(&c);
    free(tb.segs);
}

static void free_outcome(struct outcome *o)
{
    free(o->due);
    free(o->media);
}

static void test_no_needless_anchors(void)
{
    // 9.4 item 1: noise within +/-0.8 ms and an offset of at most 0.04%,
    // constant or varying with a period of 5 minutes or more.
    const struct { double fps, offset, period; uint64_t seed; } cases[] = {
        { 23.976, 0.0004, 0, 11 },
        { 23.976, -0.0004, 0, 12 },
        { 24.0, 0.0, 0, 13 },
        { 25.0, 0.0004, 300, 14 },
        { 29.97, -0.0004, 300, 15 },
        { 50.0, 0.0002, 600, 16 },
        { 59.94, 0.0004, 300, 17 },
        { 59.94, -0.0003, 0, 18 },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        CASE("no-needless-anchors");
        struct scenario sc = {
            .fps = cases[i].fps, .frames = (int)(cases[i].fps * 600),
            .speed0 = 1, .speed1 = 1, .change_frame = 1 << 30,
            .offset = cases[i].offset, .offset_period_s = cases[i].period,
            .noise_ms = 0.8, .seed = cases[i].seed,
        };
        struct outcome o;
        run_scenario(&sc, &o);
        CHECK_EQ_I(o.anchors, 1);
        CHECK(o.max_err_ms_after_30s < 1.0, "fps %.3f offset %g: error %.3f ms",
              sc.fps, sc.offset, o.max_err_ms_after_30s);
        CHECK(o.max_phase_err_ms < 10.0, "phase error %.3f ms", o.max_phase_err_ms);
        CHECK(o.rate_bounds_ok && o.write_gap_ok && o.write_size_ok && o.integral_ok,
              "rate write rules (bounds %d gap %d size %d integral %d)",
              o.rate_bounds_ok, o.write_gap_ok, o.write_size_ok, o.integral_ok);
        free_outcome(&o);
    }
}

static void test_one_anchor_per_jump(void)
{
    const int64_t jumps[] = { 51 * MS, 80 * MS, -60 * MS, 500 * MS, -2 * SEC };
    for (size_t i = 0; i < sizeof(jumps) / sizeof(jumps[0]); i++) {
        CASE("one-anchor-per-jump");
        struct scenario sc = {
            .fps = 23.976, .frames = 24 * 120, .speed0 = 1, .speed1 = 1,
            .change_frame = 1 << 30, .noise_ms = 0.5, .jump_ns = jumps[i],
            .jump_frame = 24 * 60, .seed = 100 + i,
        };
        struct outcome o;
        run_scenario(&sc, &o);
        CHECK(o.anchors == 2, "jump %lld ms: %d anchors", (long long)(jumps[i] / MS),
              o.anchors);
        CHECK(o.anchors < 2 || o.anchor_frame[1] == sc.jump_frame,
              "re-anchored at frame %d, jump at %d", o.anchor_frame[1], sc.jump_frame);
        CHECK(o.final_nominal == 1.0, "nominal %.6f", o.final_nominal);
        free_outcome(&o);
    }
}

static void test_speed_changes(void)
{
    const struct { double fps, from, to; } cases[] = {
        { 24, 1.0, 1.25 }, { 24, 1.0, 1.5 }, { 24, 1.0, 2.0 }, { 24, 2.0, 1.0 },
        { 23.976, 1.0, 0.75 }, { 25, 1.0, 0.4 }, { 24, 1.0, 0.25 },
        { 24, 1.0, 1.03 }, { 59.94, 1.0, 1.02 }, { 25, 1.0, 0.97 },
        { 59.94, 1.0, 1.012 }, { 24, 1.0, 1.035 }, { 24, 1.0, 7.5 },
        { 24, 1.0, 0.06 },
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        CASE("speed-change");
        double fps = cases[i].fps, from = cases[i].from, to = cases[i].to;
        int change = (int)(fps * 30 / from);
        struct scenario sc = {
            .fps = fps, .frames = change + (int)(fps * 30 / to) + 10,
            .speed0 = from, .speed1 = to, .change_frame = change, .noise_ms = 0.3,
            .seed = 200 + i,
        };
        if (from != 1.0) {
            // Start at the old speed as an adopted rate: begin at 1.0 and let
            // the estimator adopt the first speed well before the change.
            sc.speed0 = from;
        }
        struct outcome o;
        run_scenario(&sc, &o);
        double change_pct = fabs(to / from - 1.0);
        double tol = change_pct <= 0.04 ? 0.005 : 0.01;
        CHECK(fabs(o.final_nominal - to) <= tol, "%.3f -> %.3f: nominal %.6f",
              from, to, o.final_nominal);

        // Anchors from the change onwards.
        int after = 0, last = -1;
        int64_t change_host = o.due[change];
        for (int a = 0; a < o.anchors && a < MAX_ANCHORS; a++) {
            if (o.anchor_frame[a] >= change) {
                after++;
                last = a;
            }
        }
        int allowed = to < from / 2 ? 3 : 2;
        CHECK(after >= 1 && after <= allowed, "%.3f -> %.3f: %d anchors after the change",
              from, to, after);
        CHECK(last >= 0 && o.anchor_host[last] - change_host <= 5 * SEC,
              "last anchor %.3f s after the change",
              last >= 0 ? (o.anchor_host[last] - change_host) / 1e9 : -1.0);

        // When the new speed is adopted.
        int first_adopt_after = -1;
        // Re-run to find the adoption frame after the change (the outcome
        // records the first adoption, which may be the initial speed's).
        if (from == 1.0) {
            first_adopt_after = o.adopt_frame;
            int64_t new_frame = avf_frame_duration_ns(false, 0,
                                                      1e9 / fps / to);
            if (change_pct > 0.04) {
                // The third frame at the new duration, or the second when one
                // frame already fills the 500 ms averaging window.
                int want = new_frame >= 500 * MS ? change + 1 : change + 2;
                CHECK(first_adopt_after == want,
                      "%.3f -> %.3f adopted at frame %d, expected %d",
                      from, to, first_adopt_after, want);
            } else {
                // 500 ms of frame duration at the new speed after the
                // discontinuity that the duration step causes.
                int64_t frame = (int64_t)llround(1e9 / fps);
                int64_t d1 = avf_frame_duration_ns(false, 0, (double)frame / to);
                int64_t d0 = avf_frame_duration_ns(false, 0, (double)frame / from);
                int64_t gate = d0 / 100 > 250000 ? d0 / 100 : 250000;
                if (llabs(d1 - d0) > gate) {
                    int need = (int)((500 * MS + d1 - 1) / d1);
                    CHECK(first_adopt_after == change + need,
                          "%.3f -> %.3f adopted at frame %d, expected %d",
                          from, to, first_adopt_after, change + need);
                } else {
                    CHECK(first_adopt_after > change &&
                          first_adopt_after <= change + (int)(fps * 1.0),
                          "%.3f -> %.3f adopted at frame %d (change %d)",
                          from, to, first_adopt_after, change);
                }
            }
        }
        free_outcome(&o);
    }

    // A change of less than 1% is never adopted and causes no anchor.
    const double small[] = { 1.005, 0.995, 1.009, 0.992 };
    for (size_t i = 0; i < sizeof(small) / sizeof(small[0]); i++) {
        CASE("speed-change-below-1pct");
        struct scenario sc = {
            .fps = 24, .frames = 24 * 90, .speed0 = 1.0, .speed1 = small[i],
            .change_frame = 24 * 30, .noise_ms = 0.3, .seed = 300 + i,
        };
        struct outcome o;
        run_scenario(&sc, &o);
        CHECK_EQ_I(o.anchors, 1);
        CHECK(o.final_nominal == 1.0, "nominal %.6f", o.final_nominal);
        CHECK(o.adoptions == 0, "%d adoptions", o.adoptions);
        free_outcome(&o);
    }
}

static void test_rate_write_rules(void)
{
    // 9.4 item 4, over noisy schedules with offsets near the slew limit.
    for (int i = 0; i < 12; i++) {
        CASE("rate-write-rules");
        struct scenario sc = {
            .fps = i % 2 ? 23.976 : 59.94, .frames = 24 * 240,
            .speed0 = 1, .speed1 = 1, .change_frame = 1 << 30,
            .offset = (i % 3 - 1) * 0.012, .offset_period_s = i % 4 ? 0 : 20,
            .noise_ms = 4.0, .seed = 400 + i,
        };
        struct outcome o;
        run_scenario(&sc, &o);
        CHECK(o.rate_bounds_ok, "rate beyond 1.5%% of nominal");
        CHECK(o.write_gap_ok, "writes closer than 200 ms");
        CHECK(o.write_size_ok, "a write of 100 ppm of nominal or less");
        CHECK(o.integral_ok, "integral beyond 1.5%%");
        free_outcome(&o);
    }

    CASE("no-long-step-integrated");
    struct avf_clock c;
    avf_clock_init(&c);
    struct avf_clock_result res;
    struct avf_clock_frame in = { .media_ns = 0, .target_ns = 1000 * MS,
                                  .now_ns = 1000 * MS, .timebase_ns = 0 };
    avf_clock_step(&c, &in, &res); // anchor
    in = (struct avf_clock_frame){ .media_ns = 40 * MS, .target_ns = 1040 * MS,
                                   .now_ns = 1040 * MS, .timebase_ns = 30 * MS };
    avf_clock_step(&c, &in, &res); // first evaluation adds nothing
    CHECK(c.integral == 0, "first evaluation integrated");
    in = (struct avf_clock_frame){ .media_ns = 80 * MS, .target_ns = 1641 * MS,
                                   .now_ns = 1641 * MS, .timebase_ns = 70 * MS };
    avf_clock_step(&c, &in, &res); // 601 ms later: not integrated
    CHECK(c.integral == 0, "a step longer than 500 ms was integrated");
    in = (struct avf_clock_frame){ .media_ns = 120 * MS, .target_ns = 2141 * MS,
                                   .now_ns = 2141 * MS, .timebase_ns = 110 * MS };
    avf_clock_step(&c, &in, &res); // exactly 500 ms: integrated
    CHECK(c.integral != 0, "a 500 ms step was not integrated");
}

static void test_deterministic_trace(void)
{
    // 9.4 item 5: identical decisions, rates and integral values to the
    // reference model, for random inputs that exercise every branch.
    for (int run = 0; run < 40; run++) {
        CASE("deterministic-trace");
        struct avf_rng rng = { 0x5EED0000ULL + run };
        struct avf_clock c;
        avf_clock_init(&c);
        static struct ref_est re;
        memset(&re, 0, sizeof(re));
        struct ref_servo rs = { .nominal = 1.0, .applied = 1.0, .has_applied = true };
        int64_t m = 0, now = 5 * SEC, tb = 0;
        int64_t step = 40 * MS;
        int mismatches = 0;
        for (int i = 0; i < 3000 && mismatches < 3; i++) {
            int pick = avf_rng_int(&rng, 0, 99);
            if (pick < 3)
                step = avf_rng_int(&rng, 5, 120) * MS + avf_rng_int(&rng, 0, 999999);
            int64_t dm = pick < 5 ? 0 : (pick < 7 ? -step : step);
            if (pick >= 95)
                dm = step * avf_rng_int(&rng, 2, 12);
            m += dm;
            int64_t d = pick == 50 ? 0 : step + (pick > 90 ? avf_rng_int(&rng, -400000, 400000) : 0);
            now += avf_rng_int(&rng, 1, 700) * MS / 10;
            int64_t target = now + avf_rng_int(&rng, 0, 200) * MS;
            tb += avf_rng_int(&rng, -60, 60) * MS / 3 + step;
            if (pick == 60) {
                avf_clock_pause(&c);
                rs.paused = rs.tb_paused = true;
                rs.applied = 0;
                rs.has_applied = true;
            } else if (pick == 61) {
                avf_clock_resume(&c);
                rs.paused = rs.tb_paused = false;
                rs.anchor = false;
            }

            double nominal = avf_clock_nominal(&c);
            double est_a = 0, est_b = 0;
            bool has_a = avf_estimator_push(&c.est, m, d, nominal, &est_a);
            bool has_b = ref_est_push(&re, m, d, rs.nominal, &est_b);
            if (has_a != has_b || (has_a && est_a != est_b)) {
                avf_test_fail(__FILE__, __LINE__, "run %d frame %d: estimate %d %.17g, "
                              "reference %d %.17g", run, i, has_a, est_a, has_b, est_b);
                mismatches++;
            }
            struct avf_clock_frame in = {
                .media_ns = m, .target_ns = target, .now_ns = now, .timebase_ns = tb,
                .has_estimate = has_a, .estimate = est_a,
            };
            struct avf_clock_result res;
            avf_clock_step(&c, &in, &res);
            double ref_rate = 0;
            int ref_op = ref_step(&rs, m, target, now, tb, has_b, est_b, &ref_rate);
            int op = res.op == AVF_CLOCK_ANCHOR ? REF_ANCHOR :
                     res.op == AVF_CLOCK_SET_RATE ? REF_RATE : REF_KEEP;
            if (op != ref_op || (op != REF_KEEP && res.rate != ref_rate) ||
                c.integral != rs.integral || c.nominal != rs.nominal ||
                c.applied != rs.applied)
            {
                avf_test_fail(__FILE__, __LINE__, "run %d frame %d: op %d rate %.17g "
                              "integral %.17g nominal %.17g, reference op %d rate %.17g "
                              "integral %.17g nominal %.17g", run, i, op, res.rate,
                              c.integral, c.nominal, ref_op, ref_rate, rs.integral,
                              rs.nominal);
                mismatches++;
            }
        }
    }
}

void avf_test_clock(void)
{
    test_conversions();
    test_estimator_vectors();
    test_no_needless_anchors();
    test_one_anchor_per_jump();
    test_speed_changes();
    test_rate_write_rules();
    test_deterministic_trace();
}
