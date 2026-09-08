// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <AetherLibavformat/avformat.h>
#include <AetherLibavcodec/avcodec.h>
#include <AetherLibavutil/hwcontext.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

static inline int vv_eof(void) { return AVERROR_EOF; }
static inline int vv_exit(void) { return AVERROR_EXIT; }
static inline int vv_again(void) { return AVERROR(EAGAIN); }
static inline int64_t vv_no_pts(void) { return AV_NOPTS_VALUE; }
static inline double vv_time(AVRational value) { return av_q2d(value); }
static inline AVStream *vv_stream(AVFormatContext *format, unsigned int index) {
    return index < format->nb_streams ? format->streams[index] : NULL;
}
static inline int vv_attached_picture(AVStream *stream) { return !!(stream->disposition & AV_DISPOSITION_ATTACHED_PIC); }
static inline int vv_default(AVStream *stream) { return !!(stream->disposition & AV_DISPOSITION_DEFAULT); }
static inline int vv_forced(AVStream *stream) { return !!(stream->disposition & AV_DISPOSITION_FORCED); }
static inline double vv_origin(AVFormatContext *format) {
    return format->start_time == AV_NOPTS_VALUE ? 0 : (double)format->start_time / AV_TIME_BASE;
}
static inline void vv_free_io(AVIOContext **io) {
    if (*io) av_freep(&(*io)->buffer);
    avio_context_free(io);
}

AVCodecContext *vv_create_decoder(AVStream *stream, int hardware, int *error);
void vv_limit_input(AVFormatContext *format);
typedef struct VVConverter VVConverter;
VVConverter *vv_converter_create(void);
void vv_converter_free(VVConverter **converter);
int vv_make_video_sample(VVConverter *converter, AVFrame *frame, CMTime pts, CMTime duration, CMSampleBufferRef *sample);
int vv_make_audio_sample(VVConverter *converter, AVFrame *frame, CMTime pts, CMSampleBufferRef *sample);
CMAudioFormatDescriptionRef vv_native_audio_format(AVCodecParameters *parameters);
int vv_make_audio_packet(CMAudioFormatDescriptionRef format, AVPacket *packet, CMTime pts, CMTime duration, CMSampleBufferRef *sample);
#include <CoreGraphics/CoreGraphics.h>
static inline AVSubtitleRect *vv_subtitle_rect(AVSubtitle *subtitle, unsigned index) {
    return index < subtitle->num_rects ? subtitle->rects[index] : NULL;
}
CGImageRef vv_subtitle_image(AVSubtitleRect *rect);
typedef struct VVASS VVASS;
VVASS *vv_ass_create(const uint8_t *header, int size, int document);
void vv_ass_free(VVASS **ass);
void vv_ass_chunk(VVASS *ass, const uint8_t *data, int size, double start, double duration);
void vv_ass_flush(VVASS *ass);
CGImageRef vv_ass_render(VVASS *ass, double seconds, int width, int height, int *changed);
#include <AetherLibavutil/dovi_meta.h>
static inline int vv_dovi_profile(AVCodecParameters *parameters) {
    const AVPacketSideData *side = av_packet_side_data_get(parameters->coded_side_data, parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    return side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord) ? ((const AVDOVIDecoderConfigurationRecord *)side->data)->dv_profile : 0;
}
