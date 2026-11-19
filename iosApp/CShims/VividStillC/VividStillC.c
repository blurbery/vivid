#include "VividStillC.h"

#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/display.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

// Small, so one still pulls little more than its keyframe through the
// callbacks. Packets larger than this are read straight into place.
#define IO_BUFFER_BYTES (8 * 1024)
// How much of the start of the file is looked at to tell what it is.
#define RECOGNISE_BYTES 12
// The containers previews are made from, by the demuxers' own names.
#define MATROSKA_FORMAT "matroska,webm"
#define MP4_FORMAT "mov,mp4,m4a,3gp,3g2,mj2"
#define ALLOWED_FORMATS MATROSKA_FORMAT "," MP4_FORMAT
// The software decoders stills are made with. `software_decoder` below
// picks from the same set.
#define ALLOWED_DECODERS "h264,hevc,vp9,mpeg2video,libdav1d"
// Largest picture a decoder is made for: 8K by area, with long thin
// shapes bounded too.
#define MAX_PICTURE_PIXELS (7680LL * 4320LL)
#define MAX_SOURCE_SIDE 16384
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
// The most one call may read, whatever the caller asks for.
#define OPEN_BYTE_LIMIT (64LL * 1024 * 1024)
#define STILL_BYTE_LIMIT (32LL * 1024 * 1024)
// The demuxer's reader crosses a short gap forwards by reading through it
// instead of seeking. When the keyframe sits this close after the last
// read, the gap is fetched with it.
#define READ_THROUGH_BYTES (32 * 1024)
// A lone keyframe counts as an index when the film ends within this long
// of it: about two of the longest usual gaps between keyframes.
#define LONE_KEYFRAME_REACH_SECONDS 20.0
// The decoder's messages are moved this far down the scale of importance,
// below anything a listener set to warnings would pick up.
#define DECODER_LOG_LEVEL_OFFSET 100

typedef struct IndexPoint {
    /// The container's own time for the entry: decode time in MP4, shown
    /// time in Matroska.
    int64_t timestamp;
    /// When the keyframe is shown, as near as the index can say.
    int64_t shown;
    int64_t position;
    int size;
} IndexPoint;

