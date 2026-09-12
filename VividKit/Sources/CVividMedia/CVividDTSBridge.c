// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#include "CVividMedia.h"
#include <AetherLibavutil/audio_fifo.h>
#include <AetherLibswresample/swresample.h>
#include <math.h>

struct VVDTSBridge {
    AVFormatContext *input, *output;
    AVCodecContext *decoder, *encoder;
    SwrContext *resampler;
    AVAudioFifo *fifo;
    AVFrame *decoded, *converted;
    AVPacket *encoded;
    AVChannelLayout input_layout;
    int input_rate, input_format;
    int audio_index, video_index, header_written;
    int64_t next_sample;
    double origin;
};

void vv_dts_bridge_free(VVDTSBridge **value) {
    if (!value || !*value) return;
    VVDTSBridge *bridge = *value;
    if (bridge->output) {
        if (bridge->header_written) av_write_trailer(bridge->output);
        avformat_free_context(bridge->output);
    }
    avcodec_free_context(&bridge->decoder);
    avcodec_free_context(&bridge->encoder);
    swr_free(&bridge->resampler);
    av_channel_layout_uninit(&bridge->input_layout);
    if (bridge->fifo) av_audio_fifo_free(bridge->fifo);
    av_frame_free(&bridge->decoded);
    av_frame_free(&bridge->converted);
    av_packet_free(&bridge->encoded);
    av_freep(value);
}

