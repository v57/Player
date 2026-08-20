// fd-probe.c — isolate CMVideoFormatDescriptionCreateFromH264ParameterSets
// from C (no Swift bridging) using the MediaDemuxer bridge for the avcC bytes.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreFoundation/CoreFoundation.h>
#include "MediaDemuxer.h"

int main(void) {
    const char *path = "/Users/v57/Projects/Player/video.mkv";
    MediaDemuxer *d = media_open(path);
    if (!d) { printf("media_open failed\n"); return 1; }

    const uint8_t *avcc = NULL;
    size_t avccSize = 0;
    int r = media_get_track_extradata(d, 0, &avcc, &avccSize);
    if (r != MEDIA_RESULT_OK || !avcc) { printf("extradata failed rc=%d\n", r); return 1; }
    printf("avcC: %zu B\n", avccSize);
    for (size_t i = 0; i < avccSize; i++) printf("%02x ", avcc[i]);
    printf("\n");

    // parse avcC
    int lengthSizeMinusOne = avcc[4] & 0x03;
    int numSPS = avcc[5] & 0x1F;
    size_t off = 6;
    const uint8_t *sps = NULL, *pps = NULL;
    size_t spsLen = 0, ppsLen = 0;
    for (int i = 0; i < numSPS; i++) {
        size_t len = ((size_t)avcc[off] << 8) | avcc[off + 1];
        off += 2;
        sps = avcc + off; spsLen = len;
        off += len;
    }
    int numPPS = avcc[off++];
    for (int i = 0; i < numPPS; i++) {
        size_t len = ((size_t)avcc[off] << 8) | avcc[off + 1];
        off += 2;
        pps = avcc + off; ppsLen = len;
        off += len;
    }
    printf("SPS %zu B: ", spsLen); for (size_t i = 0; i < spsLen; i++) printf("%02x ", sps[i]); printf("\n");
    printf("PPS %zu B: ", ppsLen); for (size_t i = 0; i < ppsLen; i++) printf("%02x ", pps[i]); printf("\n");

    const uint8_t *ptrs[2] = { sps, pps };
    size_t sizes[2] = { spsLen, ppsLen };
    for (int nalLen = 4; nalLen >= 1; nalLen--) {
        CMVideoFormatDescriptionRef fd = NULL;
        OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, 2, ptrs, sizes, nalLen, &fd);
        printf("nalUnitHeaderLength=%d -> OSStatus %d (%s)\n", nalLen, st, fd ? "created" : "NULL");
        if (fd) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
            printf("  dims %dx%d\n", dims.width, dims.height);
            CFRelease(fd);
        }
    }
    media_close(d);
    return 0;
}
