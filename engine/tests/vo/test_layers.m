/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the layers
 * module, video/out/avfoundation/layers.m of the patched mpv tree, built for
 * the macOS build host behind a small UIKit shim (shim/UIKit/UIKit.h) and run
 * against real AVSampleBufferDisplayLayers (spec 2.5, 4.11, 4.12, 4.14.2,
 * 4.15.2, 4.16). Its calls are made from a background thread, as mpv's VO
 * thread makes them, while the main thread runs its run loop.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <stdatomic.h>

#include "common/msg.h"
#include "video/out/avfoundation/layers.h"

#include "fakes.h"
#include "harness.h"

// ---- the shim's UIKit ------------------------------------------------------------

NSNotificationName const UIApplicationWillResignActiveNotification =
    @"UIApplicationWillResignActiveNotification";
NSNotificationName const UIApplicationDidBecomeActiveNotification =
    @"UIApplicationDidBecomeActiveNotification";

static CGFloat screen_scale = 3.0;

@implementation UIScreen
+ (UIScreen *)mainScreen
{
    static UIScreen *screen;
    if (!screen)
        screen = [[UIScreen alloc] init];
    return screen;
}
- (CGFloat)scale
{
    return screen_scale;
}
@end

// ---- dealloc tracking ---------------------------------------------------------------

static int deallocs, deallocs_on_main;

@interface LucidTestHostLayer : AVSampleBufferDisplayLayer
@end

@implementation LucidTestHostLayer
- (void)dealloc
{
    deallocs++;
    deallocs_on_main += [NSThread isMainThread];
    [super dealloc];
}
@end

// Rides on the subtitle layer as an associated object, so it goes when the
// layer does, on the same thread.
@interface LucidTestSentinel : NSObject
@end

@implementation LucidTestSentinel
- (void)dealloc
{
    deallocs++;
    deallocs_on_main += [NSThread isMainThread];
    [super dealloc];
}
@end

static char sentinel_key;

// ---- threads --------------------------------------------------------------------------

// Runs the main run loop until done() or the timeout. Returns done().
static bool spin(bool (^done)(void), double seconds)
{
    CFAbsoluteTime end = CFAbsoluteTimeGetCurrent() + seconds;
    while (!done() && CFAbsoluteTimeGetCurrent() < end)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
    return done();
}

// Runs a block on a background thread, as the VO thread, while main keeps
// its run loop going for the module's main-thread hops. Fails the case if it
// does not finish (a hop that deadlocked). The flag is stored with release
// and loaded with acquire, so whatever the block wrote (sizes, states) is
// visible here once it reads as finished.
static void off_main(const char *what, void (^block)(void))
{
    __block _Atomic bool finished = false;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        block();
        atomic_store_explicit(&finished, true, memory_order_release);
    });
    CHECK(spin(^bool { return atomic_load_explicit(&finished, memory_order_acquire); }, 10.0),
          "%s did not finish: a main-thread hop deadlocked", what);
}

static void drain_main(void)
{
    spin(^bool { return false; }, 0.05);
}

// The subtitle layer (not retained). The sublayers array is an autoreleased
// copy holding its layers, so it goes in a pool of its own: nothing here may
// keep a layer alive past its teardown.
static AVSampleBufferDisplayLayer *subtitle_layer_of(CALayer *parent, CALayer *host)
{
    AVSampleBufferDisplayLayer *found = nil;
    @autoreleasepool {
        for (CALayer *layer in (parent ? parent : host).sublayers) {
            if (layer != host && [layer isKindOfClass:[AVSampleBufferDisplayLayer class]])
                found = (AVSampleBufferDisplayLayer *)layer;
        }
    }
    return found;
}

static CMTimebaseRef new_timebase(void)
{
    CMTimebaseRef tb = NULL;
    CMTimebaseCreateWithSourceClock(NULL, CMClockGetHostTimeClock(), &tb);
    return tb;
}

static int vo_token;
#define TEST_VO ((struct vo *)&vo_token)

// ---- cases --------------------------------------------------------------------------------

