/*
 * Host-side tests for Lucid Engine's AVFoundation video output.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 *
 * These tests compile the output's modules from the mpv tree the pipeline
 * has just patched (engine/lucid.py test-vo) and check them against the
 * behaviour in docs/playback/lucid-engine-patch-spec.md (sections 4 and 9.4).
 */

#ifndef LUCID_VO_TEST_HARNESS_H
#define LUCID_VO_TEST_HARNESS_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

extern int avf_test_cases;
extern int avf_test_failures;
extern const char *avf_test_suite;

void avf_test_fail(const char *file, int line, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

// One case: a named check that counts once.
#define CASE(name) avf_test_case(name)
void avf_test_case(const char *name);

#define CHECK(cond, ...) do { \
        if (!(cond)) \
            avf_test_fail(__FILE__, __LINE__, __VA_ARGS__); \
    } while (0)

#define CHECK_EQ_I(a, b) do { \
        long long a_ = (long long)(a), b_ = (long long)(b); \
        if (a_ != b_) \
            avf_test_fail(__FILE__, __LINE__, "%s == %lld, expected %s == %lld", \
                          #a, a_, #b, b_); \
    } while (0)

#define CHECK_NEAR(a, b, eps) do { \
        double a_ = (a), b_ = (b); \
        if (!(a_ - b_ <= (eps) && b_ - a_ <= (eps))) \
            avf_test_fail(__FILE__, __LINE__, "%s == %.9f, expected %.9f (+/- %g)", \
                          #a, a_, b_, (double)(eps)); \
    } while (0)

// Deterministic pseudo-random numbers (xorshift64*), for reproducible vectors.
struct avf_rng { uint64_t s; };
static inline uint64_t avf_rng_next(struct avf_rng *r)
{
    r->s ^= r->s >> 12;
    r->s ^= r->s << 25;
    r->s ^= r->s >> 27;
    return r->s * 0x2545F4914F6CDD1DULL;
}
static inline double avf_rng_unit(struct avf_rng *r) // [0, 1)
{
    return (avf_rng_next(r) >> 11) * (1.0 / 9007199254740992.0);
}
static inline int avf_rng_int(struct avf_rng *r, int lo, int hi) // [lo, hi]
{
    return lo + (int)(avf_rng_next(r) % (uint64_t)(hi - lo + 1));
}

void avf_test_clock(void);
void avf_test_pacing(void);
void avf_test_geometry(void);
void avf_test_pixels(void);
void avf_test_frame(void);
void avf_test_subtitles(void);

#endif
