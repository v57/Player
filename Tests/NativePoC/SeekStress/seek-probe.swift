// seek-probe.swift — where does media_seek actually land? (Player, Sep 2026)
//
// The app's 1 s log after a seek to 287 s showed `fps=0.0 drop≈300/s vq=0` for
// 23 s while the node clock ran free: the classic signature of the demuxer
// WALKING the media from the file start instead of landing near the target.
// This probe measures it directly through the same bridge the app uses:
//   for each target: media_seek(d, target), then read packets and report
//   - the first video pts and first audio pts seen after the seek
//   - how many packets were consumed before an audio packet at/after the target
//
// Build/run (minimal ThirdParty-style build):
//   clang -c ../../Sources/SomePlayerCDemux/MediaDemuxer.c \
//       -I ../../Sources/FFmpeg/include -o /tmp/MediaDemuxer.o
//   xcrun swiftc seek-probe.swift /tmp/MediaDemuxer.o -I ../../Sources/FFmpeg/include \
//       -L ../../Sources/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header ../../Sources/SomePlayerCDemux/MediaDemuxer.h -o /tmp/seek-probe
//   DYLD_LIBRARY_PATH=../../Sources/FFmpeg/lib /tmp/seek-probe

import Foundation

let path = "/Users/v57/Projects/Player/video.mkv"

guard let d = media_open(path) else {
  fputs("FATAL: media_open failed\n", stderr)
  exit(1)
}
defer { media_close(d) }

let tracks = media_get_track_count(d)
print("tracks: \(tracks)")

/// Stream time bases, for seconds conversion.
func tb(_ index: Int32) -> (num: Int64, den: Int64) {
  var t = media_track_make()
  guard media_get_track(d, index, &t) == MEDIA_RESULT_OK else { return (1, 1000) }
  return (Int64(t.time_base_num), Int64(t.time_base_den))
}

func seconds(_ pts: Int64, _ index: Int32) -> Double? {
  guard pts != Int64.min else { return nil }
  let t = tb(index)
  return Double(pts) * Double(t.num) / Double(t.den)
}

let targets: [Double] = [27.237, 287.269, 1200.0, 4000.0]

for target in targets {
  print("\n=== seek to \(target) ===")
  let rc = media_seek(d, target)
  print("media_seek rc=\(rc)")

  var firstVideoPTS: Double?
  var firstAudioPTS: Double?
  var firstAudioAtOrAfterTarget: Double?
  var packetsRead = 0
  var videoPackets = 0
  var audioPackets = 0
  var audioAtTargetPackets = 0
  let maxPackets = 200_000

  while packetsRead < maxPackets {
    var pkt = media_packet_make()
    let r = media_read_packet(d, &pkt)
    if r != MEDIA_RESULT_OK {
      print("  read stopped: rc=\(r) after \(packetsRead) packets")
      media_packet_free(&pkt)
      break
    }
    packetsRead += 1
    let sid = Int32(pkt.stream_id)
    defer { media_packet_free(&pkt) }
    if sid == 0 {  // video
      videoPackets += 1
      if firstVideoPTS == nil { firstVideoPTS = seconds(pkt.pts, sid) }
    } else if sid == 1 {  // default audio (ac3 6ch)
      audioPackets += 1
      if firstAudioPTS == nil { firstAudioPTS = seconds(pkt.pts, sid) }
      if let s = seconds(pkt.pts, sid), s >= target - 0.05, firstAudioAtOrAfterTarget == nil {
        firstAudioAtOrAfterTarget = s
      }
    }
    // Stop once we have both anchors (or 3 s of media past the target).
    if let v = firstVideoPTS, let a = firstAudioAtOrAfterTarget, a >= target, v > target {
      break
    }
    if let a = firstAudioAtOrAfterTarget, a > target + 3.0 { break }
    if let v = firstVideoPTS, v > target + 60.0 { break }
  }
  _ = audioAtTargetPackets
  func fmt(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "none" }
  print("  packets read: \(packetsRead) (video \(videoPackets), audio \(audioPackets))")
  print("  first video pts:            \(fmt(firstVideoPTS))")
  print("  first audio pts:            \(fmt(firstAudioPTS))")
  print("  first audio pts >= target:  \(fmt(firstAudioAtOrAfterTarget))")
}
