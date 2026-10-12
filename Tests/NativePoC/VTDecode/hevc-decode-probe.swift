// hevc-decode-probe.swift — deterministic VideoToolbox HEVC decode check over
// the MediaDemuxer bridge, mimicking the app's EXACT HEVC path.
//
// Why: the Player decoded a 4K Main10 HEVC file at ~6 fps with
// kVTVideoDecoderMalfunctionErr (-12909) on bursts of frames, while ffmpeg
// decoded the same range cleanly. This probe isolates VideoToolbox + stream
// from the app's scheduling/backpressure: it recovers the parameter sets the
// same way (in-band, because CodecPrivate is a bare 23-byte hvcC), builds the
// format description and the pixel-buffer attributes the same way, then feeds
// N video packets from a mid-file position and reports every decode status.
//
// Build (app's shipped minimal FFmpeg dylibs):
//   clang -c ../../../Sources/PlayerCDemux/MediaDemuxer.c -I ../../../Sources/FFmpeg/include -o /tmp/MediaDemuxer.o
//   xcrun swiftc hevc-decode-probe.swift /tmp/MediaDemuxer.o -I ../../../Sources/FFmpeg/include \
//       -L ../../../Sources/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header ../../../Sources/PlayerCDemux/MediaDemuxer.h -o /tmp/hevc-decode-probe
//   DYLD_LIBRARY_PATH=../../../Sources/FFmpeg/lib /tmp/hevc-decode-probe

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let path = "/Users/v57/Projects/Player/video.mkv"
let startAt = Double(CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 900)
let framesToFeed = 600
let frameDuration = CMTime(value: 1001, timescale: 24000)

func cstr(_ p: UnsafePointer<CChar>?) -> String {
  guard let p = p else { return "" }
  return String(cString: p)
}

guard let d = media_open(path) else {
  fputs("FATAL: media_open failed\n", stderr)
  exit(1)
}
defer { media_close(d) }

// ---------- find the video stream ----------
var videoIndex: Int32 = -1
var tbNum: Int64 = 1
var tbDen: Int64 = 1000
for i in 0..<Int32(media_get_track_count(d)) {
  var t = media_track_make()
  guard media_get_track(d, i, &t) == MEDIA_RESULT_OK else { continue }
  if t.type == MEDIA_TRACK_TYPE_VIDEO.rawValue {
    videoIndex = i
    tbNum = Int64(t.time_base_num)
    tbDen = Int64(t.time_base_den)
    print("video stream \(i): \(cstr(media_track_codec_name(&t))) \(t.channel_count) ch tb=\(tbNum)/\(tbDen)")
    break
  }
}
guard videoIndex >= 0 else { fputs("FATAL: no video stream\n", stderr); exit(1) }

// ---------- extradata / in-band parameter sets ----------
var ptr: UnsafePointer<UInt8>?
var size = 0
guard media_get_track_extradata(d, videoIndex, &ptr, &size) == MEDIA_RESULT_OK, let ptr else {
  fputs("FATAL: no extradata\n", stderr)
  exit(1)
}
let extradata = [UInt8](UnsafeBufferPointer(start: ptr, count: size))
var lengthSize = extradata.count > 21 ? Int(extradata[21] & 0x03) + 1 : 4
print("extradata \(size) B, lengthSize=\(lengthSize), numOfArrays=\(extradata.count > 22 ? Int(extradata[22]) : -1)")

var vps: [[UInt8]] = []
var sps: [[UInt8]] = []
var pps: [[UInt8]] = []

/// In-band recovery: the app's inBandHVCC — read video packets from the start
/// and pull VPS(32)/SPS(33)/PPS(34) out of the length-prefixed NAL stream.
if size < 24 || (size > 22 && extradata[22] == 0) {
  _ = media_seek(d, 0)
  var scanned = 0
  while scanned < 64, vps.isEmpty || sps.isEmpty || pps.isEmpty {
    var pkt = media_packet_make()
    guard media_read_packet(d, &pkt) == MEDIA_RESULT_OK else { break }
    defer { media_packet_free(&pkt) }
    guard Int32(pkt.stream_id) == videoIndex else { continue }
    scanned += 1
    var b = [UInt8](UnsafeBufferPointer(start: pkt.data, count: pkt.size))
    var off = 0
    while off + lengthSize <= b.count {
      var nlen = 0
      for i in 0..<lengthSize { nlen = (nlen << 8) | Int(b[off + i]) }
      off += lengthSize
      guard nlen > 0, off + nlen <= b.count else { break }
      let nalType = (b[off] >> 1) & 0x3F
      let nal = Array(b[off..<(off + nlen)])
      if nalType == 32 { vps.append(nal) }
      else if nalType == 33 { sps.append(nal) }
      else if nalType == 34 { pps.append(nal) }
      off += nlen
    }
  }
  print("in-band recovery: scanned \(scanned) packets, vps=\(vps.count) sps=\(sps.count) pps=\(pps.count)")
}
guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else {
  fputs("FATAL: no parameter sets\n", stderr)
  exit(1)
}