struct VividStill {
    VividStillCallbacks callbacks;
    /// Where the next read starts. Seeking only moves this.
    int64_t offset;
    /// Bytes the current call may still read.
    int64_t allowance;
    /// Why the current call's reading stopped, if it did.
    int read_failed;
    int over_allowance;
    /// Bytes fetched ahead of the demuxer, which then reads them from here.
    uint8_t *held;
    int64_t held_start;
    int64_t held_length;
    int64_t max_pixels;
    AVIOContext *io;
    AVFormatContext *format;
    AVStream *stream;
    int is_matroska;
    /// The first video packet's time in the stream's time base.
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

static int64_t saturating_add(int64_t left, int64_t right) {
    if (right > 0 && left > INT64_MAX - right) return INT64_MAX;
    if (right < 0 && left < INT64_MIN - right) return INT64_MIN;
    return left + right;
}

/// Starts a call: a fresh byte allowance and nothing yet gone wrong.
static void begin_call(VividStill *still, int64_t allowance) {
    still->allowance = allowance;
    still->read_failed = 0;
    still->over_allowance = 0;
    still->held_length = 0;
}

/// Why reading stopped, as a result. `otherwise` is for when nothing was
/// flagged, which means the file itself gave out.
static int stop_reason(const VividStill *still, int over_limit, int otherwise) {
    if (is_aborted(still)) return VIVID_STILL_ERROR_ABORTED;
    if (still->over_allowance) return over_limit;
    if (still->read_failed) return VIVID_STILL_ERROR_READ;
    return otherwise;
}

/// One read through the caller's callback. Returns the bytes copied, 0 at
/// the end of the file, or -1 with the reason left for `stop_reason`.
static int source_read(VividStill *still, uint8_t *buffer, int size, int64_t offset) {
    if (is_aborted(still)) return -1;
    // Out of allowance: stop the call instead of reading on without end.
    if (still->allowance <= 0) {
        still->over_allowance = 1;
        return -1;
    }
    if (size > still->allowance) size = (int)still->allowance;
    int count = still->callbacks.read(still->callbacks.context, buffer, size, offset);
    // More than was asked for would mean the callback wrote past the buffer.
    if (count < 0 || count > size) {
        if (!is_aborted(still)) still->read_failed = 1;
        return -1;
    }
    still->allowance -= count;
    return count;
}

/// Reads until `size` bytes are in or the file ends. Returns the bytes
/// read, or -1 as `source_read` does.
static int64_t source_read_fully(VividStill *still, uint8_t *buffer, int64_t size, int64_t offset) {
    int64_t filled = 0;
    while (filled < size) {
        int64_t wanted = size - filled;
        int step = wanted > (1 << 20) ? (1 << 20) : (int)wanted;
        if (offset > INT64_MAX - filled) return -1;
        int count = source_read(still, buffer + filled, step, offset + filled);
        if (count < 0) return -1;
        if (count == 0) break;
        filled += count;
    }
    return filled;
}

static int io_read(void *opaque, uint8_t *buffer, int size) {
    VividStill *still = opaque;
    if (buffer == NULL || size <= 0 || still->offset < 0) return AVERROR(EINVAL);
    // A seek may have put the offset anywhere a file says. Reading from
    // there must not carry it past what an offset can hold.
    if (still->offset > INT64_MAX - size) return AVERROR(EINVAL);
    // Bytes already fetched are handed over even after a cancel, so the
    // demuxer finishes what it is doing without an error of its own.
    if (still->held_length > 0 && still->offset >= still->held_start
        && still->offset - still->held_start < still->held_length) {
        int64_t skip = still->offset - still->held_start;
        int64_t available = still->held_length - skip;
        int count = size < available ? size : (int)available;
        memcpy(buffer, still->held + skip, (size_t)count);
        still->offset += count;
        return count;
    }
    int count = source_read(still, buffer, size, still->offset);
    if (count < 0) return is_aborted(still) ? AVERROR_EXIT : AVERROR(EIO);
    if (count == 0) return AVERROR_EOF;
    still->offset += count;
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
    if (base < 0) return AVERROR(EINVAL);
    if (offset > 0 && base > INT64_MAX - offset) return AVERROR(EINVAL);
    // `base` is not negative, so this sum can't overflow for a negative
    // offset, however large.
    if (offset < 0 && base + offset < 0) return AVERROR(EINVAL);
    still->offset = base + offset;
    return still->offset;
}

/// Given to the demuxer in place of its own way of opening things, so a
/// file can never make it open another file or an address.
static int refuse_to_open(AVFormatContext *format, AVIOContext **io, const char *url, int flags, AVDictionary **options) {
    (void)format;
    (void)url;
    (void)flags;
    (void)options;
    if (io != NULL) *io = NULL;
    return AVERROR(EACCES);
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
    if (found == NULL || found->type != AVMEDIA_TYPE_VIDEO || found->name == NULL) return NULL;
    if (found->capabilities & (AV_CODEC_CAP_HARDWARE | AV_CODEC_CAP_EXPERIMENTAL)) return NULL;
    // The same list the demuxer and the decoder are given, so the three
    // can't drift apart.
    if (av_match_list(found->name, ALLOWED_DECODERS, ',') <= 0) return NULL;
    return found;
}

/// Whether a picture of this size may be decoded: `VIVID_STILL_OK`, or why
/// not.
static int picture_size_result(const VividStill *still, int width, int height) {
    if (width < MIN_SOURCE_SIDE || height < MIN_SOURCE_SIDE) return VIVID_STILL_ERROR_UNSUPPORTED;
    if (width > MAX_SOURCE_SIDE || height > MAX_SOURCE_SIDE) return VIVID_STILL_ERROR_TOO_LARGE;
    if ((int64_t)width * (int64_t)height > still->max_pixels) return VIVID_STILL_ERROR_TOO_LARGE;
    return VIVID_STILL_OK;
}

/// Looks at the first bytes of the file and says which demuxer reads it:
/// Matroska by its opening mark, MP4 by the name of its first box. Told
/// apart here, by hand, so no demuxer of any kind is shown a file that
/// isn't one of the two, and nothing is written to the log along the way.
static int recognise(VividStill *still, const AVInputFormat **out_kind) {
    uint8_t start[RECOGNISE_BYTES];
    memset(start, 0, sizeof(start));
    int64_t filled = source_read_fully(still, start, RECOGNISE_BYTES, 0);
    if (filled < 0) return stop_reason(still, VIVID_STILL_ERROR_OPEN_TOO_COSTLY, VIVID_STILL_ERROR_READ);
    if (filled < RECOGNISE_BYTES) return VIVID_STILL_ERROR_OPEN;

    static const uint8_t matroska_mark[4] = { 0x1A, 0x45, 0xDF, 0xA3 };
    static const char first_boxes[][5] = { "ftyp", "moov", "mdat", "free", "skip", "wide" };
    const char *name = NULL;
    if (memcmp(start, matroska_mark, sizeof(matroska_mark)) == 0) {
        still->is_matroska = 1;
        name = "matroska";
    } else {
        for (size_t i = 0; i < sizeof(first_boxes) / sizeof(first_boxes[0]); i++) {
            if (memcmp(start + 4, first_boxes[i], 4) == 0) name = "mov";
        }
    }
    if (name == NULL) return VIVID_STILL_ERROR_OPEN;
    const AVInputFormat *kind = av_find_input_format(name);
    if (kind == NULL || kind->name == NULL) return VIVID_STILL_ERROR_OPEN;
    // The demuxer found by name must be the one meant.
    if (strcmp(kind->name, still->is_matroska ? MATROSKA_FORMAT : MP4_FORMAT) != 0) return VIVID_STILL_ERROR_OPEN;
    *out_kind = kind;
    return VIVID_STILL_OK;
}

/// The film's picture: the first video stream marked as the default, or
/// failing that the first one. Cover art and thumbnails don't count.
static AVStream *pick_video_stream(const AVFormatContext *format) {
    AVStream *first = NULL;
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *candidate = format->streams[i];
        if (candidate == NULL || candidate->codecpar == NULL) continue;
        if (candidate->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) continue;
        if (candidate->disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS | AV_DISPOSITION_DEPENDENT)) continue;
        if (candidate->disposition & AV_DISPOSITION_DEFAULT) return candidate;
        if (first == NULL) first = candidate;
    }
    return first;
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
        points[kept].shown = entry->timestamp;
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

