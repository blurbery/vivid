#!/usr/bin/env python3
"""Exercise the patched driver's transport decisions with a controlled clock.

Pass the ao_avfoundation.m produced by the pinned Apple patch series. Only
Objective-C message sends and external clocks are stubbed; the C control flow
is extracted from the source that the native workflow compiles.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index('static void avp_update_transport(struct ao *ao)')
end = source.index('\n// Main driver', start)
body = source[start:end]
prefetch_start = source.index('static bool avp_wait_for_prefetch(')
prefetch_end = source.index('\n// One read/unwrap pass', prefetch_start)
prefetch = source[prefetch_start:prefetch_end]
pcm_start = source.index('static bool pcm_wait_for_prefetch(')
pcm_end = source.index('\n#endif', pcm_start)
pcm_prefetch = source[pcm_start:pcm_end]
pcm_policy_start = source.index('static bool pcm_should_feed(')
pcm_policy_end = source.index('\nstatic void pcm_pump(', pcm_policy_start)
pcm_policy = source[pcm_policy_start:pcm_policy_end]
pcm_feed = source[source.index('static void feed(struct ao *ao)\n{'):source.index('static void start(')]
assert pcm_feed.index('if (ahead >= p->pcm_lookahead_ns)') < pcm_feed.index('ao_read_data(')
assert pcm_feed.index('if (pcm_wait_for_prefetch(') < pcm_feed.index('ao_read_data(')
pull = source[source.index('static bool avp_pull('):source.index('static void avp_update_transport(')]
assert pull.index('if (avp_wait_for_prefetch(ao, request_sample_count))') < pull.index('ao_read_data(ao,')
for message, stub in {
    '[p->player setRate:1];': 'rate_calls++;',
    '[p->item seekToTime:kCMTimeZero completionHandler:nil];': 'seek_calls++;',
}.items():
    assert message in body, message
    body = body.replace(message, stub)
assert '[p->' not in body, 'Unmocked Objective-C call'

harness = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define S INT64_C(1000000000)
#define MP_TIME_S_TO_NS(s) ((s)*S)
#define AVP_START_MIN_NS S
#define AVP_START_GRACE_NS (2*S)
#define AVP_START_LEAD_NS(p) (2*(p)->avp_lead_ns)
#define MP_WARN(...) ((void)0)
#define MP_ERR(...) ((void)0)
struct priv {
    bool avp_playing, spdif_reload_requested, avp_rate_applied;
    bool avp_eof, avp_start_seeked;
    void *item, *player;
    int64_t es_pts, avp_start_deadline, avp_primed_pts, avp_lead_ns;
};
struct ao { struct priv *priv; };
static int64_t now, clock_pos, feed_pos, queued_samples;
static int rate_calls, seek_calls, reload_calls, checks;
static int64_t mp_time_ns(void) { return now; }
static int64_t avp_feed_position_ns(struct ao *ao) { return feed_pos; }
static void *ao_get_queue(struct ao *ao) { return ao; }
static int64_t mp_async_queue_get_samples(void *queue) { return queued_samples; }
static int64_t avp_current_time_ns(struct ao *ao) { return clock_pos; }
static void spdif_reload(struct ao *ao) {
    reload_calls++; ao->priv->spdif_reload_requested = true;
}
static void check(bool ok, const char *name) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
}
''' + prefetch + pcm_prefetch + pcm_policy + body + r'''
static struct priv p;
static struct ao ao = { &p };
static void reset(void) {
    p = (struct priv){ .avp_playing=true, .item=&p, .avp_lead_ns=8*S };
    now=clock_pos=feed_pos=queued_samples=rate_calls=seek_calls=reload_calls=0;
}
static void tick(int64_t time, int64_t fed) {
    now=time; p.es_pts=fed; avp_update_transport(&ao);
}
int main(void) {
    reset(); tick(0, S/2);
    check(!p.avp_rate_applied && !seek_calls, "wait for minimum priming");
    tick(8*S, S/2);
    check(!seek_calls && !reload_calls, "slow source before minimum stays intact");
    tick(9*S, S);
    check(rate_calls==1 && p.avp_start_deadline==11*S, "grace begins at priming");
    tick(10*S, 2*S);
    check(!seek_calls && p.avp_start_deadline==11*S, "progress cannot postpone first recovery");
    tick(11*S, 3*S);
    check(seek_calls==1 && !reload_calls, "recover parked clock on time despite progress");
    tick(12*S, 4*S); tick(14*S, 5*S); tick(17*S, 6*S);
    check(seek_calls==1 && !reload_calls && p.avp_start_deadline==19*S,
          "retain slow-source patience after first recovery");
    clock_pos=S/10; tick(18*S, 7*S);
    check(p.avp_start_deadline==-1 && !reload_calls, "moving clock stops supervision");
    clock_pos=0; tick(25*S, 7*S);
    check(seek_calls==1 && !reload_calls, "do not seek again after healthy playback");

    reset(); tick(0,S); tick(2*S,S);
    check(seek_calls==1, "stalled input still gets first recovery");
    tick(3*S,S); tick(5*S,S);
    check(reload_calls==1, "no progress after recovery falls back to PCM");
    tick(8*S,S);
    check(reload_calls==1, "no repeated fallback once reload requested");

    reset(); tick(0,S); tick(2*S,16*S); tick(4*S,16*S);
    check(reload_calls==1 && seek_calls==1, "full startup lead cannot postpone fallback");
    reset(); p.avp_eof=true; tick(0,S/4);
    check(rate_calls==1, "short EOF stream can start without minimum lead");
    reset(); p.avp_playing=false; tick(20*S,4*S);
    check(!rate_calls && !seek_calls, "paused transport unchanged");
    reset(); p.item=NULL; tick(20*S,4*S);
    check(!rate_calls, "missing item unchanged");
    reset(); p.spdif_reload_requested=true; tick(20*S,4*S);
    check(!rate_calls, "pending reload unchanged");
    reset(); tick(0,S); clock_pos=1; tick(S,2*S);
    check(!seek_calls && p.avp_start_deadline==-1, "normal startup never seeks");
    reset(); tick(0,S); tick(2*S,3*S);
    check(seek_calls==1, "fresh item after user seek gets its own bounded recovery");
    reset(); p.es_pts=2*S;
    check(avp_wait_for_prefetch(&ao, 4800), "queued audio prevents empty prefetch underrun");
    queued_samples=4799;
    check(avp_wait_for_prefetch(&ao, 4800), "short prefetch waits while audio is buffered");
    queued_samples=4800;
    check(!avp_wait_for_prefetch(&ao, 4800), "full read proceeds without waiting");
    queued_samples=0; feed_pos=S;
    check(avp_wait_for_prefetch(&ao, 4800), "one-second reserve boundary");
    feed_pos=S+1;
    check(!avp_wait_for_prefetch(&ao, 4800), "real starvation below reserve reaches mpv");
    feed_pos=2*S;
    check(!avp_wait_for_prefetch(&ao, 4800), "drained audio is never masked");
    p.es_pts=0; feed_pos=0;
    check(!avp_wait_for_prefetch(&ao, 4800), "initial priming is never blocked");
    p.es_pts=16*S; feed_pos=0;
    check(avp_wait_for_prefetch(&ao, 4800), "retain full startup lead without false underrun");
    feed_pos=16*S;
    check(!avp_wait_for_prefetch(&ao, 4800), "pending EOF is read as buffered audio drains");
    check(!pcm_wait_for_prefetch(0, 0, 4800), "PCM initial priming is allowed");
    check(pcm_wait_for_prefetch(2*S, 0, 4800), "PCM queued audio prevents false underrun");
    check(pcm_wait_for_prefetch(S, 4799, 4800), "PCM short prefetch waits at reserve");
    check(!pcm_wait_for_prefetch(S, 4800, 4800), "PCM complete packet proceeds");
    check(!pcm_wait_for_prefetch(S-1, 0, 4800), "PCM real starvation remains visible");
    check(!pcm_wait_for_prefetch(-S, 0, 4800), "PCM drained clock permits EOF read");
    check(pcm_should_feed(true, true, -S, 4*S), "PCM starts after a flushed seek");
    check(!pcm_should_feed(false, true, 0, 4*S), "PCM pause disables refill");
    check(!pcm_should_feed(true, false, 0, 4*S), "PCM backpressure prevents enqueue");
    check(pcm_should_feed(true, true, 0, 4*S), "PCM readiness recovery resumes refill");
    check(!pcm_should_feed(true, true, 4*S, 4*S), "PCM lead is bounded at four seconds");
    check(pcm_should_feed(true, true, 4*S-1, 4*S), "PCM drained lead resumes refill");
    check(!pcm_should_feed(false, false, -S, 4*S), "PCM stop stays idle after flush");
    printf("%d audio transport checks passed\n", checks);
}
'''
with tempfile.TemporaryDirectory(prefix='vivid-audio-test-') as directory:
    path = Path(directory)
    (path/'transport.c').write_text(harness)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Werror', '-Wno-unused-parameter',
                    str(path/'transport.c'), '-o', str(path/'transport')], check=True)
    subprocess.run([str(path/'transport')], check=True)

# Exercise the actual replacement function with lightweight renderer doubles.
# No audio device is opened; only Foundation ownership and property transfer run.
sink_start = source.index('static bool pcm_recreate_sink(')
sink_end = source.index('\nstatic bool pcm_should_feed(', sink_start)
sink_body = source[sink_start:sink_end]
sink_harness = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#define HAVE_MACOS_11_3_FEATURES 0
#define HAVE_MACOS_12_FEATURES 0
#define MP_WARN(...) ((void)0)
#define MP_VERBOSE(...) ((void)0)
#define AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification @"TestFlush"
static bool fail_renderer;
@interface AVSampleBufferAudioRenderer : NSObject
@property float volume;
@property(getter=isMuted) BOOL muted;
@end
@implementation AVSampleBufferAudioRenderer
- (instancetype)init {
    self = [super init];
    if (fail_renderer) { [self release]; return nil; }
    self.volume = 1;
    return self;
}
@end
@interface AVSampleBufferRenderSynchronizer : NSObject
- (void)addRenderer:(AVSampleBufferAudioRenderer *)renderer;
@end
@implementation AVSampleBufferRenderSynchronizer
- (void)addRenderer:(AVSampleBufferAudioRenderer *)renderer { }
@end
struct priv {
    AVSampleBufferAudioRenderer *renderer;
    AVSampleBufferRenderSynchronizer *synchronizer;
    NSObject *observer;
    int64_t end_time_av, pcm_last_log_ns;
    bool pcm_needs_fresh_sink;
};
struct ao { struct priv *priv; };
static int reloads;
static void ao_request_reload(struct ao *ao) { reloads++; }
''' + sink_body + r'''
int main(void) {
    @autoreleasepool {
        struct priv p = { .renderer=[AVSampleBufferAudioRenderer new],
            .synchronizer=[AVSampleBufferRenderSynchronizer new],
            .observer=[NSObject new], .pcm_needs_fresh_sink=true,
            .end_time_av=9000, .pcm_last_log_ns=1000 };
        struct ao ao = { &p };
        p.renderer.volume = 0.37f;
        p.renderer.muted = YES;
        assert(pcm_recreate_sink(&ao));
        assert(p.renderer.volume == 0.37f && p.renderer.isMuted);
        assert(p.end_time_av == -1 && p.pcm_last_log_ns == 0 && !p.pcm_needs_fresh_sink);
        p.renderer.volume = 0.0f;
        p.renderer.muted = NO;
        assert(pcm_recreate_sink(&ao));
        assert(p.renderer.volume == 0.0f && !p.renderer.isMuted);
        AVSampleBufferAudioRenderer *original = p.renderer;
        p.pcm_needs_fresh_sink = true;
        fail_renderer = true;
        assert(!pcm_recreate_sink(&ao));
        assert(reloads == 1 && p.renderer == original && p.pcm_needs_fresh_sink);
        [[NSNotificationCenter defaultCenter] removeObserver:p.observer];
        [p.renderer release]; [p.synchronizer release]; [p.observer release];
        puts("7 PCM renderer replacement checks passed");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='vivid-pcm-sink-test-') as directory:
    path = Path(directory)
    (path/'sink.m').write_text(sink_harness)
    subprocess.run(['clang', '-fblocks', '-framework', 'Foundation',
                    str(path/'sink.m'), '-o', str(path/'sink')], check=True)
    subprocess.run([str(path/'sink')], check=True)
