// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#include "CVividMedia.h"
#include <AetherLibavutil/pixdesc.h>
#include <AetherLibswscale/swscale.h>
#include <AetherLibswresample/swresample.h>
#include <VideoToolbox/VideoToolbox.h>
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>

struct VVConverter {
    struct SwsContext *scale;
    SwrContext *resample;
    AVChannelLayout channels;
    int sample_rate, sample_format;
    CMAudioFormatDescriptionRef audio_format;
};
VVConverter *vv_converter_create(void) { return av_mallocz(sizeof(VVConverter)); }
void vv_converter_free(VVConverter **converter) {
    if (!converter || !*converter) return;
    sws_freeContext((*converter)->scale);
    swr_free(&(*converter)->resample);
    av_channel_layout_uninit(&(*converter)->channels);
    if ((*converter)->audio_format) CFRelease((*converter)->audio_format);
    av_freep(converter);
}

static int reject_nested(AVFormatContext *format, AVIOContext **io, const char *url, int flags, AVDictionary **options) {
    return AVERROR(EPERM);
}
void vv_limit_input(AVFormatContext *format) {
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    format->io_open = reject_nested;
    format->probesize = 2 * 1024 * 1024;
    format->max_analyze_duration = 2 * AV_TIME_BASE;
}
static enum AVPixelFormat select_format(AVCodecContext *codec, const enum AVPixelFormat *formats) {
    if (codec->hw_device_ctx)
        for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p)
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return avcodec_default_get_format(codec, formats);
}
static int supports_hardware(enum AVCodecID codec) {
    CMVideoCodecType type;
    switch (codec) {
        case AV_CODEC_ID_H264: type = kCMVideoCodecType_H264; break;
        case AV_CODEC_ID_HEVC: type = kCMVideoCodecType_HEVC; break;
        case AV_CODEC_ID_AV1: type = kCMVideoCodecType_AV1; break;
        case AV_CODEC_ID_VP9: type = kCMVideoCodecType_VP9; break;
        default: return 0;
    }
    return VTIsHardwareDecodeSupported(type);
}
AVCodecContext *vv_create_decoder(AVStream *stream, int hardware, int *error) {
    const AVCodec *implementation = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!implementation) { *error = AVERROR_DECODER_NOT_FOUND; return NULL; }
    AVCodecContext *codec = avcodec_alloc_context3(implementation);
    if (!codec) { *error = AVERROR(ENOMEM); return NULL; }
    *error = avcodec_parameters_to_context(codec, stream->codecpar);
    if (*error < 0) goto fail;
    codec->pkt_timebase = stream->time_base;
    codec->thread_count = 2;
    codec->get_format = select_format;
    if (hardware && supports_hardware(stream->codecpar->codec_id)) {
        for (int i = 0; ; ++i) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(implementation, i);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
                (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                av_hwdevice_ctx_create(&codec->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
                break;
            }
        }
    }
    if (codec->hw_device_ctx) codec->thread_count = 1;
    *error = avcodec_open2(codec, implementation, NULL);
    if (*error >= 0) return codec;
fail:
    avcodec_free_context(&codec);
    return NULL;
}

