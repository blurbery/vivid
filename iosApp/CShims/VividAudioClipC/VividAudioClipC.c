#include "VividAudioClipC.h"

#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>

// Small, so a seek pulls little more than it needs through the callbacks.
#define IO_BUFFER_BYTES (32 * 1024)
// How much of the start of the file is looked at to tell what it is.
#define RECOGNISE_BYTES 12
// The containers sound is read from, by the demuxers' own names.
#define MATROSKA_FORMAT "matroska,webm"
#define MP4_FORMAT "mov,mp4,m4a,3gp,3g2,mj2"
#define ALLOWED_FORMATS MATROSKA_FORMAT "," MP4_FORMAT
// The software decoders clips are made with: the sound of films, series
// and music. `allowed_decoder` below picks from the same set.
#define ALLOWED_DECODERS                                                                                              \
    "aac,aac_latm,ac3,eac3,truehd,mlp,dca,flac,opus,vorbis,mp3float,mp3,mp2float,mp2,alac,"                           \
    "pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,pcm_u8,"     \
    "pcm_bluray,pcm_dvd"
// The most channels a stream may have to be mixed.
#define MAX_CHANNELS 16
#define MIN_SOURCE_RATE 8000
#define MAX_SOURCE_RATE 768000
#define MAX_CLIP_SECONDS 30.0
// The most one call may read, whatever the caller asks for.
#define OPEN_BYTE_LIMIT (64LL * 1024 * 1024)
#define CLIP_BYTE_LIMIT (256LL * 1024 * 1024)
// Packets read at the start of the file while learning when it starts.
#define MAX_PACKETS_AT_START 4096
// Packets read in one clip before it is given up: about four times what a
// 30 second clip of the busiest file needs.
#define MAX_PACKETS_PER_CLIP 400000
// Seeks land this much before a clip's start, so a decoder that needs a
// frame or two to settle, as AAC does, has them before the clip begins.
#define PREROLL_SECONDS 0.5
// A call that starts this close to where the last one ended carries on
// from there instead of seeking.
#define CONTINUE_TOLERANCE_SECONDS 0.05
// The decoder's messages are moved this far down the scale of importance,
// below anything a listener set to warnings would pick up.
#define DECODER_LOG_LEVEL_OFFSET 100

struct VividAudioClip {
    VividAudioClipCallbacks callbacks;
    /// Where the next read starts. Seeking only moves this.
    int64_t offset;
    /// Bytes the current call may still read.
    int64_t allowance;
    /// Why the current call's reading stopped, if it did.
    int read_failed;
    int over_allowance;
    AVIOContext *io;
    AVFormatContext *format;
    AVStream *stream;
    const AVCodec *codec;
    AVCodecContext *decoder;
    SwrContext *resampler;
    /// The layout the resampler was set up for, so a change mid-stream
    /// sets it up again.
    AVChannelLayout resampler_layout;
    int resampler_rate;
    int resampler_format;
    AVPacket *packet;
    AVFrame *frame;
    /// The earliest time any sound or picture stream starts at, in
    /// `AV_TIME_BASE` units, or `AV_NOPTS_VALUE`.
    int64_t container_start;
    VividAudioClipInfo info;
    /// Each channel's share of the two mixes, summing to one in each.
    float mix_weights[MAX_CHANNELS];
    float music_weights[MAX_CHANNELS];
    int channels;
    int has_centre;
    /// Converted sound not yet handed out, channel by channel, at 48 kHz.
    float *pending[MAX_CHANNELS];
    int pending_count;
    /// Room in each channel's buffer, in samples.
    int plane_capacity[MAX_CHANNELS];
    /// When the first pending sample plays, on the player's clock. Only
    /// meaningful once `has_cursor` is set.
    double cursor_seconds;
    int has_cursor;
    /// Where the last clip ended, on the player's clock.
    double next_seconds;
    int can_continue;
    /// Set once the demuxer has run out and the decoder has been drained.
    int at_end;
};

static int is_aborted(const VividAudioClip *clip) {
    return clip->callbacks.aborted != NULL && clip->callbacks.aborted(clip->callbacks.context) != 0;
}

static int interrupt_callback(void *opaque) {
    return is_aborted((const VividAudioClip *)opaque);
}

static int64_t known_size(const VividAudioClip *clip) {
    if (clip->callbacks.size == NULL) return -1;
    return clip->callbacks.size(clip->callbacks.context);
}

/// Starts a call: a fresh byte allowance and nothing yet gone wrong.
static void begin_call(VividAudioClip *clip, int64_t allowance) {
    clip->allowance = allowance;
    clip->read_failed = 0;
    clip->over_allowance = 0;
}

/// Why reading stopped, as a result. `otherwise` is for when nothing was
/// flagged, which means the file itself gave out.
static int stop_reason(const VividAudioClip *clip, int over_limit, int otherwise) {
    if (is_aborted(clip)) return VIVID_AUDIO_CLIP_ERROR_ABORTED;
    if (clip->over_allowance) return over_limit;
    if (clip->read_failed) return VIVID_AUDIO_CLIP_ERROR_READ;
    return otherwise;
}

