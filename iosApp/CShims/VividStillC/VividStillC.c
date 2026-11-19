#include "VividStillC.h"

#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/display.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

// Small, so one still pulls little more than its keyframe through the
// callbacks. Packets larger than this are read straight into place.
#define IO_BUFFER_BYTES (8 * 1024)
// How much of the file the first look at the streams may read.
#define PROBE_BYTES (1024 * 1024)
#define PROBE_MICROSECONDS (2 * 1000 * 1000)
// Largest coded picture a decoder is opened for: 8K with room to spare.
#define MAX_SOURCE_SIDE 8192
#define MIN_SOURCE_SIDE 8
#define MIN_OUTPUT_WIDTH 16
#define MAX_OUTPUT_SIDE 4096
// Index entries looked at, and keyframes kept. A long film at one keyframe
// a second has about ten thousand.
#define MAX_INDEX_SCAN 4000000
#define MAX_INDEX_KEPT 400000
// Packets read while looking for the keyframe after a seek.
#define MAX_PACKETS_TO_KEYFRAME 512
// Packets sent after the keyframe when it alone gave no picture, which
// happens when the two fields of an interlaced picture arrive separately.
#define FOLLOW_ON_PACKETS 4
#define MAX_RECEIVE_TRIES 16
// The most one call may read when the caller sets no limit of its own.
#define OPEN_BYTE_LIMIT (64LL * 1024 * 1024)
#define STILL_BYTE_LIMIT (32LL * 1024 * 1024)

typedef struct IndexPoint {
    int64_t timestamp;
    int64_t position;
    int size;
} IndexPoint;

struct VividStill {
    VividStillCallbacks callbacks;
    /// Where the next read starts. Seeking only moves this.
    int64_t offset;
    /// Bytes the current call may still read.
    int64_t allowance;
    AVIOContext *io;
    AVFormatContext *format;
    AVStream *stream;
    /// The stream's first timestamp in its own time base.
    int64_t start;
    double seconds_per_tick;
    const AVCodec *codec;
    AVCodecContext *decoder;
    struct SwsContext *scaler;
    AVPacket *packet;
    AVPacket *keyframe;
    AVFrame *frame;
    IndexPoint *index;
    int index_count;
    int index_covers_file;
    VividStillInfo info;
};

static int is_aborted(const VividStill *still) {
    return still->callbacks.aborted != NULL && still->callbacks.aborted(still->callbacks.context) != 0;
}

static int interrupt_callback(void *opaque) {
    return is_aborted((const VividStill *)opaque);
}

static int64_t known_size(const VividStill *still) {
    if (still->callbacks.size == NULL) return -1;
    return still->callbacks.size(still->callbacks.context);
}

static int io_read(void *opaque, uint8_t *buffer, int size) {
    VividStill *still = opaque;
    if (buffer == NULL || size <= 0 || still->offset < 0) return AVERROR(EINVAL);
    if (is_aborted(still)) return AVERROR_EXIT;
    // Out of allowance: fail the call instead of reading on without end.
    if (still->allowance <= 0) return AVERROR(EIO);
    if (size > still->allowance) size = (int)still->allowance;
    int count = still->callbacks.read(still->callbacks.context, buffer, size, still->offset);
    if (count < 0) return is_aborted(still) ? AVERROR_EXIT : AVERROR(EIO);
    if (count == 0) return AVERROR_EOF;
    // More than was asked for would mean the callback wrote past the buffer.
    if (count > size) return AVERROR(EIO);
    still->offset += count;
    still->allowance -= count;
    return count;
}

static int64_t io_seek(void *opaque, int64_t offset, int whence) {
    VividStill *still = opaque;
    whence &= ~AVSEEK_FORCE;
    if (whence == AVSEEK_SIZE) {
        int64_t size = known_size(still);
        return size >= 0 ? size : AVERROR(ENOSYS);
    }
    int64_t base;
    if (whence == SEEK_SET) {
        base = 0;
    } else if (whence == SEEK_CUR) {
        base = still->offset;
    } else if (whence == SEEK_END) {
        base = known_size(still);
        if (base < 0) return AVERROR(ENOSYS);
    } else {
        return AVERROR(EINVAL);
    }
    if (offset > 0 && base > INT64_MAX - offset) return AVERROR(EINVAL);
    if (offset < 0 && base < -offset) return AVERROR(EINVAL);
    still->offset = base + offset;
    return still->offset;
}

static int transfer_tag(enum AVColorTransferCharacteristic transfer) {
    switch (transfer) {
    case AVCOL_TRC_SMPTE2084: return VIVID_STILL_TRANSFER_PQ;
    case AVCOL_TRC_ARIB_STD_B67: return VIVID_STILL_TRANSFER_HLG;
    case AVCOL_TRC_UNSPECIFIED:
    case AVCOL_TRC_RESERVED0:
    case AVCOL_TRC_RESERVED: return VIVID_STILL_TRANSFER_UNKNOWN;
    default: return VIVID_STILL_TRANSFER_SDR;
    }
}

