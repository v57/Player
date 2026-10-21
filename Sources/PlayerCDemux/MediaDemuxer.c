// MediaDemuxer.c — FFmpeg demux shim (libavformat) behind MediaDemuxer.h.
//
// C99/C11 clean. All FFmpeg types stay private to this TU; the boundary
// only crosses app-owned MediaTrack/MediaPacket structs and an opaque handle.
//
// Links the vendored minimal FFmpeg build under Sources/FFmpeg (matroska +
// mov/mp4 demuxers, dca/ac3/eac3 decoders; see Sources/FFmpeg/README.md).
// AAC decodes through AudioToolbox instead (see the streaming decoder).

// Define the real struct bodies (suppresses the Clang-importer placeholder
// in MediaDemuxer.h; must come before the include).
#define MEDIADEMUXER_IMPL 1

#include "MediaDemuxer.h"

#include <AudioToolbox/AudioToolbox.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/intreadwrite.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>

struct MediaDemuxer {
    AVFormatContext *fmt_ctx;
    /* Set by media_open_io: the custom reader, freed with its buffer at close. */
    AVIOContext *io;
};

/* AudioToolbox's description of an AAC stream (streaming decoder section). */
static int aac_input_format(const AVCodecParameters *cp, AudioStreamBasicDescription *in,
                            uint8_t **cookie_out, UInt32 *cookie_size_out);

MediaDemuxer *media_open(const char *path) {
    if (!path) return NULL;

    MediaDemuxer *d = (MediaDemuxer *)calloc(1, sizeof(*d));
    if (!d) return NULL;

    /* NULL fmt: let libavformat probe/demux by content. On failure
       avformat_open_input frees and NULLs *fmt_ctx, so media_close() is safe. */
    if (avformat_open_input(&d->fmt_ctx, path, NULL, NULL) < 0) {
        media_close(d);
        return NULL;
    }
    if (avformat_find_stream_info(d->fmt_ctx, NULL) < 0) {
        media_close(d);
        return NULL;
    }
    return d;
}

struct media_io {
    void *opaque;
    media_io_read read;
    media_io_seek seek;
};

static int media_io_read_packet(void *opaque, uint8_t *buf, int size) {
    struct media_io *io = (struct media_io *)opaque;
    int n = io->read(io->opaque, buf, size);
    if (n == 0) return AVERROR_EOF;
    return n < 0 ? AVERROR(EIO) : n;
}

static int64_t media_io_seek_to(void *opaque, int64_t offset, int whence) {
    struct media_io *io = (struct media_io *)opaque;
    if (whence & AVSEEK_SIZE) return io->seek(io->opaque, 0, MEDIA_IO_SIZE);
    return io->seek(io->opaque, offset, whence & ~AVSEEK_FORCE);
}

MediaDemuxer *media_open_io(void *opaque, media_io_read read, media_io_seek seek, const char *name) {
    if (!read || !seek) return NULL;
    MediaDemuxer *d = (MediaDemuxer *)calloc(1, sizeof(*d));
    struct media_io *io = (struct media_io *)calloc(1, sizeof(*io));
    const int buffer_size = 256 * 1024;
    uint8_t *buffer = (uint8_t *)av_malloc(buffer_size);
    if (!d || !io || !buffer) {
        free(d);
        free(io);
        av_free(buffer);
        return NULL;
    }
    io->opaque = opaque;
    io->read = read;
    io->seek = seek;
    d->io = avio_alloc_context(buffer, buffer_size, 0, io, media_io_read_packet, NULL, media_io_seek_to);
    if (!d->io) {
        av_free(buffer);
        free(io);
        free(d);
        return NULL;
    }
    d->fmt_ctx = avformat_alloc_context();
    if (!d->fmt_ctx) {
        media_close(d);
        return NULL;
    }
    d->fmt_ctx->pb = d->io;
    d->fmt_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;
    if (avformat_open_input(&d->fmt_ctx, name ? name : "", NULL, NULL) < 0) {
        media_close(d);
        return NULL;
    }
    if (avformat_find_stream_info(d->fmt_ctx, NULL) < 0) {
        media_close(d);
        return NULL;
    }
    return d;
}

int64_t media_get_duration(MediaDemuxer *d) {
    if (!d || !d->fmt_ctx) return -1;
    if (d->fmt_ctx->duration == AV_NOPTS_VALUE) return -1;
    return d->fmt_ctx->duration * 1000 / AV_TIME_BASE; /* ms */
}

int media_get_track_count(MediaDemuxer *d) {
    if (!d || !d->fmt_ctx) return 0;
    return (int)d->fmt_ctx->nb_streams;
}