/// One read through the caller's callback. Returns the bytes copied, 0 at
/// the end of the file, or -1 with the reason left for `stop_reason`.
static int source_read(VividAudioClip *clip, uint8_t *buffer, int size, int64_t offset) {
    if (is_aborted(clip)) return -1;
    // Out of allowance: stop the call instead of reading on without end.
    if (clip->allowance <= 0) {
        clip->over_allowance = 1;
        return -1;
    }
    if (size > clip->allowance) size = (int)clip->allowance;
    int count = clip->callbacks.read(clip->callbacks.context, buffer, size, offset);
    // More than was asked for would mean the callback wrote past the buffer.
    if (count < 0 || count > size) {
        if (!is_aborted(clip)) clip->read_failed = 1;
        return -1;
    }
    clip->allowance -= count;
    return count;
}

static int io_read(void *opaque, uint8_t *buffer, int size) {
    VividAudioClip *clip = opaque;
    if (buffer == NULL || size <= 0 || clip->offset < 0) return AVERROR(EINVAL);
    // A seek may have put the offset anywhere a file says. Reading from
    // there must not carry it past what an offset can hold.
    if (clip->offset > INT64_MAX - size) return AVERROR(EINVAL);
    int count = source_read(clip, buffer, size, clip->offset);
    if (count < 0) return is_aborted(clip) ? AVERROR_EXIT : AVERROR(EIO);
    if (count == 0) return AVERROR_EOF;
    clip->offset += count;
    return count;
}

static int64_t io_seek(void *opaque, int64_t offset, int whence) {
    VividAudioClip *clip = opaque;
    whence &= ~AVSEEK_FORCE;
    if (whence == AVSEEK_SIZE) {
        int64_t size = known_size(clip);
        return size >= 0 ? size : AVERROR(ENOSYS);
    }
    int64_t base;
    if (whence == SEEK_SET) {
        base = 0;
    } else if (whence == SEEK_CUR) {
        base = clip->offset;
    } else if (whence == SEEK_END) {
        base = known_size(clip);
        if (base < 0) return AVERROR(ENOSYS);
    } else {
        return AVERROR(EINVAL);
    }
    if (base < 0) return AVERROR(EINVAL);
    if (offset > 0 && base > INT64_MAX - offset) return AVERROR(EINVAL);
    if (offset < 0 && base + offset < 0) return AVERROR(EINVAL);
    clip->offset = base + offset;
    return clip->offset;
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

/// The decoder for a codec, if it is on the allowed list and works in
/// software. Anything else is refused instead of handed to whatever
/// decoder happens to exist.
static const AVCodec *allowed_decoder(enum AVCodecID codec) {
    const AVCodec *found = avcodec_find_decoder(codec);
    if (found == NULL || found->type != AVMEDIA_TYPE_AUDIO || found->name == NULL) return NULL;
    if (found->capabilities & (AV_CODEC_CAP_HARDWARE | AV_CODEC_CAP_EXPERIMENTAL)) return NULL;
    // The same list the demuxer and the decoder are given, so the three
    // can't drift apart.
    if (av_match_list(found->name, ALLOWED_DECODERS, ',') <= 0) return NULL;
    return found;
}

/// Looks at the first bytes of the file and says which demuxer reads it:
/// Matroska by its opening mark, MP4 by the name of its first box. Told
/// apart here, by hand, so no demuxer of any kind is shown a file that
/// isn't one of the two.
static int recognise(VividAudioClip *clip, const AVInputFormat **out_kind, int *out_is_matroska) {
    uint8_t start[RECOGNISE_BYTES];
    memset(start, 0, sizeof(start));
    int filled = 0;
    while (filled < RECOGNISE_BYTES) {
        int count = source_read(clip, start + filled, RECOGNISE_BYTES - filled, filled);
        if (count < 0) return stop_reason(clip, VIVID_AUDIO_CLIP_ERROR_OPEN_TOO_COSTLY, VIVID_AUDIO_CLIP_ERROR_READ);
        if (count == 0) break;
        filled += count;
    }
    if (filled < RECOGNISE_BYTES) return VIVID_AUDIO_CLIP_ERROR_OPEN;

    static const uint8_t matroska_mark[4] = { 0x1A, 0x45, 0xDF, 0xA3 };
    static const char first_boxes[][5] = { "ftyp", "moov", "mdat", "free", "skip", "wide" };
    const char *name = NULL;
    int is_matroska = 0;
    if (memcmp(start, matroska_mark, sizeof(matroska_mark)) == 0) {
        is_matroska = 1;
        name = "matroska";
    } else {
        for (size_t i = 0; i < sizeof(first_boxes) / sizeof(first_boxes[0]); i++) {
            if (memcmp(start + 4, first_boxes[i], 4) == 0) name = "mov";
        }
    }
    if (name == NULL) return VIVID_AUDIO_CLIP_ERROR_OPEN;
    const AVInputFormat *kind = av_find_input_format(name);
    if (kind == NULL || kind->name == NULL) return VIVID_AUDIO_CLIP_ERROR_OPEN;
    // The demuxer found by name must be the one meant.
    if (strcmp(kind->name, is_matroska ? MATROSKA_FORMAT : MP4_FORMAT) != 0) return VIVID_AUDIO_CLIP_ERROR_OPEN;
    *out_kind = kind;
    *out_is_matroska = is_matroska;
    return VIVID_AUDIO_CLIP_OK;
}

static int is_sound_stream(const AVStream *stream) {
    return stream != NULL && stream->codecpar != NULL && stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO;
}

/// The sound stream asked for, or the one marked as the default, or
/// failing that the first. A number that isn't a sound stream of this file
/// gets the default too: the player's numbering usually matches FFmpeg's,
/// and a film's music is the same in every dub.
static AVStream *pick_sound_stream(const AVFormatContext *format, int wanted) {
    if (wanted >= 0 && (unsigned)wanted < format->nb_streams && is_sound_stream(format->streams[wanted])) {
        return format->streams[wanted];
    }
    AVStream *first = NULL;
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *candidate = format->streams[i];
        if (!is_sound_stream(candidate)) continue;
        if (candidate->disposition & AV_DISPOSITION_DEFAULT) return candidate;
        if (first == NULL) first = candidate;
    }
    return first;
}