static int write_encoded(VVDTSBridge *bridge) {
    int result;
    while ((result = avcodec_receive_packet(bridge->encoder, bridge->encoded)) >= 0) {
        av_packet_rescale_ts(bridge->encoded, bridge->encoder->time_base, bridge->output->streams[1]->time_base);
        bridge->encoded->stream_index = 1;
        result = av_interleaved_write_frame(bridge->output, bridge->encoded);
        av_packet_unref(bridge->encoded);
        if (result < 0) return result;
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static int encode_fifo(VVDTSBridge *bridge, int flush) {
    int frame_size = bridge->encoder->frame_size;
    if (frame_size <= 0) return AVERROR_INVALIDDATA;
    while (av_audio_fifo_size(bridge->fifo) >= frame_size || (flush && av_audio_fifo_size(bridge->fifo) > 0)) {
        AVFrame *frame = av_frame_alloc();
        if (!frame) return AVERROR(ENOMEM);
        frame->format = bridge->encoder->sample_fmt;
        frame->sample_rate = bridge->encoder->sample_rate;
        int available = FFMIN(frame_size, av_audio_fifo_size(bridge->fifo));
        frame->nb_samples = bridge->encoder->codec_id == AV_CODEC_ID_EAC3 ? frame_size : available;
        int result = av_channel_layout_copy(&frame->ch_layout, &bridge->encoder->ch_layout);
        if (result >= 0) result = av_frame_get_buffer(frame, 0);
        if (result >= 0) {
            av_samples_set_silence(frame->extended_data, 0, frame->nb_samples,
                frame->ch_layout.nb_channels, frame->format);
            result = av_audio_fifo_read(bridge->fifo, (void **)frame->extended_data, available);
            if (result != available) result = AVERROR_INVALIDDATA;
            else {
                frame->pts = bridge->next_sample;
                bridge->next_sample += frame->nb_samples;
                result = avcodec_send_frame(bridge->encoder, frame);
            }
        }
        av_frame_free(&frame);
        if (result < 0) return result;
        if ((result = write_encoded(bridge)) < 0) return result;
    }
    return 0;
}

static int store_converted(VVDTSBridge *bridge, int count, int skip) {
    AVFrame *output = bridge->converted;
    if (count <= skip) return 0;
    int planar = av_sample_fmt_is_planar(output->format);
    int stride = av_get_bytes_per_sample(output->format) * (planar ? 1 : output->ch_layout.nb_channels);
    void *planes[8] = {0};
    for (int i = 0; i < (planar ? output->ch_layout.nb_channels : 1); i++)
        planes[i] = output->extended_data[i] + skip * stride;
    int result = av_audio_fifo_write(bridge->fifo, planes, count - skip);
    return result == count - skip ? encode_fifo(bridge, 0) : (result < 0 ? result : AVERROR(ENOMEM));
}

static int allocate_converted(VVDTSBridge *bridge, int capacity) {
    AVFrame *output = bridge->converted;
    av_frame_unref(output);
    output->format = bridge->encoder->sample_fmt;
    output->sample_rate = bridge->encoder->sample_rate;
    output->nb_samples = FFMAX(1, capacity);
    int result = av_channel_layout_copy(&output->ch_layout, &bridge->encoder->ch_layout);
    return result < 0 ? result : av_frame_get_buffer(output, 0);
}

static int drain_resampler(VVDTSBridge *bridge) {
    if (!bridge->resampler) return 0;
    int result;
    do {
        result = allocate_converted(bridge, swr_get_out_samples(bridge->resampler, 0));
        if (result < 0) return result;
        result = swr_convert(bridge->resampler, bridge->converted->extended_data,
            bridge->converted->nb_samples, NULL, 0);
        if (result < 0) return result;
        int stored = store_converted(bridge, result, 0);
        if (stored < 0) return stored;
    } while (result > 0);
    return 0;
}

static int decode_audio(VVDTSBridge *bridge) {
    int result;
    while ((result = avcodec_receive_frame(bridge->decoder, bridge->decoded)) >= 0) {
        AVFrame *input = bridge->decoded;
        if (input->sample_rate <= 0 || input->ch_layout.nb_channels < 1 || input->ch_layout.nb_channels > 8)
            return AVERROR_INVALIDDATA;
        if (!bridge->resampler || input->sample_rate != bridge->input_rate || input->format != bridge->input_format ||
            av_channel_layout_compare(&input->ch_layout, &bridge->input_layout)) {
            if ((result = drain_resampler(bridge)) < 0) return result;
            swr_free(&bridge->resampler);
            av_channel_layout_uninit(&bridge->input_layout);
            if ((result = av_channel_layout_copy(&bridge->input_layout, &input->ch_layout)) < 0) return result;
            bridge->input_rate = input->sample_rate; bridge->input_format = input->format;
            result = swr_alloc_set_opts2(&bridge->resampler, &bridge->encoder->ch_layout,
                bridge->encoder->sample_fmt, bridge->encoder->sample_rate,
                &input->ch_layout, input->format, input->sample_rate, 0, NULL);
            if (result < 0 || (result = swr_init(bridge->resampler)) < 0) return result;
        }
        AVFrame *output = bridge->converted;
        if ((result = allocate_converted(bridge, swr_get_out_samples(bridge->resampler, input->nb_samples))) < 0) return result;
        int count = swr_convert(bridge->resampler, output->extended_data, output->nb_samples,
            (const uint8_t **)input->extended_data, input->nb_samples);
        if (count < 0) return count;
        double seconds = input->best_effort_timestamp == AV_NOPTS_VALUE ? NAN :
            input->best_effort_timestamp * av_q2d(bridge->input->streams[bridge->audio_index]->time_base) - bridge->origin;
        int skip = isfinite(seconds) && seconds < 0 ? (int)FFMIN(count, ceil(-seconds * output->sample_rate)) : 0;
        if (skip < count) {
            if (bridge->next_sample == AV_NOPTS_VALUE) {
                bridge->next_sample = isfinite(seconds) ? llround(fmax(0, seconds) * output->sample_rate) : 0;
            }
            if ((result = store_converted(bridge, count, skip)) < 0) return result;
        }
        av_frame_unref(input);
    }
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

VVDTSBridge *vv_dts_bridge_create(AVFormatContext *input, int video_index, int audio_index,
    double origin, int lossless, const char *playlist, const char *segments, int *error) {
    *error = AVERROR_INVALIDDATA;
    if (!input || video_index < 0 || audio_index < 0 || video_index >= input->nb_streams || audio_index >= input->nb_streams) return NULL;
    AVCodecParameters *audio = input->streams[audio_index]->codecpar;
    AVCodecParameters *video = input->streams[video_index]->codecpar;
    if (audio->codec_id != AV_CODEC_ID_DTS || audio->sample_rate <= 0 ||
        audio->ch_layout.nb_channels < 1 || audio->ch_layout.nb_channels > 8 ||
        (video->codec_id != AV_CODEC_ID_H264 && video->codec_id != AV_CODEC_ID_HEVC)) return NULL;
    VVDTSBridge *bridge = av_mallocz(sizeof(*bridge));
    if (!bridge) { *error = AVERROR(ENOMEM); return NULL; }
    bridge->input = input; bridge->audio_index = audio_index; bridge->video_index = video_index;
    bridge->origin = origin; bridge->next_sample = AV_NOPTS_VALUE;
    bridge->decoder = vv_create_decoder(input->streams[audio_index], 0, error);
    enum AVCodecID output_codec = !lossless && audio->ch_layout.nb_channels > 2 ? AV_CODEC_ID_EAC3 : AV_CODEC_ID_FLAC;
    const AVCodec *encoder = avcodec_find_encoder(output_codec);
    if (!bridge->decoder) goto failed;
    if (!encoder) { *error = AVERROR_ENCODER_NOT_FOUND; goto failed; }
    bridge->encoder = avcodec_alloc_context3(encoder);
    if (!bridge->encoder) { *error = AVERROR(ENOMEM); goto failed; }
    bridge->encoder->sample_rate = output_codec == AV_CODEC_ID_EAC3 ? 48000 : audio->sample_rate;
    bridge->encoder->sample_fmt = output_codec == AV_CODEC_ID_EAC3 ? AV_SAMPLE_FMT_FLTP : AV_SAMPLE_FMT_S32;
    bridge->encoder->bits_per_raw_sample = output_codec == AV_CODEC_ID_FLAC ? 24 : 0;
    bridge->encoder->time_base = (AVRational){1, bridge->encoder->sample_rate};
    bridge->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    bridge->encoder->compression_level = 0;
    if (output_codec == AV_CODEC_ID_EAC3) {
        int channels = FFMIN(6, audio->ch_layout.nb_channels);
        if (channels == 6) bridge->encoder->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1;
        else av_channel_layout_default(&bridge->encoder->ch_layout, channels);
        bridge->encoder->bit_rate = channels * 128000;
    } else if ((*error = av_channel_layout_copy(&bridge->encoder->ch_layout, &audio->ch_layout)) < 0) goto failed;
    if ((*error = avcodec_open2(bridge->encoder, encoder, NULL)) < 0) goto failed;
    bridge->fifo = av_audio_fifo_alloc(bridge->encoder->sample_fmt, bridge->encoder->ch_layout.nb_channels, bridge->encoder->frame_size * 2);
    bridge->decoded = av_frame_alloc(); bridge->converted = av_frame_alloc(); bridge->encoded = av_packet_alloc();
    if (!bridge->fifo || !bridge->decoded || !bridge->converted || !bridge->encoded) { *error = AVERROR(ENOMEM); goto failed; }
    if ((*error = avformat_alloc_output_context2(&bridge->output, NULL, "hls", playlist)) < 0) goto failed;
    AVStream *out_video = avformat_new_stream(bridge->output, NULL);
    AVStream *out_audio = avformat_new_stream(bridge->output, NULL);
    if (!out_video || !out_audio) { *error = AVERROR(ENOMEM); goto failed; }
    if ((*error = avcodec_parameters_copy(out_video->codecpar, video)) < 0 ||
        (*error = avcodec_parameters_from_context(out_audio->codecpar, bridge->encoder)) < 0) goto failed;
    out_video->codecpar->codec_tag = video->codec_id == AV_CODEC_ID_HEVC ? MKTAG('h','v','c','1') : MKTAG('a','v','c','1');
    out_audio->codecpar->codec_tag = 0;
    out_video->time_base = input->streams[video_index]->time_base;
    out_video->avg_frame_rate = input->streams[video_index]->avg_frame_rate;
    out_audio->time_base = bridge->encoder->time_base;
    bridge->output->strict_std_compliance = FF_COMPLIANCE_EXPERIMENTAL;
    AVDictionary *options = NULL;
    av_dict_set(&options, "hls_segment_type", "fmp4", 0);
    av_dict_set(&options, "hls_time", "2", 0);
    av_dict_set(&options, "hls_list_size", "12", 0);
    av_dict_set(&options, "hls_flags", "independent_segments+temp_file+delete_segments", 0);
    av_dict_set(&options, "hls_segment_filename", segments, 0);
    av_dict_set(&options, "hls_segment_options", "strict=-2", 0);
    *error = avformat_write_header(bridge->output, &options);
    av_dict_free(&options);
    if (*error < 0) goto failed;
    bridge->header_written = 1;
    return bridge;
failed:
    vv_dts_bridge_free(&bridge);
    return NULL;
}

int vv_dts_bridge_write(VVDTSBridge *bridge, AVPacket *packet) {
    if (!bridge || !packet) return AVERROR(EINVAL);
    if (packet->stream_index == bridge->audio_index) {
        int result = avcodec_send_packet(bridge->decoder, packet);
        if (result == AVERROR(EAGAIN)) {
            result = decode_audio(bridge);
            if (result < 0) return result;
            result = avcodec_send_packet(bridge->decoder, packet);
        }
        return result < 0 ? result : decode_audio(bridge);
    }
    if (packet->stream_index != bridge->video_index) return 0;
    AVPacket *copy = av_packet_clone(packet);
    if (!copy) return AVERROR(ENOMEM);
    AVStream *source = bridge->input->streams[bridge->video_index];
    int64_t offset = llround(bridge->origin / av_q2d(source->time_base));
    if (copy->pts != AV_NOPTS_VALUE) copy->pts -= offset;
    if (copy->dts != AV_NOPTS_VALUE) copy->dts -= offset;
    av_packet_rescale_ts(copy, source->time_base, bridge->output->streams[0]->time_base);
    copy->stream_index = 0; copy->pos = -1;
    int result = av_interleaved_write_frame(bridge->output, copy);
    av_packet_free(&copy);
    return result;
}

int vv_dts_bridge_finish(VVDTSBridge *bridge) {
    int result = avcodec_send_packet(bridge->decoder, NULL);
    if (result >= 0) result = decode_audio(bridge);
    if (result >= 0) result = drain_resampler(bridge);
    if (result >= 0) result = encode_fifo(bridge, 1);
    if (result >= 0) result = avcodec_send_frame(bridge->encoder, NULL);
    if (result >= 0) result = write_encoded(bridge);
    if (result >= 0) result = av_write_trailer(bridge->output);
    bridge->header_written = 0;
    return result;
}