int media_get_track(MediaDemuxer *d, int index, MediaTrack *out) {
    if (!d || !d->fmt_ctx || !out) return MEDIA_RESULT_ERROR;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return MEDIA_RESULT_ERROR;

    AVStream *st = d->fmt_ctx->streams[index];
    AVCodecParameters *cp = st->codecpar;

    memset(out, 0, sizeof(*out));
    out->id = st->index;
    out->codec_id = cp->codec_id;

    switch (cp->codec_type) {
    case AVMEDIA_TYPE_VIDEO:      out->type = MEDIA_TRACK_TYPE_VIDEO; break;
    case AVMEDIA_TYPE_AUDIO:      out->type = MEDIA_TRACK_TYPE_AUDIO; break;
    case AVMEDIA_TYPE_SUBTITLE:   out->type = MEDIA_TRACK_TYPE_SUBTITLE; break;
    case AVMEDIA_TYPE_ATTACHMENT: out->type = MEDIA_TRACK_TYPE_ATTACHMENT; break;
    default:                      out->type = MEDIA_TRACK_TYPE_UNKNOWN; break;
    }
    /* MP4/M4V cover art is a one-picture "video" stream (mjpeg/png). */
    if (st->disposition & AV_DISPOSITION_ATTACHED_PIC) out->type = MEDIA_TRACK_TYPE_ATTACHMENT;

    const char *codec_name = avcodec_get_name(cp->codec_id);
    if (codec_name) snprintf(out->codec_name, sizeof(out->codec_name), "%s", codec_name);

    AVDictionaryEntry *e = NULL;
    e = av_dict_get(st->metadata, "language", NULL, 0);
    if (e && e->value) snprintf(out->language, sizeof(out->language), "%s", e->value);
    e = av_dict_get(st->metadata, "title", NULL, 0);
    if (e && e->value) snprintf(out->title, sizeof(out->title), "%s", e->value);

    out->channel_count = cp->ch_layout.nb_channels;
    out->sample_rate = cp->sample_rate;
    /* AAC has no FFmpeg decoder here, so the header values are the core
       layer's (HE-AAC v2: mono at half rate); report what AudioToolbox
       decodes instead. */
    AudioStreamBasicDescription aac;
    if (cp->codec_id == AV_CODEC_ID_AAC && aac_input_format(cp, &aac, NULL, NULL)) {
        out->channel_count = (int)aac.mChannelsPerFrame;
        out->sample_rate = (int)aac.mSampleRate;
    }
    out->time_base_num = st->time_base.num;
    out->time_base_den = st->time_base.den;
    out->is_default = (st->disposition & AV_DISPOSITION_DEFAULT) ? 1 : 0;
    out->is_forced = (st->disposition & AV_DISPOSITION_FORCED) ? 1 : 0;

    return MEDIA_RESULT_OK;
}

int media_get_track_extradata(MediaDemuxer *d, int index, const uint8_t **buf, size_t *size) {
    if (!d || !d->fmt_ctx || !buf || !size) return MEDIA_RESULT_ERROR;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return MEDIA_RESULT_ERROR;

    AVCodecParameters *cp = d->fmt_ctx->streams[index]->codecpar;
    if (!cp->extradata || cp->extradata_size <= 0) return MEDIA_RESULT_ERROR;

    *buf = cp->extradata;
    *size = (size_t)cp->extradata_size;
    return MEDIA_RESULT_OK;
}

int media_get_track_width(MediaDemuxer *d, int index) {
    if (!d || !d->fmt_ctx) return 0;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return 0;
    return d->fmt_ctx->streams[index]->codecpar->width;
}

int media_get_track_height(MediaDemuxer *d, int index) {
    if (!d || !d->fmt_ctx) return 0;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return 0;
    return d->fmt_ctx->streams[index]->codecpar->height;
}

int media_read_packet(MediaDemuxer *d, MediaPacket *out) {
    if (!d || !d->fmt_ctx || !out) return MEDIA_RESULT_ERROR;

    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return MEDIA_RESULT_ERROR;

    int ret = av_read_frame(d->fmt_ctx, pkt);
    if (ret == AVERROR_EOF) {
        av_packet_free(&pkt);
        return MEDIA_RESULT_EOF;
    }
    if (ret < 0) {
        av_packet_free(&pkt);
        return MEDIA_RESULT_ERROR;
    }

    memset(out, 0, sizeof(*out));
    out->stream_id = (int64_t)pkt->stream_index;
    out->pts = pkt->pts;
    out->dts = pkt->dts;
    out->duration = pkt->duration;
    out->keyframe = (pkt->flags & AV_PKT_FLAG_KEY) ? 1 : 0;
    out->size = (size_t)pkt->size;
    size_t skip_size = 0;
    const uint8_t *skip = av_packet_get_side_data(pkt, AV_PKT_DATA_SKIP_SAMPLES, &skip_size);
    if (skip && skip_size >= 8) {
        out->skip_start = (int32_t)AV_RL32(skip);
        out->skip_end = (int32_t)AV_RL32(skip + 4);
    }

    if (pkt->size > 0) {
        out->data = (uint8_t *)malloc((size_t)pkt->size);
        if (!out->data) {
            av_packet_free(&pkt);
            return MEDIA_RESULT_ERROR;
        }
        memcpy(out->data, pkt->data, (size_t)pkt->size);
    }

    av_packet_free(&pkt);
    return MEDIA_RESULT_OK;
}

void media_packet_free(MediaPacket *p) {
    if (!p) return;
    free(p->data);
    p->data = NULL;
    p->size = 0;
}

int media_seek(MediaDemuxer *d, double seconds) {
    if (!d || !d->fmt_ctx || seconds < 0.0) return MEDIA_RESULT_ERROR;
    int64_t ts = (int64_t)(seconds * (double)AV_TIME_BASE);
    int ret = av_seek_frame(d->fmt_ctx, -1, ts, AVSEEK_FLAG_BACKWARD);
    return (ret < 0) ? MEDIA_RESULT_ERROR : MEDIA_RESULT_OK;
}