/// Takes `time`, in `stream`'s time base, as the container's start if it
/// is the earliest seen. Only sound and pictures count, as they do for the
/// container's own start time: subtitles, data and cover art don't.
static void note_container_time(VividAudioClip *clip, const AVStream *stream, int64_t time) {
    if (stream == NULL || stream->codecpar == NULL || time == AV_NOPTS_VALUE) return;
    enum AVMediaType type = stream->codecpar->codec_type;
    if (type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) return;
    if (stream->disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS)) return;
    if (stream->time_base.num <= 0 || stream->time_base.den <= 0) return;
    int64_t start = av_rescale_q(time, stream->time_base, AV_TIME_BASE_Q);
    if (clip->container_start == AV_NOPTS_VALUE || start < clip->container_start) clip->container_start = start;
}

/// True for a picture stream the player shows, as opposed to cover art.
static int is_picture_stream(const AVStream *stream) {
    return stream != NULL && stream->codecpar != NULL && stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
        && !(stream->disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS));
}

/// Reads the first packets, until the chosen sound stream and the first
/// picture stream have each given one, noting when every sound and picture
/// stream starts. The container's start is the earliest of those, as it is
/// for the player.
static int learn_container_start(VividAudioClip *clip) {
    for (unsigned i = 0; i < clip->format->nb_streams; i++) {
        const AVStream *stream = clip->format->streams[i];
        if (stream != NULL) note_container_time(clip, stream, stream->start_time);
    }
    int wants_picture = 0;
    for (unsigned i = 0; i < clip->format->nb_streams; i++) {
        if (is_picture_stream(clip->format->streams[i])) wants_picture = 1;
    }
    int have_sound = 0;
    int have_picture = !wants_picture;
    for (int count = 0; count < MAX_PACKETS_AT_START && !(have_sound && have_picture); count++) {
        int read = av_read_frame(clip->format, clip->packet);
        if (read < 0) {
            int reason = stop_reason(clip, VIVID_AUDIO_CLIP_ERROR_OPEN_TOO_COSTLY, VIVID_AUDIO_CLIP_OK);
            // The file ending this early is fine: what was seen is what
            // there is.
            if (reason != VIVID_AUDIO_CLIP_OK) return reason;
            break;
        }
        int index = clip->packet->stream_index;
        if (index >= 0 && (unsigned)index < clip->format->nb_streams) {
            const AVStream *stream = clip->format->streams[index];
            int64_t time = clip->packet->pts != AV_NOPTS_VALUE ? clip->packet->pts : clip->packet->dts;
            note_container_time(clip, stream, time);
            if (stream == clip->stream) have_sound = 1;
            if (is_picture_stream(stream)) have_picture = 1;
        }
        av_packet_unref(clip->packet);
    }
    if (clip->format->start_time != AV_NOPTS_VALUE &&
        (clip->container_start == AV_NOPTS_VALUE || clip->format->start_time < clip->container_start)) {
        clip->container_start = clip->format->start_time;
    }
    if (clip->container_start == AV_NOPTS_VALUE) clip->container_start = 0;
    return VIVID_AUDIO_CLIP_OK;
}