static void attach_colour(CVPixelBufferRef pixel, AVFrame *frame) {
    CFStringRef primaries = NULL, transfer = NULL, matrix = NULL;
    if (frame->color_primaries == AVCOL_PRI_BT2020) primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
    else if (frame->color_primaries == AVCOL_PRI_BT709) primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
    if (frame->color_trc == AVCOL_TRC_SMPTE2084) transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    else if (frame->color_trc == AVCOL_TRC_ARIB_STD_B67) transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    else if (frame->color_trc == AVCOL_TRC_BT709) transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
    if (frame->colorspace == AVCOL_SPC_BT2020_NCL) matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
    else if (frame->colorspace == AVCOL_SPC_BT709) matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    else if (frame->colorspace == AVCOL_SPC_SMPTE170M) matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    if (primaries) CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, primaries, kCVAttachmentMode_ShouldPropagate);
    if (transfer) CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, transfer, kCVAttachmentMode_ShouldPropagate);
    if (matrix) CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
}
int vv_make_video_sample(VVConverter *converter, AVFrame *frame, CMTime pts, CMTime duration, CMSampleBufferRef *sample) {
    *sample = NULL;
    CVPixelBufferRef pixel = NULL;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        pixel = (CVPixelBufferRef)frame->data[3];
        if (!pixel) return AVERROR_INVALIDDATA;
        CVPixelBufferRetain(pixel);
    } else {
        const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(frame->format);
        int deep = description && description->comp[0].depth > 8;
        enum AVPixelFormat format = deep ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
        int full = frame->color_range == AVCOL_RANGE_JPEG;
        OSType cvformat = deep ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) :
            (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void *keys[] = { kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey };
        const void *values[] = { surface, kCFBooleanTrue };
        CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CVReturn result = CVPixelBufferCreate(NULL, frame->width, frame->height, cvformat, attributes, &pixel);
        CFRelease(attributes); CFRelease(surface);
        if (result != kCVReturnSuccess) return AVERROR(ENOMEM);
        converter->scale = sws_getCachedContext(converter->scale, frame->width, frame->height, frame->format,
            frame->width, frame->height, format, SWS_BILINEAR, NULL, NULL, NULL);
        struct SwsContext *scale = converter->scale;
        if (!scale) { CVPixelBufferRelease(pixel); return AVERROR(ENOMEM); }
        const int *coefficients = sws_getCoefficients(frame->colorspace == AVCOL_SPC_BT2020_NCL ? SWS_CS_BT2020 :
            frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_ITU601);
        sws_setColorspaceDetails(scale, coefficients, full, coefficients, full, 0, 1 << 16, 1 << 16);
        CVPixelBufferLockBaseAddress(pixel, 0);
        uint8_t *planes[4] = { CVPixelBufferGetBaseAddressOfPlane(pixel, 0), CVPixelBufferGetBaseAddressOfPlane(pixel, 1) };
        int strides[4] = { (int)CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) };
        int rows = sws_scale(scale, (const uint8_t * const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        if (rows <= 0) { CVPixelBufferRelease(pixel); return AVERROR_INVALIDDATA; }
    }
    attach_colour(pixel, frame);
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus result = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixel, &format);
    CMSampleTimingInfo timing = { duration, pts, kCMTimeInvalid };
    if (!result) result = CMSampleBufferCreateReadyWithImageBuffer(NULL, pixel, format, &timing, sample);
    if (format) CFRelease(format);
    CVPixelBufferRelease(pixel);
    return result ? AVERROR_INVALIDDATA : 0;
}
static AudioChannelLabel audio_label(enum AVChannel channel) {
    switch (channel) {
        case AV_CHAN_FRONT_LEFT: return kAudioChannelLabel_Left;
        case AV_CHAN_FRONT_RIGHT: return kAudioChannelLabel_Right;
        case AV_CHAN_FRONT_CENTER: return kAudioChannelLabel_Center;
        case AV_CHAN_LOW_FREQUENCY: return kAudioChannelLabel_LFEScreen;
        case AV_CHAN_BACK_LEFT: return kAudioChannelLabel_LeftSurround;
        case AV_CHAN_BACK_RIGHT: return kAudioChannelLabel_RightSurround;
        case AV_CHAN_SIDE_LEFT: return kAudioChannelLabel_LeftSurroundDirect;
        case AV_CHAN_SIDE_RIGHT: return kAudioChannelLabel_RightSurroundDirect;
        case AV_CHAN_BACK_CENTER: return kAudioChannelLabel_CenterSurround;
        case AV_CHAN_FRONT_LEFT_OF_CENTER: return kAudioChannelLabel_LeftCenter;
        case AV_CHAN_FRONT_RIGHT_OF_CENTER: return kAudioChannelLabel_RightCenter;
        default: return kAudioChannelLabel_Unknown;
    }
}
int vv_make_audio_sample(VVConverter *converter, AVFrame *frame, CMTime pts, CMSampleBufferRef *sample) {
    *sample = NULL;
    int channels = frame->ch_layout.nb_channels;
    if (channels <= 0 || channels > 32 || frame->sample_rate <= 0 || frame->nb_samples <= 0)
        return AVERROR_INVALIDDATA;
    if (!converter->resample || converter->sample_rate != frame->sample_rate ||
        converter->sample_format != frame->format || av_channel_layout_compare(&converter->channels, &frame->ch_layout)) {
        swr_free(&converter->resample);
        av_channel_layout_uninit(&converter->channels);
        if (converter->audio_format) {
            CFRelease(converter->audio_format);
            converter->audio_format = NULL;
        }
        int status = swr_alloc_set_opts2(&converter->resample, &frame->ch_layout, AV_SAMPLE_FMT_FLT, frame->sample_rate,
            &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL);
        if (status < 0) return status;
        status = swr_init(converter->resample);
        if (status < 0) { swr_free(&converter->resample); return status; }
        status = av_channel_layout_copy(&converter->channels, &frame->ch_layout);
        if (status < 0) { swr_free(&converter->resample); return status; }
        converter->sample_rate = frame->sample_rate;
        converter->sample_format = frame->format;
    }
    SwrContext *resample = converter->resample;
    int capacity = swr_get_out_samples(resample, frame->nb_samples);
    if (capacity <= 0 || capacity > INT_MAX / (channels * 4)) return AVERROR_INVALIDDATA;
    uint8_t *pcm = av_malloc((size_t)capacity * channels * 4);
    if (!pcm) return AVERROR(ENOMEM);
    int count = swr_convert(resample, &pcm, capacity, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (count <= 0) { av_free(pcm); return count < 0 ? count : AVERROR(EAGAIN); }
    OSStatus result = noErr;
    if (!converter->audio_format) {
        AudioStreamBasicDescription asbd = {
            .mSampleRate = frame->sample_rate, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = channels * 4, .mFramesPerPacket = 1,
            .mBytesPerFrame = channels * 4, .mChannelsPerFrame = channels, .mBitsPerChannel = 32
        };
        size_t layout_size = offsetof(AudioChannelLayout, mChannelDescriptions) + channels * sizeof(AudioChannelDescription);
        AudioChannelLayout *layout = av_mallocz(layout_size);
        if (!layout) { av_free(pcm); return AVERROR(ENOMEM); }
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = channels;
        for (int i = 0; i < channels; i++) layout->mChannelDescriptions[i].mChannelLabel =
            audio_label(av_channel_layout_channel_from_index(&frame->ch_layout, i));
        result = CMAudioFormatDescriptionCreate(NULL, &asbd, layout_size, layout, 0, NULL, NULL,
            &converter->audio_format);
        av_free(layout);
    }
    CMBlockBufferRef block = NULL;
    size_t size = (size_t)count * channels * 4;
    if (!result) result = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, NULL, NULL, 0, size, 0, &block);
    if (!result) result = CMBlockBufferReplaceDataBytes(pcm, block, 0, size);
    CMSampleTimingInfo timing = { CMTimeMake(1, frame->sample_rate), pts, kCMTimeInvalid };
    size_t sample_size = channels * 4;
    if (!result) result = CMSampleBufferCreateReady(NULL, block, converter->audio_format, count, 1,
        &timing, 1, &sample_size, sample);
    if (block) CFRelease(block);
    av_free(pcm);
    return result ? AVERROR_INVALIDDATA : 0;
}