void media_close(MediaDemuxer *d) {
    if (!d) return;
    if (d->fmt_ctx) avformat_close_input(&d->fmt_ctx);
    if (d->io) {
        free(d->io->opaque);
        av_freep(&d->io->buffer);
        avio_context_free(&d->io);
    }
    free(d);
}

const char *media_track_codec_name(const MediaTrack *t) { return t ? t->codec_name : ""; }
const char *media_track_language(const MediaTrack *t)   { return t ? t->language : ""; }
const char *media_track_title(const MediaTrack *t)      { return t ? t->title : ""; }

MediaTrack media_track_make(void)  { MediaTrack t; memset(&t, 0, sizeof(t)); return t; }
MediaPacket media_packet_make(void) { MediaPacket p; memset(&p, 0, sizeof(p)); return p; }
void media_track_zero(MediaTrack *t)  { if (t) memset(t, 0, sizeof(*t)); }
void media_packet_zero(MediaPacket *p) { if (p) memset(p, 0, sizeof(*p)); }

int media_get_chapter_count(MediaDemuxer *d) {
    if (!d || !d->fmt_ctx) return 0;
    return (int)d->fmt_ctx->nb_chapters;
}

int media_get_chapter(MediaDemuxer *d, int index,
                      int64_t *start_ms, char *title, size_t title_size) {
    if (!d || !d->fmt_ctx || !start_ms || !title) return MEDIA_RESULT_ERROR;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_chapters) return MEDIA_RESULT_ERROR;

    AVChapter *ch = d->fmt_ctx->chapters[index];
    /* Chapter start_time is in AV_TIME_BASE units (microseconds). */
    *start_ms = ch->start * 1000 / AV_TIME_BASE;

    AVDictionaryEntry *e = av_dict_get(ch->metadata, "title", NULL, 0);
    snprintf(title, title_size, "%s", (e && e->value) ? e->value : "");
    return MEDIA_RESULT_OK;
}

int media_get_track_channel_layout(MediaDemuxer *d, int index,
                                   uint64_t *mask, char *name, size_t name_size) {
    if (!d || !d->fmt_ctx || !mask || !name) return MEDIA_RESULT_ERROR;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return MEDIA_RESULT_ERROR;

    AVCodecParameters *cp = d->fmt_ctx->streams[index]->codecpar;
    if (cp->codec_type != AVMEDIA_TYPE_AUDIO) return MEDIA_RESULT_ERROR;

    const AVChannelLayout *cl = &cp->ch_layout;
    if (cl->order == AV_CHANNEL_ORDER_NATIVE) {
        *mask = (uint64_t)cl->u.mask;
    } else {
        *mask = 0;
    }
    char buf[64] = {0};
    av_channel_layout_describe(cl, buf, sizeof(buf));
    snprintf(name, name_size, "%s", buf[0] ? buf : "unknown");
    return MEDIA_RESULT_OK;
}

int media_decode_audio(MediaDemuxer *d, int index, int max_samples,
                       MediaAudioFrame *out) {
    if (!d || !d->fmt_ctx || !out) return MEDIA_RESULT_ERROR;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return MEDIA_RESULT_ERROR;

    AVStream *st = d->fmt_ctx->streams[index];
    AVCodecParameters *cp = st->codecpar;
    if (cp->codec_type != AVMEDIA_TYPE_AUDIO) return MEDIA_RESULT_ERROR;

    const AVCodec *dec = avcodec_find_decoder(cp->codec_id);
    if (!dec) return MEDIA_RESULT_ERROR;

    AVCodecContext *ctx = avcodec_alloc_context3(dec);
    if (!ctx) return MEDIA_RESULT_ERROR;
    if (avcodec_parameters_to_context(ctx, cp) < 0) {
        avcodec_free_context(&ctx);
        return MEDIA_RESULT_ERROR;
    }
    if (avcodec_open2(ctx, dec, NULL) < 0) {
        avcodec_free_context(&ctx);
        return MEDIA_RESULT_ERROR;
    }

    memset(out, 0, sizeof(*out));
    out->channels = ctx->ch_layout.nb_channels;
    out->sample_rate = ctx->sample_rate;
    if (ctx->ch_layout.order == AV_CHANNEL_ORDER_NATIVE) {
        out->layout_mask = (uint64_t)ctx->ch_layout.u.mask;
    }
    char layout_buf[64] = {0};
    av_channel_layout_describe(&ctx->ch_layout, layout_buf, sizeof(layout_buf));
    snprintf(out->layout_name, sizeof(out->layout_name), "%s",
             layout_buf[0] ? layout_buf : "unknown");
    snprintf(out->sample_fmt, sizeof(out->sample_fmt), "%s",
             av_get_sample_fmt_name(ctx->sample_fmt));

    /* Capacity: max_samples per channel; grow in chunks. */
    int channels = out->channels;
    int capacity = 0;
    float *buf = NULL;
    int total = 0;  /* samples per channel accumulated */
    int ret = MEDIA_RESULT_ERROR;

    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if (!pkt || !frame) goto done;

    /* Skip packets of other streams until we have enough audio. */
    while (total < max_samples) {
        int r = av_read_frame(d->fmt_ctx, pkt);
        if (r == AVERROR_EOF) break;
        if (r < 0) break;
        if (pkt->stream_index != index) {
            av_packet_unref(pkt);
            continue;
        }

        int send = avcodec_send_packet(ctx, pkt);
        av_packet_unref(pkt);
        if (send < 0) continue;

        while (1) {
            int recv = avcodec_receive_frame(ctx, frame);
            if (recv == AVERROR(EAGAIN) || recv == AVERROR_EOF) break;
            if (recv < 0) break;

            int n = frame->nb_samples;
            int need = total + n;
            if (need > capacity) {
                int newcap = capacity ? capacity * 2 : 4096;
                while (newcap < need) newcap *= 2;
                float *nb = (float *)realloc(buf, (size_t)newcap * channels * sizeof(float));
                if (!nb) goto done;
                buf = nb;
                capacity = newcap;
            }
            /* Interleave planar float32 -> interleaved float32. */
            for (int ch = 0; ch < channels; ch++) {
                const float *src = (const float *)frame->extended_data[ch];
                for (int i = 0; i < n; i++) {
                    buf[(total + i) * channels + ch] = src[i];
                }
            }
            total += n;
            av_frame_unref(frame);
            if (total >= max_samples) break;
        }
    }

    if (total > 0) {
        out->data = buf;
        out->nb_samples = total > max_samples ? max_samples : total;
        buf = NULL;
        ret = MEDIA_RESULT_OK;
    } else {
        ret = MEDIA_RESULT_EOF;
    }

done:
    free(buf);
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    return ret;
}