/// Each channel's share of the two mixes. The front pair counts fully,
/// the other speakers a little less and the low-frequency channel not at
/// all. The music mix also leaves out the centre channel, which carries a
/// film's dialogue, and only exists when there is a centre channel with
/// others beside it.
///
/// A layout that only gives a channel count, as Matroska's PCM does, is
/// taken as the usual layout for that many channels, as players do.
static int set_weights(VividAudioClip *clip, const AVChannelLayout *given) {
    int channels = given->nb_channels;
    if (channels < 1 || channels > MAX_CHANNELS) return VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
    AVChannelLayout usual = { 0 };
    const AVChannelLayout *layout = given;
    if (given->order == AV_CHANNEL_ORDER_UNSPEC && channels > 1) {
        av_channel_layout_default(&usual, channels);
        if (usual.order != AV_CHANNEL_ORDER_UNSPEC && usual.nb_channels == channels) layout = &usual;
    }
    int has_centre = 0;
    float mix_total = 0;
    float music_total = 0;
    for (int i = 0; i < channels; i++) {
        float weight = 0.5f;
        int is_centre = 0;
        if (layout->order == AV_CHANNEL_ORDER_UNSPEC || channels == 1) {
            weight = 1.0f;
        } else {
            switch (av_channel_layout_channel_from_index(layout, (unsigned)i)) {
            case AV_CHAN_FRONT_LEFT:
            case AV_CHAN_FRONT_RIGHT:
                weight = 1.0f;
                break;
            case AV_CHAN_FRONT_CENTER:
                weight = 1.0f;
                is_centre = 1;
                break;
            case AV_CHAN_LOW_FREQUENCY:
            case AV_CHAN_LOW_FREQUENCY_2:
                weight = 0.0f;
                break;
            case AV_CHAN_SIDE_LEFT:
            case AV_CHAN_SIDE_RIGHT:
            case AV_CHAN_BACK_LEFT:
            case AV_CHAN_BACK_RIGHT:
            case AV_CHAN_BACK_CENTER:
            case AV_CHAN_FRONT_LEFT_OF_CENTER:
            case AV_CHAN_FRONT_RIGHT_OF_CENTER:
            case AV_CHAN_WIDE_LEFT:
            case AV_CHAN_WIDE_RIGHT:
            case AV_CHAN_SURROUND_DIRECT_LEFT:
            case AV_CHAN_SURROUND_DIRECT_RIGHT:
                weight = 0.7f;
                break;
            default:
                weight = 0.5f;
                break;
            }
        }
        clip->mix_weights[i] = weight;
        clip->music_weights[i] = is_centre ? 0.0f : weight;
        if (is_centre) has_centre = 1;
        mix_total += weight;
        music_total += clip->music_weights[i];
    }
    av_channel_layout_uninit(&usual);
    // A centre channel on its own, or with only low frequencies beside it,
    // leaves nothing for the music mix.
    if (music_total <= 0) has_centre = 0;
    if (mix_total <= 0) return VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
    for (int i = 0; i < channels; i++) {
        clip->mix_weights[i] /= mix_total;
        clip->music_weights[i] = has_centre ? clip->music_weights[i] / music_total : 0.0f;
    }
    clip->channels = channels;
    clip->has_centre = has_centre;
    return VIVID_AUDIO_CLIP_OK;
}

static int open_decoder(VividAudioClip *clip) {
    AVCodecContext *decoder = avcodec_alloc_context3(clip->codec);
    if (decoder == NULL) return VIVID_AUDIO_CLIP_ERROR_MEMORY;
    if (avcodec_parameters_to_context(decoder, clip->stream->codecpar) < 0) {
        avcodec_free_context(&decoder);
        return VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
    }
    // One thread: this must never compete with the film's own decoders.
    decoder->thread_count = 1;
    decoder->thread_type = 0;
    decoder->pkt_timebase = clip->stream->time_base;
    // Floats come out of most decoders anyway, and the resampler takes
    // whatever does.
    decoder->request_sample_fmt = AV_SAMPLE_FMT_FLTP;
    // The log is shared with the film's player. What this decoder says
    // about a damaged frame is no business of the film's.
    decoder->log_level_offset = DECODER_LOG_LEVEL_OFFSET;
    AVDictionary *settings = NULL;
    if (av_dict_set(&settings, "codec_whitelist", ALLOWED_DECODERS, 0) < 0) {
        av_dict_free(&settings);
        avcodec_free_context(&decoder);
        return VIVID_AUDIO_CLIP_ERROR_MEMORY;
    }
    int opened = avcodec_open2(decoder, clip->codec, &settings);
    av_dict_free(&settings);
    if (opened < 0) {
        avcodec_free_context(&decoder);
        return opened == AVERROR(ENOMEM) ? VIVID_AUDIO_CLIP_ERROR_MEMORY : VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
    }
    clip->decoder = decoder;
    return VIVID_AUDIO_CLIP_OK;
}

static void release_resampler(VividAudioClip *clip) {
    swr_free(&clip->resampler);
    av_channel_layout_uninit(&clip->resampler_layout);
    clip->resampler_rate = 0;
    clip->resampler_format = AV_SAMPLE_FMT_NONE;
}

/// A resampler from the frame's layout, rate and sample format to planar
/// floats at 48 kHz in the same layout. Made again only when one of those
/// changes.
static int prepare_resampler(VividAudioClip *clip, const AVFrame *frame) {
    if (clip->resampler != NULL && clip->resampler_rate == frame->sample_rate && clip->resampler_format == frame->format
        && av_channel_layout_compare(&clip->resampler_layout, &frame->ch_layout) == 0) {
        return VIVID_AUDIO_CLIP_OK;
    }
    if (frame->sample_rate < MIN_SOURCE_RATE || frame->sample_rate > MAX_SOURCE_RATE) return VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
    if (av_channel_layout_check(&frame->ch_layout) == 0) return VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
    // Converted sound waiting to be handed out is in the old layout.
    if (clip->pending_count > 0 && frame->ch_layout.nb_channels != clip->channels) return VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
    int weighted = set_weights(clip, &frame->ch_layout);
    if (weighted != VIVID_AUDIO_CLIP_OK) return weighted;

    release_resampler(clip);
    SwrContext *resampler = NULL;
    int made = swr_alloc_set_opts2(&resampler, &frame->ch_layout, AV_SAMPLE_FMT_FLTP, VIVID_AUDIO_CLIP_SAMPLE_RATE,
                                   &frame->ch_layout, (enum AVSampleFormat)frame->format, frame->sample_rate, 0, NULL);
    if (made < 0 || resampler == NULL) {
        swr_free(&resampler);
        return made == AVERROR(ENOMEM) ? VIVID_AUDIO_CLIP_ERROR_MEMORY : VIVID_AUDIO_CLIP_ERROR_RESAMPLE;
    }
    // Channels pass through as they are: the layout in and out is the
    // same. Mixing happens afterwards, with this shim's own weights.
    if (swr_init(resampler) < 0) {
        swr_free(&resampler);
        return VIVID_AUDIO_CLIP_ERROR_RESAMPLE;
    }
    if (av_channel_layout_copy(&clip->resampler_layout, &frame->ch_layout) < 0) {
        swr_free(&resampler);
        return VIVID_AUDIO_CLIP_ERROR_MEMORY;
    }
    clip->resampler = resampler;
    clip->resampler_rate = frame->sample_rate;
    clip->resampler_format = frame->format;
    return VIVID_AUDIO_CLIP_OK;
}