static void store_be32(uint8_t *bytes, uint32_t value) {
    bytes[0] = value >> 24; bytes[1] = value >> 16; bytes[2] = value >> 8; bytes[3] = value;
}
static CMAudioFormatDescriptionRef aac_description(AVCodecParameters *parameters) {
    // ISO BMFF mp4a sample entry, including the MPEG-4 DecoderSpecificInfo.
    int count = parameters->extradata_size;
    if (!parameters->extradata || count < 2 || count > 64 || parameters->sample_rate > 65535) return NULL;
    uint8_t entry[160] = {0};
    int length = 73 + count;
    store_be32(entry, length); memcpy(entry + 4, "mp4a", 4);
    entry[15] = 1;
    entry[24] = parameters->ch_layout.nb_channels >> 8; entry[25] = parameters->ch_layout.nb_channels;
    entry[27] = 16;
    store_be32(entry + 32, (uint32_t)parameters->sample_rate << 16);
    store_be32(entry + 36, 37 + count); memcpy(entry + 40, "esds", 4);
    int offset = 48;
    entry[offset++] = 3; entry[offset++] = 23 + count;
    entry[offset++] = 0; entry[offset++] = 1; entry[offset++] = 0;
    entry[offset++] = 4; entry[offset++] = 15 + count;
    entry[offset++] = 0x40; entry[offset++] = 0x15;
    offset += 11;
    entry[offset++] = 5; entry[offset++] = count;
    memcpy(entry + offset, parameters->extradata, count); offset += count;
    entry[offset++] = 6; entry[offset++] = 1; entry[offset++] = 2;
    if (offset != length) return NULL;
    CMAudioFormatDescriptionRef description = NULL;
    if (CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(NULL, entry, length,
        kCMSoundDescriptionFlavor_ISOFamily, &description) != noErr) return NULL;
    return description;
}
CMAudioFormatDescriptionRef vv_native_audio_format(AVCodecParameters *parameters) {
    AudioStreamBasicDescription input = {0};
    CMAudioFormatDescriptionRef prepared = NULL;
    switch (parameters->codec_id) {
        case AV_CODEC_ID_AAC:
            prepared = aac_description(parameters);
            if (!prepared) return NULL;
            input = *CMAudioFormatDescriptionGetStreamBasicDescription(prepared);
            break;
        case AV_CODEC_ID_AC3: input.mFormatID = kAudioFormatAC3; input.mFramesPerPacket = 1536; break;
        case AV_CODEC_ID_EAC3: input.mFormatID = kAudioFormatEnhancedAC3; input.mFramesPerPacket = parameters->frame_size; break;
        case AV_CODEC_ID_MP3: input.mFormatID = kAudioFormatMPEGLayer3; input.mFramesPerPacket = parameters->sample_rate > 24000 ? 1152 : 576; break;
        default: return NULL;
    }
    input.mSampleRate = parameters->sample_rate;
    input.mChannelsPerFrame = parameters->ch_layout.nb_channels;
    if (!input.mSampleRate || !input.mChannelsPerFrame) { if (prepared) CFRelease(prepared); return NULL; }
    UInt32 property_size = 0;
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, sizeof(input.mFormatID), &input.mFormatID, &property_size) != noErr || !property_size) { if (prepared) CFRelease(prepared); return NULL; }
    AudioStreamBasicDescription output = {0};
    output.mSampleRate = input.mSampleRate;
    output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    output.mChannelsPerFrame = input.mChannelsPerFrame;
    output.mFramesPerPacket = 1;
    output.mBitsPerChannel = 32;
    output.mBytesPerPacket = output.mBytesPerFrame = 4 * output.mChannelsPerFrame;
    AudioConverterRef probe = NULL;
    if (AudioConverterNew(&input, &output, &probe) != noErr) { if (prepared) CFRelease(prepared); return NULL; }
    if (prepared) {
        size_t size = 0;
        const void *cookie = CMAudioFormatDescriptionGetMagicCookie(prepared, &size);
        OSStatus status = cookie && size ? AudioConverterSetProperty(probe, kAudioConverterDecompressionMagicCookie, (UInt32)size, cookie) : noErr;
        AudioConverterDispose(probe);
        if (status != noErr) { CFRelease(prepared); return NULL; }
        return prepared;
    }
    AudioConverterDispose(probe);
    CMAudioFormatDescriptionRef description = NULL;
    if (CMAudioFormatDescriptionCreate(NULL, &input, 0, NULL, 0, NULL, NULL, &description) != noErr) return NULL;
    return description;
}
int vv_make_audio_packet(CMAudioFormatDescriptionRef format, AVPacket *packet, CMTime pts, CMTime duration, CMSampleBufferRef *sample) {
    *sample = NULL;
    if (!format || !packet || packet->size <= 0) return AVERROR(EINVAL);
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, NULL, packet->size, NULL, NULL, 0, packet->size, 0, &block);
    if (status != noErr) return status;
    status = CMBlockBufferReplaceDataBytes(packet->data, block, 0, packet->size);
    if (status == noErr) {
        CMSampleTimingInfo timing = {duration, pts, kCMTimeInvalid};
        size_t size = packet->size;
        status = CMSampleBufferCreateReady(NULL, block, format, 1, 1, &timing, 1, &size, sample);
    }
    CFRelease(block);
    return status;
}