void media_audio_frame_free(MediaAudioFrame *f) {
    if (!f) return;
    free(f->data);
    f->data = NULL;
    f->nb_samples = 0;
}

const char *media_audio_frame_layout_name(const MediaAudioFrame *f) {
    return f ? f->layout_name : "";
}

const char *media_audio_frame_sample_fmt(const MediaAudioFrame *f) {
    return f ? f->sample_fmt : "";
}

/* ---- streaming audio decoder ---- */

/* Two backends behind one API: libavcodec for DTS/AC3/E-AC3, AudioToolbox for
   AAC. Apple's AAC decoder ships with the OS (LC, HE-AAC v1/v2), so AAC costs
   no FFmpeg growth — the FFmpeg aac decoder would add ~230 KB to libavcodec,
   ~10% of the app. Both backends hand out interleaved float32 in FFmpeg's
   native channel order. */

#define AT_MAX_CHANNELS 8
#define AT_MAX_FRAMES 8192          /* per packet: AAC 1024, HE-AAC 2048 */
#define AT_NO_MORE_INPUT 0x6E6D6F72 /* 'nmor': input proc has no packet left */

struct MediaAudioDecoder {
    /* libavcodec backend */
    AVCodecContext *ctx;
    AVFrame *frame;
    /* AudioToolbox backend */
    AudioConverterRef converter;
    const uint8_t *at_input;        /* packet handed to the input proc, NULL once taken */
    UInt32 at_input_size;
    AudioStreamPacketDescription at_desc;
    float *at_pcm;                  /* last packet's output (interleaved, native order) */
    float *at_scratch;              /* channel-reorder target, swapped with at_pcm */
    int at_frames;                  /* frames waiting in at_pcm; 0 = nothing to receive */
    int at_skip;                    /* priming frames still to drop */
    int at_padding;                 /* container-declared priming, until the first packet */
    int at_order[AT_MAX_CHANNELS];  /* output channel i = converter channel at_order[i] */
    int at_reorder;
    /* output format */
    int channels;
    int sample_rate;
    uint64_t layout_mask;
    char layout_name[64];
    char sample_fmt[16];
};

static void decoder_set_layout(MediaAudioDecoder *ad, const AVChannelLayout *cl) {
    ad->layout_mask = (cl->order == AV_CHANNEL_ORDER_NATIVE) ? (uint64_t)cl->u.mask : 0;
    char buf[64] = {0};
    av_channel_layout_describe(cl, buf, sizeof(buf));
    snprintf(ad->layout_name, sizeof(ad->layout_name), "%s", buf[0] ? buf : "unknown");
}

/* -- AudioToolbox (AAC) -- */

/* MPEG-4 descriptor header: tag + 4-byte expandable size. */
static uint8_t *put_descr(uint8_t *p, int tag, unsigned size) {
    *p++ = (uint8_t)tag;
    for (int i = 3; i > 0; i--) *p++ = (uint8_t)((size >> (7 * i)) | 0x80);
    *p++ = (uint8_t)(size & 0x7F);
    return p;
}

/* AudioToolbox takes the AAC magic cookie as an ES descriptor (the 'esds'
   payload of an MP4) wrapping the AudioSpecificConfig. Caller frees. */
static uint8_t *aac_esds_cookie(const uint8_t *asc, int asc_size, UInt32 *out_size) {
    unsigned size = 5 + 3 + 5 + 13 + 5 + (unsigned)asc_size;
    uint8_t *cookie = (uint8_t *)malloc(size);
    if (!cookie) return NULL;
    uint8_t *p = put_descr(cookie, 0x03, 3 + 5 + 13 + 5 + asc_size); /* ES_Descriptor */
    *p++ = 0; *p++ = 0;                                              /* ES_ID */
    *p++ = 0;                                                        /* flags */
    p = put_descr(p, 0x04, 13 + 5 + asc_size);                       /* DecoderConfigDescriptor */
    *p++ = 0x40;                                                     /* objectType: MPEG-4 audio */
    *p++ = 0x15;                                                     /* streamType: audio */
    memset(p, 0, 11);                                                /* buffer size, bitrates */
    p += 11;
    p = put_descr(p, 0x05, (unsigned)asc_size);                      /* DecoderSpecificInfo */
    memcpy(p, asc, (size_t)asc_size);
    *out_size = size;
    return cookie;
}

