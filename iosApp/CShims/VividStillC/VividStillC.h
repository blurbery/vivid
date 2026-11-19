#ifndef VIVID_STILL_C_H
#define VIVID_STILL_C_H

#include <stdint.h>

/// Reads single keyframes out of a media file for scrub previews.
///
/// Every byte comes through the caller's callbacks, so nothing here opens a
/// file or a socket. A handle holds one demuxer and, while stills are being
/// made, one single-threaded software decoder.
///
/// Only Matroska and MP4 files are read, and only H.264, HEVC, VP9, MPEG-2
/// and AV1 video is decoded. No other decoder is ever made: opening a file
/// reads its header, its keyframe index and its first video packet, and
/// leaves every other stream alone.
///
/// Threading: a handle is not locked. Call its functions from one thread at
/// a time. The callbacks run on the thread that made the call. Only the
/// `aborted` callback's answer may change from another thread.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VividStill VividStill;

/// Results. Zero is success, everything else is negative.
enum {
    VIVID_STILL_OK = 0,
    VIVID_STILL_ERROR_ARGUMENT = -1,
    VIVID_STILL_ERROR_MEMORY = -2,
    /// The bytes aren't a Matroska or MP4 file that could be read.
    VIVID_STILL_ERROR_OPEN = -3,
    VIVID_STILL_ERROR_NO_VIDEO = -4,
    /// A codec outside the list above, a decoder that refuses the stream,
    /// or a pixel layout that can't be turned into a picture.
    VIVID_STILL_ERROR_UNSUPPORTED = -5,
    /// No keyframe sits at or before the time asked for.
    VIVID_STILL_ERROR_SEEK = -6,
    /// The read callback failed. Nothing is wrong with the file as far as
    /// is known, so the same call may work later.
    VIVID_STILL_ERROR_READ = -7,
    VIVID_STILL_ERROR_DECODE = -8,
    VIVID_STILL_ERROR_SCALE = -9,
    /// The `aborted` callback said stop. The handle is still usable.
    VIVID_STILL_ERROR_ABORTED = -10,
    /// The time resolves to the last keyframe of a Matroska index, which
    /// the demuxer can only reach by reading on to the end of the file.
    /// Refused before anything is read.
    VIVID_STILL_ERROR_LAST_CUE = -11,
    /// The picture has more pixels than the handle allows.
    VIVID_STILL_ERROR_TOO_LARGE = -12,
    /// Opening needed more than `max_open_bytes`.
    VIVID_STILL_ERROR_OPEN_TOO_COSTLY = -13,
    /// The still needed more than `max_read_bytes`.
    VIVID_STILL_ERROR_OVER_BYTE_LIMIT = -14,
    /// The container has no keyframe index, so nothing can be found
    /// without reading through the file.
    VIVID_STILL_ERROR_NO_INDEX = -15,
    /// The keyframe's bytes are missing or damaged: the file ends early,
    /// or what the index points at isn't a whole keyframe.
    VIVID_STILL_ERROR_DATA = -16,
};

/// Copies up to `size` bytes at `offset` into `buffer`. Returns how many
/// were copied (fewer than asked is fine), 0 at the end of the file, or a
/// negative number on failure.
typedef int (*VividStillReadCallback)(void *context, uint8_t *buffer, int size, int64_t offset);
/// The file's length in bytes, or a negative number when it isn't known.
typedef int64_t (*VividStillSizeCallback)(void *context);
/// Non-zero once the current call should give up.
typedef int (*VividStillAbortedCallback)(void *context);

typedef struct VividStillCallbacks {
    void *context;
    VividStillReadCallback read;
    /// May be null.
    VividStillSizeCallback size;
    /// May be null.
    VividStillAbortedCallback aborted;
} VividStillCallbacks;

typedef struct VividStillOpenOptions {
    /// The most the open may read before it fails with
    /// `VIVID_STILL_ERROR_OPEN_TOO_COSTLY`. Zero or less, or anything above
    /// it, means the built-in ceiling of 64 MiB.
    int64_t max_open_bytes;
    /// The largest picture, as width times height, a decoder is made for.
    /// Zero or less, or anything above it, means the built-in ceiling of
    /// 7680 by 4320. Each side must also be between 8 and 16384.
    int64_t max_picture_pixels;
} VividStillOpenOptions;

enum {
    VIVID_STILL_TRANSFER_UNKNOWN = 0,
    VIVID_STILL_TRANSFER_SDR = 1,
    VIVID_STILL_TRANSFER_PQ = 2,
    VIVID_STILL_TRANSFER_HLG = 3,
};

enum {
    VIVID_STILL_PRIMARIES_UNKNOWN = 0,
    VIVID_STILL_PRIMARIES_BT709 = 1,
    VIVID_STILL_PRIMARIES_BT601 = 2,
    VIVID_STILL_PRIMARIES_BT2020 = 3,
    VIVID_STILL_PRIMARIES_P3 = 4,
};

enum {
    VIVID_STILL_MATRIX_UNKNOWN = 0,
    VIVID_STILL_MATRIX_BT709 = 1,
    VIVID_STILL_MATRIX_BT601 = 2,
    VIVID_STILL_MATRIX_BT2020 = 3,
    VIVID_STILL_MATRIX_OTHER = 4,
};

enum {
    VIVID_STILL_RANGE_UNKNOWN = 0,
    VIVID_STILL_RANGE_LIMITED = 1,
    VIVID_STILL_RANGE_FULL = 2,
};