static int primaries_tag(enum AVColorPrimaries primaries) {
    switch (primaries) {
    case AVCOL_PRI_BT709: return VIVID_STILL_PRIMARIES_BT709;
    case AVCOL_PRI_BT470BG:
    case AVCOL_PRI_SMPTE170M:
    case AVCOL_PRI_SMPTE240M: return VIVID_STILL_PRIMARIES_BT601;
    case AVCOL_PRI_BT2020: return VIVID_STILL_PRIMARIES_BT2020;
    case AVCOL_PRI_SMPTE431:
    case AVCOL_PRI_SMPTE432: return VIVID_STILL_PRIMARIES_P3;
    default: return VIVID_STILL_PRIMARIES_UNKNOWN;
    }
}

static int matrix_tag(enum AVColorSpace matrix) {
    switch (matrix) {
    case AVCOL_SPC_BT709: return VIVID_STILL_MATRIX_BT709;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_SMPTE240M: return VIVID_STILL_MATRIX_BT601;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL: return VIVID_STILL_MATRIX_BT2020;
    case AVCOL_SPC_UNSPECIFIED:
    case AVCOL_SPC_RESERVED: return VIVID_STILL_MATRIX_UNKNOWN;
    default: return VIVID_STILL_MATRIX_OTHER;
    }
}

static int range_tag(enum AVColorRange range) {
    if (range == AVCOL_RANGE_MPEG) return VIVID_STILL_RANGE_LIMITED;
    if (range == AVCOL_RANGE_JPEG) return VIVID_STILL_RANGE_FULL;
    return VIVID_STILL_RANGE_UNKNOWN;
}

/// The decoders the engine package ships in software. Anything else is
/// refused instead of handed to whatever decoder happens to exist.
static const AVCodec *software_decoder(enum AVCodecID codec) {
    const AVCodec *found = NULL;
    switch (codec) {
    case AV_CODEC_ID_AV1:
        // FFmpeg's own AV1 decoder only works with a hardware device.
        found = avcodec_find_decoder_by_name("libdav1d");
        break;
    case AV_CODEC_ID_H264:
    case AV_CODEC_ID_HEVC:
    case AV_CODEC_ID_VP9:
    case AV_CODEC_ID_MPEG2VIDEO:
        found = avcodec_find_decoder(codec);
        break;
    default:
        break;
    }
    if (found == NULL || found->type != AVMEDIA_TYPE_VIDEO) return NULL;
    if (found->capabilities & (AV_CODEC_CAP_HARDWARE | AV_CODEC_CAP_EXPERIMENTAL)) return NULL;
    return found;
}

static int side_is_valid(int side) {
    return side >= MIN_SOURCE_SIDE && side <= MAX_SOURCE_SIDE;
}

static int compare_index_points(const void *left, const void *right) {
    const IndexPoint *a = left;
    const IndexPoint *b = right;
    if (a->timestamp != b->timestamp) return a->timestamp < b->timestamp ? -1 : 1;
    if (a->position != b->position) return a->position < b->position ? -1 : 1;
    return 0;
}

/// Copies the keyframes out of the container's index. MP4 lists every
/// sample, Matroska only its cue points.
static int collect_index(VividStill *still) {
    int total = avformat_index_get_entries_count(still->stream);
    if (total <= 0) return VIVID_STILL_OK;
    if (total > MAX_INDEX_SCAN) total = MAX_INDEX_SCAN;

    int keyframes = 0;
    for (int i = 0; i < total; i++) {
        const AVIndexEntry *entry = avformat_index_get_entry(still->stream, i);
        if (entry == NULL) break;
        if ((entry->flags & AVINDEX_KEYFRAME) && !(entry->flags & AVINDEX_DISCARD_FRAME)) keyframes++;
    }
    if (keyframes == 0) return VIVID_STILL_OK;
    if (keyframes > MAX_INDEX_KEPT) keyframes = MAX_INDEX_KEPT;

    IndexPoint *points = calloc((size_t)keyframes, sizeof(IndexPoint));
    if (points == NULL) return VIVID_STILL_ERROR_MEMORY;

    int kept = 0;
    int in_order = 1;
    for (int i = 0; i < total && kept < keyframes; i++) {
        const AVIndexEntry *entry = avformat_index_get_entry(still->stream, i);
        if (entry == NULL) break;
        if (!(entry->flags & AVINDEX_KEYFRAME) || (entry->flags & AVINDEX_DISCARD_FRAME)) continue;
        if (entry->timestamp == AV_NOPTS_VALUE || entry->pos < 0) continue;
        points[kept].timestamp = entry->timestamp;
        points[kept].position = entry->pos;
        points[kept].size = entry->size > 0 ? entry->size : 0;
        if (kept > 0 && points[kept].timestamp < points[kept - 1].timestamp) in_order = 0;
        kept++;
    }
    if (kept == 0) {
        free(points);
        return VIVID_STILL_OK;
    }
    if (!in_order) qsort(points, (size_t)kept, sizeof(IndexPoint), compare_index_points);

    still->index = points;
    still->index_count = kept;
    return VIVID_STILL_OK;
}

