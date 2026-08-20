// MediaDemuxer.h — FFmpeg demux shim for the Player native stack.
//
// App-owned C API. NO FFmpeg headers, NO AV* types: this header only depends
// on <stdint.h>/<stddef.h>. That makes it safe to use directly as the Swift
// bridging header with zero build-setting changes, while the implementation
// (MediaDemuxer.c) links libavformat privately.
//
// Ownership rules:
//   - media_open() returns a handle you must release with media_close().
//   - media_read_packet() fills a MediaPacket whose ->data is malloc'd and
//     caller-owned; release it with media_packet_free().
//   - media_get_track() fills a caller-provided MediaTrack (no ownership).
//   - codec_name/language/title are NUL-terminated buffers inside MediaTrack;
//     read them via the media_track_*() accessors.

#ifndef MEDIADEMUXER_H
#define MEDIADEMUXER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque demuxer handle — the only type that crosses the boundary. The
   placeholder body (not a bare forward typedef) keeps the Clang importer
   from dropping the type when it's referenced through the bridging header.
   The implementation (MediaDemuxer.c) defines MEDIADEMUXER_IMPL before
   including this header, which suppresses the placeholder so the real
   struct body can be defined there. */
typedef struct MediaDemuxer MediaDemuxer;
#ifndef MEDIADEMUXER_IMPL
struct MediaDemuxer { int _placeholder; };
#endif

typedef enum {
    MEDIA_TRACK_TYPE_UNKNOWN = -1,
    MEDIA_TRACK_TYPE_VIDEO = 0,
    MEDIA_TRACK_TYPE_AUDIO = 1,
    MEDIA_TRACK_TYPE_SUBTITLE = 2,
    MEDIA_TRACK_TYPE_ATTACHMENT = 3
} MediaTrackType;

typedef struct MediaTrack {
    int id;
    int type;                /* MediaTrackType */
    int codec_id;            /* raw AVCodecID value (diagnostics only) */
    char codec_name[32];
    char language[8];
    char title[256];
    int channel_count;
    int sample_rate;
    int time_base_num;       /* stream time base: pts/dts/duration are in these units */
    int time_base_den;
    int is_default;
    int is_forced;
} MediaTrack;

typedef struct MediaPacket {
    int64_t stream_id;
    int64_t pts;             /* stream time base; Int64.min (AV_NOPTS_VALUE) if unknown */
    int64_t dts;
    int64_t duration;        /* stream time base */
    uint8_t *data;           /* malloc'd, caller-owned; free via media_packet_free() */
    size_t size;
    int keyframe;
} MediaPacket;

/* Result codes. */
enum {
    MEDIA_RESULT_ERROR = -1,
    MEDIA_RESULT_OK = 0,
    MEDIA_RESULT_EOF = 1
};

/* Open a media file. Returns NULL on failure. */
MediaDemuxer *media_open(const char *path);

/* Container duration in milliseconds, or -1 if unknown. */
int64_t media_get_duration(MediaDemuxer *d);

/* Number of tracks (streams) in the container. */
int media_get_track_count(MediaDemuxer *d);

/* Fill *out with track `index` metadata. Returns MEDIA_RESULT_OK/ERROR. */
int media_get_track(MediaDemuxer *d, int index, MediaTrack *out);

/* Borrow `index` stream's codec extradata (e.g. the avcC record for H.264 in
   MKV). On success *buf and *size are set; the pointer is owned by the
   demuxer and stays valid until media_close(). Returns MEDIA_RESULT_OK/ERROR. */
int media_get_track_extradata(MediaDemuxer *d, int index, const uint8_t **buf, size_t *size);

/* Video stream coded dimensions from the codec parameters (0 if not video). */
int media_get_track_width(MediaDemuxer *d, int index);
int media_get_track_height(MediaDemuxer *d, int index);

/* Next packet. Returns MEDIA_RESULT_OK, MEDIA_RESULT_EOF, or MEDIA_RESULT_ERROR. */
int media_read_packet(MediaDemuxer *d, MediaPacket *out);

/* Release a MediaPacket's data buffer. */
void media_packet_free(MediaPacket *p);

/* Seek to `seconds` (backward, keyframe granularity). Returns OK/ERROR. */
int media_seek(MediaDemuxer *d, double seconds);

/* Close and free the demuxer. */
void media_close(MediaDemuxer *d);

