/*
 * Lucid Engine: test vectors for the AVFoundation audio output.
 *
 * Copyright (C) 2026 blurbery
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Built by `lucid.py test-audio` on the build host against the audio output
 * sources of the mpv tree the pipeline has just patched (never a copy), and
 * run once per slice. It drives the shipped decision code through fakes of
 * mpv, the session, the renderer, the synchroniser, AVPlayer and the clock,
 * and covers every vector of section 9.3 of the patch specification. It
 * prints how many vectors ran and fails when any failed or none ran.
 */

#include <inttypes.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ao_avfoundation_compressed.h"
#include "ao_avfoundation_core.h"
#include "ao_avfoundation_iec61937.h"
#include "ao_avfoundation_pcm.h"
#include "ao_avfoundation_startup.h"

#if defined(__APPLE__)
#include <CoreMedia/CoreMedia.h>
#endif

// Times are written as integer nanoseconds so that boundaries such as
// "1 s minus 1 ns" stay exact.
#define SEC(n) ((int64_t)(n) * INT64_C(1000000000))
#define MS(n) ((int64_t)(n) * INT64_C(1000000))

// ------------------------------------------------------------ the harness

static int vectors_run;
static int vectors_failed;
static int checks_failed_in_vector;
static const char *vector_name;

static void vector_begin(const char *name)
{
    vector_name = name;
    checks_failed_in_vector = 0;
}

static void vector_end(void)
{
    vectors_run++;
    if (checks_failed_in_vector) {
        vectors_failed++;
        printf("FAIL  %s\n", vector_name);
    } else {
        printf("ok    %s\n", vector_name);
    }
}

#define CHECK(cond, ...) do {                                      \
        if (!(cond)) {                                             \
            checks_failed_in_vector++;                             \
            printf("      %s:%d: %s: ", __FILE__, __LINE__, #cond); \
            printf(__VA_ARGS__);                                   \
            printf("\n");                                          \
        }                                                          \
    } while (0)

// ------------------------------------------------------------- fake mpv

#define MAX_LINES 4096

struct line {
    enum avfao_level level;
    char text[600];
};

struct fake_host {
    int64_t now;
    struct line lines[MAX_LINES];
    int nlines;

    int64_t queued;
    int frame_bytes;
    int reads;
    int64_t ends[8];           // end times of the first reads
    int64_t last_end_ns;
    int last_frames;
    int read_limit;            // -1: return every frame asked for
    bool read_eof;
    const uint8_t *source;     // NULL: silence
    size_t source_len;
    size_t source_pos;
    void (*on_read)(void);
    int stop_streaming;
    int reloads;
    double latency;
};

static struct fake_host F;

static int64_t host_now(void *ctx)
{
    return F.now;
}

static void host_log(void *ctx, enum avfao_level level, const char *fmt, va_list va)
{
    if (F.nlines >= MAX_LINES)
        return;
    struct line *l = &F.lines[F.nlines++];
    l->level = level;
    vsnprintf(l->text, sizeof(l->text), fmt, va);
    size_t n = strlen(l->text);
    if (n && l->text[n - 1] == '\n')
        l->text[n - 1] = '\0';
}

static int host_read(void *ctx, void *data, int frames, int64_t end_ns, bool *eof)
{
    F.reads++;
    if (F.reads <= 8)
        F.ends[F.reads - 1] = end_ns;
    F.last_end_ns = end_ns;
    F.last_frames = frames;
    if (F.on_read)
        F.on_read();
    int n = F.read_limit < 0 ? frames : (F.read_limit < frames ? F.read_limit : frames);
    size_t bytes = (size_t)n * F.frame_bytes;
    uint8_t *out = data;
    for (size_t i = 0; i < bytes; i++) {
        if (F.source && F.source_pos < F.source_len) {
            out[i] = F.source[F.source_pos++];
        } else {
            out[i] = 0;
        }
    }
    *eof = F.read_eof;
    return n;
}

static int64_t host_queued(void *ctx)
{
    return F.queued;
}

static void host_stop_streaming(void *ctx)
{
    F.stop_streaming++;
}

static void host_request_reload(void *ctx)
{
    F.reloads++;
}

static double host_latency(void *ctx)
{
    return F.latency;
}

static const struct avfao_host_ops host_ops = {
    .now = host_now,
    .log = host_log,
    .read = host_read,
    .queued_frames = host_queued,
    .stop_streaming = host_stop_streaming,
    .request_reload = host_request_reload,
    .output_latency = host_latency,
};

static const struct avfao_host HOST = {.ops = &host_ops, .ctx = NULL};

static void host_reset(void)
{
    memset(&F, 0, sizeof(F));
    F.read_limit = -1;
    F.frame_bytes = 4;
}

static void clear_lines(void)
{
    F.nlines = 0;
}

static int count_text(const char *text)
{
    int n = 0;
    for (int i = 0; i < F.nlines; i++)
        n += strcmp(F.lines[i].text, text) == 0;
    return n;
}

static int count_prefix(const char *prefix)
{
    int n = 0;
    for (int i = 0; i < F.nlines; i++)
        n += strncmp(F.lines[i].text, prefix, strlen(prefix)) == 0;
    return n;
}

static int find_text(const char *text)
{
    for (int i = 0; i < F.nlines; i++) {
        if (strcmp(F.lines[i].text, text) == 0)
            return i;
    }
    return -1;
}

static int find_prefix(const char *prefix)
{
    for (int i = 0; i < F.nlines; i++) {
        if (strncmp(F.lines[i].text, prefix, strlen(prefix)) == 0)
            return i;
    }
    return -1;
}

static bool has_line(enum avfao_level level, const char *text)
{
    int i = find_text(text);
    return i >= 0 && F.lines[i].level == level;
}

static void dump_lines(void)
{
    for (int i = 0; i < F.nlines; i++)
        printf("        [%d] %s\n", F.lines[i].level, F.lines[i].text);
}

// -------------------------------------------------- fake AVPlayer and item

struct fake_player {
    int item_creates;
    int teardowns;
    int rate_calls;
    int rate_one;
    int rate_zero;
    int seeks;
    bool timebase_valid;
    int64_t timebase_ns;
    bool current_valid;
    int64_t current_ns;
    int status;
    int time_control;
    bool failed;
    int serves;
    int64_t gap;
    int timer_armed;
    int timer_idle;
    bool create_fails;
    bool clock_after_rate_set; // rate 1 moves the clock to clock_after_rate
    int64_t clock_after_rate;
};

static struct fake_player P;
static struct avfao_cx CX;
static struct avfao_trace TRACE;

static bool cx_item_create(void *ctx)
{
    if (P.create_fails)
        return false;
    P.item_creates++;
    return true;
}

static void cx_item_teardown(void *ctx)
{
    P.teardowns++;
    P.rate_zero++;
}

static void cx_set_rate(void *ctx, float rate)
{
    P.rate_calls++;
    if (rate == 1) {
        P.rate_one++;
        if (P.clock_after_rate_set)
            P.timebase_ns = P.current_ns = P.clock_after_rate;
    }
    if (rate == 0)
        P.rate_zero++;
}

static void cx_seek(void *ctx)
{
    P.seeks++;
}

static bool cx_timebase(void *ctx, int64_t *ns)
{
    if (!P.timebase_valid)
        return false;
    *ns = P.timebase_ns;
    return true;
}

static bool cx_current(void *ctx, int64_t *ns)
{
    if (!P.current_valid)
        return false;
    *ns = P.current_ns;
    return true;
}

static int cx_status(void *ctx)
{
    return P.status;
}

static int cx_time_control(void *ctx)
{
    return P.time_control;
}

static bool cx_failure(void *ctx, char *desc, size_t ds, char *domain, size_t dms, long *code)
{
    if (!P.failed)
        return false;
    snprintf(desc, ds, "%s", "Cannot Decode");
    snprintf(domain, dms, "%s", "AVFoundationErrorDomain");
    *code = -11821;
    return true;
}

static void cx_serve(void *ctx)
{
    P.serves++;
}

static int64_t cx_gap(void *ctx)
{
    return P.gap;
}

static void cx_timer(void *ctx, bool armed)
{
    if (armed) {
        P.timer_armed++;
    } else {
        P.timer_idle++;
    }
}

static const struct avfao_cx_ops cx_ops = {
    .item_create = cx_item_create,
    .item_teardown = cx_item_teardown,
    .set_rate = cx_set_rate,
    .seek_to_start = cx_seek,
    .timebase_time = cx_timebase,
    .current_time = cx_current,
    .item_status = cx_status,
    .time_control = cx_time_control,
    .failure = cx_failure,
    .serve = cx_serve,
    .reader_gap = cx_gap,
    .timer = cx_timer,
};

struct cx_setup {
    double lead, grace, first_grace;
    bool anchor_start, anchor_resume, initial_mode;
    enum avfao_codec codec;
    int carrier;
};

static struct cx_setup default_setup(void)
{
    return (struct cx_setup){
        .lead = 8, .grace = 2, .first_grace = 2,
        .codec = AVFAO_CODEC_EAC3, .carrier = 192000,
    };
}

// A playing item with nothing fed: the preamble of 9.3 (item ready, clock
// 0, initial-start mode off unless asked for).
static void cx_begin(const struct cx_setup *s)
{
    host_reset();
    memset(&P, 0, sizeof(P));
    memset(&TRACE, 0, sizeof(TRACE));
    avfao_block_clear();
    P.timebase_valid = true;
    P.status = AVFAO_ITEM_READY;
    P.gap = -1;
    struct avfao_cx_cfg cfg = {
        .lead = s->lead, .grace = s->grace, .first_grace = s->first_grace,
        .anchor_start = s->anchor_start, .anchor_resume = s->anchor_resume,
    };
    bool ok = avfao_cx_init(&CX, &HOST, &cx_ops, NULL, &TRACE, s->codec, s->carrier, &cfg);
    CHECK(ok, "avfao_cx_init failed");
    CX.st.initial_mode = s->initial_mode;
    F.read_limit = 0;
    avfao_cx_start(&CX);
    F.read_limit = -1;
    clear_lines();
    P.rate_calls = P.rate_one = P.rate_zero = P.seeks = 0;
    P.serves = 0;
    F.reads = 0;
}

static void cx_finish(void)
{
    avfao_cx_uninit(&CX);
}

static size_t put_burst(uint8_t *buf, int type_byte, int pd, int payload_len, bool sync,
                        int padding);

// Whole E-AC-3 bursts (one 32 ms period each) as mpv's spdif muxer writes
// them; the first `unsynced` lack the syncword.
static uint8_t stream_buf[24576 * 48];

static void use_eac3_stream(int bursts, int unsynced)
{
    size_t n = 0;
    for (int i = 0; i < bursts && i < 48; i++)
        n += put_burst(stream_buf + n, 0x15, 100, 100, i >= unsynced, 24576 - 8 - 100);
    F.source = stream_buf;
    F.source_len = n;
    F.source_pos = 0;
}

// One supervision evaluation at host time t with fed duration f.
static void tick(int64_t t, int64_t f)
{
    F.now = t;
    CX.fed_ns = f;
    avfao_cx_supervise(&CX);
}

static void tick_c(int64_t t, int64_t f, int64_t c)
{
    P.timebase_ns = c;
    tick(t, f);
}

static bool deadline_is(int64_t when)
{
    return CX.st.deadline_set && !CX.st.deadline_cleared && CX.st.deadline_ns == when;
}

// ------------------------------------------------------------ 9.3.1