// ---------- format description (app's makeFormatDescription shape) ----------
var packed = [UInt8]()
var offsets: [Int] = []
var sizes: [Int] = []
for n in vps + sps + pps {
  offsets.append(packed.count)
  sizes.append(n.count)
  packed.append(contentsOf: n)
}
var fd: CMVideoFormatDescription?
let fdStatus = packed.withUnsafeBufferPointer { pk -> OSStatus in
  let base = pk.baseAddress!
  let pts: [UnsafePointer<UInt8>] = offsets.map { base + $0 }
  return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
    allocator: kCFAllocatorDefault, parameterSetCount: pts.count, parameterSetPointers: pts,
    parameterSetSizes: sizes, nalUnitHeaderLength: Int32(lengthSize), extensions: nil,
    formatDescriptionOut: &fd)
}
guard fdStatus == noErr, let fd else {
  fputs("FATAL: format description failed \(fdStatus)\n", stderr)
  exit(1)
}
let dims = CMVideoFormatDescriptionGetDimensions(fd)
print("format description: \(dims.width)x\(dims.height)")

// ---------- decode session (app's attributes) ----------
final class Counters: @unchecked Sendable {
  var ok = 0
  var failed = 0
  var dropFlag = 0
  var failures: [(Double, Int32)] = []
}
let counters = Counters()
let attrs: [String: Any] = [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
  kCVPixelBufferWidthKey as String: Int(dims.width),
  kCVPixelBufferHeightKey as String: Int(dims.height),
]
var cbRecord = VTDecompressionOutputCallbackRecord(
  decompressionOutputCallback: { refCon, _, status, infoFlags, imageBuffer, pts, _ in
    let c = Unmanaged<Counters>.fromOpaque(refCon!).takeUnretainedValue()
    let t = CMTimeGetSeconds(pts)
    if status == noErr, imageBuffer != nil {
      c.ok += 1
    } else {
      c.failed += 1
      if c.failures.count < 12 { c.failures.append((t, status)) }
    }
    if infoFlags.contains(.frameDropped) { c.dropFlag += 1 }
  }, decompressionOutputRefCon: Unmanaged.passUnretained(counters).toOpaque())
var session: VTDecompressionSession?
let sStatus = VTDecompressionSessionCreate(
  allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
  imageBufferAttributes: attrs as CFDictionary, outputCallback: &cbRecord,
  decompressionSessionOut: &session)
guard sStatus == noErr, let session else {
  fputs("FATAL: session create failed \(sStatus)\n", stderr)
  exit(1)
}
var hw: CFTypeRef?
VTSessionCopyProperty(
  session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder as CFString,
  allocator: kCFAllocatorDefault, valueOut: &hw)
print("hardware accelerated: \(hw.map { "\($0)" } ?? "unknown")")

// ---------- feed N frames from `startAt` ----------
let seekRC = media_seek(d, startAt)
print("seek to \(startAt): rc=\(seekRC)")
var fed = 0
var keyframes = 0
var firstFailurePTS: Double?
var lastPTS: Double = -1
var nonMonotonic = 0
while fed < framesToFeed {
  var pkt = media_packet_make()
  guard media_read_packet(d, &pkt) == MEDIA_RESULT_OK else { break }
  defer { media_packet_free(&pkt) }
  guard Int32(pkt.stream_id) == videoIndex else { continue }
  fed += 1
  if pkt.keyframe == 1 { keyframes += 1 }
  let ptsSeconds = pkt.pts == Int64.min ? -1 : Double(pkt.pts) * Double(tbNum) / Double(tbDen)
  if ptsSeconds >= 0, ptsSeconds <= lastPTS { nonMonotonic += 1 }
  if ptsSeconds >= 0 { lastPTS = ptsSeconds }

  let n = Int(pkt.size)
  var block: CMBlockBuffer?
  guard
    CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: n, flags: 0, blockBufferOut: &block) == noErr, let block
  else { continue }
  let copied = CMBlockBufferReplaceDataBytes(
    with: pkt.data, blockBuffer: block, offsetIntoDestination: 0, dataLength: n)
  guard copied == noErr else { continue }

  var timing = CMSampleTimingInfo(
    duration: frameDuration,
    presentationTimeStamp: ptsSeconds < 0
      ? .invalid : CMTime(value: Int64(ptsSeconds * 1000), timescale: 1000),
    decodeTimeStamp: .invalid)
  var sbuf: CMSampleBuffer?
  var sampleSize = n
  guard
    CMSampleBufferCreate(
      allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
      makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize, sampleBufferOut: &sbuf) == noErr, let sbuf
  else { continue }

  let before = counters.failed
  VTDecompressionSessionDecodeFrame(
    session, sampleBuffer: sbuf, flags: [], frameRefcon: nil, infoFlagsOut: nil)
  if counters.failed > before, firstFailurePTS == nil { firstFailurePTS = ptsSeconds }
}

print("\nfed \(fed) video packets (\(keyframes) keyframes, nonMonotonicPTS=\(nonMonotonic)) from \(startAt) s")
print("ok=\(counters.ok)  failed=\(counters.failed)  dropFlag=\(counters.dropFlag)")
print("first failure pts: \(firstFailurePTS.map { String(format: "%.3f", $0) } ?? "none")")
print("first failures (pts, status): \(counters.failures.map { (String(format: "%.3f", $0.0), $0.1) })")
print(counters.failed == 0 ? "PASS: decoder clean over this range" : "FAIL: decoder reported errors")
exit(counters.failed == 0 ? 0 : 1)
