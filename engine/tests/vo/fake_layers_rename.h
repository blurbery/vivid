/*
 * Host-side tests for Lucid Engine's AVFoundation video output: renames
 * every function of video/out/avfoundation/layers.h, so a file that includes
 * this first calls (or defines) the fake layers module instead.
 *
 * Copyright (C) 2026 blurbery
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or (at
 * your option) any later version.
 */

#ifndef LUCID_VO_TEST_FAKE_LAYERS_RENAME_H
#define LUCID_VO_TEST_FAKE_LAYERS_RENAME_H

#define avf_layers_create fake_layers_create
#define avf_layers_destroy fake_layers_destroy
#define avf_layers_attach_timebase fake_layers_attach_timebase
#define avf_layers_read_geometry fake_layers_read_geometry
#define avf_layers_create_subtitle_layer fake_layers_create_subtitle_layer
#define avf_layers_observe_app_state fake_layers_observe_app_state
#define avf_layers_observe_geometry fake_layers_observe_geometry
#define avf_layers_take_resync fake_layers_take_resync
#define avf_layers_take_resize fake_layers_take_resize
#define avf_layers_has_subtitle_layer fake_layers_has_subtitle_layer
#define avf_layers_copy_frame_async fake_layers_copy_frame_async
#define avf_layers_flush_subtitles_async fake_layers_flush_subtitles_async
#define avf_layers_flush_subtitles fake_layers_flush_subtitles
#define avf_layers_subtitles_ready fake_layers_subtitles_ready
#define avf_layers_enqueue_subtitles fake_layers_enqueue_subtitles
#define avf_layers_flush_host fake_layers_flush_host
#define avf_layers_host_ready fake_layers_host_ready
#define avf_layers_host_needs_recovery fake_layers_host_needs_recovery
#define avf_layers_enqueue_host fake_layers_enqueue_host
#define avf_layers_recover fake_layers_recover
#define avf_layers_remove_observers fake_layers_remove_observers
#define avf_layers_flush_for_teardown fake_layers_flush_for_teardown
#define avf_layers_detach_timebase fake_layers_detach_timebase
#define avf_layers_remove_subtitle_layer fake_layers_remove_subtitle_layer

#endif