static void test_supervision(void)
{
    struct cx_setup s = default_setup();

    vector_begin("9.3.1 P1 not primed: rate never requested");
    cx_begin(&s);
    tick(SEC(0), MS(400));
    tick(SEC(6), MS(900));
    CHECK(P.rate_one == 0, "rate requests %d", P.rate_one);
    CHECK(P.seeks == 0 && !CX.fallback, "seeks %d", P.seeks);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 P2 primed at 1 s: rate once, deadline 9");
    cx_begin(&s);
    tick(SEC(0), MS(400));
    tick(SEC(6), MS(900));
    tick(SEC(7), SEC(1));
    CHECK(P.rate_one == 1, "rate requests %d", P.rate_one);
    CHECK(deadline_is(SEC(9)), "deadline %" PRId64, CX.st.deadline_ns);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 P3 end of file primes");
    cx_begin(&s);
    // mpv reports end of file on the step's first read.
    F.now = SEC(3);
    F.read_eof = true;
    F.read_limit = 0;
    avfao_cx_step(&CX);
    CHECK(CX.eof && F.stop_streaming == 1, "no end of file");
    tick(SEC(3), MS(300));
    CHECK(P.rate_one == 1, "rate requests %d", P.rate_one);
    CHECK(deadline_is(SEC(5)), "deadline %" PRId64, CX.st.deadline_ns);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 P4 paused: nothing");
    cx_begin(&s);
    avfao_cx_pause(&CX, true);
    P.rate_one = P.rate_zero = P.rate_calls = 0;
    tick(SEC(30), SEC(5));
    CHECK(P.rate_calls == 0 && P.seeks == 0 && !CX.fallback, "calls %d", P.rate_calls);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 P5 no item: nothing");
    cx_begin(&s);
    avfao_cx_reset(&CX);
    CX.playing = true;
    P.rate_one = P.rate_zero = P.rate_calls = 0;
    tick(SEC(30), SEC(5));
    CHECK(P.rate_calls == 0 && P.seeks == 0 && !CX.fallback, "calls %d", P.rate_calls);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 P6 fallback already requested: nothing");
    cx_begin(&s);
    avfao_cx_fallback(&CX);
    P.rate_one = P.rate_zero = P.rate_calls = 0;
    tick(SEC(30), SEC(5));
    CHECK(P.rate_calls == 0 && P.seeks == 0 && F.reloads == 1, "calls %d", P.rate_calls);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 P7 grace 3: deadline 3 after both ticks");
    s.grace = 3;
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    CHECK(P.rate_one == 1 && deadline_is(SEC(3)), "after first tick");
    tick(SEC(1), SEC(16));
    CHECK(P.rate_one == 1 && deadline_is(SEC(3)), "after second tick");
    cx_finish();
    vector_end();
    s = default_setup();

    vector_begin("9.3.1 E1 engagement at 1.5 s");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick_c(MS(1500), SEC(3), 1);
    CHECK(P.seeks == 0, "seeks %d", P.seeks);
    CHECK(CX.st.deadline_cleared, "deadline not cleared");
    CHECK(has_line(AVFAO_V, "compressed clock engaged after 1.500 s, seeked 0, anchors 0"),
          "engaged line missing");
    cx_finish();
    vector_end();

    vector_begin("9.3.1 E2 engagement before a later deadline");
    s.grace = 3;
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(2), SEC(16));
    tick_c(MS(2500), SEC(16), MS(100));
    CHECK(P.seeks == 0 && CX.st.deadline_cleared, "seeks %d", P.seeks);
    cx_finish();
    vector_end();
    s = default_setup();

    vector_begin("9.3.1 E3 seek, then engagement, then a clock of 0");
    cx_begin(&s);
    tick(SEC(5), SEC(1));
    tick(SEC(7), SEC(2));
    CHECK(P.seeks == 1, "seek at 7: %d", P.seeks);
    tick_c(SEC(8), SEC(3), MS(200));
    CHECK(CX.st.deadline_cleared, "not cleared at 8");
    CHECK(has_line(AVFAO_V, "compressed clock engaged after 3.000 s, seeked 1, anchors 0"),
          "engaged line missing");
    clear_lines();
    tick_c(SEC(20), SEC(3), 0);
    CHECK(F.nlines == 0 && P.seeks == 1 && !CX.fallback, "something at 20");
    cx_finish();
    vector_end();

    vector_begin("9.3.1 E4 unpause moves the deadline");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    F.now = MS(500);
    avfao_cx_pause(&CX, true);
    F.now = SEC(1);
    avfao_cx_pause(&CX, false);
    CHECK(deadline_is(SEC(3)), "deadline %" PRId64, CX.st.deadline_ns);
    tick_c(MS(2500), SEC(2), MS(100));
    CHECK(has_line(AVFAO_V, "compressed clock engaged after 2.500 s, seeked 0, anchors 0"),
          "engaged line missing");
    cx_finish();
    vector_end();

    vector_begin("9.3.1 R1 progress before the deadline does not postpone the seek");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(1), SEC(2));
    CHECK(deadline_is(SEC(2)), "deadline %" PRId64, CX.st.deadline_ns);
    tick(SEC(2), SEC(4));
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 R2 grace 3: seek at 3");
    s.grace = 3;
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(3), SEC(16));
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    cx_finish();
    vector_end();
    s = default_setup();

    vector_begin("9.3.1 R3 one seek on each item");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(2), SEC(1));
    CHECK(P.seeks == 1, "first item seeks %d", P.seeks);
    avfao_cx_reset(&CX);
    avfao_cx_start(&CX);
    CHECK(P.item_creates == 2, "items %d", P.item_creates);
    tick(SEC(5), SEC(1));
    tick(SEC(7), SEC(1));
    CHECK(P.seeks == 2, "seeks %d", P.seeks);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 R4 the seek's calls: one seek, rate 1 twice, nothing else");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(2), SEC(1));
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    CHECK(P.rate_one == 2 && P.rate_calls == 2, "rate calls %d (rate 1: %d)",
          P.rate_calls, P.rate_one);
    CHECK(P.teardowns == 0 && P.item_creates == 1, "other item calls");
    CHECK(has_line(AVFAO_WARN, "playback did not engage; seeking to the stream start"),
          "warning missing");
    CHECK(count_prefix("first start recovery after") == 0, "first-start line outside mode");
    cx_finish();
    vector_end();

    vector_begin("9.3.1 W1 slow source extends the deadline after the seek");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(2), SEC(2));
    CHECK(P.seeks == 1 && deadline_is(SEC(4)), "seek at 2");
    tick(SEC(3), SEC(5));
    CHECK(deadline_is(SEC(5)), "deadline %" PRId64, CX.st.deadline_ns);
    tick(MS(4500), SEC(7));
    CHECK(deadline_is(MS(6500)), "deadline %" PRId64, CX.st.deadline_ns);
    tick(SEC(6), SEC(9));
    CHECK(deadline_is(SEC(8)), "deadline %" PRId64, CX.st.deadline_ns);
    tick(MS(7900), SEC(9));
    CHECK(!CX.fallback, "fallback at 7.9");
    tick(SEC(8), SEC(9));
    CHECK(CX.fallback, "no fallback at 8");
    CHECK(has_line(AVFAO_ERR, "native compressed playback did not start; falling back to PCM"),
          "fallback line missing");
    cx_finish();
    vector_end();

    vector_begin("9.3.1 W2 a small gain extends by the grace from that tick");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(2), SEC(1));
    CHECK(P.seeks == 1 && deadline_is(SEC(4)), "seek at 2");
    tick(MS(2050), SEC(1));
    CHECK(deadline_is(MS(4050)), "deadline %" PRId64, CX.st.deadline_ns);
    tick(SEC(4), SEC(1));
    CHECK(!CX.fallback, "fallback at 4");
    tick(MS(4050), SEC(1));
    CHECK(CX.fallback, "no fallback at 4.05");
    cx_finish();
    vector_end();

    vector_begin("9.3.1 W3 a full start-up lead does not extend");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(2), SEC(16));
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    tick(SEC(4), SEC(16));
    CHECK(CX.fallback, "no fallback at 4");
    cx_finish();
    vector_end();

    vector_begin("9.3.1 F1 fallback once, block set, rate 0");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    tick(SEC(2), SEC(1));
    tick(SEC(3), SEC(1));
    CHECK(deadline_is(SEC(5)), "deadline %" PRId64, CX.st.deadline_ns);
    P.rate_zero = 0;
    tick(SEC(5), SEC(1));
    CHECK(CX.fallback && F.reloads == 1, "fallback %d reloads %d", CX.fallback, F.reloads);
    CHECK(avfao_blocked(AVFAO_CODEC_EAC3) && !avfao_blocked(AVFAO_CODEC_AC3), "block");
    CHECK(P.rate_zero == 1, "rate 0 calls %d", P.rate_zero);
    tick(SEC(9), SEC(1));
    CHECK(F.reloads == 1, "reloads %d", F.reloads);
    cx_finish();
    vector_end();

    struct cx_setup airplay = default_setup();
    airplay.grace = 1;
    airplay.first_grace = 0.25;
    airplay.initial_mode = true;

    vector_begin("9.3.1 I1 initial grace, first-start line, warning, seek");
    cx_begin(&airplay);
    tick(SEC(0), SEC(1));
    CHECK(deadline_is(MS(250)), "deadline %" PRId64, CX.st.deadline_ns);
    tick(MS(200), SEC(2));
    CHECK(P.seeks == 0, "seek at 0.2");
    tick(MS(250), SEC(2));
    int first = find_text("first start recovery after 0.250 s");
    int warn = find_text("playback did not engage; seeking to the stream start");
    CHECK(first >= 0 && F.lines[first].level == AVFAO_V, "first-start line");
    CHECK(warn > first && F.lines[warn].level == AVFAO_WARN, "warning after it");
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 I2 an item that is not ready is held");
    cx_begin(&airplay);
    P.status = 0;
    tick(SEC(0), SEC(1));
    tick(MS(600), SEC(2));
    CHECK(P.seeks == 0, "seek at 0.6");
    P.status = AVFAO_ITEM_READY;
    tick(MS(650), SEC(2));
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 I3 an item never ready seeks at the ordinary grace");
    cx_begin(&airplay);
    P.status = 0;
    tick(SEC(0), SEC(1));
    tick(SEC(1), SEC(2));
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 I4 initial-start mode off");
    struct cx_setup off = airplay;
    off.initial_mode = false;
    cx_begin(&off);
    tick(SEC(0), SEC(1));
    CHECK(deadline_is(SEC(1)), "deadline %" PRId64, CX.st.deadline_ns);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 I5 initial grace capped at the ordinary grace");
    struct cx_setup capped = airplay;
    capped.first_grace = 3;
    cx_begin(&capped);
    tick(SEC(0), SEC(1));
    CHECK(deadline_is(SEC(1)), "deadline %" PRId64, CX.st.deadline_ns);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 I6 engagement ends initial-start mode for later items");
    cx_begin(&airplay);
    tick(SEC(0), SEC(1));
    tick_c(MS(100), SEC(2), MS(100));
    CHECK(!CX.st.initial_mode, "mode still on");
    avfao_cx_reset(&CX);
    avfao_cx_start(&CX);
    tick(SEC(5), SEC(1));
    CHECK(P.seeks == 0, "seeks %d", P.seeks);
    CHECK(deadline_is(SEC(6)), "deadline %" PRId64, CX.st.deadline_ns);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 I7 unpause before engagement uses the ordinary grace");
    cx_begin(&airplay);
    tick(SEC(0), SEC(1));
    F.now = MS(100);
    avfao_cx_pause(&CX, true);
    F.now = MS(200);
    avfao_cx_pause(&CX, false);
    CHECK(deadline_is(MS(1200)), "deadline %" PRId64, CX.st.deadline_ns);
    tick(MS(300), SEC(2));
    CHECK(P.seeks == 0, "seek at 0.3");
    clear_lines();
    tick(MS(1200), SEC(2));
    CHECK(has_line(AVFAO_V, "first start recovery after 1.200 s"), "first-start line");
    CHECK(P.seeks == 1, "seeks %d", P.seeks);
    cx_finish();
    vector_end();

    vector_begin("9.3.1 I8 initial-start mode survives a reset");
    cx_begin(&airplay);
    tick(SEC(0), SEC(1));
    avfao_cx_reset(&CX);
    avfao_cx_start(&CX);
    tick(SEC(10), SEC(1));
    CHECK(deadline_is(MS(10250)), "deadline %" PRId64, CX.st.deadline_ns);
    cx_finish();
    vector_end();
}