/// Room for `extra` more pending samples in every channel.
static int reserve_pending(VividAudioClip *clip, int extra) {
    if (extra < 0) return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;
    if (clip->pending_count > INT_MAX - extra) return VIVID_AUDIO_CLIP_ERROR_MEMORY;
    int needed = clip->pending_count + extra;
    // Only the stream's own channels get room: stereo needs two, not the
    // most a stream may have.
    for (int c = 0; c < clip->channels; c++) {
        if (needed <= clip->plane_capacity[c]) continue;
        int capacity = clip->plane_capacity[c] > 0 ? clip->plane_capacity[c] : 4096;
        while (capacity < needed) {
            if (capacity > INT_MAX / 2) return VIVID_AUDIO_CLIP_ERROR_MEMORY;
            capacity *= 2;
        }
        float *grown = realloc(clip->pending[c], (size_t)capacity * sizeof(float));
        if (grown == NULL) return VIVID_AUDIO_CLIP_ERROR_MEMORY;
        clip->pending[c] = grown;
        clip->plane_capacity[c] = capacity;
    }
    return VIVID_AUDIO_CLIP_OK;
}

/// Drops the first `count` pending samples, moving the cursor on.
static void drop_pending(VividAudioClip *clip, int count) {
    if (count <= 0) return;
    if (count >= clip->pending_count) {
        clip->cursor_seconds += (double)clip->pending_count / VIVID_AUDIO_CLIP_SAMPLE_RATE;
        clip->pending_count = 0;
        return;
    }
    int left = clip->pending_count - count;
    for (int c = 0; c < clip->channels; c++) {
        memmove(clip->pending[c], clip->pending[c] + count, (size_t)left * sizeof(float));
    }
    clip->pending_count = left;
    clip->cursor_seconds += (double)count / VIVID_AUDIO_CLIP_SAMPLE_RATE;
}

static void forget_position(VividAudioClip *clip) {
    clip->pending_count = 0;
    clip->has_cursor = 0;
    clip->cursor_seconds = 0;
    clip->can_continue = 0;
    clip->at_end = 0;
}

/// When a frame's first sample plays, on the player's clock, or NAN when
/// the frame doesn't say.
static double frame_seconds(const VividAudioClip *clip, const AVFrame *frame) {
    int64_t time = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp : frame->pts;
    if (time == AV_NOPTS_VALUE) return NAN;
    double seconds = (double)time * av_q2d(clip->stream->time_base) - (double)clip->container_start / (double)AV_TIME_BASE;
    return isfinite(seconds) ? seconds : NAN;
}

/// Converts a decoded frame, or with null whatever the resampler still
/// holds, and adds it to the pending sound.
static int convert_into_pending(VividAudioClip *clip, const AVFrame *frame) {
    if (clip->resampler == NULL) return VIVID_AUDIO_CLIP_OK;
    int room = swr_get_out_samples(clip->resampler, frame != NULL ? frame->nb_samples : 0);
    if (room < 0) return VIVID_AUDIO_CLIP_ERROR_RESAMPLE;
    if (room == 0) return VIVID_AUDIO_CLIP_OK;
    int reserved = reserve_pending(clip, room);
    if (reserved != VIVID_AUDIO_CLIP_OK) return reserved;
    uint8_t *outputs[MAX_CHANNELS];
    for (int c = 0; c < clip->channels; c++) {
        outputs[c] = (uint8_t *)(clip->pending[c] + clip->pending_count);
    }
    const uint8_t **inputs = frame != NULL ? (const uint8_t **)frame->extended_data : NULL;
    int converted = swr_convert(clip->resampler, outputs, room, inputs, frame != NULL ? frame->nb_samples : 0);
    if (converted < 0) return VIVID_AUDIO_CLIP_ERROR_RESAMPLE;
    clip->pending_count += converted;
    return VIVID_AUDIO_CLIP_OK;
}