static void test_sibling_layer(void)
{
    CASE("layers-sibling-placement");
    stubs_reset();
    deallocs = deallocs_on_main = 0;
    CALayer *parent = [[CALayer alloc] init];
    LucidTestHostLayer *host = [[LucidTestHostLayer alloc] init];
    host.frame = CGRectMake(10, 20, 300, 200);
    host.contentsScale = 2.0;
    host.zPosition = 3;
    [parent addSublayer:host];
    CMTimebaseRef tb = new_timebase();
    void *hostp = host;

    __block struct avf_layers *l = NULL;
    __block int w = 0, h = 0;
    off_main("creation", ^{
        l = avf_layers_create(NULL, hostp);
        avf_layers_attach_timebase(l, tb);
        avf_layers_read_geometry(l, &w, &h);
        avf_layers_create_subtitle_layer(l, tb);
        avf_layers_observe_app_state(l, TEST_VO);
        avf_layers_observe_geometry(l, TEST_VO);
    });
    CHECK(w == 600 && h == 400, "geometry %dx%d", w, h);
    CHECK(host.controlTimebase == tb, "host controlTimebase not set");
    AVSampleBufferDisplayLayer *sub = subtitle_layer_of(parent, host);
    CHECK(sub != nil, "no subtitle layer beside the host");
    if (!sub)
        return;
    CHECK(sub.superlayer == parent && avf_layers_has_subtitle_layer(l), "not a sibling");
    @autoreleasepool {
        CHECK(parent.sublayers.lastObject == sub, "not above the existing sublayers");
    }
    CHECK(sub.zPosition == 4, "zPosition %f", sub.zPosition);
    CHECK(CGRectEqualToRect(sub.frame, host.frame), "frame not the host's frame");
    CHECK(sub.contentsScale == 2.0, "contentsScale %f", sub.contentsScale);
    CHECK([sub.videoGravity isEqualToString:AVLayerVideoGravityResize], "gravity");
    CHECK(!sub.opaque && !sub.backgroundColor, "not clear");
    CHECK(sub.controlTimebase == tb, "subtitle layer timebase");
    LucidTestSentinel *sentinel = [[LucidTestSentinel alloc] init];
    objc_setAssociatedObject(sub, &sentinel_key, sentinel, OBJC_ASSOCIATION_RETAIN);
    [sentinel release];

    // Equal-value writes are not a change; real ones raise one wake-up.
    CASE("layers-equal-writes-ignored");
    int wakeups = stubs.wakeups;
    host.bounds = host.bounds;
    host.contentsScale = 2.0;
    CHECK(!avf_layers_take_resize(l) && stubs.wakeups == wakeups, "an equal write counted");
    host.bounds = CGRectMake(0, 0, 320, 200);
    CHECK(avf_layers_take_resize(l) && stubs.wakeups == wakeups + 1, "a resize was missed");
    CHECK(!avf_layers_take_resize(l), "the resize flag was not consumed");
    host.contentsScale = 3.0;
    CHECK(avf_layers_take_resize(l) && stubs.wakeups == wakeups + 2, "a scale change was missed");

    CASE("layers-geometry-fallbacks");
    host.contentsScale = 0;
    if (host.contentsScale <= 0) {
        off_main("geometry read", ^{ avf_layers_read_geometry(l, &w, &h); });
        CHECK(w == 960 && h == 600, "screen scale not used: %dx%d", w, h);
    }
    host.contentsScale = 2.0;
    host.bounds = CGRectMake(0, 0, 0.6, 0.2);
    off_main("geometry read", ^{ avf_layers_read_geometry(l, &w, &h); });
    CHECK(w == 1 && h == 1, "tiny layer %dx%d", w, h);
    host.bounds = CGRectMake(0, 0, 320, 200);
    avf_layers_take_resize(l);

    // Becoming active again after resigning asks for one resync.
    CASE("layers-app-state");
    wakeups = stubs.wakeups;
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    drain_main();
    CHECK(!avf_layers_take_resync(l), "a resync without resigning first");
    [nc postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    [nc postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    CHECK(spin(^bool { return stubs.wakeups > wakeups; }, 2.0), "no wake-up after becoming active");
    CHECK(avf_layers_take_resync(l), "no resync after becoming active");
    CHECK(!avf_layers_take_resync(l), "resync flag not consumed");

    // The subtitle layer copies the host's frame on main, later.
    CASE("layers-frame-copy");
    host.frame = CGRectMake(40, 50, 400, 225);
    host.zPosition = 7;
    off_main("frame copy", ^{ avf_layers_copy_frame_async(l); });
    CHECK(spin(^bool { return CGRectEqualToRect(sub.frame, host.frame); }, 2.0),
          "subtitle layer frame not copied");
    CHECK(sub.zPosition == 8 && sub.contentsScale == 2.0, "placement after the copy");
    avf_layers_take_resize(l);

    // Renderer work from the VO thread, including the recovery's main hop.
    CASE("layers-renderer-calls");
    __block struct avf_recovery_state st = { .status = -1 };
    __block bool ready = false, needs = true, sub_ready = false;
    off_main("renderer calls", ^{
        avf_layers_flush_host(l, false);
        avf_layers_flush_subtitles(l, true);
        avf_layers_flush_subtitles_async(l);
        ready = avf_layers_host_ready(l);
        needs = avf_layers_host_needs_recovery(l);
        sub_ready = avf_layers_subtitles_ready(l);
        avf_layers_recover(l, tb, &st);
    });
    drain_main();
    CHECK(ready && sub_ready, "renderers not ready");
    CHECK(!needs, "a fresh layer needs recovery");
    CHECK(st.status == AVQueuedSampleBufferRenderingStatusUnknown ||
          st.status == AVQueuedSampleBufferRenderingStatusRendering, "status %ld", st.status);

    // Teardown: observers gone first, then the flushes, the timebase and the
    // subtitle layer, and the layers' last release on main.
    CASE("layers-teardown");
    off_main("observer removal", ^{ avf_layers_remove_observers(l); });
    wakeups = stubs.wakeups;
    host.bounds = CGRectMake(0, 0, 100, 100);
    [nc postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    [nc postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    drain_main();
    CHECK(stubs.wakeups == wakeups && !avf_layers_take_resize(l) && !avf_layers_take_resync(l),
          "a wake-up after the observers were removed");
    off_main("teardown", ^{
        avf_layers_flush_for_teardown(l);
        avf_layers_detach_timebase(l);
        avf_layers_remove_subtitle_layer(l);
    });
    CHECK(!host.controlTimebase && !sub.controlTimebase, "controlTimebase not cleared");
    CHECK(!sub.superlayer, "subtitle layer still in the tree");
    CHECK(host.superlayer == parent, "the host layer was removed from its superlayer");
    [host removeFromSuperlayer];
    [host release];
    host = nil;
    sub = nil;
    deallocs = deallocs_on_main = 0;
    off_main("destroy", ^{ avf_layers_destroy(l); });
    CHECK(spin(^bool { return deallocs == 2; }, 5.0), "%d of 2 layers released", deallocs);
    CHECK(deallocs_on_main == deallocs, "a layer was deallocated off the main thread");
    [parent release];
    CFRelease(tb);
}

static void test_nested_layer(void)
{
    CASE("layers-nested-placement");
    stubs_reset();
    LucidTestHostLayer *host = [[LucidTestHostLayer alloc] init];
    host.frame = CGRectMake(5, 6, 160, 90);
    host.contentsScale = 1.0;
    CMTimebaseRef tb = new_timebase();
    void *hostp = host;
    __block struct avf_layers *l = NULL;
    off_main("nested creation", ^{
        l = avf_layers_create(NULL, hostp);
        avf_layers_attach_timebase(l, tb);
        avf_layers_create_subtitle_layer(l, tb);
    });
    AVSampleBufferDisplayLayer *sub = subtitle_layer_of(nil, host);
    CHECK(sub && sub.superlayer == host, "subtitle layer not inside the host");
    CHECK(sub && CGRectEqualToRect(sub.frame, host.bounds), "nested frame is not the bounds");
    CHECK(stubs.last_level == MSGL_WARN, "no warning for a host without a superlayer");
    host.frame = CGRectMake(5, 6, 200, 100);
    off_main("nested frame copy", ^{ avf_layers_copy_frame_async(l); });
    CHECK(spin(^bool { return CGRectEqualToRect(sub.frame, host.bounds); }, 2.0),
          "nested frame copy is not the bounds");
    off_main("nested teardown", ^{
        avf_layers_remove_observers(l);
        avf_layers_flush_for_teardown(l);
        avf_layers_detach_timebase(l);
        avf_layers_remove_subtitle_layer(l);
    });
    // The host keeps its own internal sublayers; only ours must be gone.
    CHECK(!sub.superlayer, "subtitle layer left inside the host");
    [host release];
    deallocs = deallocs_on_main = 0;
    off_main("nested destroy", ^{ avf_layers_destroy(l); });
    CHECK(spin(^bool { return deallocs == 1; }, 5.0), "host layer not released");
    CHECK(deallocs_on_main == deallocs, "host layer deallocated off the main thread");
    CFRelease(tb);
}

void avf_test_layers(void)
{
    @autoreleasepool {
        test_sibling_layer();
        test_nested_layer();
    }
}
