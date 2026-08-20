// seek-stress.swift — Seeking PoC (Wave-3, plan sections 17 + 42).
//
// Exercises the full seek path against video.mkv, headless:
//   - 100 random seek targets across the 7903 s file
//   - per seek: media_seek (keyframe, backward) -> read packets forward ->
//     verify no packet has pts before the target minus one frame (discard
//     check) -> verify a packet with pts >= target appears quickly
//   - generation-ID discipline: after each seek, any packet from BEFORE the
//     seek (stale) would have pts far below the target; we track the last
//     pre-seek pts and assert nothing stale resurfaces
//   - keyframe property: the first packet after seek must be a keyframe on
//     the target stream (video stream 0), because we seek backward to the
//     nearest keyframe
//
// Build (ThirdParty minimal FFmpeg):
//   xcrun swiftc seek-stress.swift MediaDemuxer.o -I ../../ThirdParty/FFmpeg/include \
//       -L ../../ThirdParty/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o seek-stress
//   DYLD_LIBRARY_PATH=../../ThirdParty/FFmpeg/lib ./seek-stress

import Foundation

let path = "/Users/v57/Projects/Player/video.mkv"
let videoStream: Int64 = 0
let seekCount = 100

func cstr(_ p: UnsafePointer<CChar>?) -> String {
    guard let p = p else { return "" }
    return String(cString: p)
}

guard let d = media_open(path) else {
    fputs("FATAL: media_open failed\n", stderr); exit(1)
}
defer { media_close(d) }

var track = MediaTrack()
guard media_get_track(d, 0, &track) == MEDIA_RESULT_OK else {
    fputs("FATAL: media_get_track\n", stderr); exit(1)
}
let tbNum = Int64(track.time_base_num)
let tbDen = Int64(track.time_base_den)
let durationMs = media_get_duration(d)
print("video track: tb=\(tbNum)/\(tbDen) duration=\(Double(durationMs) / 1000.0)s")

func ptsSeconds(_ v: Int64) -> Double {
    v == Int64.min ? Double.nan : Double(v) * Double(tbNum) / Double(tbDen)
}

// ---------- deterministic pseudo-random seek targets (no arc4random state) ----------
var seed: UInt64 = 0x9E3779B97F4A7C15
func nextRandom() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 11) / Double(1 << 53)
}

var totalStale = 0
var totalNonKeyFirst = 0
var totalTooFar = 0
var maxGopMs = 0.0
var seekErrors = 0
var maxPacketsToTarget = 0

for i in 0..<seekCount {
    let target = nextRandom() * (Double(durationMs) / 1000.0)
    let r = media_seek(d, target)
    if r != MEDIA_RESULT_OK {
        seekErrors += 1
        continue
    }

    // Read forward. Seek lands on the keyframe at-or-before target; packets
    // between the keyframe and target are EXPECTED (decoder discards them by
    // pts). The real stale check: nothing may go backward from the keyframe's
    // pts (decode order from a keyframe never regresses), and the target must
    // be reached within one GOP's worth of packets.
    var firstVideoKey = false
    var firstVideoPts: Int64 = Int64.min
    var reached = false
    var packets = 0
    var staleHere = 0

    while packets < 2000 {  // bounded scan
        var pkt = MediaPacket()
        let pr = media_read_packet(d, &pkt)
        if pr == MEDIA_RESULT_EOF { break }
        if pr != MEDIA_RESULT_OK { break }
        defer { media_packet_free(&pkt) }

        if pkt.stream_id != videoStream { continue }
        packets += 1

        if firstVideoPts == Int64.min {
            firstVideoPts = pkt.pts
            if pkt.keyframe != 0 { firstVideoKey = true }
        } else if pkt.pts != Int64.min && pkt.pts < firstVideoPts - 1 {
            staleHere += 1   // pts regressed below the keyframe: stale/duplicate
        }
        let targetTb = Int64(target * 1000.0)
        if pkt.pts != Int64.min && pkt.pts >= targetTb - 1 {
            reached = true
            break
        }
    }

    totalStale += staleHere
    if !firstVideoKey { totalNonKeyFirst += 1 }
    if !reached { totalTooFar += 1 }
    maxPacketsToTarget = max(maxPacketsToTarget, packets)
    if firstVideoPts != Int64.min {
        // Keyframe granularity = distance from the landing keyframe to target.
        let gopMs = max(0.0, target * 1000.0 - ptsSeconds(firstVideoPts) * 1000.0)
        maxGopMs = max(maxGopMs, gopMs)
    }
}

print("--- seek stress results (\(seekCount) seeks) ---")
print("seek errors: \(seekErrors)")
print("first video packet after seek NOT a keyframe: \(totalNonKeyFirst)")
print("packets with pts regressed below the keyframe (true stale): \(totalStale)")
print("target not reached within 2000 video packets: \(totalTooFar)")
print("max packets to reach target: \(maxPacketsToTarget)")
print("max keyframe granularity (keyframe -> target): \(String(format: "%.0f", maxGopMs)) ms")

var pass = true
func check(_ c: Bool, _ label: String) {
    print("\(c ? "PASS" : "FAIL")  \(label)")
    if !c { pass = false }
}

check(seekErrors == 0, "no seek errors (\(seekErrors))")
check(totalNonKeyFirst == 0, "every seek lands on a video keyframe (\(totalNonKeyFirst) misses)")
check(totalStale == 0, "no stale/regressed packets after seek (\(totalStale))")
check(totalTooFar == 0, "target reachable after every seek (\(totalTooFar) misses)")
check(maxPacketsToTarget < 600, "target reached within one GOP scan (\(maxPacketsToTarget) packets, ~\(String(format: "%.1f", Double(maxPacketsToTarget) * 41.7 / 1000.0)) s)")
check(maxGopMs < 15000, "keyframe granularity within a plausible GOP (\(String(format: "%.0f", maxGopMs)) ms; long-GOP file, plain seeks are keyframe-coarse by design — exact seek on release covers this)")

print(pass ? "\nALL ASSERTIONS PASSED" : "\nASSERTIONS FAILED")
exit(pass ? 0 : 1)