/// Takes in one decoded frame: frames wholly before `start` are skipped
/// before conversion, and the converted sound is trimmed to start there.
static int take_frame(VividAudioClip *clip, const AVFrame *frame, double start) {
    if (frame->nb_samples <= 0 || frame->sample_rate <= 0) return VIVID_AUDIO_CLIP_OK;
    double time = frame_seconds(clip, frame);
    if (!clip->has_cursor) {
        // Until something has been kept, a frame that ends before the clip
        // starts is skipped, and a frame without a time can't be placed.
        if (!isfinite(time)) return VIVID_AUDIO_CLIP_OK;
        double end = time + (double)frame->nb_samples / frame->sample_rate;
        if (end <= start) return VIVID_AUDIO_CLIP_OK;
    }
    int prepared = prepare_resampler(clip, frame);
    if (prepared != VIVID_AUDIO_CLIP_OK) return prepared;
    if (!clip->has_cursor) {
        clip->cursor_seconds = time;
        clip->has_cursor = 1;
    }
    int converted = convert_into_pending(clip, frame);
    if (converted != VIVID_AUDIO_CLIP_OK) return converted;
    // Sound from before the clip's start is dropped as it arrives.
    if (clip->cursor_seconds < start) {
        double early = (start - clip->cursor_seconds) * VIVID_AUDIO_CLIP_SAMPLE_RATE;
        int drop = early >= (double)clip->pending_count ? clip->pending_count : (int)llround(early);
        drop_pending(clip, drop);
    }
    return VIVID_AUDIO_CLIP_OK;
}

/// Decodes until at least `wanted` samples are pending or the file ends.
static int fill_pending(VividAudioClip *clip, double start, int wanted) {
    int packets = 0;
    while (clip->pending_count < wanted && !clip->at_end) {
        int received = avcodec_receive_frame(clip->decoder, clip->frame);
        if (received == 0) {
            // A damaged frame is skipped, not mixed in.
            int damaged = (clip->frame->flags & AV_FRAME_FLAG_CORRUPT) != 0 || clip->frame->decode_error_flags != 0;
            int taken = damaged ? VIVID_AUDIO_CLIP_OK : take_frame(clip, clip->frame, start);
            av_frame_unref(clip->frame);
            if (taken != VIVID_AUDIO_CLIP_OK) return taken;
            continue;
        }
        if (received == AVERROR_EOF) {
            // Whatever the resampler still holds is the last of it.
            int flushed = convert_into_pending(clip, NULL);
            if (flushed != VIVID_AUDIO_CLIP_OK) return flushed;
            clip->at_end = 1;
            break;
        }
        if (received != AVERROR(EAGAIN)) return VIVID_AUDIO_CLIP_ERROR_DECODE;

        if (++packets > MAX_PACKETS_PER_CLIP) return VIVID_AUDIO_CLIP_ERROR_DATA;
        int read = av_read_frame(clip->format, clip->packet);
        if (read < 0) {
            int reason = stop_reason(clip, VIVID_AUDIO_CLIP_ERROR_OVER_BYTE_LIMIT, VIVID_AUDIO_CLIP_OK);
            if (reason != VIVID_AUDIO_CLIP_OK) return reason;
            // The end of the file: let the decoder hand over what it holds.
            if (avcodec_send_packet(clip->decoder, NULL) < 0) clip->at_end = 1;
            continue;
        }
        // Packets marked to be discarded still go to the decoder, which
        // needs them to start up and drops their sound itself.
        if (clip->packet->stream_index != clip->stream->index || (clip->packet->flags & AV_PKT_FLAG_CORRUPT)
            || clip->packet->size <= 0) {
            av_packet_unref(clip->packet);
            continue;
        }
        int sent = avcodec_send_packet(clip->decoder, clip->packet);
        av_packet_unref(clip->packet);
        // A packet the decoder can't take is damaged. The ones after it
        // usually aren't.
        if (sent < 0 && sent != AVERROR(EAGAIN)) {
            if (sent == AVERROR(ENOMEM)) return VIVID_AUDIO_CLIP_ERROR_MEMORY;
            continue;
        }
    }
    return VIVID_AUDIO_CLIP_OK;
}

/// Moves the demuxer to just before `start` and forgets everything held.
static int seek_to(VividAudioClip *clip, double start) {
    forget_position(clip);
    avcodec_flush_buffers(clip->decoder);
    release_resampler(clip);
    double target = (double)clip->container_start / (double)AV_TIME_BASE + start - PREROLL_SECONDS;
    double ticks = target * (double)AV_TIME_BASE;
    if (!isfinite(ticks) || ticks > (double)(INT64_MAX / 2) || ticks < (double)(INT64_MIN / 2)) {
        return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;
    }
    int64_t timestamp = (int64_t)llround(ticks);
    // At or before the time, from the container's index of keyframes.
    // Sound before the time is decoded and dropped.
    int sought = avformat_seek_file(clip->format, -1, INT64_MIN, timestamp, timestamp, 0);
    if (sought < 0) {
        int reason = stop_reason(clip, VIVID_AUDIO_CLIP_ERROR_OVER_BYTE_LIMIT, VIVID_AUDIO_CLIP_OK);
        if (reason != VIVID_AUDIO_CLIP_OK) return reason;
        // Nothing at or before the time, as when it falls before the first
        // keyframe of the index: the first place after it will do, and the
        // clip says where it really starts.
        sought = avformat_seek_file(clip->format, -1, INT64_MIN, timestamp, INT64_MAX, 0);
        if (sought < 0) {
            reason = stop_reason(clip, VIVID_AUDIO_CLIP_ERROR_OVER_BYTE_LIMIT, VIVID_AUDIO_CLIP_ERROR_SEEK);
            return reason;
        }
    }
    return VIVID_AUDIO_CLIP_OK;
}