/// The time between two timestamps in seconds. Worked in floating point:
/// the timestamps are the file's, and their difference needn't fit.
static double seconds_between(const VividStill *still, int64_t later, int64_t earlier) {
    return ((double)later - (double)earlier) * still->seconds_per_tick;
}

/// What is known about the pictures, gathered from the container, then the
/// decoder, then a decoded frame, each filling in or correcting the last.
typedef struct PictureFacts {
    int width;
    int height;
    enum AVPixelFormat layout;
    enum AVColorTransferCharacteristic transfer;
    enum AVColorPrimaries primaries;
    enum AVColorSpace matrix;
    enum AVColorRange range;
} PictureFacts;

static void learn_facts(PictureFacts *facts, int width, int height, int layout, enum AVColorTransferCharacteristic transfer,
                        enum AVColorPrimaries primaries, enum AVColorSpace matrix, enum AVColorRange range) {
    if (width > 0 && height > 0) {
        facts->width = width;
        facts->height = height;
    }
    if (layout != AV_PIX_FMT_NONE && av_pix_fmt_desc_get((enum AVPixelFormat)layout) != NULL) facts->layout = (enum AVPixelFormat)layout;
    if (transfer_tag(transfer) != VIVID_STILL_TRANSFER_UNKNOWN) facts->transfer = transfer;
    if (primaries_tag(primaries) != VIVID_STILL_PRIMARIES_UNKNOWN) facts->primaries = primaries;
    if (matrix_tag(matrix) != VIVID_STILL_MATRIX_UNKNOWN) facts->matrix = matrix;
    if (range_tag(range) != VIVID_STILL_RANGE_UNKNOWN) facts->range = range;
}

static void fill_info(VividStill *still, const PictureFacts *facts) {
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
    info->width = facts->width;
    info->height = facts->height;

    AVRational shape = av_guess_sample_aspect_ratio(still->format, still->stream, NULL);
    if (shape.num > 0 && shape.den > 0) {
        info->sample_aspect_numerator = shape.num;
        info->sample_aspect_denominator = shape.den;
    } else {
        info->sample_aspect_numerator = 1;
        info->sample_aspect_denominator = 1;
    }

    const AVPixFmtDescriptor *layout = av_pix_fmt_desc_get(facts->layout);
    if (layout != NULL && layout->nb_components > 0) {
        info->bit_depth = layout->comp[0].depth;
    } else if (parameters->bits_per_raw_sample > 0 && parameters->bits_per_raw_sample <= 16) {
        info->bit_depth = parameters->bits_per_raw_sample;
    }

    info->transfer = transfer_tag(facts->transfer);
    info->primaries = primaries_tag(facts->primaries);
    info->matrix = matrix_tag(facts->matrix);
    info->range = range_tag(facts->range);

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

    // Only the record's first fields are read, so only they need to be
    // there: the record has grown over time and may grow again.
    const size_t needed = offsetof(AVDOVIDecoderConfigurationRecord, dv_bl_signal_compatibility_id) + sizeof(uint8_t);
    const AVPacketSideData *dolby = av_packet_side_data_get(parameters->coded_side_data, parameters->nb_coded_side_data,
                                                            AV_PKT_DATA_DOVI_CONF);
    if (dolby != NULL && dolby->data != NULL && dolby->size >= needed) {
        AVDOVIDecoderConfigurationRecord record;
        memset(&record, 0, sizeof(record));
        memcpy(&record, dolby->data, dolby->size < sizeof(record) ? dolby->size : sizeof(record));
        info->dolby_vision_profile = record.dv_profile;
        info->dolby_vision_compatibility = record.dv_bl_signal_compatibility_id;
    }
}