// ------------------------------------------------------------ 9.3.2

static void test_start_anchoring(void)
{
    struct row {
        const char *name;
        int64_t since;          // since the last anchor read; -1: pacing at origin
        int64_t fed;
        int64_t clock;
        bool eof;
        bool option;
        bool rate_requested;
        bool fallback;
        bool room;
        int64_t now;
        bool eligible;
    } rows[] = {
        {"0.25 s, fed 10", MS(250), SEC(10), 0, false, true, true, false, true, SEC(30), true},
        {"0.1 s, fed 19.5", MS(100), MS(19500), 0, false, true, true, false, true, SEC(30), true},
        {"0.1 s - 1 ns", MS(100) - 1, SEC(12), 0, false, true, true, false, true, SEC(30), false},
        {"fed 20", SEC(1), SEC(20), 0, false, true, true, false, true, SEC(30), false},
        {"fed 20 s - 1 ns", SEC(1), SEC(20) - 1, 0, false, true, true, false, true, SEC(30), true},
        {"clock 1 ns", SEC(1), SEC(12), 1, false, true, true, false, true, SEC(30), false},
        {"end of file", SEC(1), SEC(12), 0, true, true, true, false, true, SEC(30), false},
        {"option off", SEC(1), SEC(12), 0, false, false, true, false, true, SEC(30), false},
        {"rate 1 not requested", SEC(1), SEC(3), 0, false, true, false, false, true, SEC(30), false},
        {"fallback requested", SEC(1), SEC(12), 0, false, true, true, true, true, SEC(30), false},
        {"no window room", SEC(1), SEC(12), 0, false, true, true, false, false, SEC(30), false},
        {"pacing at origin, host 30 s", -1, SEC(12), 0, false, true, true, false, true, SEC(30), true},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        char name[160];
        snprintf(name, sizeof(name), "9.3.2 start anchoring: %s", rows[i].name);
        vector_begin(name);
        struct avfao_startup st;
        avfao_startup_init(&st);
        st.rate_requested = rows[i].rate_requested;
        st.anchor_pacing_ns = rows[i].since < 0 ? 0 : rows[i].now - rows[i].since;
        struct avfao_startup_cfg cfg;
        avfao_startup_cfg_init(&cfg, 8, 2, 2, rows[i].option, false);
        struct avfao_startup_view v = {
            .now_ns = rows[i].now, .fed_ns = rows[i].fed, .clock_ns = rows[i].clock,
            .eof = rows[i].eof, .item_ready = true,
        };
        bool due = avfao_start_anchor_due(&st, &cfg, &v, rows[i].fallback, rows[i].room);
        CHECK(due == rows[i].eligible, "got %d", due);
        vector_end();
    }

    // The same rule inside a real feed step: one anchor read, counted.
    vector_begin("9.3.2 start anchoring in a feed step reads once and counts it");
    struct cx_setup s = default_setup();
    s.anchor_start = true;
    cx_begin(&s);
    F.queued = 100000;
    // Rate 1 from supervision leaves the pacing time at mpv's clock origin,
    // so the step at 29.9 s anchors, and so does the one 0.1 s later.
    tick(SEC(29), MS(19500));
    CHECK(P.rate_one == 1 && CX.st.anchor_pacing_ns == 0, "rate 1");
    F.now = SEC(30) - MS(100);
    avfao_cx_step(&CX);
    F.reads = 0;
    F.now = SEC(30);
    avfao_cx_step(&CX);
    CHECK(F.reads == 1, "reads %d", F.reads);
    CHECK(CX.st.anchors == 2, "anchors %d", CX.st.anchors);
    CHECK(CX.st.anchor_pacing_ns == SEC(30), "pacing %" PRId64, CX.st.anchor_pacing_ns);
    cx_finish();
    vector_end();
}

// ------------------------------------------------------------ 9.3.3

struct resume_row {
    const char *name;
    bool pending;
    int64_t since_unpause;
    int64_t since_anchor;
    int64_t clock;
    int64_t recorded;
    bool eof;
    bool option;
    bool read_fallback;
    bool failed;
    // Expected.
    bool read;
    bool resumed_line;
    bool still_pending;
    bool no_serving;
};

static struct avfao_cx *hook_cx;

static void fallback_on_read(void)
{
    avfao_cx_fallback(hook_cx);
}

static void run_resume_row(const struct resume_row *r)
{
    char name[200];
    snprintf(name, sizeof(name), "9.3.3 resume: %s", r->name);
    vector_begin(name);
    struct cx_setup s = default_setup();
    s.anchor_resume = r->option;
    cx_begin(&s);

    int64_t now = SEC(100);
    int64_t unpaused = now - r->since_unpause;
    F.queued = 100000;
    P.current_valid = true;
    // The fed duration is an input, as in the ticks of 9.3: enough that
    // filling has nothing to do, unless a read in filling must request the
    // fallback.
    int64_t fed = r->read_fallback ? r->clock + SEC(4) : r->clock + SEC(20);
    tick(SEC(50), fed);
    CHECK(P.rate_one == 1, "rate 1 not requested");
    P.timebase_ns = P.current_ns = r->recorded;
    if (r->pending) {
        // A real pause and unpause record the resume; the unpause's own
        // step makes the first anchor read when the option is on.
        F.now = unpaused - MS(100);
        avfao_cx_pause(&CX, true);
        F.now = unpaused;
        avfao_cx_pause(&CX, false);
        if (r->option && r->since_anchor < r->since_unpause) {
            // The latest anchor read, which reports mpv's end of file in the
            // end-of-file row.
            F.read_eof = r->eof;
            F.now = now - r->since_anchor;
            avfao_cx_step(&CX);
            CHECK(CX.eof == r->eof, "end of file %d", CX.eof);
        }
    }

    F.now = now;
    P.timebase_ns = P.current_ns = r->clock;
    if (r->read_fallback) {
        hook_cx = &CX;
        F.on_read = fallback_on_read;
    }
    P.failed = r->failed;
    clear_lines();
    F.reads = 0;
    P.serves = 0;
    P.seeks = 0;

    avfao_cx_step(&CX);

    int reads_expected = r->read ? 1 : (r->read_fallback ? 1 : 0);
    CHECK(F.reads == reads_expected, "reads %d, expected %d", F.reads, reads_expected);
    int resumed = count_prefix("compressed clock resumed after ");
    CHECK(resumed == (r->resumed_line ? 1 : 0), "resumed lines %d", resumed);
    CHECK(CX.st.resume_pending == r->still_pending, "pending %d", CX.st.resume_pending);
    if (r->no_serving) {
        CHECK(P.serves == 0, "serves %d", P.serves);
        CHECK(P.seeks == 0 && count_prefix("compressed clock engaged") == 0,
              "supervision ran");
    }
    if (r->failed) {
        int rej = find_text("player rejected the compressed stream: Cannot Decode "
                            "(AVFoundationErrorDomain:-11821)");
        int fb = find_text("falling back to PCM");
        CHECK(rej >= 0 && F.lines[rej].level == AVFAO_ERR, "rejection line");
        CHECK(fb == rej + 1 && F.lines[fb].level == AVFAO_ERR, "separate fallback line");
        CHECK(F.reloads == 1 && CX.fallback, "fallback");
    }
    if (checks_failed_in_vector)
        dump_lines();
    F.on_read = NULL;
    cx_finish();
    vector_end();
}

static void test_resume(void)
{
    const struct resume_row rows[] = {
        {"0.7 s, 0.3 s, 30 and 30", true, MS(700), MS(300), SEC(30), SEC(30), false, true,
         false, false, true, false, true, false},
        {"clock 29.5 below 30", true, MS(700), MS(300), MS(29500), SEC(30), false, true,
         false, false, true, false, true, false},
        {"clock 0 and 0", true, MS(700), MS(300), 0, 0, false, true,
         false, false, true, false, true, false},
        {"clock 30 + 1 ns: resumed", true, MS(700), MS(300), SEC(30) + 1, SEC(30), false, true,
         false, false, false, true, false, false},
        {"2 s - 1 ns since unpause", true, SEC(2) - 1, MS(300), SEC(30), SEC(30), false, true,
         false, false, true, false, true, false},
        {"2 s since unpause", true, SEC(2), MS(300), SEC(30), SEC(30), false, true,
         false, false, false, false, true, false},
        {"0.1 s - 1 ns since the last anchor", true, MS(700), MS(100) - 1, SEC(30), SEC(30),
         false, true, false, false, false, false, true, false},
        {"end of file", true, MS(700), MS(300), SEC(30), SEC(30), true, true,
         false, false, false, false, true, false},
        {"option off", true, MS(700), MS(300), SEC(30), SEC(30), false, false,
         false, false, false, false, true, false},
        {"option off, clock 31: resumed", true, MS(700), MS(300), SEC(31), SEC(30), false, false,
         false, false, false, true, false, false},
        {"no pending resume", false, MS(700), MS(300), SEC(31), SEC(30), false, true,
         false, false, false, false, false, false},
        {"a read requested a fallback: resumed, nothing after", true, MS(700), MS(300),
         SEC(31), SEC(30), false, true, true, false, false, true, false, true},
        {"item failed: rejection, resume stays pending", true, MS(700), MS(300), SEC(31),
         SEC(30), false, true, false, true, false, false, true, true},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++)
        run_resume_row(&rows[i]);

    vector_begin("9.3.3 resume: the feed step at the end of an unpause anchors");
    struct cx_setup s = default_setup();
    s.anchor_resume = true;
    cx_begin(&s);
    F.queued = 100000;
    P.timebase_ns = SEC(30);
    tick(SEC(29), SEC(40));
    F.now = MS(29500);
    avfao_cx_pause(&CX, true);
    F.reads = 0;
    F.now = SEC(30);
    avfao_cx_pause(&CX, false);
    CHECK(F.reads == 1, "reads %d", F.reads);
    CHECK(CX.st.resume_pending, "no pending resume");
    CHECK(CX.st.resume_clock_ns == SEC(30) && CX.st.resume_ns == SEC(30), "recorded");
    cx_finish();
    vector_end();
}

// ------------------------------------------------------------ 9.3.4

static void test_prefetch_compressed(void)
{
    struct row {
        int64_t queued;
        int64_t fed;
        int64_t position;
        bool skipped;
    } rows[] = {
        {0, SEC(3), 0, true},
        {4799, SEC(3), 0, true},
        {4800, SEC(3), 0, false},
        {0, SEC(3), SEC(2), true},
        {0, SEC(3), SEC(2) + 1, false},
        {0, SEC(3), SEC(3), false},
        {0, 0, 0, false},
        {100, SEC(12), 0, true},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        char name[160];
        snprintf(name, sizeof(name), "9.3.4 compressed prefetch guard: queued %" PRId64
                 ", fed %.3f, position %.9f", rows[i].queued,
                 rows[i].fed / 1e9, rows[i].position / 1e9);
        vector_begin(name);
        struct cx_setup s = default_setup();
        s.carrier = 48000; // a planned read of 4800 frames
        s.codec = AVFAO_CODEC_AC3;
        cx_begin(&s);
        F.now = SEC(10);
        F.queued = rows[i].queued;
        F.read_limit = 0; // no data comes back, so at most one read
        CX.fed_ns = rows[i].fed;
        P.timebase_ns = rows[i].position;
        P.current_valid = true;
        P.current_ns = rows[i].position;
        avfao_cx_step(&CX);
        bool skipped = F.reads == 0;
        CHECK(skipped == rows[i].skipped, "reads %d", F.reads);
        CHECK(F.reads == 0 || F.last_frames == 4800, "planned %d", F.last_frames);
        cx_finish();
        vector_end();
    }
}

