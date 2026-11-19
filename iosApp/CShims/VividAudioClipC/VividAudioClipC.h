#ifndef VIVID_AUDIO_CLIP_C_H
#define VIVID_AUDIO_CLIP_C_H

#include <stdint.h>

/// Decodes a few seconds of a media file's sound, for song identification.
///
/// Every byte comes through the caller's callbacks, so nothing here opens a
/// file or a socket. A handle holds one demuxer and one single-threaded
/// software decoder for one sound stream.
///
/// Only Matroska and MP4 files are read, and only common film and music
/// codecs are decoded (see `ALLOWED_DECODERS` in the source). The sound
/// comes back as 48 kHz mono floats in two mixes: every channel, and the
/// same without the centre channel, where films keep their dialogue.
///
/// Threading: a handle is not locked. Call its functions from one thread at
/// a time. The callbacks run on the thread that made the call. Only the
/// `aborted` callback's answer may change from another thread.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VividAudioClip VividAudioClip;

/// Results. Zero is success, everything else is negative.
enum {
    VIVID_AUDIO_CLIP_OK = 0,
    VIVID_AUDIO_CLIP_ERROR_ARGUMENT = -1,
    VIVID_AUDIO_CLIP_ERROR_MEMORY = -2,
    /// The bytes aren't a Matroska or MP4 file that could be read.
    VIVID_AUDIO_CLIP_ERROR_OPEN = -3,
    /// The file has no sound stream.
    VIVID_AUDIO_CLIP_ERROR_NO_AUDIO = -4,
    /// A codec outside the allowed list, a decoder that refuses the stream,
    /// or a channel layout that can't be mixed.
    VIVID_AUDIO_CLIP_ERROR_UNSUPPORTED = -5,
    /// The time asked for couldn't be found in the file.
    VIVID_AUDIO_CLIP_ERROR_SEEK = -6,
    /// The read callback failed. Nothing is wrong with the file as far as
    /// is known, so the same call may work later.
    VIVID_AUDIO_CLIP_ERROR_READ = -7,
    VIVID_AUDIO_CLIP_ERROR_DECODE = -8,
    VIVID_AUDIO_CLIP_ERROR_RESAMPLE = -9,
    /// The `aborted` callback said stop. The handle is still usable.
    VIVID_AUDIO_CLIP_ERROR_ABORTED = -10,
    /// Opening needed more than its byte limit.
    VIVID_AUDIO_CLIP_ERROR_OPEN_TOO_COSTLY = -13,
    /// The clip needed more than its byte limit.
    VIVID_AUDIO_CLIP_ERROR_OVER_BYTE_LIMIT = -14,
    /// No sound at all was found from the time asked for: the file ends
    /// there, or its sound stream has a gap.
    VIVID_AUDIO_CLIP_ERROR_DATA = -16,
};

/// Copies up to `size` bytes at `offset` into `buffer`. Returns how many
/// were copied (fewer than asked is fine), 0 at the end of the file, or a
/// negative number on failure.
typedef int (*VividAudioClipReadCallback)(void *context, uint8_t *buffer, int size, int64_t offset);
/// The file's length in bytes, or a negative number when it isn't known.
typedef int64_t (*VividAudioClipSizeCallback)(void *context);
/// Non-zero once the current call should give up.
typedef int (*VividAudioClipAbortedCallback)(void *context);

typedef struct VividAudioClipCallbacks {
    void *context;
    VividAudioClipReadCallback read;
    /// May be null.
    VividAudioClipSizeCallback size;
    /// May be null.
    VividAudioClipAbortedCallback aborted;
} VividAudioClipCallbacks;

/// The sample rate every clip comes back at.
#define VIVID_AUDIO_CLIP_SAMPLE_RATE 48000

/// What the file says about the sound stream that was picked.
typedef struct VividAudioClipInfo {
    /// The stream's index in the container, as FFmpeg and mpv's `ff-index`
    /// count them.
    int stream_index;
    int channels;
    /// The stream's own rate, before conversion to 48 kHz.
    int sample_rate;
    /// Non-zero when the header says the stream has a centre channel and
    /// other channels beside it. Some containers only give a channel count
    /// until the first frame is decoded, so a clip's `music` is the final
    /// word.
    int has_centre;
    /// When the container starts, in seconds of the file's own time. A
    /// player clock that counts from the container's start, as mpv's does,
    /// is this far behind the file's timestamps. Clip times are on the
    /// player's clock.
    double container_start_seconds;
    /// 0 when the container doesn't say.
    double duration_seconds;
} VividAudioClipInfo;

typedef struct VividAudioClipSamples {
    /// Every channel mixed to one, at `VIVID_AUDIO_CLIP_SAMPLE_RATE`.
    /// Owned by the samples: give them back with
    /// `vivid_audio_clip_samples_free`.
    float *mix;
    /// The same without the centre channel and the low-frequency channel,
    /// or null when the stream has no centre channel.
    float *music;
    /// Samples in each mix.
    int count;
    /// When the first sample plays, on the player's clock.
    double start_seconds;
} VividAudioClipSamples;

/// Opens a file through the callbacks and picks its sound stream:
/// `stream_index` when it is a sound stream, otherwise the stream the file
/// marks as the default sound, or failing that the first. Reads the header and
/// the first packets, to learn when the container starts.
///
/// `max_open_bytes` caps what the open may read. Zero or less, or anything
/// above it, means the built-in ceiling of 64 MiB.
///
/// `VIVID_AUDIO_CLIP_ERROR_READ`, `VIVID_AUDIO_CLIP_ERROR_ABORTED` and
/// `VIVID_AUDIO_CLIP_ERROR_MEMORY` say nothing about the file and can be
/// tried again. `VIVID_AUDIO_CLIP_ERROR_ARGUMENT` is a mistake by the
/// caller. Every other failure is about the file itself.
int vivid_audio_clip_open(const VividAudioClipCallbacks *callbacks, int64_t max_open_bytes, int stream_index,
                          VividAudioClip **out_handle);

/// Frees the handle. Null is ignored.
void vivid_audio_clip_close(VividAudioClip *handle);

int vivid_audio_clip_get_info(const VividAudioClip *handle, VividAudioClipInfo *out_info);

/// The codec's short name, such as "eac3". Valid until the handle closes.
const char *vivid_audio_clip_codec_name(const VividAudioClip *handle);

/// Decodes `duration_seconds` of sound starting at `start_seconds` on the
/// player's clock. A call that starts where the last one ended carries on
/// without seeking, so a clip can be lengthened a piece at a time.
///
/// Fewer samples than asked for come back when the file ends first.
/// `duration_seconds` is at most 30. `max_read_bytes` caps what the call
/// may read, failing with `VIVID_AUDIO_CLIP_ERROR_OVER_BYTE_LIMIT` beyond
/// it. Zero or less leaves only the built-in cap of 256 MiB.
int vivid_audio_clip_read(VividAudioClip *handle, double start_seconds, double duration_seconds, int64_t max_read_bytes,
                          VividAudioClipSamples *out_samples);

/// Frees a clip's samples and clears it. Safe on a cleared clip.
void vivid_audio_clip_samples_free(VividAudioClipSamples *samples);

#ifdef __cplusplus
}
#endif

#endif