/* A 2-byte AAC-LC AudioSpecificConfig from the container's rate/channels, for
   a stream that carries none. Returns 0 when the rate has no index. */
static int aac_synth_asc(const AVCodecParameters *cp, uint8_t asc[2]) {
    static const int rates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000,
                                22050, 16000, 12000, 11025, 8000,  7350};
    int ch = cp->ch_layout.nb_channels;
    int config = ch == 8 ? 7 : ch;
    if (config < 1 || config > 7) return 0;
    for (int i = 0; i < (int)(sizeof(rates) / sizeof(rates[0])); i++) {
        if (rates[i] != cp->sample_rate) continue;
        asc[0] = (uint8_t)((2 << 3) | (i >> 1));   /* object type 2 (LC) */
        asc[1] = (uint8_t)(((i & 1) << 7) | (config << 3));
        return 1;
    }
    return 0;
}

static enum AVChannel at_label_channel(AudioChannelLabel label) {
    switch (label) {
    case kAudioChannelLabel_Left:                return AV_CHAN_FRONT_LEFT;
    case kAudioChannelLabel_Right:               return AV_CHAN_FRONT_RIGHT;
    case kAudioChannelLabel_Center:
    case kAudioChannelLabel_Mono:                return AV_CHAN_FRONT_CENTER;
    case kAudioChannelLabel_LFEScreen:           return AV_CHAN_LOW_FREQUENCY;
    case kAudioChannelLabel_LeftSurround:
    case kAudioChannelLabel_LeftSurroundDirect:  return AV_CHAN_SIDE_LEFT;
    case kAudioChannelLabel_RightSurround:
    case kAudioChannelLabel_RightSurroundDirect: return AV_CHAN_SIDE_RIGHT;
    case kAudioChannelLabel_LeftCenter:          return AV_CHAN_FRONT_LEFT_OF_CENTER;
    case kAudioChannelLabel_RightCenter:         return AV_CHAN_FRONT_RIGHT_OF_CENTER;
    case kAudioChannelLabel_CenterSurround:      return AV_CHAN_BACK_CENTER;
    case kAudioChannelLabel_TopCenterSurround:   return AV_CHAN_TOP_CENTER;
    case kAudioChannelLabel_RearSurroundLeft:    return AV_CHAN_BACK_LEFT;
    case kAudioChannelLabel_RearSurroundRight:   return AV_CHAN_BACK_RIGHT;
    case kAudioChannelLabel_LeftWide:            return AV_CHAN_WIDE_LEFT;
    case kAudioChannelLabel_RightWide:           return AV_CHAN_WIDE_RIGHT;
    case kAudioChannelLabel_LFE2:                return AV_CHAN_LOW_FREQUENCY_2;
    default:                                     return AV_CHAN_NONE;
    }
}

/* The converter's output channel layout, expanded to channel descriptions.
   Caller frees. */
static AudioChannelLayout *at_output_layout(AudioConverterRef conv) {
    UInt32 size = 0;
    if (AudioConverterGetPropertyInfo(conv, kAudioConverterOutputChannelLayout, &size, NULL) != noErr ||
        size < sizeof(AudioChannelLayout)) {
        return NULL;
    }
    AudioChannelLayout *layout = (AudioChannelLayout *)malloc(size);
    if (!layout) return NULL;
    if (AudioConverterGetProperty(conv, kAudioConverterOutputChannelLayout, &size, layout) != noErr) {
        free(layout);
        return NULL;
    }
    AudioChannelLayoutTag tag = layout->mChannelLayoutTag;
    if (tag == kAudioChannelLayoutTag_UseChannelDescriptions) return layout;

    AudioFormatPropertyID prop = kAudioFormatProperty_ChannelLayoutForTag;
    const void *spec = &tag;
    UInt32 spec_size = sizeof(tag);
    if (tag == kAudioChannelLayoutTag_UseChannelBitmap) {
        prop = kAudioFormatProperty_ChannelLayoutForBitmap;
        spec = &layout->mChannelBitmap;
        spec_size = sizeof(layout->mChannelBitmap);
    }
    AudioChannelLayout *full = NULL;
    if (AudioFormatGetPropertyInfo(prop, spec_size, spec, &size) == noErr &&
        size >= sizeof(AudioChannelLayout) && (full = (AudioChannelLayout *)malloc(size)) &&
        AudioFormatGetProperty(prop, spec_size, spec, &size, full) != noErr) {
        free(full);
        full = NULL;
    }
    free(layout);
    return full;
}

/* Maps the converter's channel order onto FFmpeg's native order (ascending
   AVChannel), which is what the player's channel roles and 5.1 passthrough
   assume. AAC's own order is centre-first (C L R Ls Rs LFE). */