static double seconds_from_start(const VividStill *still, int64_t timestamp) {
    return (double)(timestamp - still->start) * still->seconds_per_tick;
}

static void fill_info(VividStill *still) {
    const AVCodecParameters *parameters = still->stream->codecpar;
    VividStillInfo *info = &still->info;
    memset(info, 0, sizeof(*info));

    int64_t duration = still->stream->duration;
    if (duration != AV_NOPTS_VALUE && duration > 0) {
        info->duration_seconds = (double)duration * still->seconds_per_tick;
    } else if (still->format->duration != AV_NOPTS_VALUE && still->format->duration > 0) {
        info->duration_seconds = (double)still->format->duration / (double)AV_TIME_BASE;
    }
    info->start_seconds = (double)still->start * still->seconds_per_tick;
    info->width = parameters->width;
    info->height = parameters->height;

    AVRational shape = av_guess_sample_aspect_ratio(still->format, still->stream, NULL);
    if (shape.num > 0 && shape.den > 0) {
        info->sample_aspect_numerator = shape.num;
        info->sample_aspect_denominator = shape.den;
    } else {
        info->sample_aspect_numerator = 1;
        info->sample_aspect_denominator = 1;
    }

    const AVPixFmtDescriptor *layout = av_pix_fmt_desc_get((enum AVPixelFormat)parameters->format);
    if (layout != NULL && layout->nb_components > 0) {
        info->bit_depth = layout->comp[0].depth;
    } else if (parameters->bits_per_raw_sample > 0 && parameters->bits_per_raw_sample <= 16) {
        info->bit_depth = parameters->bits_per_raw_sample;
    }

    info->transfer = transfer_tag(parameters->color_trc);
    info->primaries = primaries_tag(parameters->color_primaries);
    info->matrix = matrix_tag(parameters->color_space);
    info->range = range_tag(parameters->color_range);

    const AVPacketSideData *turn = av_packet_side_data_get(parameters->coded_side_data, parameters->nb_coded_side_data,
                                                           AV_PKT_DATA_DISPLAYMATRIX);
    if (turn != NULL && turn->data != NULL && turn->size >= 9 * sizeof(int32_t)) {
        int32_t matrix[9];
        memcpy(matrix, turn->data, sizeof(matrix));
        // The matrix gives the anticlockwise angle. Callers want clockwise,
        // in quarter turns.
        double anticlockwise = av_display_rotation_get(matrix);
        if (isfinite(anticlockwise)) {
            long quarters = lround(-anticlockwise / 90.0);
            info->rotation_degrees = (int)(((quarters % 4) + 4) % 4) * 90;
        }
    }

    const AVPacketSideData *dolby = av_packet_side_data_get(parameters->coded_side_data, parameters->nb_coded_side_data,
                                                            AV_PKT_DATA_DOVI_CONF);
    if (dolby != NULL && dolby->data != NULL && dolby->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
        AVDOVIDecoderConfigurationRecord record;
        memcpy(&record, dolby->data, sizeof(record));
        info->dolby_vision_profile = record.dv_profile;
        info->dolby_vision_compatibility = record.dv_bl_signal_compatibility_id;
    }

    info->index_count = still->index_count;
    info->has_index = still->index_covers_file;
}