// ------------------------------------------------- fake renderer and sync

struct fake_renderer {
    int id;
    float volume;
    bool muted;
    bool observed;
    bool released;
    bool ready;
    int status;
    int flushes;
    int enqueued;
    int request_when_ready;
    int stop_requesting;
};

struct fake_sync {
    int id;
    bool released;
    double rate;
    int64_t time;
};

static struct fake_renderer renderers[16];
static struct fake_sync syncs[16];
static int nrenderers, nsyncs;

struct fake_pcm {
    bool renderer_fails;
    bool sync_fails;
    int timer_on;
    int timer_off;
    int restarts;
    int enqueue_fails;
    int buffers_live;
};

static struct fake_pcm R;
static struct avfao_pcm PCM;

static int64_t pcm_sync_time(void *ctx, void *sync)
{
    return ((struct fake_sync *)sync)->time;
}

static double pcm_sync_rate(void *ctx, void *sync)
{
    return ((struct fake_sync *)sync)->rate;
}

static void pcm_set_rate(void *ctx, void *sync, double rate)
{
    ((struct fake_sync *)sync)->rate = rate;
}

static bool pcm_ready(void *ctx, void *renderer)
{
    return ((struct fake_renderer *)renderer)->ready;
}

static int pcm_status(void *ctx, void *renderer)
{
    return ((struct fake_renderer *)renderer)->status;
}

static int pcm_sufficient(void *ctx, void *renderer)
{
    return 1;
}

static void pcm_flush(void *ctx, void *renderer)
{
    ((struct fake_renderer *)renderer)->flushes++;
}

static void pcm_stop_requesting(void *ctx, void *renderer)
{
    ((struct fake_renderer *)renderer)->stop_requesting++;
}

static void pcm_request_when_ready(void *ctx, void *renderer)
{
    ((struct fake_renderer *)renderer)->request_when_ready++;
}

static void *pcm_buffer_new(void *ctx, size_t bytes)
{
    R.buffers_live++;
    return malloc(bytes);
}

static void pcm_buffer_free(void *ctx, void *buffer)
{
    R.buffers_live--;
    free(buffer);
}

static bool pcm_enqueue(void *ctx, void *renderer, void *buffer, size_t bytes,
                        int frames, int64_t pts)
{
    R.buffers_live--;
    free(buffer);
    if (R.enqueue_fails)
        return false;
    ((struct fake_renderer *)renderer)->enqueued++;
    return true;
}

static void pcm_timer(void *ctx, bool on)
{
    if (on) {
        R.timer_on++;
    } else {
        R.timer_off++;
    }
}

static void *pcm_renderer_new(void *ctx)
{
    if (R.renderer_fails)
        return NULL;
    if (nrenderers >= (int)(sizeof(renderers) / sizeof(renderers[0]))) {
        CHECK(false, "fake renderer pool exhausted");
        return NULL;
    }
    struct fake_renderer *r = &renderers[nrenderers];
    *r = (struct fake_renderer){.id = nrenderers, .volume = 1, .ready = true};
    nrenderers++;
    return r;
}

static void *pcm_sync_new(void *ctx, void *renderer)
{
    if (R.sync_fails)
        return NULL;
    if (nsyncs >= (int)(sizeof(syncs) / sizeof(syncs[0]))) {
        CHECK(false, "fake synchroniser pool exhausted");
        return NULL;
    }
    struct fake_sync *s = &syncs[nsyncs];
    *s = (struct fake_sync){.id = nsyncs};
    nsyncs++;
    return s;
}

static float pcm_volume(void *ctx, void *renderer)
{
    return ((struct fake_renderer *)renderer)->volume;
}

static void pcm_set_volume(void *ctx, void *renderer, float volume)
{
    ((struct fake_renderer *)renderer)->volume = volume;
}

static bool pcm_muted(void *ctx, void *renderer)
{
    return ((struct fake_renderer *)renderer)->muted;
}

static void pcm_set_muted(void *ctx, void *renderer, bool muted)
{
    ((struct fake_renderer *)renderer)->muted = muted;
}

static void pcm_observe(void *ctx, void *renderer, bool on)
{
    ((struct fake_renderer *)renderer)->observed = on;
}

static void pcm_release(void *ctx, void *renderer, void *sync)
{
    if (renderer) {
        struct fake_renderer *r = renderer;
        // No observer may outlive its renderer.
        CHECK(!r->observed, "renderer %d released while observed", r->id);
        r->released = true;
    }
    if (sync)
        ((struct fake_sync *)sync)->released = true;
}

static void pcm_restart(void *ctx)
{
    R.restarts++;
    // As the glue does it on the AO queue: the driver's reset, then start.
    avfao_pcm_reset(&PCM);
    avfao_pcm_start(&PCM);
}

static const struct avfao_pcm_ops pcm_ops = {
    .sync_time = pcm_sync_time,
    .sync_rate = pcm_sync_rate,
    .set_rate = pcm_set_rate,
    .ready = pcm_ready,
    .status = pcm_status,
    .sufficient = pcm_sufficient,
    .flush = pcm_flush,
    .stop_requesting = pcm_stop_requesting,
    .request_when_ready = pcm_request_when_ready,
    .buffer_new = pcm_buffer_new,
    .buffer_free = pcm_buffer_free,
    .enqueue = pcm_enqueue,
    .timer = pcm_timer,
    .renderer_new = pcm_renderer_new,
    .synchroniser_new = pcm_sync_new,
    .volume = pcm_volume,
    .set_volume = pcm_set_volume,
    .muted = pcm_muted,
    .set_muted = pcm_set_muted,
    .observe = pcm_observe,
    .release = pcm_release,
    .restart = pcm_restart,
};

static struct fake_renderer *cur_renderer(void)
{
    return PCM.renderer;
}

static struct fake_sync *cur_sync(void)
{
    return PCM.sync;
}

// A 48 kHz stereo float PCM sink as open leaves it.
static void pcm_begin(double max_lookahead, double audio_buffer, bool timer_ok)
{
    host_reset();
    memset(&R, 0, sizeof(R));
    memset(&TRACE, 0, sizeof(TRACE));
    nrenderers = nsyncs = 0;
    F.frame_bytes = 8;
    avfao_pcm_init(&PCM, &HOST, &pcm_ops, NULL, &TRACE, 48000, 8);
    PCM.renderer = pcm_renderer_new(NULL);
    PCM.sync = pcm_sync_new(NULL, PCM.renderer);
    pcm_observe(NULL, PCM.renderer, true);
    avfao_pcm_choose_mode(&PCM, max_lookahead, audio_buffer, timer_ok);
}

// ------------------------------------------------------------ 9.3.5

static void test_prefetch_pcm(void)
{
    struct row {
        int64_t queued;
        int64_t ahead;
        bool skipped;
    } rows[] = {
        {0, 0, false},
        {0, SEC(3), true},
        {4799, SEC(1), true},
        {4800, SEC(1), false},
        {0, SEC(1) - 1, false},
        {0, -MS(500), false},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        char name[160];
        snprintf(name, sizeof(name), "9.3.5 PCM prefetch guard: queued %" PRId64
                 ", ahead %.9f", rows[i].queued, rows[i].ahead / 1e9);
        vector_begin(name);
        pcm_begin(4, 0.2, true);
        avfao_pcm_start(&PCM);
        F.now = SEC(10);
        F.queued = rows[i].queued;
        F.read_limit = 0;
        cur_sync()->time = SEC(20);
        PCM.end_ns = SEC(20) + rows[i].ahead;
        F.reads = 0;
        avfao_pcm_tick(&PCM);
        CHECK((F.reads == 0) == rows[i].skipped, "reads %d", F.reads);
        CHECK(F.reads == 0 || F.last_frames == 4800, "request %d", F.last_frames);
        vector_end();
    }
}

// ------------------------------------------------------------ 9.3.6