/// What the container, the decoder and the first keyframe say about the
/// video stream.
typedef struct VividStillInfo {
    /// 0 when the container doesn't say.
    double duration_seconds;
    /// The first video packet's time. Still and index times count from it.
    double start_seconds;
    /// How long after the container's start the first video packet comes,
    /// for a player whose clock counts from the container's start. 0 when
    /// the video starts first or the container doesn't say.
    double video_start_offset_seconds;
    int width;
    int height;
    /// Pixel shape, 1:1 when unknown.
    int sample_aspect_numerator;
    int sample_aspect_denominator;
    /// How far to turn the picture clockwise for display: 0, 90, 180 or 270.
    int rotation_degrees;
    /// 0 when unknown.
    int bit_depth;
    int transfer;
    int primaries;
    int matrix;
    int range;
    /// 0 when the stream carries no Dolby Vision configuration.
    int dolby_vision_profile;
    /// The base layer's compatibility id: 0 means it only makes sense with
    /// the Dolby Vision metadata applied.
    int dolby_vision_compatibility;
    /// Non-zero when the container's keyframe index covers the file.
    int has_index;
    int index_count;
    /// Non-zero when the last index entry can't be made into a still
    /// (Matroska): asking for it gives `VIVID_STILL_ERROR_LAST_CUE`.
    int last_entry_is_unreadable;
} VividStillInfo;

typedef struct VividStillIndexEntry {
    /// When the keyframe is shown, in seconds from the start of the
    /// stream. Asking for a still at exactly this time gives this
    /// keyframe. Matroska records it. MP4 records decode times, so there
    /// it is the decode time plus the first keyframe's reorder delay:
    /// exact for the usual closed groups of pictures, and up to a few
    /// frames early for a keyframe with pictures shown before it.
    double time_seconds;
    int64_t byte_position;
    /// 0 when the container doesn't record it (Matroska).
    int size;
} VividStillIndexEntry;

enum {
    /// 16-bit RGBA for PQ and HLG pictures, 8-bit BGRA for the rest.
    VIVID_STILL_LAYOUT_AUTO = 0,
    /// Four bytes a pixel: blue, green, red, then a filled alpha byte.
    VIVID_STILL_LAYOUT_BGRA8 = 1,
    /// Four native-endian 16-bit values a pixel: red, green, blue, alpha.
    VIVID_STILL_LAYOUT_RGBA16 = 2,
};

typedef struct VividStillPicture {
    /// Owned by the picture: give it back with `vivid_still_picture_free`.
    uint8_t *pixels;
    int width;
    int height;
    /// Bytes from one row to the next.
    int stride;
    /// `VIVID_STILL_LAYOUT_BGRA8` or `VIVID_STILL_LAYOUT_RGBA16`.
    int layout;
    /// The picture's own time, in seconds from the start of the stream.
    double time_seconds;
    /// Which index entry this is.
    int index_position;
    int transfer;
    int primaries;
    /// The size of the keyframe's packet.
    int packet_bytes;
    /// How many packets went to the decoder: 1 unless the keyframe alone
    /// didn't give a picture.
    int packets_decoded;
} VividStillPicture;

/// Opens a file through the callbacks, picks its video stream and reads the
/// keyframe index. `options` may be null for the built-in limits. On
/// success `*out_handle` is set and must be closed with
/// `vivid_still_close`.
///
/// `VIVID_STILL_ERROR_READ`, `VIVID_STILL_ERROR_ABORTED` and
/// `VIVID_STILL_ERROR_MEMORY` say nothing about the file and can be tried
/// again. `VIVID_STILL_ERROR_ARGUMENT` is a mistake by the caller. Every
/// other failure is about the file itself.
int vivid_still_open(const VividStillCallbacks *callbacks, const VividStillOpenOptions *options, VividStill **out_handle);

/// Frees the handle. Null is ignored.
void vivid_still_close(VividStill *handle);

int vivid_still_get_info(const VividStill *handle, VividStillInfo *out_info);

/// The codec's short name, such as "hevc". Valid until the handle closes.
const char *vivid_still_codec_name(const VividStill *handle);

/// Keyframes in the container's index, in time order.
int vivid_still_index_count(const VividStill *handle);
int vivid_still_index_entry(const VividStill *handle, int position, VividStillIndexEntry *out_entry);

/// Which index entry a still at `seconds` would be: the last one at or
/// before that time. -1 when there is none. Reads nothing.
int vivid_still_index_position(const VividStill *handle, double seconds);

/// Decodes the keyframe at or before `seconds` (from the start of the
/// stream), scaled to square pixels no wider than `max_width` and never
/// enlarged. Reads only that keyframe's packet. On success fills
/// `out_picture`.
///
/// `max_read_bytes` caps what the call may read, failing with
/// `VIVID_STILL_ERROR_OVER_BYTE_LIMIT` beyond it. Zero or less leaves only
/// the built-in cap of 32 MiB. Where the index records the keyframe's size
/// (MP4), a keyframe over the cap is refused before anything is read.
int vivid_still_decode(VividStill *handle, double seconds, int max_width, int layout, int64_t max_read_bytes,
                       VividStillPicture *out_picture);

/// Frees a picture's pixels and clears it. Safe on a cleared picture.
void vivid_still_picture_free(VividStillPicture *picture);

/// Frees the decoder and scaler, keeping the demuxer and index. The next
/// `vivid_still_decode` makes them again. Returns 1 when there was a
/// decoder to free, otherwise 0.
int vivid_still_close_decoder(VividStill *handle);

#ifdef __cplusplus
}
#endif

#endif