static void at_setup_layout(MediaAudioDecoder *ad) {
    int n = ad->channels;
    for (int i = 0; i < n; i++) ad->at_order[i] = i;
    ad->at_reorder = 0;

    AVChannelLayout cl;
    av_channel_layout_default(&cl, n);
    if (n > 2) {
        AudioChannelLayout *layout = at_output_layout(ad->converter);
        enum AVChannel chan[AT_MAX_CHANNELS];
        uint64_t mask = 0;
        int ok = layout && (int)layout->mNumberChannelDescriptions == n;
        for (int i = 0; ok && i < n; i++) {
            chan[i] = at_label_channel(layout->mChannelDescriptions[i].mChannelLabel);
            ok = chan[i] != AV_CHAN_NONE && !(mask & (1ULL << chan[i]));
            if (ok) mask |= 1ULL << chan[i];
        }
        free(layout);
        if (ok) {
            for (int i = 0; i < n; i++) {
                int rank = 0;
                for (int j = 0; j < n; j++) rank += chan[j] < chan[i];
                ad->at_order[rank] = i;
                if (rank != i) ad->at_reorder = 1;
            }
            av_channel_layout_uninit(&cl);
            av_channel_layout_from_mask(&cl, mask);
        } else {
            /* Unknown labels: keep the converter's order, report no mask. */
            av_channel_layout_uninit(&cl);
            cl = (AVChannelLayout){.order = AV_CHANNEL_ORDER_UNSPEC, .nb_channels = n};
        }
    }
    decoder_set_layout(ad, &cl);
    av_channel_layout_uninit(&cl);
}

static OSStatus at_input_proc(AudioConverterRef conv, UInt32 *packets, AudioBufferList *data,
                              AudioStreamPacketDescription **desc, void *user) {
    (void)conv;
    MediaAudioDecoder *ad = (MediaAudioDecoder *)user;
    if (!ad->at_input) {
        *packets = 0;
        return AT_NO_MORE_INPUT;
    }
    data->mNumberBuffers = 1;
    data->mBuffers[0].mNumberChannels = 0;
    data->mBuffers[0].mDataByteSize = ad->at_input_size;
    data->mBuffers[0].mData = (void *)ad->at_input;
    ad->at_desc = (AudioStreamPacketDescription){0, 0, ad->at_input_size};
    if (desc) *desc = &ad->at_desc;
    *packets = 1;
    ad->at_input = NULL;
    return noErr;
}

static int aac_input_format(const AVCodecParameters *cp, AudioStreamBasicDescription *in,
                            uint8_t **cookie_out, UInt32 *cookie_size_out) {
    uint8_t synth[2];
    const uint8_t *asc = cp->extradata;
    int asc_size = cp->extradata_size;
    if (!asc || asc_size <= 0) {
        if (!aac_synth_asc(cp, synth)) return 0;
        asc = synth;
        asc_size = 2;
    }
    UInt32 cookie_size = 0;
    uint8_t *cookie = aac_esds_cookie(asc, asc_size, &cookie_size);
    if (!cookie) return 0;

    /* The format list puts the richest layer first (HE-AAC v2 > HE-AAC >
       LC), so an HE-AAC stream decodes at its full rate and channel count
       rather than the core layer's (e.g. 24 kHz mono for a 48 kHz stereo
       HE-AAC v2 stream). */
    memset(in, 0, sizeof(*in));
    AudioFormatInfo info = {0};
    info.mASBD.mFormatID = kAudioFormatMPEG4AAC;
    info.mMagicCookie = cookie;
    info.mMagicCookieSize = cookie_size;
    UInt32 size = 0;
    if (AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList, sizeof(info), &info, &size) == noErr &&
        size >= sizeof(AudioFormatListItem)) {
        AudioFormatListItem *items = (AudioFormatListItem *)malloc(size);
        if (items && AudioFormatGetProperty(kAudioFormatProperty_FormatList, sizeof(info), &info, &size,
                                            items) == noErr) {
            *in = items[0].mASBD;
        }
        free(items);
    }
    if (in->mFormatID == 0) {
        in->mFormatID = kAudioFormatMPEG4AAC;
        size = sizeof(*in);
        if (AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, cookie_size, cookie, &size, in) !=
            noErr) {
            in->mFormatID = 0;
        }
    }
    if (in->mFormatID == 0 || in->mChannelsPerFrame < 1 || in->mChannelsPerFrame > AT_MAX_CHANNELS ||
        in->mSampleRate <= 0) {
        free(cookie);
        return 0;
    }
    if (cookie_out) {
        *cookie_out = cookie;
        *cookie_size_out = cookie_size;
    } else {
        free(cookie);
    }
    return 1;
}

static MediaAudioDecoder *at_decoder_create(const AVCodecParameters *cp) {
    AudioStreamBasicDescription in;
    uint8_t *cookie = NULL;
    UInt32 cookie_size = 0;
    if (!aac_input_format(cp, &in, &cookie, &cookie_size)) return NULL;
    int channels = (int)in.mChannelsPerFrame;

    AudioStreamBasicDescription out = {0};
    out.mSampleRate = in.mSampleRate;
    out.mFormatID = kAudioFormatLinearPCM;
    out.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    out.mChannelsPerFrame = (UInt32)channels;
    out.mBitsPerChannel = 32;
    out.mFramesPerPacket = 1;
    out.mBytesPerFrame = out.mBytesPerPacket = 4 * (UInt32)channels;

    MediaAudioDecoder *ad = (MediaAudioDecoder *)calloc(1, sizeof(*ad));
    if (!ad || AudioConverterNew(&in, &out, &ad->converter) != noErr ||
        AudioConverterSetProperty(ad->converter, kAudioConverterDecompressionMagicCookie, cookie_size,
                                  cookie) != noErr ||
        !(ad->at_pcm = (float *)malloc((size_t)AT_MAX_FRAMES * channels * sizeof(float))) ||
        !(ad->at_scratch = (float *)malloc((size_t)AT_MAX_FRAMES * channels * sizeof(float)))) {
        free(cookie);
        media_audio_decoder_free(ad);
        return NULL;
    }
    free(cookie);
    ad->channels = channels;
    ad->sample_rate = (int)in.mSampleRate;
    ad->at_padding = cp->initial_padding;
    snprintf(ad->sample_fmt, sizeof(ad->sample_fmt), "flt");
    at_setup_layout(ad);
    return ad;
}