/* String accessors (point into the MediaTrack's own buffers). */
const char *media_track_codec_name(const MediaTrack *t);
const char *media_track_language(const MediaTrack *t);
const char *media_track_title(const MediaTrack *t);

/* Zero a MediaTrack/MediaPacket before passing it to a media_* function
   (Swift can't default-init imported C structs). media_track_make returns a
   zeroed struct by value — the preferred form from Swift. */
MediaTrack media_track_make(void);
MediaPacket media_packet_make(void);
void media_track_zero(MediaTrack *t);
void media_packet_zero(MediaPacket *p);

/* ---- chapters (Matroska) ---- */

/* Number of chapters in the container (0 when none). */
int media_get_chapter_count(MediaDemuxer *d);

/* Chapter `index`: start time in milliseconds and title (NUL-terminated
   buffer). Returns MEDIA_RESULT_OK/ERROR. */
int media_get_chapter(MediaDemuxer *d, int index,
                      int64_t *start_ms, char *title, size_t title_size);

/* Channel layout of audio track `index`. mask = FFmpeg AV_CHANNEL_LAYOUT_*
   mask (valid only when the layout order is native), name = describe string
   (e.g. "5.1(side)"). Returns MEDIA_RESULT_OK/ERROR; non-audio tracks fail. */
int media_get_track_channel_layout(MediaDemuxer *d, int index,
                                   uint64_t *mask, char *name, size_t name_size);

/* ---- audio decode (libavcodec) ---- */

/* Decoded PCM frame: interleaved float32, caller-owned. */
typedef struct MediaAudioFrame {
    float *data;          /* interleaved, nb_samples * channels floats */
    int nb_samples;       /* per channel */
    int channels;
    int sample_rate;
    uint64_t layout_mask; /* native-order mask, 0 if not native */
    char layout_name[64]; /* e.g. "5.1(side)" */
    char sample_fmt[16];  /* source sample format name, e.g. "fltp" */
} MediaAudioFrame;

/* Decode audio track `index` from the current demux position until
   `max_samples` samples per channel are produced (or EOF/error). The demuxer
   is advanced; call media_seek() first to rewind. Returns MEDIA_RESULT_OK and
   fills *out (caller frees via media_audio_frame_free), MEDIA_RESULT_EOF if no
   frame could be decoded, or MEDIA_RESULT_ERROR. */
int media_decode_audio(MediaDemuxer *d, int index, int max_samples,
                       MediaAudioFrame *out);

/* Release a MediaAudioFrame's data buffer. */
void media_audio_frame_free(MediaAudioFrame *f);

/* String accessors for a MediaAudioFrame (char[] fields import as tuples
   into Swift — read them through these instead). */
const char *media_audio_frame_layout_name(const MediaAudioFrame *f);
const char *media_audio_frame_sample_fmt(const MediaAudioFrame *f);

/* ---- streaming audio decoder (for continuous playback) ---- */

/* Opaque incremental decoder for one audio stream. Feed it packets from the
   shared demuxer (media_read_packet, filtered to the stream); it outputs PCM
   frames. Owns its own AVCodecContext. Placeholder body keeps the type from
   being dropped by the Clang importer (see MediaDemuxer); suppressed by
   MEDIADEMUXER_IMPL so the .c can define the real struct. */
typedef struct MediaAudioDecoder MediaAudioDecoder;
#ifndef MEDIADEMUXER_IMPL
struct MediaAudioDecoder { int _placeholder; };
#endif

MediaAudioDecoder *media_audio_decoder_create(MediaDemuxer *d, int index);
/* Send one packet (must belong to the decoder's stream). Returns
   MEDIA_RESULT_OK/ERROR. */
int media_audio_decoder_send(MediaAudioDecoder *dec, MediaPacket *pkt);
/* Receive one PCM frame. Returns MEDIA_RESULT_OK (fills *out — caller frees
   via media_audio_frame_free), MEDIA_RESULT_EOF when no frame is ready yet
   (send more packets), or MEDIA_RESULT_ERROR. */
int media_audio_decoder_receive(MediaAudioDecoder *dec, MediaAudioFrame *out);
/* Flush the decoder (after a seek). Returns MEDIA_RESULT_OK/ERROR. */
int media_audio_decoder_flush(MediaAudioDecoder *dec);
void media_audio_decoder_free(MediaAudioDecoder *dec);

#ifdef __cplusplus
}
#endif

#endif /* MEDIADEMUXER_H */