static void release_pending(VividAudioClip *clip) {
    for (int c = 0; c < MAX_CHANNELS; c++) {
        free(clip->pending[c]);
        clip->pending[c] = NULL;
        clip->plane_capacity[c] = 0;
    }
    clip->pending_count = 0;
}

int vivid_audio_clip_open(const VividAudioClipCallbacks *callbacks, int64_t max_open_bytes, int stream_index,
                          VividAudioClip **out_handle) {
    if (out_handle == NULL) return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;
    *out_handle = NULL;
    if (callbacks == NULL || callbacks->read == NULL) return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;

    VividAudioClip *clip = calloc(1, sizeof(VividAudioClip));
    if (clip == NULL) return VIVID_AUDIO_CLIP_ERROR_MEMORY;
    clip->callbacks = *callbacks;
    clip->container_start = AV_NOPTS_VALUE;
    clip->resampler_format = AV_SAMPLE_FMT_NONE;
    int64_t open_limit = OPEN_BYTE_LIMIT;
    if (max_open_bytes > 0 && max_open_bytes < OPEN_BYTE_LIMIT) open_limit = max_open_bytes;
    begin_call(clip, open_limit);

    int result = VIVID_AUDIO_CLIP_ERROR_MEMORY;
    AVDictionary *settings = NULL;
    const AVInputFormat *kind = NULL;
    int is_matroska = 0;

    clip->packet = av_packet_alloc();
    clip->frame = av_frame_alloc();
    if (clip->packet == NULL || clip->frame == NULL) goto fail;

    result = recognise(clip, &kind, &is_matroska);
    if (result != VIVID_AUDIO_CLIP_OK) goto fail;
    result = VIVID_AUDIO_CLIP_ERROR_MEMORY;

    // Everything that can fail for want of memory comes before the demuxer
    // is given the reader, so no failure leaves the two half joined.
    if (av_dict_set(&settings, "format_whitelist", ALLOWED_FORMATS, 0) < 0) goto fail;
    if (av_dict_set(&settings, "codec_whitelist", ALLOWED_DECODERS, 0) < 0) goto fail;
    // MP4 can name other files to take its samples from. Off is the
    // default, and it is said here so it stays off.
    if (!is_matroska && av_dict_set(&settings, "enable_drefs", "0", 0) < 0) goto fail;

    uint8_t *buffer = av_malloc(IO_BUFFER_BYTES);
    if (buffer == NULL) goto fail;
    clip->io = avio_alloc_context(buffer, IO_BUFFER_BYTES, 0, clip, io_read, NULL, io_seek);
    if (clip->io == NULL) {
        av_free(buffer);
        goto fail;
    }

    clip->format = avformat_alloc_context();
    if (clip->format == NULL) goto fail;
    // The reader belongs to this handle. Marked as such in the same breath
    // as it is handed over, so closing the demuxer never closes it too.
    clip->format->pb = clip->io;
    clip->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    clip->format->io_open = refuse_to_open;
    clip->format->interrupt_callback.callback = interrupt_callback;
    clip->format->interrupt_callback.opaque = clip;

    // On failure this frees the context it was given and clears the pointer.
    int opened = avformat_open_input(&clip->format, NULL, kind, &settings);
    av_dict_free(&settings);
    if (opened < 0) {
        result = stop_reason(clip, VIVID_AUDIO_CLIP_ERROR_OPEN_TOO_COSTLY, VIVID_AUDIO_CLIP_ERROR_OPEN);
        goto fail;
    }

    clip->stream = pick_sound_stream(clip->format, stream_index);
    if (clip->stream == NULL) {
        result = VIVID_AUDIO_CLIP_ERROR_NO_AUDIO;
        goto fail;
    }
    AVRational base = clip->stream->time_base;
    if (base.num <= 0 || base.den <= 0) {
        result = VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
        goto fail;
    }
    clip->codec = allowed_decoder(clip->stream->codecpar->codec_id);
    if (clip->codec == NULL) {
        result = VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
        goto fail;
    }
    int channels = clip->stream->codecpar->ch_layout.nb_channels;
    if (channels > MAX_CHANNELS) {
        result = VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
        goto fail;
    }

    // Only picture and sound packets are read while learning when the file
    // starts. After that, only the chosen sound stream's.
    for (unsigned i = 0; i < clip->format->nb_streams; i++) {
        AVStream *other = clip->format->streams[i];
        if (other != clip->stream && !is_sound_stream(other) && !is_picture_stream(other)) other->discard = AVDISCARD_ALL;
    }
    result = learn_container_start(clip);
    for (unsigned i = 0; i < clip->format->nb_streams; i++) {
        if (clip->format->streams[i] != clip->stream) clip->format->streams[i]->discard = AVDISCARD_ALL;
    }
    if (result != VIVID_AUDIO_CLIP_OK) goto fail;

    result = open_decoder(clip);
    if (result != VIVID_AUDIO_CLIP_OK) goto fail;
    if (clip->decoder->ch_layout.nb_channels > MAX_CHANNELS) {
        result = VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
        goto fail;
    }
    // The header's layout, where it gives one, for `has_centre`. Decoded
    // frames have the final say.
    const AVChannelLayout *layout = &clip->decoder->ch_layout;
    if (layout->nb_channels <= 0) layout = &clip->stream->codecpar->ch_layout;
    if (layout->nb_channels > 0 && set_weights(clip, layout) != VIVID_AUDIO_CLIP_OK) {
        result = VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED;
        goto fail;
    }

    VividAudioClipInfo *info = &clip->info;
    info->stream_index = clip->stream->index;
    info->channels = layout->nb_channels > 0 ? layout->nb_channels : 0;
    info->sample_rate = clip->decoder->sample_rate > 0 ? clip->decoder->sample_rate : clip->stream->codecpar->sample_rate;
    info->has_centre = clip->has_centre;
    info->container_start_seconds = (double)clip->container_start / (double)AV_TIME_BASE;
    if (clip->format->duration != AV_NOPTS_VALUE && clip->format->duration > 0) {
        info->duration_seconds = (double)clip->format->duration / (double)AV_TIME_BASE;
    } else if (clip->stream->duration != AV_NOPTS_VALUE && clip->stream->duration > 0) {
        info->duration_seconds = (double)clip->stream->duration * av_q2d(base);
    }

    *out_handle = clip;
    return VIVID_AUDIO_CLIP_OK;

fail:
    av_dict_free(&settings);
    vivid_audio_clip_close(clip);
    return result;
}