static void test_bounded_pcm(void)
{
    struct row {
        int64_t ahead;
        bool ready;
        bool feeding;
        bool read;
    } rows[] = {
        {-MS(500), true, true, true},
        {SEC(2), true, true, true},
        {SEC(4) - 1, true, true, true},
        {SEC(4), true, true, false},
        {0, false, true, false},
        {0, true, false, false},
        {-MS(500), false, false, false},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        char name[160];
        snprintf(name, sizeof(name), "9.3.6 bounded feed condition: ahead %.9f, ready %d, "
                 "feeding %d", rows[i].ahead / 1e9, rows[i].ready, rows[i].feeding);
        vector_begin(name);
        pcm_begin(4, 0.2, true);
        avfao_pcm_start(&PCM);
        if (!rows[i].feeding)
            avfao_pcm_set_feeding(&PCM, false);
        F.now = SEC(10);
        F.queued = 1000000;
        F.read_limit = 0;
        cur_renderer()->ready = rows[i].ready;
        cur_sync()->time = SEC(20);
        PCM.end_ns = SEC(20) + rows[i].ahead;
        F.reads = 0;
        avfao_pcm_tick(&PCM);
        CHECK((F.reads > 0) == rows[i].read, "reads %d", F.reads);
        vector_end();
    }

    struct mode {
        const char *name;
        double max_lookahead;
        double audio_buffer;
        bool timer_ok;
        bool bounded;
        int64_t bound;
        int warnings;
    } modes[] = {
        {"0 and 0.2: unbounded", 0, 0.2, true, false, 0, 0},
        {"0 and 5: unbounded", 0, 5, true, false, 0, 0},
        {"4 and 0.2: bound 4 s", 4, 0.2, true, true, SEC(4), 0},
        {"0.1 and 0.2: bound 0.2 s", 0.1, 0.2, true, true, MS(200), 0},
        {"4, timer fails: one warning, unbounded", 4, 0.2, false, false, 0, 1},
    };
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        char name[160];
        snprintf(name, sizeof(name), "9.3.6 mode selection: %s", modes[i].name);
        vector_begin(name);
        pcm_begin(modes[i].max_lookahead, modes[i].audio_buffer, modes[i].timer_ok);
        CHECK(PCM.bounded == modes[i].bounded, "bounded %d", PCM.bounded);
        CHECK(PCM.bound_ns == modes[i].bound, "bound %" PRId64, PCM.bound_ns);
        int warnings = 0;
        for (int n = 0; n < F.nlines; n++)
            warnings += F.lines[n].level == AVFAO_WARN;
        CHECK(warnings == modes[i].warnings && F.nlines == modes[i].warnings,
              "lines %d warnings %d", F.nlines, warnings);
        vector_end();
    }

    vector_begin("9.3.6 unbounded: readiness callbacks, no timer, no extra edges or lines");
    pcm_begin(0, 0.2, true);
    F.now = SEC(30);
    avfao_pcm_start(&PCM);
    CHECK(cur_renderer()->request_when_ready == 1, "readiness requests");
    CHECK(R.timer_on == 0 && R.timer_off == 0, "timer used");
    CHECK(PCM.end_ns == -1 && cur_sync()->rate == 1, "start state");
    avfao_pcm_pause(&PCM, true);
    CHECK(cur_sync()->rate == 0, "pause rate");
    avfao_pcm_pause(&PCM, false);
    CHECK(cur_sync()->rate == 1, "resume rate");
    CHECK(F.nlines == 0, "lines %d", F.nlines);
    avfao_pcm_reset(&PCM);
    CHECK(F.nlines == 1 && find_prefix("trace edge reset: clock ") == 0, "reset edge");
    CHECK(!PCM.fresh_pending && nrenderers == 1, "fresh sink in unbounded mode");
    avfao_pcm_start(&PCM);
    CHECK(nrenderers == 1 && F.nlines == 1, "start after reset");
    // A feed: end time and the enqueued end.
    cur_sync()->time = SEC(2);
    PCM.end_ns = -1;
    F.queued = 0;
    avfao_pcm_feed(&PCM);
    CHECK(F.reads == 1, "the readiness feed has no prefetch guard");
    CHECK(F.last_end_ns == SEC(30) + MS(100), "end %" PRId64, F.last_end_ns);
    CHECK(PCM.end_ns == SEC(2) + MS(100), "enqueued end %" PRId64, PCM.end_ns);
    CHECK(R.buffers_live == 0, "buffers leaked %d", R.buffers_live);
    vector_end();

    vector_begin("9.3.6 fresh sink carries volume and mute, resets the end and the line time");
    pcm_begin(4, 0.2, true);
    F.now = SEC(30);
    avfao_pcm_start(&PCM);
    avfao_pcm_tick(&PCM);
    CHECK(PCM.line_ns == SEC(30), "line time %" PRId64, PCM.line_ns);
    struct fake_renderer *old = cur_renderer();
    struct fake_sync *old_sync = cur_sync();
    old->volume = 0.6f;
    old->muted = true;
    avfao_pcm_reset(&PCM);
    CHECK(PCM.fresh_pending && PCM.end_ns == -1 && !PCM.feeding, "reset state");
    clear_lines();
    avfao_pcm_start(&PCM);
    CHECK(cur_renderer() != old && cur_sync() != old_sync, "objects not replaced");
    CHECK(cur_renderer()->volume == 0.6f && cur_renderer()->muted, "volume or mute lost");
    CHECK(PCM.end_ns == -1 && PCM.line_ns == 0 && !PCM.fresh_pending, "state after replace");
    CHECK(old->released && old_sync->released && !old->observed, "old objects");
    CHECK(cur_renderer()->observed, "new renderer not observed");
    CHECK(find_text("pcm fresh sink after reset") == 0 &&
          find_prefix("trace edge start-fresh: clock ") == 1, "lines");
    CHECK(PCM.feeding && cur_sync()->rate == 1, "feeding");
    struct fake_renderer *second = cur_renderer();
    second->volume = 1.0f;
    second->muted = false;
    avfao_pcm_reset(&PCM);
    avfao_pcm_start(&PCM);
    CHECK(cur_renderer() != second && cur_renderer()->volume == 1.0f &&
          !cur_renderer()->muted, "second replacement");
    vector_end();

    vector_begin("9.3.6 restart notifications: the new renderer's restart, never the old one's");
    pcm_begin(4, 0.2, true);
    F.now = SEC(30);
    avfao_pcm_start(&PCM);
    struct fake_renderer *first_renderer = cur_renderer();
    avfao_pcm_reset(&PCM);
    avfao_pcm_start(&PCM);
    clear_lines();
    avfao_pcm_notification(&PCM, "AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification",
                           false, 0, first_renderer);
    CHECK(R.restarts == 0, "old renderer restarted the sink");
    CHECK(F.nlines == 1 && has_line(AVFAO_V, "notification name: "
          "AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification"), "name line");
    clear_lines();
    avfao_pcm_notification(&PCM,
                           "AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification",
                           true, 1.5, cur_renderer());
    CHECK(R.restarts == 1, "restarts %d", R.restarts);
    static const char *const expected[] = {
        "notification name: AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification",
        "notification flush time 1.500, current 1",
        "trace edge restart: clock ",
        "restarting due to system notification; this will cause desync",
        "trace edge reset: clock ",
        "pcm fresh sink after reset",
        "trace edge start-fresh: clock ",
    };
    CHECK(F.nlines == 7, "lines %d", F.nlines);
    for (int n = 0; n < 7 && n < F.nlines; n++) {
        CHECK(strncmp(F.lines[n].text, expected[n], strlen(expected[n])) == 0,
              "line %d is '%s'", n, F.lines[n].text);
    }
    CHECK(F.lines[3].level == AVFAO_WARN, "warning level");
    if (checks_failed_in_vector)
        dump_lines();
    vector_end();

    vector_begin("9.3.6 renderer creation fails: one reload, old renderer kept, still pending");
    pcm_begin(4, 0.2, true);
    avfao_pcm_start(&PCM);
    struct fake_renderer *kept = cur_renderer();
    avfao_pcm_reset(&PCM);
    R.renderer_fails = true;
    clear_lines();
    avfao_pcm_start(&PCM);
    CHECK(F.reloads == 1, "reloads %d", F.reloads);
    CHECK(cur_renderer() == kept && !kept->released, "old renderer replaced");
    CHECK(PCM.fresh_pending, "not pending");
    CHECK(has_line(AVFAO_WARN, "pcm fresh sink failed; requesting audio reload"), "warning");
    CHECK(count_prefix("trace edge") == 0 && !PCM.feeding, "carried on after failure");
    vector_end();

    vector_begin("9.3.6 synchroniser creation fails: one reload, new renderer released");
    pcm_begin(4, 0.2, true);
    avfao_pcm_start(&PCM);
    kept = cur_renderer();
    avfao_pcm_reset(&PCM);
    R.sync_fails = true;
    avfao_pcm_start(&PCM);
    CHECK(F.reloads == 1, "reloads %d", F.reloads);
    CHECK(cur_renderer() == kept && PCM.fresh_pending, "state");
    CHECK(nrenderers == 2 && renderers[1].released, "half-made renderer kept");
    vector_end();

    vector_begin("9.3.6 pending replacement: pause, resume and notifications do nothing more");
    pcm_begin(4, 0.2, true);
    avfao_pcm_start(&PCM);
    avfao_pcm_reset(&PCM);
    clear_lines();
    double rate = cur_sync()->rate;
    int on = R.timer_on, off = R.timer_off;
    avfao_pcm_pause(&PCM, true);
    avfao_pcm_pause(&PCM, false);
    CHECK(F.nlines == 0 && cur_sync()->rate == rate && R.timer_on == on &&
          R.timer_off == off && !PCM.feeding, "pause or resume acted");
    avfao_pcm_notification(&PCM, "AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification",
                           true, 0.25, cur_renderer());
    CHECK(F.nlines == 2 && R.restarts == 0, "lines %d restarts %d", F.nlines, R.restarts);
    CHECK(has_line(AVFAO_V, "notification flush time 0.250, current 1"), "flush line");
    vector_end();

    vector_begin("9.3.6 first tick after init logs the transport line at once with fed 0.000");
    pcm_begin(4, 0.2, true);
    F.now = SEC(3);
    F.read_limit = 0;
    avfao_pcm_start(&PCM);
    clear_lines();
    avfao_pcm_tick(&PCM);
    CHECK(find_prefix("pcm: clock 0.000, fed 0.000, ahead 0.000, rate 1.000, status 0, "
                      "latency 0.000, sufficient 1") == 0, "transport line");
    if (checks_failed_in_vector)
        dump_lines();
    vector_end();

    vector_begin("9.3.6 transport line cadence: 2 s, 250 ms in the detail window");
    pcm_begin(4, 0.2, true);
    F.read_limit = 0;
    F.now = SEC(100);
    avfao_pcm_start(&PCM); // trace edge: detail window until 108 s
    clear_lines();
    avfao_pcm_tick(&PCM);
    F.now = SEC(100) + MS(249);
    avfao_pcm_tick(&PCM);
    F.now = SEC(100) + MS(250);
    avfao_pcm_tick(&PCM);
    CHECK(count_prefix("pcm: ") == 2, "detail cadence %d", count_prefix("pcm: "));
    F.now = SEC(110);
    avfao_pcm_tick(&PCM);
    F.now = SEC(111);
    avfao_pcm_tick(&PCM);
    F.now = SEC(112);
    avfao_pcm_tick(&PCM);
    CHECK(count_prefix("pcm: ") == 4, "plain cadence %d", count_prefix("pcm: "));
    vector_end();

    vector_begin("9.3.6 renderer failure: warning, feeding off, reload, nothing enqueued");
    pcm_begin(4, 0.2, true);
    F.now = SEC(10);
    avfao_pcm_start(&PCM);
    cur_renderer()->status = 2;
    clear_lines();
    F.reads = 0;
    avfao_pcm_tick(&PCM);
    CHECK(find_prefix("pcm: ") == 0, "transport line first");
    CHECK(has_line(AVFAO_WARN, "pcm renderer failed; requesting audio reload"), "warning");
    CHECK(!PCM.feeding && F.reloads == 1 && F.reads == 0, "state");
    vector_end();

    vector_begin("9.3.6 bounded end of file: feeding off, renderer and end kept");
    pcm_begin(4, 0.2, true);
    F.now = SEC(10);
    F.queued = 1000000;
    avfao_pcm_start(&PCM);
    F.read_eof = true;
    F.read_limit = 100;
    avfao_pcm_tick(&PCM);
    CHECK(!PCM.feeding && F.stop_streaming == 1, "feeding %d", PCM.feeding);
    CHECK(PCM.end_ns > 0 && nrenderers == 1 && !PCM.fresh_pending, "kept");
    avfao_pcm_start(&PCM);
    CHECK(find_prefix("trace edge start: clock ") >= 0 && nrenderers == 1, "plain start");
    vector_end();

    vector_begin("9.3.6 a tick reads at most four times and stops at the bound");
    pcm_begin(4, 0.2, true);
    F.now = SEC(10);
    F.queued = 1000000;
    avfao_pcm_start(&PCM);
    F.reads = 0;
    avfao_pcm_tick(&PCM);
    CHECK(F.reads == 4 && PCM.end_ns == MS(400), "reads %d end %" PRId64, F.reads, PCM.end_ns);
    PCM.end_ns = SEC(4) - MS(50);
    F.reads = 0;
    avfao_pcm_tick(&PCM);
    CHECK(F.reads == 1, "reads at the bound %d", F.reads);
    CHECK(R.buffers_live == 0, "buffers leaked %d", R.buffers_live);
    vector_end();
}

// ------------------------------------------------------------ 9.3.7

struct fake_session {
    int category;
    int multichannel;
    int activate;
    int deactivate;
    int max_reads;
    int route_lines;
    int preferred_calls;
    long preferred;
    long max;
    int queues;
    int pcm_opens;
    int compressed_opens;
    int discards;
    bool open_fails;
};

static struct fake_session SS;

static void ss_category(void *ctx) { SS.category++; }
static void ss_multichannel(void *ctx) { SS.multichannel++; }
static void ss_activate(void *ctx) { SS.activate++; }
static void ss_deactivate(void *ctx) { SS.deactivate++; }
static long ss_max(void *ctx) { SS.max_reads++; return SS.max; }
static void ss_route(void *ctx, long max) { SS.route_lines++; }
static void ss_preferred(void *ctx, long n) { SS.preferred_calls++; SS.preferred = n; }

static const struct avfao_session_ops session_ops = {
    .set_category_and_mode = ss_category,
    .declare_multichannel = ss_multichannel,
    .activate = ss_activate,
    .deactivate = ss_deactivate,
    .max_output_channels = ss_max,
    .log_route = ss_route,
    .set_preferred_output_channels = ss_preferred,
};

static bool oo_queue(void *ctx) { SS.queues++; return true; }
static bool oo_pcm(void *ctx) { SS.pcm_opens++; return !SS.open_fails; }
static bool oo_cx(void *ctx, enum avfao_codec c) { SS.compressed_opens++; return !SS.open_fails; }
static void oo_discard(void *ctx) { SS.discards++; }

static const struct avfao_open_ops open_ops = {
    .create_queue = oo_queue,
    .open_pcm = oo_pcm,
    .open_compressed = oo_cx,
    .discard = oo_discard,
};