/* Decodes one AAC packet into at_pcm and applies the trims. A frame left
   unreceived from the previous packet is replaced (libavcodec would refuse
   the packet instead; either way the caller lost it by not receiving). */
static int at_decoder_send(MediaAudioDecoder *ad, const MediaPacket *pkt) {
    int ch = ad->channels;
    int total = 0;
    ad->at_frames = 0;
    ad->at_input = pkt->data;
    ad->at_input_size = (UInt32)pkt->size;
    while (total < AT_MAX_FRAMES) {
        UInt32 frames = (UInt32)(AT_MAX_FRAMES - total);
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = (UInt32)ch;
        abl.mBuffers[0].mDataByteSize = frames * (UInt32)ch * sizeof(float);
        abl.mBuffers[0].mData = ad->at_pcm + (size_t)total * ch;
        OSStatus st = AudioConverterFillComplexBuffer(ad->converter, at_input_proc, ad, &frames, &abl, NULL);
        total += (int)frames;
        if (st == AT_NO_MORE_INPUT || frames == 0) break;
        if (st != noErr) {
            /* Corrupt packet: drop it and the decoder's overlap state. */
            ad->at_input = NULL;
            AudioConverterReset(ad->converter);
            return MEDIA_RESULT_ERROR;
        }
    }
    ad->at_input = NULL;

    /* Encoder priming. Matroska declares it once (CodecDelay, with the first
       packet timestamped that far before zero); it applies only when decoding
       starts at that packet, not after a seek or track switch. MP4 edit lists
       arrive as skip-samples on the packet and can span packets: HE-AAC's
       2112 frames outlast its first 2048-frame packet. */
    if (ad->at_padding > 0) {
        if (pkt->pts != AV_NOPTS_VALUE && pkt->pts < 0) ad->at_skip = ad->at_padding;
        ad->at_padding = 0;
    }
    if (pkt->skip_start > 0) ad->at_skip = pkt->skip_start;
    int drop = ad->at_skip < total ? ad->at_skip : total;
    if (drop > 0) {
        memmove(ad->at_pcm, ad->at_pcm + (size_t)drop * ch, (size_t)(total - drop) * ch * sizeof(float));
        total -= drop;
        ad->at_skip -= drop;
    }
    if (pkt->skip_end > 0) total -= pkt->skip_end < total ? pkt->skip_end : total;

    if (ad->at_reorder && total > 0) {
        for (int i = 0; i < total; i++) {
            const float *src = ad->at_pcm + (size_t)i * ch;
            float *dst = ad->at_scratch + (size_t)i * ch;
            for (int c = 0; c < ch; c++) dst[c] = src[ad->at_order[c]];
        }
        float *t = ad->at_pcm;
        ad->at_pcm = ad->at_scratch;
        ad->at_scratch = t;
    }
    ad->at_frames = total;
    return MEDIA_RESULT_OK;
}

static int at_decoder_receive(MediaAudioDecoder *ad, MediaAudioFrame *out) {
    if (ad->at_frames <= 0) return MEDIA_RESULT_EOF;
    size_t count = (size_t)ad->at_frames * ad->channels;
    float *buf = (float *)malloc(count * sizeof(float));
    if (!buf) return MEDIA_RESULT_ERROR;
    memcpy(buf, ad->at_pcm, count * sizeof(float));
    out->data = buf;
    out->nb_samples = ad->at_frames;
    ad->at_frames = 0;
    return MEDIA_RESULT_OK;
}

/* -- shared API -- */

MediaAudioDecoder *media_audio_decoder_create(MediaDemuxer *d, int index) {
    if (!d || !d->fmt_ctx) return NULL;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return NULL;

    AVCodecParameters *cp = d->fmt_ctx->streams[index]->codecpar;
    if (cp->codec_type != AVMEDIA_TYPE_AUDIO) return NULL;
    if (cp->codec_id == AV_CODEC_ID_AAC) return at_decoder_create(cp);

    const AVCodec *dec = avcodec_find_decoder(cp->codec_id);
    if (!dec) return NULL;

    MediaAudioDecoder *ad = (MediaAudioDecoder *)calloc(1, sizeof(*ad));
    if (!ad) return NULL;

    ad->ctx = avcodec_alloc_context3(dec);
    ad->frame = av_frame_alloc();
    if (!ad->ctx || !ad->frame ||
        avcodec_parameters_to_context(ad->ctx, cp) < 0 ||
        avcodec_open2(ad->ctx, dec, NULL) < 0) {
        media_audio_decoder_free(ad);
        return NULL;
    }

    ad->channels = ad->ctx->ch_layout.nb_channels;
    ad->sample_rate = ad->ctx->sample_rate;
    decoder_set_layout(ad, &ad->ctx->ch_layout);
    snprintf(ad->sample_fmt, sizeof(ad->sample_fmt), "%s",
             av_get_sample_fmt_name(ad->ctx->sample_fmt));
    return ad;
}

