// hvcc-probe.swift — does video.mkv's video stream carry its HEVC parameter
// sets in CodecPrivate (hvcC) or IN-BAND (numOfArrays == 0)?
//
// If they are in-band, the app's hevcParameterSets() falls back to
// inBandHVCC(), which seek(0)s the demuxer — and performSeek calls
// setupVideoToolbox on every seek, so a seek silently becomes "walk the media
// from 0" (measured: 23 s of wall time and 6900 dropped frames for a seek to
// 287 s; the video then stays ~22 s behind the audio clock).
//
// Build (same as seek-probe):
//   clang -c ../../Sources/SomePlayerCDemux/MediaDemuxer.c -I ../../Sources/FFmpeg/include -o /tmp/MediaDemuxer.o
//   xcrun swiftc hvcc-probe.swift /tmp/MediaDemuxer.o -I ../../Sources/FFmpeg/include \
//       -L ../../Sources/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header ../../Sources/SomePlayerCDemux/MediaDemuxer.h -o /tmp/hvcc-probe
//   DYLD_LIBRARY_PATH=../../Sources/FFmpeg/lib /tmp/hvcc-probe

import Foundation

let path = "/Users/v57/Projects/Player/video.mkv"
guard let d = media_open(path) else {
  fputs("FATAL: media_open failed\n", stderr)
  exit(1)
}
defer { media_close(d) }

for index in 0..<Int32(media_get_track_count(d)) {
  var t = media_track_make()
  guard media_get_track(d, index, &t) == MEDIA_RESULT_OK else { continue }
  guard t.type == MEDIA_TRACK_TYPE_VIDEO.rawValue else { continue }
  var ptr: UnsafePointer<UInt8>?
  var size = 0
  guard media_get_track_extradata(d, index, &ptr, &size) == MEDIA_RESULT_OK, let ptr else {
    print("video stream \(index): no extradata")
    continue
  }
  let b = [UInt8](UnsafeBufferPointer(start: ptr, count: size))
  print("video stream \(index) (\(String(cString: media_track_codec_name(&t)))) extradata \(size) bytes")
  if size > 23 {
    let lengthSize = Int(b[21] & 0x03) + 1
    let numArrays = Int(b[22])
    print("  b[21]=0x\(String(b[21], radix: 16)) -> lengthSize=\(lengthSize)")
    print("  b[22]=\(numArrays)  (numOfArrays)")
    var off = 23
    for _ in 0..<numArrays {
      guard off < size else { break }
      let type = Int(b[off] & 0x3F)
      off += 1
      guard off + 2 <= size else { break }
      let numNalus = (Int(b[off]) << 8) | Int(b[off + 1])
      off += 2
      print("  array NAL type \(type) (\(type == 32 ? "VPS" : type == 33 ? "SPS" : type == 34 ? "PPS" : "?")) count \(numNalus)")
      for _ in 0..<numNalus {
        guard off + 2 <= size else { break }
        let len = (Int(b[off]) << 8) | Int(b[off + 1])
        off += 2 + len
      }
    }
    print("  => parameter sets \(numArrays == 0 ? "IN-BAND (hvcC bare header)" : "in CodecPrivate")")
  } else {
    print("  extradata too small for an hvcC header (\(size) bytes) => IN-BAND")
  }
}