static int open_decoder(VividStill *still) {
    if (still->decoder != NULL) return VIVID_STILL_OK;
    AVCodecContext *decoder = avcodec_alloc_context3(still->codec);
    if (decoder == NULL) return VIVID_STILL_ERROR_MEMORY;
    if (avcodec_parameters_to_context(decoder, still->stream->codecpar) < 0) {
        avcodec_free_context(&decoder);
        return VIVID_STILL_ERROR_UNSUPPORTED;
    }
    // One thread and no hardware device: this must never compete with the
    // film's own decoder, and one thread also means no pictures are held
    // back waiting for others.
    decoder->thread_count = 1;
    decoder->thread_type = 0;
    decoder->flags |= AV_CODEC_FLAG_LOW_DELAY;
    decoder->pkt_timebase = still->stream->time_base;
    decoder->max_pixels = still->max_pixels;
    // The log is shared with the film's player. What this decoder says
    // about a damaged keyframe is no business of the film's.
    decoder->log_level_offset = DECODER_LOG_LEVEL_OFFSET;
    AVDictionary *settings = NULL;
    if (av_dict_set(&settings, "codec_whitelist", ALLOWED_DECODERS, 0) < 0) {
        av_dict_free(&settings);
        avcodec_free_context(&decoder);
        return VIVID_STILL_ERROR_MEMORY;
    }
    int opened = avcodec_open2(decoder, still->codec, &settings);
    av_dict_free(&settings);
    if (opened < 0) {
        avcodec_free_context(&decoder);
        return opened == AVERROR(ENOMEM) ? VIVID_STILL_ERROR_MEMORY : VIVID_STILL_ERROR_UNSUPPORTED;
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

static int packet_is_a_usable_keyframe(const VividStill *still, const AVPacket *packet) {
    return packet->stream_index == still->stream->index
        && (packet->flags & AV_PKT_FLAG_KEY)
        && !(packet->flags & (AV_PKT_FLAG_CORRUPT | AV_PKT_FLAG_DISCARD))
        && packet->size > 0;
}

/// Reads on from the seek point to the first keyframe of the video stream
/// and leaves it in `still->keyframe`.
static int read_keyframe(VividStill *still) {
    av_packet_unref(still->keyframe);
    for (int count = 0; count < MAX_PACKETS_TO_KEYFRAME; count++) {
        int read = av_read_frame(still->format, still->packet);
        if (read < 0) return stop_reason(still, VIVID_STILL_ERROR_OVER_BYTE_LIMIT, VIVID_STILL_ERROR_DATA);
        if (packet_is_a_usable_keyframe(still, still->packet)) {
            av_packet_move_ref(still->keyframe, still->packet);
            return VIVID_STILL_OK;
        }
        av_packet_unref(still->packet);
    }
    return VIVID_STILL_ERROR_DATA;
}

/// A picture the decoder patched up or flagged isn't worth showing.
static int picture_is_damaged(const AVFrame *frame) {
    return (frame->flags & AV_FRAME_FLAG_CORRUPT) != 0 || frame->decode_error_flags != 0;
}

/// Decodes the keyframe on its own. `sent` counts the packets used. With
/// `may_read_on`, a keyframe that gives no picture alone is tried again
/// with the few packets after it.
static int decode_keyframe(VividStill *still, int may_read_on, int *sent) {
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
    if (have_picture) return picture_is_damaged(still->frame) ? VIVID_STILL_ERROR_DECODE : VIVID_STILL_OK;
    if (!may_read_on) return VIVID_STILL_ERROR_DECODE;

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
    if (have_picture) return picture_is_damaged(still->frame) ? VIVID_STILL_ERROR_DECODE : VIVID_STILL_OK;
    return stop_reason(still, VIVID_STILL_ERROR_OVER_BYTE_LIMIT, VIVID_STILL_ERROR_DECODE);
}

/// Reads the first video packet, for the time the stream starts at. A
/// keyframe is kept in `still->keyframe`.
static int read_first_packet(VividStill *still, int64_t *time, int64_t *position, int *is_keyframe) {
    *time = AV_NOPTS_VALUE;
    *position = -1;
    *is_keyframe = 0;
    av_packet_unref(still->keyframe);
    for (int count = 0; count < MAX_PACKETS_TO_KEYFRAME; count++) {
        int read = av_read_frame(still->format, still->packet);
        if (read < 0) return stop_reason(still, VIVID_STILL_ERROR_OPEN_TOO_COSTLY, VIVID_STILL_ERROR_OPEN);
        if (still->packet->stream_index != still->stream->index) {
            av_packet_unref(still->packet);
            continue;
        }
        *time = still->packet->pts != AV_NOPTS_VALUE ? still->packet->pts : still->packet->dts;
        *position = still->packet->pos;
        if (packet_is_a_usable_keyframe(still, still->packet)) {
            *is_keyframe = 1;
            av_packet_move_ref(still->keyframe, still->packet);
        } else {
            av_packet_unref(still->packet);
        }
        return VIVID_STILL_OK;
    }
    return VIVID_STILL_ERROR_OPEN;
}

/// Works out when each keyframe is shown and whether the index covers the
/// file. `first_time` and `first_position` describe the first video packet
/// when it was a keyframe, and are `AV_NOPTS_VALUE` and -1 otherwise.
static void finish_index(VividStill *still, int64_t first_time, int64_t first_position) {
    if (still->index_count == 0) return;

    // MP4 lists decode times. The first keyframe was read, so how long
    // after its decode time it is shown is known, and the usual keyframe
    // waits exactly as long.
    int64_t delay = 0;
    const IndexPoint *first = &still->index[0];
    if (!still->is_matroska && first_time != AV_NOPTS_VALUE && first_position == first->position) {
        double apart = (double)first_time - (double)first->timestamp;
        // A reorder delay is a few frames. Anything else isn't one.
        if (apart > 0 && apart * still->seconds_per_tick <= 10.0) delay = first_time - first->timestamp;
    }
    for (int i = 0; i < still->index_count; i++) {
        still->index[i].shown = saturating_add(still->index[i].timestamp, delay);
    }

    // A few entries picked up along the way aren't an index. It counts
    // when its last keyframe is within two of its own widest gaps of the
    // end of the file.
    double widest = 0;
    for (int i = 1; i < still->index_count; i++) {
        double gap = seconds_between(still, still->index[i].shown, still->index[i - 1].shown);
        if (gap > widest) widest = gap;
    }
    double last = seconds_between(still, still->index[still->index_count - 1].shown, still->start);
    double duration = still->info.duration_seconds;
    if (still->index_count >= 2) {
        still->index_covers_file = duration <= 0 || last + 2.0 * widest >= duration;
    } else {
        // One keyframe is the whole index of a short clip, and no index at
        // all for a film.
        still->index_covers_file = duration > 0 && last + LONE_KEYFRAME_REACH_SECONDS >= duration;
    }
}

static void release_decoder(VividStill *still) {
    avcodec_free_context(&still->decoder);
    sws_freeContext(still->scaler);
    still->scaler = NULL;
    if (still->frame != NULL) av_frame_unref(still->frame);
    if (still->keyframe != NULL) av_packet_unref(still->keyframe);
}

static void release_held(VividStill *still) {
    free(still->held);
    still->held = NULL;
    still->held_length = 0;
}

int vivid_still_open(const VividStillCallbacks *callbacks, const VividStillOpenOptions *options, VividStill **out_handle) {
    if (out_handle == NULL) return VIVID_STILL_ERROR_ARGUMENT;
    *out_handle = NULL;
    if (callbacks == NULL || callbacks->read == NULL) return VIVID_STILL_ERROR_ARGUMENT;

    VividStill *still = calloc(1, sizeof(VividStill));
    if (still == NULL) return VIVID_STILL_ERROR_MEMORY;
    still->callbacks = *callbacks;
    still->max_pixels = MAX_PICTURE_PIXELS;
    int64_t open_limit = OPEN_BYTE_LIMIT;
    if (options != NULL) {
        if (options->max_open_bytes > 0 && options->max_open_bytes < OPEN_BYTE_LIMIT) open_limit = options->max_open_bytes;
        if (options->max_picture_pixels > 0 && options->max_picture_pixels < MAX_PICTURE_PIXELS) {
            still->max_pixels = options->max_picture_pixels;
        }
    }
    begin_call(still, open_limit);

    int result = VIVID_STILL_ERROR_MEMORY;
    AVDictionary *settings = NULL;
    const AVInputFormat *kind = NULL;

    still->packet = av_packet_alloc();
    still->keyframe = av_packet_alloc();
    still->frame = av_frame_alloc();
    if (still->packet == NULL || still->keyframe == NULL || still->frame == NULL) goto fail;

    result = recognise(still, &kind);
    if (result != VIVID_STILL_OK) goto fail;
    result = VIVID_STILL_ERROR_MEMORY;

    // Everything that can fail for want of memory comes before the demuxer
    // is given the reader, so no failure leaves the two half joined.
    //
    // The demuxer is told the same two lists the shim keeps to: it is
    // already the right kind, and should it ever make a decoder of its own
    // it may only make one of these.
    if (av_dict_set(&settings, "format_whitelist", ALLOWED_FORMATS, 0) < 0) goto fail;
    if (av_dict_set(&settings, "codec_whitelist", ALLOWED_DECODERS, 0) < 0) goto fail;
    // MP4 can name other files to take its samples from. Off is the
    // default, and it is said here so it stays off.
    if (!still->is_matroska && av_dict_set(&settings, "enable_drefs", "0", 0) < 0) goto fail;

    uint8_t *buffer = av_malloc(IO_BUFFER_BYTES);
    if (buffer == NULL) goto fail;
    still->io = avio_alloc_context(buffer, IO_BUFFER_BYTES, 0, still, io_read, NULL, io_seek);
    if (still->io == NULL) {
        av_free(buffer);
        goto fail;
    }

    still->format = avformat_alloc_context();
    if (still->format == NULL) goto fail;
    // The reader belongs to this handle. Marked as such in the same breath
    // as it is handed over, so closing the demuxer never closes it too.
    still->format->pb = still->io;
    still->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    // Packets are taken as the container frames them and timed as it
    // times them, so no parser is made for any stream.
    still->format->flags |= AVFMT_FLAG_NOPARSE | AVFMT_FLAG_NOFILLIN;
    still->format->io_open = refuse_to_open;
    still->format->interrupt_callback.callback = interrupt_callback;
    still->format->interrupt_callback.opaque = still;

    // On failure this frees the context it was given and clears the pointer.
    int opened = avformat_open_input(&still->format, NULL, kind, &settings);
    av_dict_free(&settings);
    if (opened < 0) {
        result = stop_reason(still, VIVID_STILL_ERROR_OPEN_TOO_COSTLY, VIVID_STILL_ERROR_OPEN);
        goto fail;
    }

    still->stream = pick_video_stream(still->format);
    if (still->stream == NULL) {
        result = VIVID_STILL_ERROR_NO_VIDEO;
        goto fail;
    }
    // Nothing is wanted from any other stream, now or later.
    for (unsigned i = 0; i < still->format->nb_streams; i++) {
        if (still->format->streams[i] != still->stream) still->format->streams[i]->discard = AVDISCARD_ALL;
    }

    const AVCodecParameters *parameters = still->stream->codecpar;
    still->codec = software_decoder(parameters->codec_id);
    if (still->codec == NULL) {
        result = VIVID_STILL_ERROR_UNSUPPORTED;
        goto fail;
    }
    // The header must say how large the picture is. Finding out by
    // decoding would mean letting the demuxer make decoders of its own.
    result = picture_size_result(still, parameters->width, parameters->height);
    if (result != VIVID_STILL_OK) goto fail;
    AVRational base = still->stream->time_base;
    if (base.num <= 0 || base.den <= 0) {
        result = VIVID_STILL_ERROR_UNSUPPORTED;
        goto fail;
    }
    still->seconds_per_tick = av_q2d(base);

    int64_t first_time = AV_NOPTS_VALUE;
    int64_t first_position = -1;
    int first_is_keyframe = 0;
    result = read_first_packet(still, &first_time, &first_position, &first_is_keyframe);
    if (result != VIVID_STILL_OK) goto fail;
    still->start = first_time != AV_NOPTS_VALUE ? first_time : 0;

    PictureFacts facts = { 0, 0, AV_PIX_FMT_NONE, AVCOL_TRC_UNSPECIFIED, AVCOL_PRI_UNSPECIFIED, AVCOL_SPC_UNSPECIFIED,
                           AVCOL_RANGE_UNSPECIFIED };
    learn_facts(&facts, parameters->width, parameters->height, parameters->format, parameters->color_trc,
                parameters->color_primaries, parameters->color_space, parameters->color_range);

    // The stream's own word on bit depth and colour, from this handle's
    // decoder: straight from its setup data where that says enough, and
    // from the first keyframe where it doesn't.
    result = open_decoder(still);
    if (result != VIVID_STILL_OK) goto fail;
    learn_facts(&facts, still->decoder->width, still->decoder->height, still->decoder->pix_fmt, still->decoder->color_trc,
                still->decoder->color_primaries, still->decoder->colorspace, still->decoder->color_range);
    if (still->decoder->pix_fmt == AV_PIX_FMT_NONE && first_is_keyframe) {
        int sent = 0;
        if (decode_keyframe(still, 0, &sent) == VIVID_STILL_OK) {
            const AVFrame *frame = still->frame;
            learn_facts(&facts, frame->width, frame->height, frame->format, frame->color_trc, frame->color_primaries,
                        frame->colorspace, frame->color_range);
        }
    }
    release_decoder(still);
    result = picture_size_result(still, facts.width, facts.height);
    if (result != VIVID_STILL_OK) goto fail;

    if (still->is_matroska) {
        // Matroska leaves a cue table at the end of the file unread until
        // the first seek. Seeking forward to the start reads it.
        still->io->error = 0;
        still->io->eof_reached = 0;
        (void)av_seek_frame(still->format, still->stream->index, still->start, 0);
    }
    // A read that failed along the way may have been passed over, leaving
    // the index short. That isn't a fact about the file.
    result = stop_reason(still, VIVID_STILL_ERROR_OPEN_TOO_COSTLY, VIVID_STILL_OK);
    if (result != VIVID_STILL_OK) goto fail;

    result = collect_index(still);
    if (result != VIVID_STILL_OK) goto fail;
    fill_info(still, &facts);
    finish_index(still, first_is_keyframe ? first_time : AV_NOPTS_VALUE, first_is_keyframe ? first_position : -1);
    still->info.index_count = still->index_count;
    still->info.has_index = still->index_covers_file;
    still->info.last_entry_is_unreadable = still->is_matroska && still->index_count > 0;

    *out_handle = still;
    return VIVID_STILL_OK;

fail:
    av_dict_free(&settings);
    vivid_still_close(still);
    return result;
}

void vivid_still_close_decoder(VividStill *handle) {
    if (handle == NULL) return;
    release_decoder(handle);
}

void vivid_still_close(VividStill *handle) {
    if (handle == NULL) return;
    release_decoder(handle);
    release_held(handle);
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
    out_entry->time_seconds = seconds_between(handle, point->shown, handle->start);
    out_entry->byte_position = point->position;
    out_entry->size = point->size;
    return VIVID_STILL_OK;
}

int vivid_still_index_position(const VividStill *handle, double seconds) {
    if (handle == NULL || !isfinite(seconds) || handle->index_count == 0) return -1;
    if (seconds < 0) seconds = 0;
    // Floating point throughout: the start is the file's and the time is
    // the caller's, and their sum needn't fit a timestamp.
    double ticks = (double)handle->start + seconds / handle->seconds_per_tick;
    int64_t target;
    if (ticks >= 9.0e18) {
        target = INT64_MAX;
    } else if (ticks <= -9.0e18) {
        target = INT64_MIN;
    } else {
        target = llround(ticks);
    }
    // The last entry shown at or before the target.
    int low = 0;
    int high = handle->index_count;
    while (low < high) {
        int middle = low + (high - low) / 2;
        if (handle->index[middle].shown <= target) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    return low - 1;
}

/// Fetches a keyframe whose place and size the index records, before the
/// demuxer is asked for it. A cancel, a failed read, a file that ends
/// early or a keyframe over the limit is then found here, quietly, and the
/// demuxer only ever reads bytes that are already in hand.
static int hold_keyframe_bytes(VividStill *still, const IndexPoint *point) {
    int64_t from = point->position;
    if (from > still->offset && from - still->offset <= READ_THROUGH_BYTES) from = still->offset;
    int64_t length = (point->position - from) + point->size;
    if (length > still->allowance) return VIVID_STILL_ERROR_OVER_BYTE_LIMIT;
    release_held(still);
    still->held = malloc((size_t)length);
    if (still->held == NULL) return VIVID_STILL_ERROR_MEMORY;
    int64_t filled = source_read_fully(still, still->held, length, from);
    if (filled < 0) return stop_reason(still, VIVID_STILL_ERROR_OVER_BYTE_LIMIT, VIVID_STILL_ERROR_READ);
    if (filled < length) return VIVID_STILL_ERROR_DATA;
    still->held_start = from;
    still->held_length = length;
    return VIVID_STILL_OK;
}

/// Seeks to an index entry and leaves its keyframe in `still->keyframe`.
static int fetch_keyframe(VividStill *still, int position) {
    const IndexPoint *point = &still->index[position];
    int64_t seek_time = point->shown;
    for (int attempt = 0; attempt < 2; attempt++) {
        // An aborted or failed read leaves the reader flagged. Clear that,
        // and let the seek throw away whatever was half read.
        still->io->error = 0;
        still->io->eof_reached = 0;
        if (av_seek_frame(still->format, still->stream->index, seek_time, AVSEEK_FLAG_BACKWARD) < 0) {
            return stop_reason(still, VIVID_STILL_ERROR_OVER_BYTE_LIMIT, VIVID_STILL_ERROR_SEEK);
        }
        int result = read_keyframe(still);
        if (result != VIVID_STILL_OK) return result;
        // Matroska's index points at a cluster, not at the packet, so
        // there is nothing to compare.
        if (still->is_matroska || point->size <= 0) return VIVID_STILL_OK;
        if (still->keyframe->pos == point->position) return VIVID_STILL_OK;
        // The demuxer goes by when a keyframe is shown, and gave the one
        // before: this one is shown later than the index could say. Just
        // short of the next keyframe can't miss in the same way.
        if (position + 1 < still->index_count) {
            seek_time = saturating_add(still->index[position + 1].shown, -1);
        } else {
            double minute = 60.0 / still->seconds_per_tick;
            seek_time = saturating_add(point->shown, minute < 4.0e18 ? llround(minute) : (int64_t)4.0e18);
        }
    }
    av_packet_unref(still->keyframe);
    return VIVID_STILL_ERROR_DATA;
}

/// The old full-range pixel layouts are the plain ones with the range in
/// the name. The scaler is given the plain one, so it resizes the values
/// as they are and has nothing to say about the old names.
static enum AVPixelFormat plain_layout(enum AVPixelFormat layout) {
    switch (layout) {
    case AV_PIX_FMT_YUVJ420P: return AV_PIX_FMT_YUV420P;
    case AV_PIX_FMT_YUVJ422P: return AV_PIX_FMT_YUV422P;
    case AV_PIX_FMT_YUVJ444P: return AV_PIX_FMT_YUV444P;
    case AV_PIX_FMT_YUVJ440P: return AV_PIX_FMT_YUV440P;
    case AV_PIX_FMT_YUVJ411P: return AV_PIX_FMT_YUV411P;
    default: return layout;
    }
}

/// 0 for a limited-range frame. For a full-range one, the value white has
/// after the scaler widens the planes to 16 bits, which it does by moving
/// the bits up: 255 becomes 255 * 256, not 65535.
static int full_range_white(const AVFrame *frame, const AVPixFmtDescriptor *plain) {
    int is_full = frame->color_range == AVCOL_RANGE_JPEG || plain_layout((enum AVPixelFormat)frame->format) != frame->format;
    if (!is_full) return 0;
    int depth = plain->comp[0].depth;
    if (depth < 8 || depth > 16) return 65535;
    return ((1 << depth) - 1) << (16 - depth);
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
///
/// `full_white` is 0 for limited range. For full range it is the value
/// white has once the scaler has widened the source to 16 bits.
static void planes_to_rgb(uint8_t *const planes[4], const int strides[4], int width, int height, int full_white,
                          double red_weight, double blue_weight, int layout, uint8_t *pixels, int stride) {
    double green_weight = 1.0 - red_weight - blue_weight;
    float red_from_cr = (float)(2.0 * (1.0 - red_weight));
    float blue_from_cb = (float)(2.0 * (1.0 - blue_weight));
    float green_from_cb = (float)(-blue_weight * 2.0 * (1.0 - blue_weight) / green_weight);
    float green_from_cr = (float)(-red_weight * 2.0 * (1.0 - red_weight) / green_weight);
    // Limited range in 16 bits: black at 16 * 256, white 219 * 256 above
    // it, and colour differences spanning 224 * 256.
    float luma_floor = full_white > 0 ? 0.0f : 4096.0f;
    float luma_scale = full_white > 0 ? 1.0f / (float)full_white : 1.0f / 56064.0f;
    float chroma_scale = full_white > 0 ? 1.0f / (float)full_white : 1.0f / 57344.0f;

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
    int fits = picture_size_result(still, frame->width, frame->height);
    if (fits != VIVID_STILL_OK) return fits;
    enum AVPixelFormat source_format = plain_layout((enum AVPixelFormat)frame->format);
    if (frame->data[0] == NULL || !sws_isSupportedInput(source_format)) return VIVID_STILL_ERROR_UNSUPPORTED;
    const AVPixFmtDescriptor *source_layout = av_pix_fmt_desc_get(source_format);
    if (source_layout == NULL || source_layout->nb_components < 1) return VIVID_STILL_ERROR_UNSUPPORTED;

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

    still->scaler = sws_getCachedContext(still->scaler, frame->width, frame->height, source_format,
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
        planes_to_rgb(planes, strides, width, height, full_range_white(frame, source_layout), red_weight, blue_weight,
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
    out_picture->index_position = -1;
    if (handle == NULL || !isfinite(seconds)) return VIVID_STILL_ERROR_ARGUMENT;
    if (layout != VIVID_STILL_LAYOUT_AUTO && layout != VIVID_STILL_LAYOUT_BGRA8 && layout != VIVID_STILL_LAYOUT_RGBA16) {
        return VIVID_STILL_ERROR_ARGUMENT;
    }
    begin_call(handle, max_read_bytes > 0 && max_read_bytes < STILL_BYTE_LIMIT ? max_read_bytes : STILL_BYTE_LIMIT);
    if (is_aborted(handle)) return VIVID_STILL_ERROR_ABORTED;

    // Without an index the only way to a keyframe is reading through the
    // file for it, which a preview must never do.
    if (handle->index_count == 0) return VIVID_STILL_ERROR_NO_INDEX;
    int position = vivid_still_index_position(handle, seconds);
    if (position < 0) return VIVID_STILL_ERROR_SEEK;
    const IndexPoint *point = &handle->index[position];

    if (handle->is_matroska) {
        // Asked for its last cue, or for a time before its first, the
        // Matroska demuxer reads on through the file looking for keyframes
        // the cues might have missed. Its own index is asked the question
        // it would ask itself, and those two answers are refused here.
        int entries = avformat_index_get_entries_count(handle->stream);
        int found = av_index_search_timestamp(handle->stream, point->shown, AVSEEK_FLAG_BACKWARD);
        if (found < 0) return VIVID_STILL_ERROR_SEEK;
        if (position == handle->index_count - 1 || found >= entries - 1) return VIVID_STILL_ERROR_LAST_CUE;
    }

    int result = open_decoder(handle);
    if (result != VIVID_STILL_OK) return result;

    if (point->size > 0) result = hold_keyframe_bytes(handle, point);
    if (result == VIVID_STILL_OK) result = fetch_keyframe(handle, position);
    if (result != VIVID_STILL_OK) {
        release_held(handle);
        return result;
    }
    int packet_bytes = handle->keyframe->size;
    int64_t packet_time = handle->keyframe->pts != AV_NOPTS_VALUE ? handle->keyframe->pts : handle->keyframe->dts;

    int sent = 0;
    result = decode_keyframe(handle, 1, &sent);
    av_packet_unref(handle->keyframe);
    release_held(handle);
    if (result == VIVID_STILL_OK) result = scale_picture(handle, max_width, layout, out_picture);
    if (result == VIVID_STILL_OK) {
        int64_t shown = handle->frame->best_effort_timestamp;
        if (shown == AV_NOPTS_VALUE) shown = handle->frame->pts;
        if (shown == AV_NOPTS_VALUE) shown = packet_time;
        if (shown == AV_NOPTS_VALUE) shown = point->shown;
        out_picture->time_seconds = seconds_between(handle, shown, handle->start);
        out_picture->index_position = position;
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
