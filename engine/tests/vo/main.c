/*
 * Host-side tests for Lucid Engine's AVFoundation video output: entry point,
 * case counting and the two mpv logging functions the modules call.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include "common/msg.h"

#include "harness.h"

int avf_test_cases;
int avf_test_failures;
const char *avf_test_suite = "";
static const char *current_case = "";
static bool verbose;

void avf_test_case(const char *name)
{
    current_case = name;
    avf_test_cases += 1;
    if (verbose)
        printf("  case %s/%s\n", avf_test_suite, name);
}

void avf_test_fail(const char *file, int line, const char *fmt, ...)
{
    avf_test_failures += 1;
    printf("FAIL %s/%s (%s:%d): ", avf_test_suite, current_case, file, line);
    va_list va;
    va_start(va, fmt);
    vprintf(fmt, va);
    va_end(va);
    printf("\n");
}

// mpv's logging, as the modules under test call it.
void mp_msg(struct mp_log *log, int lev, const char *format, ...)
{
    if (!verbose)
        return;
    va_list va;
    va_start(va, format);
    printf("    [log %d] ", lev);
    vprintf(format, va);
    va_end(va);
}

int mp_msg_level(struct mp_log *log)
{
    return MSGL_V;
}

static void run(const char *name, void (*fn)(void))
{
    avf_test_suite = name;
    int before = avf_test_cases, failed = avf_test_failures;
    fn();
    printf("suite %-10s %4d cases, %d failures\n", name,
           avf_test_cases - before, avf_test_failures - failed);
}

int main(int argc, char **argv)
{
    verbose = argc > 1 && !strcmp(argv[1], "-v");
    run("clock", avf_test_clock);
    run("pacing", avf_test_pacing);
    run("geometry", avf_test_geometry);
    run("pixels", avf_test_pixels);
    run("frame", avf_test_frame);
    run("subtitles", avf_test_subtitles);
    printf("RESULT %d cases, %d failures\n", avf_test_cases, avf_test_failures);
    if (!avf_test_cases) {
        printf("FAIL no test case ran\n");
        return 1;
    }
    return avf_test_failures ? 1 : 0;
}