static bool open_with(enum avfao_kind kind, int channels, bool accept, bool manage)
{
    struct avfao_open_args args = {
        .kind = kind,
        .format_name = kind == AVFAO_KIND_PCM ? "floatp" :
                       kind == AVFAO_KIND_AC3 ? "spdif-ac3" :
                       kind == AVFAO_KIND_EAC3 ? "spdif-eac3" : "spdif-dts",
        .channels = channels,
        .accept_compressed = accept,
        .manage_session = manage,
    };
    return avfao_open(&HOST, &session_ops, &open_ops, NULL, &args);
}

static void test_session(void)
{
    vector_begin("9.3.7 manage-audio-session off: no category, mode or activation ever");
    host_reset();
    memset(&SS, 0, sizeof(SS));
    SS.max = 8;
    avfao_block_clear();
    avfao_block_set(AVFAO_CODEC_AC3);
    bool ok1 = open_with(AVFAO_KIND_PCM, 2, true, false);
    avfao_session_end(&session_ops, NULL, false);
    avfao_block_set(AVFAO_CODEC_AC3);
    bool ok2 = open_with(AVFAO_KIND_AC3, 2, true, false);   // blocked: fails
    bool ok3 = open_with(AVFAO_KIND_OTHER_SPDIF, 2, true, false); // unsupported: fails
    SS.open_fails = true;
    bool ok4 = open_with(AVFAO_KIND_EAC3, 2, true, false);  // sink fails
    SS.open_fails = false;
    bool ok5 = open_with(AVFAO_KIND_EAC3, 2, true, false);
    avfao_session_end(&session_ops, NULL, false);
    CHECK(ok1 && !ok2 && !ok3 && !ok4 && ok5, "outcomes %d %d %d %d %d", ok1, ok2, ok3, ok4, ok5);
    CHECK(SS.category == 0 && SS.activate == 0 && SS.deactivate == 0, "session calls");
    CHECK(SS.discards == 3, "discards %d", SS.discards);
    CHECK(count_prefix("not opening spdif-ac3: ") == 1, "block refusal line");
    for (int n = 0; n < F.nlines; n++) {
        CHECK(strstr(F.lines[n].text, "falling back to PCM") == NULL, "fault text in '%s'",
              F.lines[n].text);
    }
    vector_end();

    vector_begin("9.3.7 6-channel PCM, maximum 8: multichannel declared, preferred 6");
    memset(&SS, 0, sizeof(SS));
    SS.max = 8;
    CHECK(open_with(AVFAO_KIND_PCM, 6, true, false), "open");
    CHECK(SS.multichannel == 1 && SS.preferred_calls == 1 && SS.preferred == 6, "preferred %ld",
          SS.preferred);
    CHECK(SS.category == 0 && SS.activate == 0, "session managed");
    vector_end();

    vector_begin("9.3.7 6-channel PCM, maximum 2: preferred 2");
    memset(&SS, 0, sizeof(SS));
    SS.max = 2;
    CHECK(open_with(AVFAO_KIND_PCM, 6, true, false), "open");
    CHECK(SS.preferred == 2, "preferred %ld", SS.preferred);
    vector_end();

    vector_begin("9.3.7 stereo PCM: no multichannel declaration");
    memset(&SS, 0, sizeof(SS));
    SS.max = 8;
    CHECK(open_with(AVFAO_KIND_PCM, 2, true, false), "open");
    CHECK(SS.multichannel == 0 && SS.preferred == 2, "multichannel %d", SS.multichannel);
    vector_end();

    vector_begin("9.3.7 compressed: multichannel declared, route line, no preferred count");
    memset(&SS, 0, sizeof(SS));
    SS.max = 2;
    avfao_block_clear();
    CHECK(open_with(AVFAO_KIND_EAC3, 2, true, false), "open");
    CHECK(SS.multichannel == 1 && SS.route_lines == 1 && SS.preferred_calls == 0, "calls");
    vector_end();

    vector_begin("9.3.7 spdif with accept-compressed off: no session call at all");
    host_reset();
    memset(&SS, 0, sizeof(SS));
    CHECK(!open_with(AVFAO_KIND_EAC3, 2, false, true), "open succeeded");
    CHECK(SS.category + SS.multichannel + SS.activate + SS.deactivate + SS.max_reads +
          SS.route_lines + SS.preferred_calls == 0, "session calls");
    CHECK(SS.queues == 0 && SS.discards == 0, "allocation");
    CHECK(F.nlines == 1 && F.lines[0].level == AVFAO_V, "verbose note");
    vector_end();

    vector_begin("9.3.7 manage-audio-session on: activate, and deactivate on both paths");
    memset(&SS, 0, sizeof(SS));
    SS.max = 8;
    CHECK(open_with(AVFAO_KIND_PCM, 2, true, true), "open");
    CHECK(SS.category == 1 && SS.activate == 1 && SS.deactivate == 0, "init calls");
    avfao_session_end(&session_ops, NULL, true);
    CHECK(SS.deactivate == 1, "uninit deactivation");
    SS.open_fails = true;
    CHECK(!open_with(AVFAO_KIND_PCM, 2, true, true), "failing open");
    CHECK(SS.activate == 2 && SS.deactivate == 2, "error path deactivation");
    vector_end();

    vector_begin("9.3.7 a PCM open clears the passthrough block before anything can fail");
    memset(&SS, 0, sizeof(SS));
    avfao_block_set(AVFAO_CODEC_AC3);
    avfao_block_set(AVFAO_CODEC_EAC3);
    SS.open_fails = true;
    CHECK(!open_with(AVFAO_KIND_PCM, 2, true, false), "open");
    CHECK(!avfao_blocked(AVFAO_CODEC_AC3) && !avfao_blocked(AVFAO_CODEC_EAC3), "block kept");
    vector_end();
}

// ------------------------------------------------------------ 9.3.8

static bool eof_at_read;

static void record_eof(void)
{
    eof_at_read = hook_cx->eof;
}

static void test_eof_restart(void)
{
    vector_begin("9.3.8 start after end of file keeps the item and reads at once");
    struct cx_setup s = default_setup();
    cx_begin(&s);
    // 40 real bursts (1.28 s): fed, written and primed, so rate 1 goes in.
    use_eac3_stream(40, 0);
    F.now = SEC(40);
    F.queued = 1000000;
    avfao_cx_step(&CX);
    CHECK(CX.fed_ns == 40 * INT64_C(32000000) && P.rate_one == 1, "fed %" PRId64, CX.fed_ns);
    // Then mpv reports end of file.
    F.read_eof = true;
    F.read_limit = 0;
    avfao_cx_step(&CX);
    CHECK(CX.eof, "no end of file");
    int64_t head = CX.win.head;
    int64_t consumed = CX.consumed_frames;
    F.read_eof = false;
    F.read_limit = -1;
    P.rate_one = 0;
    F.reads = 0;
    clear_lines();
    hook_cx = &CX;
    F.on_read = record_eof;
    eof_at_read = true;
    avfao_cx_start(&CX);
    CHECK(has_line(AVFAO_V, "resuming compressed feed after audio EOF"), "line");
    CHECK(F.reads > 0 && !eof_at_read, "reads %d, eof at read %d", F.reads, eof_at_read);
    CHECK(P.item_creates == 1 && P.teardowns == 0, "item replaced");
    CHECK(CX.win.head == head && CX.consumed_frames > consumed, "stream offsets");
    CHECK(P.rate_one == 1, "rate requests %d", P.rate_one);
    int line = find_text("resuming compressed feed after audio EOF");
    int edge = find_prefix("trace edge start: clock ");
    CHECK(line >= 0 && edge > line, "order");
    F.on_read = NULL;
    cx_finish();
    vector_end();

    vector_begin("9.3.8 end of file stops filling and primes; the step still serves");
    cx_begin(&s);
    F.now = SEC(1);
    F.queued = 1000000;
    F.read_eof = true;
    F.read_limit = 10;
    avfao_cx_step(&CX);
    CHECK(F.reads == 1 && CX.eof && F.stop_streaming == 1, "reads %d", F.reads);
    CHECK(P.serves == 1, "serves %d", P.serves);
    CHECK(P.rate_one == 1, "end of file primes: %d", P.rate_one);
    cx_finish();
    vector_end();
}

// ------------------------------------------------------------ 9.3.9

static struct avfao_iec IEC;
static struct avfao_window WIN;
static int64_t FED, DROPPED;

static void iec_begin(enum avfao_codec codec, int carrier)
{
    host_reset();
    bool ok = avfao_iec_alloc(&IEC, codec, carrier) &&
              avfao_window_alloc(&WIN, avfao_window_capacity(8));
    CHECK(ok, "allocation");
    FED = DROPPED = 0;
}

static void iec_finish(void)
{
    avfao_iec_free(&IEC);
    avfao_window_free(&WIN);
}

// Appends one burst: preamble, Pd, then a payload whose byte-swapped form
// starts with the syncword (when sync) and then counts up.
static size_t put_burst(uint8_t *buf, int type_byte, int pd, int payload_len, bool sync,
                        int padding)
{
    size_t n = 0;
    buf[n++] = 0x72;
    buf[n++] = 0xF8;
    buf[n++] = 0x1F;
    buf[n++] = 0x4E;
    buf[n++] = (uint8_t)type_byte;
    buf[n++] = 0x00;
    buf[n++] = (uint8_t)(pd & 0xFF);
    buf[n++] = (uint8_t)(pd >> 8);
    for (int i = 0; i < payload_len; i++) {
        // swapped[i] = raw[i ^ 1]
        uint8_t swapped;
        if (i == 0) {
            swapped = sync ? 0x0B : 0x12;
        } else if (i == 1) {
            swapped = sync ? 0x77 : 0x34;
        } else {
            swapped = (uint8_t)(i * 7 + 3);
        }
        buf[n + (i ^ 1)] = swapped;
    }
    if (payload_len & 1)
        buf[n + payload_len] = 0; // the pad byte that completes the last word
    n += (payload_len + 1) & ~1;
    for (int i = 0; i < padding; i++)
        buf[n++] = 0;
    return n;
}

static bool unwrap(const uint8_t *data, size_t len)
{
    memcpy(IEC.carry + IEC.carry_len, data, len);
    IEC.carry_len += len;
    return avfao_iec_unwrap(&IEC, &WIN, &HOST, &FED, &DROPPED);
}

static bool window_payload_ok(int64_t offset, int len)
{
    const uint8_t *w = avfao_window_bytes(&WIN, offset);
    for (int i = 0; i < len; i++) {
        uint8_t expect = i == 0 ? 0x0B : i == 1 ? 0x77 : (uint8_t)(i * 7 + 3);
        if (w[i] != expect)
            return false;
    }
    return true;
}