CGImageRef vv_subtitle_image(AVSubtitleRect *rect) {
    if (!rect || rect->w <= 0 || rect->h <= 0 || rect->w > 8192 || rect->h > 4320 ||
        !rect->data[0] || !rect->data[1] || rect->linesize[0] < rect->w || rect->nb_colors > 256) return NULL;
    size_t size = (size_t)rect->w * rect->h * 4;
    uint8_t *pixels = av_malloc(size);
    if (!pixels) return NULL;
    const uint32_t *palette = (const uint32_t *)rect->data[1];
    for (int y = 0; y < rect->h; ++y) for (int x = 0; x < rect->w; ++x) {
        unsigned index = rect->data[0][y * rect->linesize[0] + x];
        uint32_t colour = index < rect->nb_colors ? palette[index] : 0;
        uint8_t *pixel = pixels + ((size_t)y * rect->w + x) * 4;
        pixel[0] = colour >> 16; pixel[1] = colour >> 8; pixel[2] = colour; pixel[3] = colour >> 24;
    }
    CFDataRef data = CFDataCreate(NULL, pixels, size);
    av_free(pixels);
    if (!data) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colour = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(rect->w, rect->h, 8, 32, rect->w * 4, colour,
        kCGBitmapByteOrder32Big | kCGImageAlphaLast, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colour); CGDataProviderRelease(provider); CFRelease(data);
    return image;
}