int vivid_still_open(const VividStillCallbacks *callbacks, const char *name_hint, VividStill **out_handle) {
    if (out_handle == NULL) return VIVID_STILL_ERROR_ARGUMENT;
    *out_handle = NULL;
    if (callbacks == NULL || callbacks->read == NULL) return VIVID_STILL_ERROR_ARGUMENT;

    VividStill *still = calloc(1, sizeof(VividStill));
    if (still == NULL) return VIVID_STILL_ERROR_MEMORY;
    still->callbacks = *callbacks;
    still->allowance = OPEN_BYTE_LIMIT;

    int result = VIVID_STILL_ERROR_MEMORY;
    AVDictionary *options = NULL;

    still->packet = av_packet_alloc();
    still->keyframe = av_packet_alloc();
    still->frame = av_frame_alloc();
    if (still->packet == NULL || still->keyframe == NULL || still->frame == NULL) goto fail;

    uint8_t *buffer = av_malloc(IO_BUFFER_BYTES);
    if (buffer == NULL) goto fail;
    still->io = avio_alloc_context(buffer, IO_BUFFER_BYTES, 0, still, io_read, NULL, io_seek);
    if (still->io == NULL) {
        av_free(buffer);
        goto fail;
    }

    still->format = avformat_alloc_context();
    if (still->format == NULL) goto fail;
    still->format->pb = still->io;
    still->format->interrupt_callback.callback = interrupt_callback;
    still->format->interrupt_callback.opaque = still;
    still->format->probesize = PROBE_BYTES;
    still->format->max_analyze_duration = PROBE_MICROSECONDS;

    // Only the containers previews are made from. This also keeps out the
    // formats that would go and open other files or addresses themselves.
    if (av_dict_set(&options, "format_whitelist", "matroska,webm,mov,mp4,m4a,3gp,3g2,mj2,mpegts", 0) < 0) goto fail;

    // On failure this frees the context it was given and clears the pointer.
    int opened = avformat_open_input(&still->format, name_hint, NULL, &options);
    av_dict_free(&options);
    if (opened < 0) {
        result = is_aborted(still) ? VIVID_STILL_ERROR_ABORTED : VIVID_STILL_ERROR_OPEN;
        goto fail;
    }

    // Other streams stay readable for this pass, so it ends as soon as each
    // one is understood instead of running to the probe limit.
    if (avformat_find_stream_info(still->format, NULL) < 0) {
        result = is_aborted(still) ? VIVID_STILL_ERROR_ABORTED : VIVID_STILL_ERROR_OPEN;
        goto fail;
    }
    if (is_aborted(still)) {
        result = VIVID_STILL_ERROR_ABORTED;
        goto fail;
    }

    int chosen = av_find_best_stream(still->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (chosen < 0 || (unsigned)chosen >= still->format->nb_streams) {
        result = VIVID_STILL_ERROR_NO_VIDEO;
        goto fail;
    }
    still->stream = still->format->streams[chosen];
    if (still->stream->disposition & AV_DISPOSITION_ATTACHED_PIC) {
        // Cover art, not the film.
        result = VIVID_STILL_ERROR_NO_VIDEO;
        goto fail;
    }
    for (unsigned i = 0; i < still->format->nb_streams; i++) {
        if ((int)i != chosen) still->format->streams[i]->discard = AVDISCARD_ALL;
    }

    const AVCodecParameters *parameters = still->stream->codecpar;
    still->codec = software_decoder(parameters->codec_id);
    if (still->codec == NULL || !side_is_valid(parameters->width) || !side_is_valid(parameters->height)) {
        result = VIVID_STILL_ERROR_UNSUPPORTED;
        goto fail;
    }
    AVRational base = still->stream->time_base;
    if (base.num <= 0 || base.den <= 0) {
        result = VIVID_STILL_ERROR_UNSUPPORTED;
        goto fail;
    }
    still->seconds_per_tick = av_q2d(base);
    still->start = still->stream->start_time != AV_NOPTS_VALUE ? still->stream->start_time : 0;

    // Matroska leaves its cue table unread until the first seek. Seeking to
    // the start reads it, and puts every container at a known place.
    still->io->error = 0;
    still->io->eof_reached = 0;
    int sought = av_seek_frame(still->format, chosen, still->start, AVSEEK_FLAG_BACKWARD);
    if (is_aborted(still)) {
        result = VIVID_STILL_ERROR_ABORTED;
        goto fail;
    }
    if (sought >= 0) {
        result = collect_index(still);
        if (result != VIVID_STILL_OK) goto fail;
    }

    fill_info(still);
    if (still->index_count >= 2) {
        // A few entries picked up while probing aren't an index. It counts
        // when its last keyframe is within two of its own widest gaps of
        // the end of the file.
        int64_t widest = 0;
        for (int i = 1; i < still->index_count; i++) {
            int64_t gap = still->index[i].timestamp - still->index[i - 1].timestamp;
            if (gap > widest) widest = gap;
        }
        double last = seconds_from_start(still, still->index[still->index_count - 1].timestamp);
        double reach = last + 2.0 * (double)widest * still->seconds_per_tick;
        still->index_covers_file = still->info.duration_seconds <= 0 || reach >= still->info.duration_seconds;
    }
    still->info.has_index = still->index_covers_file;

    *out_handle = still;
    return VIVID_STILL_OK;

fail:
    av_dict_free(&options);
    vivid_still_close(still);
    return result;
}

void vivid_still_close_decoder(VividStill *handle) {
    if (handle == NULL) return;
    avcodec_free_context(&handle->decoder);
    sws_freeContext(handle->scaler);
    handle->scaler = NULL;
    if (handle->frame != NULL) av_frame_unref(handle->frame);
    if (handle->keyframe != NULL) av_packet_unref(handle->keyframe);
}

void vivid_still_close(VividStill *handle) {
    if (handle == NULL) return;
    vivid_still_close_decoder(handle);
    if (handle->format != NULL) avformat_close_input(&handle->format);
    if (handle->io != NULL) {
        // The demuxer may have swapped the buffer for a bigger one, so free
        // whichever one the context holds now.
        av_freep(&handle->io->buffer);
        avio_context_free(&handle->io);
    }
    av_packet_free(&handle->packet);
    av_packet_free(&handle->keyframe);
    av_frame_free(&handle->frame);
    free(handle->index);
    free(handle);
}

int vivid_still_get_info(const VividStill *handle, VividStillInfo *out_info) {
    if (handle == NULL || out_info == NULL) return VIVID_STILL_ERROR_ARGUMENT;
    *out_info = handle->info;
    return VIVID_STILL_OK;
}

const char *vivid_still_codec_name(const VividStill *handle) {
    if (handle == NULL || handle->codec == NULL) return "";
    return avcodec_get_name(handle->codec->id);
}

int vivid_still_index_count(const VividStill *handle) {
    return handle != NULL ? handle->index_count : 0;
}

int vivid_still_index_entry(const VividStill *handle, int position, VividStillIndexEntry *out_entry) {
    if (handle == NULL || out_entry == NULL) return VIVID_STILL_ERROR_ARGUMENT;
    if (position < 0 || position >= handle->index_count) return VIVID_STILL_ERROR_ARGUMENT;
    const IndexPoint *point = &handle->index[position];
    double seconds = seconds_from_start(handle, point->timestamp);
    out_entry->time_seconds = seconds > 0 ? seconds : 0;
    out_entry->byte_position = point->position;
    out_entry->size = point->size;
    return VIVID_STILL_OK;
}

static int open_decoder(VividStill *still) {
    if (still->decoder != NULL) return VIVID_STILL_OK;
    AVCodecContext *decoder = avcodec_alloc_context3(still->codec);
    if (decoder == NULL) return VIVID_STILL_ERROR_MEMORY;
    if (avcodec_parameters_to_context(decoder, still->stream->codecpar) < 0) {
        avcodec_free_context(&decoder);
        return VIVID_STILL_ERROR_DECODE;
    }
    // One thread and no hardware device: this must never compete with the
    // film's own decoder, and one thread also means no pictures are held
    // back waiting for others.
    decoder->thread_count = 1;
    decoder->thread_type = 0;
    decoder->flags |= AV_CODEC_FLAG_LOW_DELAY;
    decoder->pkt_timebase = still->stream->time_base;
    decoder->max_pixels = (int64_t)MAX_SOURCE_SIDE * MAX_SOURCE_SIDE;
    if (avcodec_open2(decoder, still->codec, NULL) < 0) {
        avcodec_free_context(&decoder);
        return VIVID_STILL_ERROR_DECODE;
    }
    still->decoder = decoder;
    return VIVID_STILL_OK;
}

/// Tells the decoder no more packets are coming, so it hands over the
/// picture it has instead of waiting for the frames that would follow.
/// Returns 1 with a picture in `still->frame`, 0 with none.
static int drain_one_picture(VividStill *still) {
    if (avcodec_send_packet(still->decoder, NULL) < 0) return 0;
    for (int attempt = 0; attempt < MAX_RECEIVE_TRIES; attempt++) {
        int received = avcodec_receive_frame(still->decoder, still->frame);
        if (received == 0) return 1;
        if (received != AVERROR(EAGAIN)) return 0;
    }
    return 0;
}

/// Reads on from the seek point to the first keyframe of the video stream
/// and leaves it in `still->keyframe`.
static int read_keyframe(VividStill *still) {
    av_packet_unref(still->keyframe);
    for (int count = 0; count < MAX_PACKETS_TO_KEYFRAME; count++) {
        int read = av_read_frame(still->format, still->packet);
        if (read < 0) return is_aborted(still) ? VIVID_STILL_ERROR_ABORTED : VIVID_STILL_ERROR_READ;
        int wanted = still->packet->stream_index == still->stream->index
            && (still->packet->flags & AV_PKT_FLAG_KEY)
            && !(still->packet->flags & (AV_PKT_FLAG_CORRUPT | AV_PKT_FLAG_DISCARD))
            && still->packet->size > 0;
        if (wanted) {
            av_packet_move_ref(still->keyframe, still->packet);
            return VIVID_STILL_OK;
        }
        av_packet_unref(still->packet);
    }
    return VIVID_STILL_ERROR_READ;
}

/// Decodes the keyframe on its own. `sent` counts the packets used.
static int decode_keyframe(VividStill *still, int *sent) {
    *sent = 0;
    av_frame_unref(still->frame);
    if (avcodec_send_packet(still->decoder, still->keyframe) < 0) {
        avcodec_flush_buffers(still->decoder);
        return VIVID_STILL_ERROR_DECODE;
    }
    *sent = 1;
    int have_picture = drain_one_picture(still);
    // Draining ends the stream as far as the decoder knows. Flushing makes
    // it ready for the next keyframe.
    avcodec_flush_buffers(still->decoder);
    if (have_picture) return VIVID_STILL_OK;

    // No picture from the keyframe alone. Try once more with the few
    // packets after it.
    av_frame_unref(still->frame);
    if (avcodec_send_packet(still->decoder, still->keyframe) < 0) {
        avcodec_flush_buffers(still->decoder);
        return VIVID_STILL_ERROR_DECODE;
    }
    int followed = 0;
    for (int count = 0; count < MAX_PACKETS_TO_KEYFRAME && followed < FOLLOW_ON_PACKETS; count++) {
        if (av_read_frame(still->format, still->packet) < 0) break;
        if (still->packet->stream_index == still->stream->index) {
            int accepted = avcodec_send_packet(still->decoder, still->packet);
            followed++;
            if (accepted >= 0) *sent += 1;
            if (accepted == AVERROR(EAGAIN)) {
                // It already has a picture waiting, which is all that's wanted.
                av_packet_unref(still->packet);
                break;
            }
        }
        av_packet_unref(still->packet);
    }
    have_picture = avcodec_receive_frame(still->decoder, still->frame) == 0;
    if (!have_picture) have_picture = drain_one_picture(still);
    avcodec_flush_buffers(still->decoder);
    if (have_picture) return VIVID_STILL_OK;
    return is_aborted(still) ? VIVID_STILL_ERROR_ABORTED : VIVID_STILL_ERROR_DECODE;
}

/// What range the scaled planes are in. The scaler knows nothing of the
/// frame's range tag: it passes values through untouched, except for the
/// old full-range pixel layouts, which it squeezes to limited range itself.
static int scaled_planes_are_full_range(const AVFrame *frame) {
    switch (frame->format) {
    case AV_PIX_FMT_YUVJ420P:
    case AV_PIX_FMT_YUVJ422P:
    case AV_PIX_FMT_YUVJ444P:
    case AV_PIX_FMT_YUVJ440P:
    case AV_PIX_FMT_YUVJ411P: return 0;
    default: return frame->color_range == AVCOL_RANGE_JPEG;
    }
}

/// The red and blue luma weights of the frame's matrix. Untagged video is
/// taken as BT.709 from 720 lines up and BT.601 below, as players do.
/// Returns 0 for matrices that aren't a plain luma and two colour
/// differences, such as ICtCp.
static int luma_weights(const AVFrame *frame, double *red, double *blue) {
    switch (frame->colorspace) {
    case AVCOL_SPC_BT709: *red = 0.2126; *blue = 0.0722; return 1;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M: *red = 0.299; *blue = 0.114; return 1;
    case AVCOL_SPC_SMPTE240M: *red = 0.212; *blue = 0.087; return 1;
    case AVCOL_SPC_FCC: *red = 0.30; *blue = 0.11; return 1;
    case AVCOL_SPC_BT2020_NCL: *red = 0.2627; *blue = 0.0593; return 1;
    case AVCOL_SPC_UNSPECIFIED:
    case AVCOL_SPC_RESERVED:
        if (frame->height >= 720) {
            *red = 0.2126; *blue = 0.0722;
        } else {
            *red = 0.299; *blue = 0.114;
        }
        return 1;
    default: return 0;
    }
}

static int even_at_least_two(int64_t value) {
    if (value > MAX_OUTPUT_SIDE) value = MAX_OUTPUT_SIDE;
    value -= value % 2;
    return value < 2 ? 2 : (int)value;
}

static float unit_clamp(float value) {
    return value < 0.0f ? 0.0f : (value > 1.0f ? 1.0f : value);
}

/// Turns small 16-bit luma and colour-difference planes into RGB with the
/// frame's own matrix and range. Done here, on the already small picture,
/// so the colours don't depend on which conversions a scaler build has.
static void planes_to_rgb(uint8_t *const planes[4], const int strides[4], int width, int height, int full_range,
                          double red_weight, double blue_weight, int layout, uint8_t *pixels, int stride) {
    double green_weight = 1.0 - red_weight - blue_weight;
    float red_from_cr = (float)(2.0 * (1.0 - red_weight));
    float blue_from_cb = (float)(2.0 * (1.0 - blue_weight));
    float green_from_cb = (float)(-blue_weight * 2.0 * (1.0 - blue_weight) / green_weight);
    float green_from_cr = (float)(-red_weight * 2.0 * (1.0 - red_weight) / green_weight);
    // Limited range in 16 bits: black at 16 * 256, white 219 * 256 above
    // it, and colour differences spanning 224 * 256.
    float luma_floor = full_range ? 0.0f : 4096.0f;
    float luma_scale = full_range ? 1.0f / 65535.0f : 1.0f / 56064.0f;
    float chroma_scale = full_range ? 1.0f / 65535.0f : 1.0f / 57344.0f;

    for (int row = 0; row < height; row++) {
        const uint16_t *luma = (const uint16_t *)(planes[0] + (ptrdiff_t)row * strides[0]);
        const uint16_t *cb_row = (const uint16_t *)(planes[1] + (ptrdiff_t)row * strides[1]);
        const uint16_t *cr_row = (const uint16_t *)(planes[2] + (ptrdiff_t)row * strides[2]);
        uint8_t *out = pixels + (size_t)row * (size_t)stride;
        for (int column = 0; column < width; column++) {
            float y = ((float)luma[column] - luma_floor) * luma_scale;
            float cb = ((float)cb_row[column] - 32768.0f) * chroma_scale;
            float cr = ((float)cr_row[column] - 32768.0f) * chroma_scale;
            float red = unit_clamp(y + red_from_cr * cr);
            float green = unit_clamp(y + green_from_cb * cb + green_from_cr * cr);
            float blue = unit_clamp(y + blue_from_cb * cb);
            if (layout == VIVID_STILL_LAYOUT_RGBA16) {
                uint16_t *wide = (uint16_t *)(out + (size_t)column * 8);
                wide[0] = (uint16_t)(red * 65535.0f + 0.5f);
                wide[1] = (uint16_t)(green * 65535.0f + 0.5f);
                wide[2] = (uint16_t)(blue * 65535.0f + 0.5f);
                wide[3] = 65535;
            } else {
                uint8_t *narrow = out + (size_t)column * 4;
                narrow[0] = (uint8_t)(blue * 255.0f + 0.5f);
                narrow[1] = (uint8_t)(green * 255.0f + 0.5f);
                narrow[2] = (uint8_t)(red * 255.0f + 0.5f);
                narrow[3] = 255;
            }
        }
    }
}

/// Shrinks `still->frame` and turns it into RGB. The scaler only resizes,
/// keeping luma and colour differences as they are, and the matrix is
/// applied to the small result.
static int scale_picture(VividStill *still, int max_width, int layout, VividStillPicture *picture) {
    const AVFrame *frame = still->frame;
    if (!side_is_valid(frame->width) || !side_is_valid(frame->height)) return VIVID_STILL_ERROR_UNSUPPORTED;
    if (frame->data[0] == NULL || !sws_isSupportedInput((enum AVPixelFormat)frame->format)) return VIVID_STILL_ERROR_UNSUPPORTED;
    const AVPixFmtDescriptor *source_layout = av_pix_fmt_desc_get((enum AVPixelFormat)frame->format);
    if (source_layout == NULL) return VIVID_STILL_ERROR_UNSUPPORTED;

    // A few streams are coded as RGB. Those need no matrix at all.
    int is_rgb = (source_layout->flags & AV_PIX_FMT_FLAG_RGB) != 0 || frame->colorspace == AVCOL_SPC_RGB;
    double red_weight = 0, blue_weight = 0;
    if (!is_rgb && !luma_weights(frame, &red_weight, &blue_weight)) return VIVID_STILL_ERROR_UNSUPPORTED;

    int transfer = transfer_tag(frame->color_trc);
    if (transfer == VIVID_STILL_TRANSFER_UNKNOWN) transfer = still->info.transfer;
    int primaries = primaries_tag(frame->color_primaries);
    if (primaries == VIVID_STILL_PRIMARIES_UNKNOWN) primaries = still->info.primaries;

    if (layout == VIVID_STILL_LAYOUT_AUTO) {
        int is_hdr = transfer == VIVID_STILL_TRANSFER_PQ || transfer == VIVID_STILL_TRANSFER_HLG;
        layout = is_hdr ? VIVID_STILL_LAYOUT_RGBA16 : VIVID_STILL_LAYOUT_BGRA8;
    }
    int bytes_per_pixel = layout == VIVID_STILL_LAYOUT_RGBA16 ? 8 : 4;
    enum AVPixelFormat scaled_format;
    if (!is_rgb) {
        scaled_format = AV_PIX_FMT_YUV444P16;
    } else {
        scaled_format = layout == VIVID_STILL_LAYOUT_RGBA16 ? AV_PIX_FMT_RGBA64 : AV_PIX_FMT_BGRA;
    }

    // Width as it's shown, once stretched pixels are made square.
    AVRational shape = av_guess_sample_aspect_ratio(still->format, still->stream, still->frame);
    int64_t shown_width = frame->width;
    if (shape.num > 0 && shape.den > 0 && (int64_t)shape.num <= (int64_t)shape.den * 8 && (int64_t)shape.den <= (int64_t)shape.num * 8) {
        shown_width = av_rescale(frame->width, shape.num, shape.den);
    }
    if (shown_width < 2) shown_width = 2;

    if (max_width < MIN_OUTPUT_WIDTH) max_width = MIN_OUTPUT_WIDTH;
    if (max_width > MAX_OUTPUT_SIDE) max_width = MAX_OUTPUT_SIDE;
    int width = even_at_least_two(shown_width < max_width ? shown_width : max_width);
    int height = even_at_least_two(av_rescale(width, frame->height, shown_width));

    still->scaler = sws_getCachedContext(still->scaler, frame->width, frame->height, (enum AVPixelFormat)frame->format,
                                         width, height, scaled_format, SWS_BILINEAR, NULL, NULL, NULL);
    if (still->scaler == NULL) return VIVID_STILL_ERROR_SCALE;

    // The scaler writes into padded, aligned rows of its own kind. The
    // caller gets a tightly packed copy.
    uint8_t *planes[4] = { NULL, NULL, NULL, NULL };
    int strides[4] = { 0, 0, 0, 0 };
    if (av_image_alloc(planes, strides, width, height, scaled_format, 64) < 0) return VIVID_STILL_ERROR_MEMORY;

    // Both sides are at most MAX_OUTPUT_SIDE, so this can't overflow.
    int stride = width * bytes_per_pixel;
    uint8_t *pixels = malloc((size_t)stride * (size_t)height);
    if (pixels == NULL) {
        av_freep(&planes[0]);
        return VIVID_STILL_ERROR_MEMORY;
    }

    int rows = sws_scale(still->scaler, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
    if (rows != height) {
        av_freep(&planes[0]);
        free(pixels);
        return VIVID_STILL_ERROR_SCALE;
    }
    if (is_rgb) {
        for (int row = 0; row < height; row++) {
            memcpy(pixels + (size_t)row * (size_t)stride, planes[0] + (ptrdiff_t)row * strides[0], (size_t)stride);
        }
    } else {
        planes_to_rgb(planes, strides, width, height, scaled_planes_are_full_range(frame), red_weight, blue_weight,
                      layout, pixels, stride);
    }
    av_freep(&planes[0]);

    picture->pixels = pixels;
    picture->width = width;
    picture->height = height;
    picture->stride = stride;
    picture->layout = layout;
    picture->transfer = transfer;
    picture->primaries = primaries;
    return VIVID_STILL_OK;
}

int vivid_still_decode(VividStill *handle, double seconds, int max_width, int layout, int64_t max_read_bytes,
                       VividStillPicture *out_picture) {
    if (out_picture == NULL) return VIVID_STILL_ERROR_ARGUMENT;
    memset(out_picture, 0, sizeof(*out_picture));
    if (handle == NULL || !isfinite(seconds)) return VIVID_STILL_ERROR_ARGUMENT;
    if (layout != VIVID_STILL_LAYOUT_AUTO && layout != VIVID_STILL_LAYOUT_BGRA8 && layout != VIVID_STILL_LAYOUT_RGBA16) {
        return VIVID_STILL_ERROR_ARGUMENT;
    }
    if (is_aborted(handle)) return VIVID_STILL_ERROR_ABORTED;
    handle->allowance = max_read_bytes > 0 && max_read_bytes < STILL_BYTE_LIMIT ? max_read_bytes : STILL_BYTE_LIMIT;

    int result = open_decoder(handle);
    if (result != VIVID_STILL_OK) return result;

    if (seconds < 0) seconds = 0;
    if (handle->info.duration_seconds > 0 && seconds > handle->info.duration_seconds) seconds = handle->info.duration_seconds;
    double ticks = seconds / handle->seconds_per_tick;
    if (!(ticks < 9.0e15)) return VIVID_STILL_ERROR_ARGUMENT;
    int64_t target = handle->start + llround(ticks);

    // An aborted or failed read leaves the reader flagged. Clear that, and
    // let the seek throw away whatever was half read.
    handle->io->error = 0;
    handle->io->eof_reached = 0;
    if (av_seek_frame(handle->format, handle->stream->index, target, AVSEEK_FLAG_BACKWARD) < 0) {
        return is_aborted(handle) ? VIVID_STILL_ERROR_ABORTED : VIVID_STILL_ERROR_SEEK;
    }

    result = read_keyframe(handle);
    if (result != VIVID_STILL_OK) return result;
    int packet_bytes = handle->keyframe->size;
    int64_t packet_time = handle->keyframe->pts != AV_NOPTS_VALUE ? handle->keyframe->pts : handle->keyframe->dts;

    int sent = 0;
    result = decode_keyframe(handle, &sent);
    av_packet_unref(handle->keyframe);
    if (result == VIVID_STILL_OK) result = scale_picture(handle, max_width, layout, out_picture);
    if (result == VIVID_STILL_OK) {
        int64_t shown = handle->frame->best_effort_timestamp;
        if (shown == AV_NOPTS_VALUE) shown = handle->frame->pts;
        if (shown == AV_NOPTS_VALUE) shown = packet_time;
        if (shown == AV_NOPTS_VALUE) shown = target;
        out_picture->time_seconds = seconds_from_start(handle, shown);
        out_picture->packet_bytes = packet_bytes;
        out_picture->packets_decoded = sent;
    }
    av_frame_unref(handle->frame);
    return result;
}

void vivid_still_picture_free(VividStillPicture *picture) {
    if (picture == NULL) return;
    free(picture->pixels);
    memset(picture, 0, sizeof(*picture));
}