static void test_unwrapping(void)
{
    static uint8_t buf[200000];
    size_t n;

    vector_begin("9.3.9 valid AC-3 bursts with zero padding");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = 0;
    n += put_burst(buf + n, 0x01, 1000 * 8, 1000, true, 6144 - 8 - 1000);
    n += put_burst(buf + n, 0x01, 1200 * 8, 1200, true, 6144 - 8 - 1200);
    n += put_burst(buf + n, 0x01, 800 * 8, 800, true, 100);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(WIN.head == 3000, "head %" PRId64, WIN.head);
    CHECK(window_payload_ok(0, 1000) && window_payload_ok(1000, 1200) &&
          window_payload_ok(2200, 800), "payload bytes");
    CHECK(FED == 3 * INT64_C(32000000) && DROPPED == 0, "fed %" PRId64, FED);
    CHECK(F.nlines == 0, "lines %d", F.nlines);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 E-AC-3 stream with a data type 0x01 preamble");
    iec_begin(AVFAO_CODEC_EAC3, 192000);
    n = put_burst(buf, 0x01, 100, 100, true, 40);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(F.nlines == 1 && has_line(AVFAO_WARN, "skipping unexpected IEC 61937 data type 0x1"),
          "lines %d", F.nlines);
    CHECK(WIN.head == 0 && FED == 0, "accepted");
    iec_finish();
    vector_end();

    vector_begin("9.3.9 scanning resumes one byte after a wrong data type");
    iec_begin(AVFAO_CODEC_EAC3, 192000);
    // A wrong-type preamble claiming a long payload, then a valid burst
    // straight after its 8 bytes: only a one-byte resume finds it.
    n = put_burst(buf, 0x02, 2000, 0, true, 0);
    n += put_burst(buf + n, 0x15, 100, 100, true, 20);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(WIN.head == 100 && F.nlines == 1, "head %" PRId64 ", lines %d", WIN.head, F.nlines);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 AC-3 byte 4 = 0x81 is data type 0x01");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x81, 64 * 8, 64, true, 10);
    CHECK(unwrap(buf, n) && WIN.head == 64 && F.nlines == 0, "head %" PRId64, WIN.head);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 AC-3 Pd 100 bits is a 12-byte payload");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x01, 100, 12, true, 20);
    CHECK(unwrap(buf, n) && WIN.head == 12 && F.nlines == 0, "head %" PRId64, WIN.head);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 AC-3 Pd 76: odd 9-byte payload dropped");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x01, 76, 9, true, 20);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(F.nlines == 1 && has_line(AVFAO_WARN, "discarding burst with odd payload length"),
          "lines");
    CHECK(DROPPED == INT64_C(32000000) && FED == 0 && WIN.head == 0, "dropped %" PRId64, DROPPED);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 AC-3 Pd 63: invalid 7-byte payload");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x01, 63, 8, true, 20);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(has_line(AVFAO_WARN, "skipping burst with invalid payload length 7") &&
          F.nlines == 1, "lines %d", F.nlines);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 AC-3 Pd 64 and 49088 accepted");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x01, 64, 8, true, 0);
    n += put_burst(buf + n, 0x01, 49088, 6136, true, 0);
    CHECK(unwrap(buf, n) && WIN.head == 6144 && F.nlines == 0, "head %" PRId64, WIN.head);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 AC-3 Pd 49096: 6137 bytes is invalid");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x01, 49096, 6136, true, 10);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(count_text("skipping burst with invalid payload length 6137") == 1, "warning");
    iec_finish();
    vector_end();

    vector_begin("9.3.9 E-AC-3 Pd 24568 accepted, 24569 invalid");
    iec_begin(AVFAO_CODEC_EAC3, 192000);
    n = put_burst(buf, 0x15, 24568, 24568, true, 0);
    CHECK(unwrap(buf, n) && WIN.head == 24568 && F.nlines == 0, "head %" PRId64, WIN.head);
    n = put_burst(buf, 0x15, 24569, 24568, true, 10);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(count_text("skipping burst with invalid payload length 24569") == 1, "warning");
    iec_finish();
    vector_end();

    vector_begin("9.3.9 E-AC-3 Pd 9: odd, dropped, resume 18 bytes after the preamble");
    iec_begin(AVFAO_CODEC_EAC3, 192000);
    n = put_burst(buf, 0x15, 9, 9, true, 0);
    // A wrong-type preamble inside the skipped 18 bytes would warn if the
    // scan resumed early.
    buf[9] = 0x72; buf[10] = 0xF8; buf[11] = 0x1F; buf[12] = 0x4E; buf[13] = 0x02;
    CHECK(n == 18, "burst length %zu", n);
    n += put_burst(buf + n, 0x15, 20, 20, true, 10);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(F.nlines == 1 && has_line(AVFAO_WARN, "discarding burst with odd payload length"),
          "lines %d", F.nlines);
    CHECK(WIN.head == 20 && DROPPED == INT64_C(32000000), "head %" PRId64, WIN.head);
    if (checks_failed_in_vector)
        dump_lines();
    iec_finish();
    vector_end();

    vector_begin("9.3.9 wrong data type and bad length: only the data-type warning");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x15, 3, 8, true, 10);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(F.nlines == 1 && count_prefix("skipping unexpected IEC 61937 data type") == 1,
          "lines %d", F.nlines);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 an incomplete payload is kept from its preamble");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x01, 1000 * 8, 1000, true, 0);
    CHECK(unwrap(buf, 500), "fallback");
    CHECK(F.nlines == 0 && IEC.carry_len == 500 && WIN.head == 0, "carry %" PRId64,
          IEC.carry_len);
    vector_end();

    vector_begin("9.3.9 a burst split across two reads is appended once, complete");
    CHECK(unwrap(buf + 500, n - 500), "fallback");
    CHECK(WIN.head == 1000 && window_payload_ok(0, 1000) && FED == INT64_C(32000000),
          "head %" PRId64, WIN.head);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 no syncword after the swap: dropped");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    n = put_burst(buf, 0x01, 100 * 8, 100, false, 10);
    CHECK(unwrap(buf, n), "fallback");
    CHECK(F.nlines == 1 && has_line(AVFAO_WARN, "discarding burst without syncframe"), "lines");
    CHECK(DROPPED == INT64_C(32000000) && FED == 0 && WIN.head == 0, "dropped %" PRId64, DROPPED);
    iec_finish();
    vector_end();

    vector_begin("9.3.9 19200 bytes with no preamble: silent, last 7 bytes kept");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    for (int i = 0; i < 19200; i++)
        buf[i] = (uint8_t)(i * 13 + 1);
    CHECK(unwrap(buf, 19200), "fallback");
    CHECK(F.nlines == 0 && IEC.carry_len == 7 && FED == 0, "carry %" PRId64, IEC.carry_len);
    CHECK(memcmp(IEC.carry, buf + 19200 - 7, 7) == 0, "kept bytes");
    iec_finish();
    vector_end();

    vector_begin("9.3.9 window overflow falls back with its own line");
    iec_begin(AVFAO_CODEC_AC3, 48000);
    WIN.capacity = 50;
    n = put_burst(buf, 0x01, 100 * 8, 100, true, 10);
    CHECK(!unwrap(buf, n), "no fallback");
    CHECK(F.nlines == 1 && has_line(AVFAO_ERR,
          "elementary stream window overflow; falling back to PCM"), "lines");
    iec_finish();
    vector_end();
}

// ----------------------------------------------- feed step and clock extras

static void test_feed_details(void)
{
    vector_begin("constants: buffer and window sizes, burst periods");
    struct avfao_iec a;
    CHECK(avfao_iec_alloc(&a, AVFAO_CODEC_EAC3, 192000) && a.carry_size == 175104 &&
          a.burst_ns == 32000000, "192 kHz E-AC-3 %" PRId64, a.carry_size);
    avfao_iec_free(&a);
    CHECK(avfao_iec_alloc(&a, AVFAO_CODEC_EAC3, 176400) && a.carry_size == 168864 &&
          a.burst_ns == 34829932, "176.4 kHz E-AC-3 %" PRId64 " %" PRId64, a.carry_size,
          a.burst_ns);
    avfao_iec_free(&a);
    CHECK(avfao_iec_alloc(&a, AVFAO_CODEC_AC3, 48000) && a.carry_size == 43776 &&
          a.burst_ns == 32000000 && a.data_type == 1 && a.burst_bytes == 6144, "48 kHz AC-3");
    avfao_iec_free(&a);
    CHECK(avfao_window_capacity(8) == 15728640, "window %" PRId64, avfao_window_capacity(8));
    vector_end();

    vector_begin("mpv's end time comes from consumed frames minus dropped duration");
    struct cx_setup s = default_setup();
    cx_begin(&s);
    // The first 100 ms read holds one burst without a syncframe: 32 ms
    // dropped, nothing fed. The second read's end time counts 100 ms
    // written minus 32 ms dropped, not the fed duration.
    use_eac3_stream(1, 1);
    F.now = SEC(5);
    F.queued = 1000000;
    avfao_cx_step(&CX);
    CHECK(F.reads >= 2, "reads %d", F.reads);
    CHECK(CX.dropped_ns >= INT64_C(32000000) && CX.fed_ns == 0, "dropped %" PRId64,
          CX.dropped_ns);
    CHECK(F.ends[0] == SEC(5) + MS(100), "first end %" PRId64, F.ends[0]);
    CHECK(F.ends[1] == SEC(5) + MS(68) + MS(100), "second end %" PRId64, F.ends[1]);
    cx_finish();
    vector_end();

    vector_begin("compressed clock: timebase first, currentTime fallback, clamped to fed");
    cx_begin(&s);
    CX.fed_ns = SEC(10);
    P.timebase_ns = SEC(3);
    P.current_valid = true;
    P.current_ns = SEC(4);
    CHECK(avfao_cx_clock(&CX) == SEC(3), "timebase");
    CHECK(avfao_cx_feed_position(&CX) == SEC(4), "later reading for the feed");
    P.timebase_valid = false;
    CHECK(avfao_cx_clock(&CX) == SEC(4), "currentTime");
    P.current_valid = false;
    CHECK(avfao_cx_clock(&CX) == 0, "neither");
    P.timebase_valid = true;
    P.timebase_ns = SEC(12);
    CHECK(avfao_cx_clock(&CX) == SEC(10), "clamped");
    P.timebase_ns = -5;
    CHECK(avfao_cx_clock(&CX) == 0, "negative");
    cx_finish();
    vector_end();

    vector_begin("feed step: status line from -1, heartbeat every 100, every 5 in detail");
    cx_begin(&s);
    F.read_limit = 0;
    P.time_control = 1;
    F.now = SEC(1000);
    clear_lines();
    avfao_cx_reset(&CX);
    avfao_cx_start(&CX);  // a new item: its first step logs from -1
    CHECK(has_line(AVFAO_V, "item status -1 -> 1, time control -1 -> 1, pos 0.000s, "
                            "fed 0.000s"), "status line");
    F.now = SEC(1010);    // past the start edge's detail window
    clear_lines();
    uint64_t first = CX.heartbeat;
    int to_hundred = (int)(100 - first % 100);
    for (int i = 0; i < to_hundred; i++)
        avfao_cx_step(&CX);
    CHECK(count_prefix("heartbeat: ") == 1, "heartbeats %d", count_prefix("heartbeat: "));
    CHECK(has_line(AVFAO_V, "heartbeat: raw pos -1.000s, clamped 0.000s, fed 0.000s, "
                            "status 1, tc 1, reader gap -1 B"), "heartbeat text");
    avfao_cx_pause(&CX, true); // a trace edge opens the detail window
    clear_lines();
    for (int i = 0; i < 10; i++)
        avfao_cx_step(&CX);
    CHECK(count_prefix("heartbeat: ") == 2, "detail heartbeats %d",
          count_prefix("heartbeat: "));
    CHECK(CX.heartbeat == first + to_hundred + 10, "counter %" PRIu64, CX.heartbeat);
    avfao_cx_fallback(&CX);
    avfao_cx_step(&CX);
    CHECK(CX.heartbeat == first + to_hundred + 10, "a step that does nothing counted");
    if (checks_failed_in_vector)
        dump_lines();
    cx_finish();
    vector_end();

    vector_begin("filling: at most 64 reads in one step");
    cx_begin(&s);
    F.now = SEC(1);
    F.queued = 100000000;
    avfao_cx_step(&CX);  // silence: reads succeed but feed nothing
    CHECK(F.reads == 64, "reads %d", F.reads);
    cx_finish();
    vector_end();

    vector_begin("loader serving: below, data, wait, beyond, finish, trim");
    host_reset();
    struct avfao_window w;
    CHECK(avfao_window_alloc(&w, avfao_window_capacity(8)), "alloc");
    w.head = 5000000;
    w.base = 1000000;
    int64_t len = 0;
    CHECK(avfao_serve_request(&HOST, &w, 999999, -1, &len) == AVFAO_SERVE_BELOW, "below");
    CHECK(has_line(AVFAO_ERR, "loader requested offset 999999 below the retained window at "
                              "1000000"), "below line");
    CHECK(avfao_serve_request(&HOST, &w, 4000000, -1, &len) == AVFAO_SERVE_DATA &&
          len == 1000000, "to end %" PRId64, len);
    CHECK(avfao_serve_request(&HOST, &w, 4000000, 4000100, &len) == AVFAO_SERVE_DATA &&
          len == 100, "bounded %" PRId64, len);
    CHECK(avfao_serve_request(&HOST, &w, 5000000, -1, &len) == AVFAO_SERVE_WAIT, "wait");
    clear_lines();
    CHECK(avfao_serve_request(&HOST, &w, 5000001, -1, &len) == AVFAO_SERVE_BEYOND, "beyond");
    CHECK(F.nlines == 1 && F.lines[0].level == AVFAO_V &&
          strstr(F.lines[0].text, "loader requested offset") == NULL, "beyond line");
    CHECK(avfao_serve_request(&HOST, &w, 4000100, 4000100, &len) == AVFAO_SERVE_FINISH, "end");
    avfao_window_trim(&w, 4000000);
    CHECK(w.base == 4000000 - 2097152, "trim %" PRId64, w.base);
    avfao_window_trim(&w, 1000);
    CHECK(w.base == 4000000 - 2097152, "trim moved back");
    avfao_window_free(&w);
    vector_end();

    vector_begin("rejection: two separate error lines, one fallback, block set");
    cx_begin(&s);
    P.failed = true;
    F.queued = 1000000;
    avfao_cx_step(&CX);
    CHECK(F.reads == 0 && P.serves == 0 && F.reloads == 1, "reads %d serves %d", F.reads,
          P.serves);
    CHECK(avfao_blocked(AVFAO_CODEC_EAC3), "block");
    avfao_cx_step(&CX);
    CHECK(F.reloads == 1 && count_text("falling back to PCM") == 1, "repeat");
    cx_finish();
    vector_end();

    vector_begin("trace edges: format and the 8 s detail window");
    host_reset();
    struct avfao_trace t = {0};
    F.now = SEC(50);
    F.latency = 0.025;
    CHECK(!avfao_in_detail_window(&HOST, &t), "window before any edge");
    avfao_trace_edge(&HOST, &t, "start-fresh", -1, -1);
    CHECK(has_line(AVFAO_V, "trace edge start-fresh: clock -0.000, fed -0.000, latency 0.025"),
          "line '%s'", F.nlines ? F.lines[0].text : "");
    F.now = SEC(58) - 1;
    CHECK(avfao_in_detail_window(&HOST, &t), "inside");
    F.now = SEC(58);
    CHECK(!avfao_in_detail_window(&HOST, &t), "outside");
    vector_end();

    vector_begin("pause and reset: timer idled, rate 0, item torn down from byte 0");
    cx_begin(&s);
    use_eac3_stream(40, 0);
    F.queued = 1000000;
    F.now = SEC(1);
    avfao_cx_step(&CX);
    CHECK(CX.fed_ns > 0 && CX.win.head > 0 && P.rate_one == 1, "fed %" PRId64, CX.fed_ns);
    F.now = SEC(2);
    avfao_cx_pause(&CX, true);
    F.now = SEC(3);
    avfao_cx_pause(&CX, false);
    CHECK(CX.st.resume_pending, "no pending resume");
    P.timer_idle = 0;
    P.rate_zero = 0;
    F.now = SEC(4);
    avfao_cx_pause(&CX, true);
    CHECK(P.timer_idle == 1 && P.rate_zero == 1 && !CX.st.resume_pending, "pause");
    avfao_cx_reset(&CX);
    CHECK(P.teardowns == 1 && !CX.item && CX.fed_ns == 0 && CX.win.head == 0, "reset");
    avfao_cx_start(&CX);
    CHECK(P.item_creates == 2 && CX.last_status == AVFAO_ITEM_READY, "new item");
    cx_finish();
    vector_end();
}