void vivid_audio_clip_close(VividAudioClip *clip) {
    if (clip == NULL) return;
    release_resampler(clip);
    avcodec_free_context(&clip->decoder);
    avformat_close_input(&clip->format);
    if (clip->io != NULL) {
        av_freep(&clip->io->buffer);
        avio_context_free(&clip->io);
    }
    av_packet_free(&clip->packet);
    av_frame_free(&clip->frame);
    release_pending(clip);
    free(clip);
}

int vivid_audio_clip_get_info(const VividAudioClip *clip, VividAudioClipInfo *out_info) {
    if (clip == NULL || out_info == NULL) return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;
    *out_info = clip->info;
    return VIVID_AUDIO_CLIP_OK;
}

const char *vivid_audio_clip_codec_name(const VividAudioClip *clip) {
    if (clip == NULL || clip->codec == NULL || clip->codec->name == NULL) return "";
    return clip->codec->name;
}

int vivid_audio_clip_read(VividAudioClip *clip, double start_seconds, double duration_seconds, int64_t max_read_bytes,
                          VividAudioClipSamples *out_samples) {
    if (out_samples != NULL) memset(out_samples, 0, sizeof(*out_samples));
    if (clip == NULL || out_samples == NULL || clip->decoder == NULL) return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;
    if (!isfinite(start_seconds) || start_seconds < 0) return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;
    if (!isfinite(duration_seconds) || duration_seconds <= 0 || duration_seconds > MAX_CLIP_SECONDS) {
        return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;
    }
    int64_t limit = CLIP_BYTE_LIMIT;
    if (max_read_bytes > 0 && max_read_bytes < CLIP_BYTE_LIMIT) limit = max_read_bytes;
    begin_call(clip, limit);

    int wanted = (int)llround(duration_seconds * VIVID_AUDIO_CLIP_SAMPLE_RATE);
    if (wanted <= 0) return VIVID_AUDIO_CLIP_ERROR_ARGUMENT;

    int carries_on = clip->can_continue && fabs(start_seconds - clip->next_seconds) <= CONTINUE_TOLERANCE_SECONDS;
    if (!carries_on) {
        int sought = seek_to(clip, start_seconds);
        if (sought != VIVID_AUDIO_CLIP_OK) return sought;
    }

    int filled = fill_pending(clip, start_seconds, wanted);
    if (filled != VIVID_AUDIO_CLIP_OK) {
        // What was decoded can't be trusted to line up with a later call.
        forget_position(clip);
        return filled;
    }
    int count = clip->pending_count < wanted ? clip->pending_count : wanted;
    if (count <= 0 || !clip->has_cursor) {
        forget_position(clip);
        return VIVID_AUDIO_CLIP_ERROR_DATA;
    }

    float *mix = malloc((size_t)count * sizeof(float));
    float *music = clip->has_centre ? malloc((size_t)count * sizeof(float)) : NULL;
    if (mix == NULL || (clip->has_centre && music == NULL)) {
        free(mix);
        free(music);
        return VIVID_AUDIO_CLIP_ERROR_MEMORY;
    }
    for (int i = 0; i < count; i++) {
        float sum = 0;
        float music_sum = 0;
        for (int c = 0; c < clip->channels; c++) {
            float sample = clip->pending[c][i];
            if (!isfinite(sample)) sample = 0;
            sum += sample * clip->mix_weights[c];
            music_sum += sample * clip->music_weights[c];
        }
        mix[i] = sum;
        if (music != NULL) music[i] = music_sum;
    }

    out_samples->mix = mix;
    out_samples->music = music;
    out_samples->count = count;
    out_samples->start_seconds = clip->cursor_seconds;
    drop_pending(clip, count);
    clip->next_seconds = clip->cursor_seconds;
    // A clip cut short by the end of the file can't be carried on.
    clip->can_continue = count == wanted;
    return VIVID_AUDIO_CLIP_OK;
}

void vivid_audio_clip_samples_free(VividAudioClipSamples *samples) {
    if (samples == NULL) return;
    free(samples->mix);
    free(samples->music);
    memset(samples, 0, sizeof(*samples));
}
