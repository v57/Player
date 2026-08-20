// MediaDemuxer.c — FFmpeg demux shim (libavformat) behind MediaDemuxer.h.
//
// C99/C11 clean. All FFmpeg types stay private to this TU; the boundary
// only crosses app-owned MediaTrack/MediaPacket structs and an opaque handle.
//
// Dev PoC links against Homebrew ffmpeg 8.1.2 (/opt/homebrew); the shipped
// build will swap to ThirdParty/FFmpeg libs per KANBAN Wave-1 B.

// Define the real struct bodies (suppresses the Clang-importer placeholder
// in MediaDemuxer.h; must come before the include).
#define MEDIADEMUXER_IMPL 1

#include "MediaDemuxer.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>

#include <stdlib.h>
#include <string.h>

struct MediaDemuxer {
    AVFormatContext *fmt_ctx;
};

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

    const char *codec_name = avcodec_get_name(cp->codec_id);
    if (codec_name) snprintf(out->codec_name, sizeof(out->codec_name), "%s", codec_name);

    AVDictionaryEntry *e = NULL;
    e = av_dict_get(st->metadata, "language", NULL, 0);
    if (e && e->value) snprintf(out->language, sizeof(out->language), "%s", e->value);
    e = av_dict_get(st->metadata, "title", NULL, 0);
    if (e && e->value) snprintf(out->title, sizeof(out->title), "%s", e->value);

    out->channel_count = cp->ch_layout.nb_channels;
    out->sample_rate = cp->sample_rate;
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

struct MediaAudioDecoder {
    AVCodecContext *ctx;
    AVFrame *frame;
    int channels;
    int sample_rate;
    uint64_t layout_mask;
    char layout_name[64];
    char sample_fmt[16];
};

MediaAudioDecoder *media_audio_decoder_create(MediaDemuxer *d, int index) {
    if (!d || !d->fmt_ctx) return NULL;
    if (index < 0 || index >= (int)d->fmt_ctx->nb_streams) return NULL;

    AVCodecParameters *cp = d->fmt_ctx->streams[index]->codecpar;
    if (cp->codec_type != AVMEDIA_TYPE_AUDIO) return NULL;

    const AVCodec *dec = avcodec_find_decoder(cp->codec_id);
    if (!dec) return NULL;

    MediaAudioDecoder *ad = (MediaAudioDecoder *)calloc(1, sizeof(*ad));
    if (!ad) return NULL;

    ad->ctx = avcodec_alloc_context3(dec);
    ad->frame = av_frame_alloc();
    if (!ad->ctx || !ad->frame ||
        avcodec_parameters_to_context(ad->ctx, cp) < 0 ||
        avcodec_open2(ad->ctx, dec, NULL) < 0) {
        if (ad->frame) av_frame_free(&ad->frame);
        if (ad->ctx) avcodec_free_context(&ad->ctx);
        free(ad);
        return NULL;
    }

    ad->channels = ad->ctx->ch_layout.nb_channels;
    ad->sample_rate = ad->ctx->sample_rate;
    if (ad->ctx->ch_layout.order == AV_CHANNEL_ORDER_NATIVE) {
        ad->layout_mask = (uint64_t)ad->ctx->ch_layout.u.mask;
    }
    char buf[64] = {0};
    av_channel_layout_describe(&ad->ctx->ch_layout, buf, sizeof(buf));
    snprintf(ad->layout_name, sizeof(ad->layout_name), "%s",
             buf[0] ? buf : "unknown");
    snprintf(ad->sample_fmt, sizeof(ad->sample_fmt), "%s",
             av_get_sample_fmt_name(ad->ctx->sample_fmt));
    return ad;
}

int media_audio_decoder_send(MediaAudioDecoder *ad, MediaPacket *pkt) {
    if (!ad || !ad->ctx || !pkt || !pkt->data || pkt->size <= 0) {
        return MEDIA_RESULT_ERROR;
    }
    AVPacket *avpkt = av_packet_alloc();
    if (!avpkt) return MEDIA_RESULT_ERROR;
    avpkt->data = pkt->data;
    avpkt->size = (int)pkt->size;
    avpkt->pts = pkt->pts;
    avpkt->dts = pkt->dts;
    int ret = avcodec_send_packet(ad->ctx, avpkt);
    av_packet_free(&avpkt);
    return (ret < 0) ? MEDIA_RESULT_ERROR : MEDIA_RESULT_OK;
}

int media_audio_decoder_receive(MediaAudioDecoder *ad, MediaAudioFrame *out) {
    if (!ad || !ad->ctx || !out) return MEDIA_RESULT_ERROR;
    memset(out, 0, sizeof(*out));

    int ret = avcodec_receive_frame(ad->ctx, ad->frame);
    if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) return MEDIA_RESULT_EOF;
    if (ret < 0) return MEDIA_RESULT_ERROR;

    out->channels = ad->channels;
    out->sample_rate = ad->sample_rate;
    out->layout_mask = ad->layout_mask;
    snprintf(out->layout_name, sizeof(out->layout_name), "%s", ad->layout_name);
    snprintf(out->sample_fmt, sizeof(out->sample_fmt), "%s", ad->sample_fmt);

    int n = ad->frame->nb_samples;
    int channels = ad->channels;
    float *buf = (float *)malloc((size_t)n * channels * sizeof(float));
    if (!buf) return MEDIA_RESULT_ERROR;
    for (int ch = 0; ch < channels; ch++) {
        const float *src = (const float *)ad->frame->extended_data[ch];
        for (int i = 0; i < n; i++) {
            buf[(size_t)i * channels + ch] = src[i];
        }
    }
    out->data = buf;
    out->nb_samples = n;
    av_frame_unref(ad->frame);
    return MEDIA_RESULT_OK;
}

int media_audio_decoder_flush(MediaAudioDecoder *ad) {
    if (!ad || !ad->ctx) return MEDIA_RESULT_ERROR;
    avcodec_flush_buffers(ad->ctx);
    return MEDIA_RESULT_OK;
}

void media_audio_decoder_free(MediaAudioDecoder *ad) {
    if (!ad) return;
    if (ad->frame) av_frame_free(&ad->frame);
    if (ad->ctx) avcodec_free_context(&ad->ctx);
    free(ad);
}