// ------------------------------------------------- review vectors

static void test_review(void)
{
    struct cx_setup s = default_setup();
    struct target_row {
        const char *name;
        int64_t timebase;
        int64_t current;
        int64_t fed;
        int64_t queued;
        bool read;
    } rows[] = {
        {"start-up target at position 0 is twice the lead: fed 16 s - 1 ns reads",
         0, 0, SEC(16) - 1, 1000000, true},
        {"start-up target at position 0 is twice the lead: fed 16 s does not",
         0, 0, SEC(16), 1000000, false},
        {"start-up target at position 0 is twice the lead: fed 9 s reads",
         0, 0, SEC(9), 1000000, true},
        {"steady target above position 0 is the lead: 1 s and fed 9 s - 1 ns reads",
         SEC(1), SEC(1), SEC(9) - 1, 1000000, true},
        {"steady target above position 0 is the lead: 1 s and fed 9 s does not",
         SEC(1), SEC(1), SEC(9), 1000000, false},
        {"fill pacing uses the later currentTime: timebase 2 s, current 5 s, fed 12 s",
         SEC(2), SEC(5), SEC(12), 1000000, true},
        {"prefetch reserve uses the feed position: timebase 1 s, current 2.5 s, fed 3 s",
         SEC(1), MS(2500), SEC(3), 0, true},
    };
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        vector_begin(rows[i].name);
        cx_begin(&s);
        F.now = SEC(10);
        F.queued = rows[i].queued;
        F.read_limit = 0;
        P.timebase_ns = rows[i].timebase;
        P.current_valid = true;
        P.current_ns = rows[i].current;
        CX.fed_ns = rows[i].fed;
        avfao_cx_step(&CX);
        CHECK((F.reads > 0) == rows[i].read, "reads %d", F.reads);
        cx_finish();
        vector_end();
    }

    vector_begin("unbounded restart: warning, then the name, then one restart");
    pcm_begin(0, 0.2, true);
    F.now = SEC(5);
    avfao_pcm_start(&PCM);
    clear_lines();
    avfao_pcm_notification(&PCM, "AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification",
                           true, 2.0, cur_renderer());
    CHECK(R.restarts == 1, "restarts %d", R.restarts);
    CHECK(F.nlines == 3, "lines %d", F.nlines);
    CHECK(F.nlines >= 3 && F.lines[0].level == AVFAO_WARN &&
          strcmp(F.lines[0].text, "restarting due to system notification; this will "
                 "cause desync") == 0, "warning first");
    CHECK(F.nlines >= 3 && strcmp(F.lines[1].text, "notification name: "
          "AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification") == 0, "name second");
    CHECK(F.nlines >= 3 && strncmp(F.lines[2].text, "trace edge reset: clock ", 24) == 0,
          "reset third");
    CHECK(count_prefix("notification flush time") == 0, "flush line outside the bound");
    if (checks_failed_in_vector)
        dump_lines();
    vector_end();

    vector_begin("flush times: infinite prints inf or -inf, invalid prints nan");
    pcm_begin(4, 0.2, true);
    avfao_pcm_start(&PCM);
    clear_lines();
    // From a renderer that is not the current one, so nothing restarts.
    avfao_pcm_notification(&PCM, "n", true, INFINITY, NULL);
    avfao_pcm_notification(&PCM, "n", true, -INFINITY, NULL);
    avfao_pcm_notification(&PCM, "n", true, NAN, NULL);
    CHECK(count_text("notification flush time inf, current 0") == 1, "inf");
    CHECK(count_text("notification flush time -inf, current 0") == 1, "-inf");
    CHECK(count_text("notification flush time nan, current 0") == 1, "nan");
    CHECK(R.restarts == 0, "restarts %d", R.restarts);
    if (checks_failed_in_vector)
        dump_lines();
    vector_end();

    vector_begin("after a fallback: unpause and start still request rate 1, start makes an item");
    cx_begin(&s);
    tick(SEC(0), SEC(1));
    CHECK(P.rate_one == 1, "rate 1");
    avfao_cx_fallback(&CX);
    P.rate_one = 0;
    F.reads = 0;
    uint64_t heartbeat = CX.heartbeat;
    int armed = P.timer_armed;
    F.now = SEC(1);
    avfao_cx_pause(&CX, true);
    F.now = SEC(2);
    avfao_cx_pause(&CX, false);
    CHECK(P.rate_one == 1, "unpause rate requests %d", P.rate_one);
    CHECK(deadline_is(SEC(4)), "deadline %" PRId64, CX.st.deadline_ns);
    CHECK(CX.st.resume_pending && CX.st.resume_ns == SEC(2) &&
          CX.st.anchor_pacing_ns == 0, "resume");
    CHECK(P.timer_armed == armed + 1, "timer not armed");
    avfao_cx_start(&CX);
    CHECK(P.rate_one == 2, "start rate requests %d", P.rate_one);
    avfao_cx_reset(&CX);
    avfao_cx_start(&CX);
    CHECK(CX.item && P.item_creates == 2, "items %d", P.item_creates);
    CHECK(P.rate_one == 2, "rate requested on the new item");
    CHECK(F.reads == 0 && CX.heartbeat == heartbeat && P.serves == 0, "a step acted");
    CHECK(F.reloads == 1, "reloads %d", F.reloads);
    cx_finish();
    vector_end();

    vector_begin("unpause records the clock read after its rate-1 request");
    cx_begin(&s);
    tick(SEC(0), SEC(10));
    P.timebase_ns = SEC(5);
    F.now = SEC(1);
    avfao_cx_pause(&CX, true);
    P.clock_after_rate_set = true;
    P.clock_after_rate = SEC(7);
    clear_lines();
    F.now = SEC(2);
    avfao_cx_pause(&CX, false);
    CHECK(CX.st.resume_clock_ns == SEC(7), "recorded %" PRId64, CX.st.resume_clock_ns);
    CHECK(find_prefix("trace edge resume: clock 5.000, ") == 0, "edge before the request");
    cx_finish();
    vector_end();
}

// ------------------------------------------- frames to ns against CoreMedia

static void test_rounding(void)
{
    vector_begin("frames to nanoseconds: half away from zero");
    CHECK(avfao_frames_to_ns(1536, 44100) == 34829932, "%" PRId64,
          avfao_frames_to_ns(1536, 44100));
    CHECK(avfao_frames_to_ns(1, 3) == 333333333, "1/3");
    CHECK(avfao_frames_to_ns(2, 3) == 666666667, "2/3");
    CHECK(avfao_frames_to_ns(1, 2000000000) == 1, "half rounds up");
    CHECK(avfao_frames_to_ns(INT64_C(192000) * 86400, 192000) == SEC(86400), "a day");
    vector_end();

#if defined(__APPLE__)
    vector_begin("frames to nanoseconds: identical to CMTimeConvertScale");
    static const int rates[] = {8000, 22050, 32000, 44100, 48000, 88200, 96000, 176400,
                                192000, 3, 7, 1000001};
    int mismatches = 0;
    for (size_t r = 0; r < sizeof(rates) / sizeof(rates[0]); r++) {
        for (int64_t f = 0; f < 5000; f += 1) {
            int64_t frames = f * 7919 + (f % 13);
            CMTime t = CMTimeConvertScale(CMTimeMake(frames, rates[r]), 1000000000,
                                          kCMTimeRoundingMethod_Default);
            if (t.value != avfao_frames_to_ns(frames, rates[r]))
                mismatches++;
        }
    }
    CHECK(mismatches == 0, "%d mismatches", mismatches);
    vector_end();
#endif
}

int main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    test_supervision();
    test_start_anchoring();
    test_resume();
    test_prefetch_compressed();
    test_prefetch_pcm();
    test_bounded_pcm();
    test_session();
    test_eof_restart();
    test_unwrapping();
    test_feed_details();
    test_review();
    test_rounding();

    printf("audio output vectors: %d run, %d failed\n", vectors_run, vectors_failed);
    if (vectors_run == 0)
        return 2;
    return vectors_failed ? 1 : 0;
}
