/*
 * Host-side tests for Lucid Engine's AVFoundation video output: the little of
 * UIKit that video/out/avfoundation/layers.m uses, so the layers module can
 * be built and run on the macOS build host. test_layers.m provides it.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#ifndef LUCID_VO_TEST_UIKIT_SHIM_H
#define LUCID_VO_TEST_UIKIT_SHIM_H

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface UIScreen : NSObject
+ (UIScreen *)mainScreen;
@property (nonatomic, readonly) CGFloat scale;
@end

extern NSNotificationName const UIApplicationWillResignActiveNotification;
extern NSNotificationName const UIApplicationDidBecomeActiveNotification;

#endif