#include <libass/ass/ass.h>
struct VVASS { ASS_Library *library; ASS_Renderer *renderer; ASS_Track *track; };
static void quiet_ass(int level, const char *format, va_list args, void *opaque) {}
VVASS *vv_ass_create(const uint8_t *header, int size, int document) {
    if (!header || size <= 0 || size > 16 * 1024 * 1024) return NULL;
    VVASS *ass = av_mallocz(sizeof(VVASS));
    if (!ass) return NULL;
    ass->library = ass_library_init();
    if (!ass->library) goto fail;
    ass_set_message_cb(ass->library, quiet_ass, NULL);
    ass->renderer = ass_renderer_init(ass->library);
    if (!ass->renderer) goto fail;
    ass_set_cache_limits(ass->renderer, 512, 24);
    ass_set_fonts(ass->renderer, NULL, "Helvetica", ASS_FONTPROVIDER_CORETEXT, NULL, 1);
    if (document) ass->track = ass_read_memory(ass->library, (char *)header, size, NULL);
    else {
        ass->track = ass_new_track(ass->library);
        if (ass->track) ass_process_codec_private(ass->track, (char *)header, size);
    }
    if (!ass->track) goto fail;
    return ass;
fail:
    vv_ass_free(&ass); return NULL;
}
void vv_ass_free(VVASS **ass) {
    if (!ass || !*ass) return;
    if ((*ass)->track) ass_free_track((*ass)->track);
    if ((*ass)->renderer) ass_renderer_done((*ass)->renderer);
    if ((*ass)->library) ass_library_done((*ass)->library);
    av_freep(ass);
}
void vv_ass_chunk(VVASS *ass, const uint8_t *data, int size, double start, double duration) {
    if (ass && data && size > 0 && size <= 1024 * 1024 && isfinite(start) && isfinite(duration))
        ass_process_chunk(ass->track, (char *)data, size, (long long)(start * 1000), (long long)(duration * 1000));
}
void vv_ass_flush(VVASS *ass) { if (ass) ass_flush_events(ass->track); }
CGImageRef vv_ass_render(VVASS *ass, double seconds, int width, int height, int *changed) {
    if (!ass || !isfinite(seconds) || width < 1 || height < 1 || width > 3840 || height > 2160) return NULL;
    ass_set_frame_size(ass->renderer, width, height);
    ASS_Image *images = ass_render_frame(ass->renderer, ass->track, (long long)(seconds * 1000), changed);
    if (!images || !*changed) return NULL;
    size_t length = (size_t)width * height * 4;
    uint8_t *pixels = av_mallocz(length);
    if (!pixels) return NULL;
    for (ASS_Image *image = images; image; image = image->next) {
        unsigned red = image->color >> 24, green = (image->color >> 16) & 255, blue = (image->color >> 8) & 255;
        unsigned opacity = 255 - (image->color & 255);
        for (int y = 0; y < image->h; ++y) {
            int dy = image->dst_y + y; if (dy < 0 || dy >= height) continue;
            for (int x = 0; x < image->w; ++x) {
                int dx = image->dst_x + x; if (dx < 0 || dx >= width) continue;
                unsigned alpha = image->bitmap[y * image->stride + x] * opacity / 255;
                uint8_t *pixel = pixels + ((size_t)dy * width + dx) * 4;
                pixel[0] = red * alpha / 255 + pixel[0] * (255 - alpha) / 255;
                pixel[1] = green * alpha / 255 + pixel[1] * (255 - alpha) / 255;
                pixel[2] = blue * alpha / 255 + pixel[2] * (255 - alpha) / 255;
                pixel[3] = alpha + pixel[3] * (255 - alpha) / 255;
            }
        }
    }
    CFDataRef data = CFDataCreate(NULL, pixels, length); av_free(pixels);
    if (!data) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colour = CGColorSpaceCreateDeviceRGB();
    CGImageRef output = CGImageCreate(width, height, 8, 32, width * 4, colour,
        kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colour); CGDataProviderRelease(provider); CFRelease(data);
    return output;
}