int media_audio_decoder_get_format(MediaAudioDecoder *ad, int *channels, int *sample_rate,
                                   uint64_t *mask, char *name, size_t name_size) {
    if (!ad || !channels || !sample_rate || !mask || !name) return MEDIA_RESULT_ERROR;
    *channels = ad->channels;
    *sample_rate = ad->sample_rate;
    *mask = ad->layout_mask;
    snprintf(name, name_size, "%s", ad->layout_name);
    return MEDIA_RESULT_OK;
}

int media_audio_decoder_send(MediaAudioDecoder *ad, MediaPacket *pkt) {
    if (!ad || !pkt || !pkt->data || pkt->size <= 0) {
        return MEDIA_RESULT_ERROR;
    }
    if (ad->converter) return at_decoder_send(ad, pkt);
    if (!ad->ctx) return MEDIA_RESULT_ERROR;

    AVPacket *avpkt = av_packet_alloc();
    if (!avpkt) return MEDIA_RESULT_ERROR;
    avpkt->data = pkt->data;
    avpkt->size = (int)pkt->size;
    avpkt->pts = pkt->pts;
    avpkt->dts = pkt->dts;
    if (pkt->skip_start > 0 || pkt->skip_end > 0) {
        uint8_t *skip = av_packet_new_side_data(avpkt, AV_PKT_DATA_SKIP_SAMPLES, 10);
        if (skip) {
            AV_WL32(skip, (uint32_t)(pkt->skip_start > 0 ? pkt->skip_start : 0));
            AV_WL32(skip + 4, (uint32_t)(pkt->skip_end > 0 ? pkt->skip_end : 0));
            skip[8] = skip[9] = 0;
        }
    }
    int ret = avcodec_send_packet(ad->ctx, avpkt);
    av_packet_free(&avpkt);
    return (ret < 0) ? MEDIA_RESULT_ERROR : MEDIA_RESULT_OK;
}

int media_audio_decoder_receive(MediaAudioDecoder *ad, MediaAudioFrame *out) {
    if (!ad || !out) return MEDIA_RESULT_ERROR;
    memset(out, 0, sizeof(*out));

    out->channels = ad->channels;
    out->sample_rate = ad->sample_rate;
    out->layout_mask = ad->layout_mask;
    snprintf(out->layout_name, sizeof(out->layout_name), "%s", ad->layout_name);
    snprintf(out->sample_fmt, sizeof(out->sample_fmt), "%s", ad->sample_fmt);
    if (ad->converter) return at_decoder_receive(ad, out);
    if (!ad->ctx) return MEDIA_RESULT_ERROR;

    int ret = avcodec_receive_frame(ad->ctx, ad->frame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return MEDIA_RESULT_EOF;
    if (ret < 0) return MEDIA_RESULT_ERROR;

    /* The frame's own channel count bounds the planes we may read; the caller
       skips a frame whose count differs from the stream's. */
    int n = ad->frame->nb_samples;
    int channels = ad->frame->ch_layout.nb_channels;
    if (ad->frame->format != AV_SAMPLE_FMT_FLTP || channels <= 0) {
        av_frame_unref(ad->frame);
        return MEDIA_RESULT_ERROR;
    }
    float *buf = (float *)malloc((size_t)n * channels * sizeof(float));
    if (!buf) {
        av_frame_unref(ad->frame);
        return MEDIA_RESULT_ERROR;
    }
    for (int ch = 0; ch < channels; ch++) {
        const float *src = (const float *)ad->frame->extended_data[ch];
        for (int i = 0; i < n; i++) {
            buf[(size_t)i * channels + ch] = src[i];
        }
    }
    out->data = buf;
    out->nb_samples = n;
    out->channels = channels;
    av_frame_unref(ad->frame);
    return MEDIA_RESULT_OK;
}

int media_audio_decoder_flush(MediaAudioDecoder *ad) {
    if (!ad) return MEDIA_RESULT_ERROR;
    if (ad->converter) {
        AudioConverterReset(ad->converter);
        ad->at_frames = 0;
        ad->at_skip = 0;
        ad->at_padding = 0;
        return MEDIA_RESULT_OK;
    }
    if (!ad->ctx) return MEDIA_RESULT_ERROR;
    avcodec_flush_buffers(ad->ctx);
    return MEDIA_RESULT_OK;
}

void media_audio_decoder_free(MediaAudioDecoder *ad) {
    if (!ad) return;
    if (ad->frame) av_frame_free(&ad->frame);
    if (ad->ctx) avcodec_free_context(&ad->ctx);
    if (ad->converter) AudioConverterDispose(ad->converter);
    free(ad->at_pcm);
    free(ad->at_scratch);
    free(ad);
}

/* ---- linked FFmpeg ------------------------------------------------------ */

const char *media_ffmpeg_version(void) { return av_version_info(); }

const char *media_ffmpeg_license(void) {
    const char *format = avformat_license();
    if (strcmp(format, avcodec_license()) != 0 || strcmp(format, avutil_license()) != 0)
        return NULL;
    return format;
}

const char *media_ffmpeg_configuration(void) { return avformat_configuration(); }
