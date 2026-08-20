// decode-check.c — prove the minimal ThirdParty FFmpeg build can decode DTS.
// Opens video.mkv, finds the first DTS audio stream, decodes the first few
// packets with the dca decoder, and prints the resulting PCM layout.
// Build: clang decode-check.c -I../../ThirdParty/FFmpeg/include -L../../ThirdParty/FFmpeg/lib -lavformat -lavcodec -lavutil -o decode-check
// Run:   DYLD_LIBRARY_PATH=../../ThirdParty/FFmpeg/lib ./decode-check video.mkv
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <file>\n", argv[0]); return 2; }
    avformat_network_init();

    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, argv[1], NULL, NULL) < 0) {
        fprintf(stderr, "FAIL: avformat_open_input\n"); return 1;
    }
    if (avformat_find_stream_info(fmt, NULL) < 0) {
        fprintf(stderr, "FAIL: avformat_find_stream_info\n"); return 1;
    }

    // First audio stream.
    int astream = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        if (fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) { astream = (int)i; break; }
    }
    if (astream < 0) { fprintf(stderr, "FAIL: no audio stream\n"); return 1; }

    AVCodecParameters *par = fmt->streams[astream]->codecpar;
    const AVCodec *dec = avcodec_find_decoder(par->codec_id);
    if (!dec) { fprintf(stderr, "FAIL: no decoder for codec_id %d (decoder not in this build?)\n", par->codec_id); return 1; }
    fprintf(stderr, "decoder: %s\n", dec->name);

    AVCodecContext *ctx = avcodec_alloc_context3(dec);
    if (avcodec_parameters_to_context(ctx, par) < 0) { fprintf(stderr, "FAIL: parameters_to_context\n"); return 1; }
    if (avcodec_open2(ctx, dec, NULL) < 0) { fprintf(stderr, "FAIL: avcodec_open2\n"); return 1; }

    // Decode until we get one full PCM frame.
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int got = 0, packets = 0;
    while (got == 0 && av_read_frame(fmt, pkt) >= 0) {
        if (pkt->stream_index != astream) { av_packet_unref(pkt); continue; }
        packets++;
        if (avcodec_send_packet(ctx, pkt) < 0) { av_packet_unref(pkt); continue; }
        int ret = avcodec_receive_frame(ctx, frame);
        if (ret == 0) {
            char layout[64] = "?";
            av_channel_layout_describe(&frame->ch_layout, layout, sizeof(layout));
            printf("PCM: samples=%d ch=%d layout=%s fmt=%s rate=%d pts=%lld\n",
                   frame->nb_samples, frame->ch_layout.nb_channels, layout,
                   av_get_sample_fmt_name(frame->format), frame->sample_rate,
                   (long long)frame->pts);
            got = 1;
        }
        av_packet_unref(pkt);
    }
    printf("packets consumed: %d, decoded frame: %s\n", packets, got ? "YES" : "NO");
    if (!got) { fprintf(stderr, "FAIL: no decoded frame\n"); return 1; }

    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&ctx);
    avformat_close_input(&fmt);
    printf("PASS\n");
    return 0;
}
