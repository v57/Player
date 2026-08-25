// corpus-check.swift — automated metadata verification over the robustness
// corpus (plan section 48). For each file: open via the MediaDemuxer bridge,
// report duration + track summary + chapter count, then exercise a seek.
//
// Build (ThirdParty minimal FFmpeg):
//   xcrun swiftc corpus-check.swift MediaDemuxer-tp.o -I ../../ThirdParty/FFmpeg/include \
//       -L ../../ThirdParty/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o corpus-check
//   DYLD_LIBRARY_PATH=../../ThirdParty/FFmpeg/lib ./corpus-check <file...>

import Foundation

func cstr(_ p: UnsafePointer<CChar>?) -> String {
  guard let p = p else { return "" }
  return String(cString: p)
}

let args = CommandLine.arguments
guard args.count > 1 else {
  fputs("usage: corpus-check <file...>\n", stderr)
  exit(2)
}

var failures = 0
for path in args.dropFirst() {
  let name = (path as NSString).lastPathComponent
  guard let d = media_open(path) else {
    print("\(name): OPEN FAILED")
    failures += 1
    continue
  }
  defer { media_close(d) }

  let durMs = media_get_duration(d)
  let durStr = durMs >= 0 ? String(format: "%.3fs", Double(durMs) / 1000.0) : "unknown"
  var parts: [String] = []
  let n = media_get_track_count(d)
  for i in 0..<n {
    var t = media_track_make()
    guard media_get_track(d, Int32(i), &t) == MEDIA_RESULT_OK else { continue }
    let type: String
    switch t.type {
    case MEDIA_TRACK_TYPE_VIDEO.rawValue: type = "v"
    case MEDIA_TRACK_TYPE_AUDIO.rawValue: type = "a"
    case MEDIA_TRACK_TYPE_SUBTITLE.rawValue: type = "s"
    case MEDIA_TRACK_TYPE_ATTACHMENT.rawValue: type = "att"
    default: type = "?"
    }
    let codec = cstr(media_track_codec_name(&t))
    if t.channel_count > 0 {
      parts.append("\(type):\(codec)(\(t.channel_count)ch)")
    } else {
      parts.append("\(type):\(codec)")
    }
  }
  let chapters = Int(media_get_chapter_count(d))

  // Seek exercise: to 40 % of duration (or 1 s when unknown), then read
  // until we see a video packet.
  let target = durMs >= 0 ? Double(durMs) / 1000.0 * 0.4 : 1.0
  let seekOK = media_seek(d, target) == MEDIA_RESULT_OK
  var sawVideoAfterSeek = false
  var attempts = 0
  while attempts < 500 {
    var pkt = media_packet_make()
    let r = media_read_packet(d, &pkt)
    if r == MEDIA_RESULT_EOF { break }
    if r != MEDIA_RESULT_OK { break }
    defer { media_packet_free(&pkt) }
    attempts += 1
    if pkt.stream_id == 0 && pkt.pts != Int64.min && pkt.keyframe != 0 {
      sawVideoAfterSeek = true
      break
    }
  }

  let status = seekOK && sawVideoAfterSeek ? "OK" : "SEEK-ISSUE"
  if !(seekOK && sawVideoAfterSeek) { failures += 1 }
  print(
    "\(name): dur=\(durStr) chapters=\(chapters) tracks=[\(parts.joined(separator: ", "))] seek40%=\(status)"
  )
}

print(failures == 0 ? "\nCORPUS CHECK: ALL OK" : "\nCORPUS CHECK: \(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
