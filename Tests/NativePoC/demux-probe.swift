// demux-probe.swift — Swift CLI probe for the MediaDemuxer C bridge.
//
// Opens video.mkv, dumps container duration + per-track metadata, then reads
// the first 300 packets printing per-packet stream_id + pts/dts/duration in
// stream time-base units (rational num/den) AND seconds, with a running
// sanity check that video pts deltas are ~41/42 ms (23.976 fps at 1/1000).
//
// Build (dev PoC vs Homebrew ffmpeg 8.1.2):
//   clang -c MediaDemuxer.c -I/opt/homebrew/include -o MediaDemuxer.o
//   xcrun swiftc demux-probe.swift MediaDemuxer.o -I /opt/homebrew/include \
//       -L /opt/homebrew/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o demux-probe

import Foundation

let path = "/Users/v57/Projects/Player/video.mkv"
let packetLimit = 300

struct TB { let num: Int64; let den: Int64 }

func cstr(_ p: UnsafePointer<CChar>?) -> String {
    guard let p = p else { return "" }
    return String(cString: p)
}

func trackTypeName(_ t: MediaTrack) -> String {
    switch t.type {
    case MEDIA_TRACK_TYPE_VIDEO.rawValue: return "video"
    case MEDIA_TRACK_TYPE_AUDIO.rawValue: return "audio"
    case MEDIA_TRACK_TYPE_SUBTITLE.rawValue: return "subtitle"
    case MEDIA_TRACK_TYPE_ATTACHMENT.rawValue: return "attachment"
    default: return "unknown(\(t.type))"
    }
}

func secondsString(_ v: Int64, _ tb: TB) -> String {
    guard v != Int64.min else { return "N/A" }
    return String(format: "%.6f", Double(v) * Double(tb.num) / Double(tb.den))
}

func durationMsString(_ v: Int64, _ tb: TB) -> String {
    guard v != Int64.min else { return "N/A" }
    return String(format: "%.2f", Double(v) * 1000.0 * Double(tb.num) / Double(tb.den))
}

// ---------- open ----------
guard let d = media_open(path) else {
    fputs("FATAL: media_open(\"\(path)\") returned NULL\n", stderr)
    exit(1)
}
defer { media_close(d) }

let durMs = media_get_duration(d)
print(durMs >= 0
    ? String(format: "container: duration = %.3f s (%lld ms)", Double(durMs) / 1000.0, durMs)
    : "container: duration = unknown")

// ---------- tracks ----------
let trackCount = media_get_track_count(d)
print("tracks: \(trackCount)")
var tbByStream: [Int64: TB] = [:]
for i in 0..<trackCount {
    var t = MediaTrack()
    let r = media_get_track(d, Int32(i), &t)
    guard r == MEDIA_RESULT_OK else {
        print("  [track \(i)] ERROR: media_get_track returned \(r)")
        continue
    }
    let tb = TB(num: Int64(t.time_base_num), den: Int64(t.time_base_den))
    tbByStream[Int64(t.id)] = tb
    let codec = cstr(media_track_codec_name(&t))
    let lang = cstr(media_track_language(&t))
    let title = cstr(media_track_title(&t))
    print("  [track \(t.id)] type=\(trackTypeName(t)) codec=\(codec) codec_id=\(t.codec_id)"
        + " lang=\(lang.isEmpty ? "(none)" : lang) title=\(title.isEmpty ? "(none)" : title)"
        + " channels=\(t.channel_count) sample_rate=\(t.sample_rate)"
        + " tb=\(t.time_base_num)/\(t.time_base_den) default=\(t.is_default) forced=\(t.is_forced)")
}

// ---------- packets ----------
print("\nreading first \(packetLimit) packets ...")
var videoDeltaMs: [Int64: Int] = [:]
var videoDeltasAll: [Int64] = []
var lastVideoPts: Int64? = nil
var packetsRead = 0
var eofHit = false
var errHit = false
var errDetail = ""

while packetsRead < packetLimit {
    var pkt = MediaPacket()
    let r = media_read_packet(d, &pkt)
    if r == MEDIA_RESULT_EOF { eofHit = true; break }
    if r != MEDIA_RESULT_OK { errHit = true; errDetail = "media_read_packet returned \(r)"; break }
    defer { media_packet_free(&pkt) }

    let tb = tbByStream[pkt.stream_id] ?? TB(num: 1, den: 1000)
    let key = pkt.keyframe != 0 ? " key" : ""
    print("pkt stream=\(pkt.stream_id) pts=\(pkt.pts) (\(secondsString(pkt.pts, tb))s)"
        + " dts=\(pkt.dts) dur=\(durationMsString(pkt.duration, tb))ms tb=\(tb.num)/\(tb.den)\(key)")

    if pkt.stream_id == 0 && pkt.pts != Int64.min {
        if let prev = lastVideoPts {
            let delta = pkt.pts - prev
            let ms = Int64((Double(delta) * 1000.0 * Double(tb.num) / Double(tb.den)).rounded())
            videoDeltaMs[ms, default: 0] += 1
            videoDeltasAll.append(ms)
        }
        lastVideoPts = pkt.pts
    }
    packetsRead += 1
}

print("\nread \(packetsRead) packets\(eofHit ? " (hit EOF)" : "")\(errHit ? " (stopped early: \(errDetail))" : "")")

if videoDeltasAll.isEmpty {
    print("video sanity: no video (stream 0) pts deltas seen in first \(packetsRead) packets")
} else {
    let nominal = videoDeltasAll.filter { (40...43).contains($0) }.count
    let pct = Double(nominal) * 100.0 / Double(videoDeltasAll.count)
    let negative = videoDeltasAll.filter { $0 < 0 }.count
    let dist = videoDeltaMs.sorted { $0.key < $1.key }.map { "\($0.key)ms x\($0.value)" }.joined(separator: ", ")
    print("video sanity: \(videoDeltasAll.count) deltas, distribution: \(dist)")
    print("video sanity: nominal 40-43ms: \(nominal)/\(videoDeltasAll.count) (\(String(format: "%.1f", pct))%), negative: \(negative)")
    let pass = pct >= 95.0 && negative == 0
    print("video sanity: \(pass ? "PASS" : "FAIL") — pts cadence consistent with 23.976 fps (41/42 ms at tb 1/1000)")
}

// ---------- seek exercise ----------
print("\nseek test: media_seek(d, 3600.0)")
let seekResult = media_seek(d, 3600.0)
print("media_seek -> \(seekResult == MEDIA_RESULT_OK ? "OK" : "ERROR (\(seekResult))")")
var afterSeek: [String] = []
var got = 0
while got < 3 {
    var pkt = MediaPacket()
    let r = media_read_packet(d, &pkt)
    if r != MEDIA_RESULT_OK { break }
    defer { media_packet_free(&pkt) }
    let tb = tbByStream[pkt.stream_id] ?? TB(num: 1, den: 1000)
    afterSeek.append("stream=\(pkt.stream_id) pts=\(pkt.pts) (\(secondsString(pkt.pts, tb))s) key=\(pkt.keyframe)")
    got += 1
}
print("post-seek packets: \(afterSeek.isEmpty ? "(none)" : afterSeek.joined(separator: " | "))")
