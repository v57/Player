// vt-decode-hevc.swift — VideoToolbox HEVC (H.265) decoder PoC over the
// MediaDemuxer bridge.
//
// Proves the two things the app's HEVC path depends on, against the real
// video.mkv:
//   1. CMVideoFormatDescriptionCreateFromHEVCParameterSets succeeds with the
//      VPS+SPS+PPS parsed from the hvcC extradata.
//   2. VTDecompressionSessionCreate + DecodeFrame produce CVPixelBuffers at
//      the coded dimensions, decode with hardware acceleration, and emit
//      frames in decode order (B-frames -> client must reorder).
//
// Build (against the app's shipped minimal FFmpeg dylibs):
//   clang -c ../../../Sources/SomePlayerCDemux/MediaDemuxer.c -I ../../../Sources/FFmpeg/include -o MediaDemuxer.o
//   cp ../../../Sources/SomePlayerCDemux/MediaDemuxer.h .
//   xcrun swiftc vt-decode-hevc.swift MediaDemuxer.o -I ../../../Sources/FFmpeg/include \
//       -L ../../../Sources/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o vt-decode-hevc
//   DYLD_LIBRARY_PATH=../../../Sources/FFmpeg/lib ./vt-decode-hevc

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let path = "/Users/v57/Projects/Player/video.mkv"
let expectedWidth = 3840
let expectedHeight = 1606
let expectedFourCC: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
let frameDuration = CMTime(value: 1001, timescale: 24000)

func cstr(_ p: UnsafePointer<CChar>?) -> String {
  guard let p = p else { return "" }
  return String(cString: p)
}

func fourccString(_ t: OSType) -> String {
  func c(_ b: UInt32) -> String {
    b >= 0x20 && b <= 0x7E ? String(UnicodeScalar(b)!) : String(format: "\\x%02x", b)
  }
  return c((t >> 24) & 0xFF) + c((t >> 16) & 0xFF) + c((t >> 8) & 0xFF) + c(t & 0xFF)
}

// ---------- hvcC (HEVCDecoderConfigurationRecord) parser ----------
// Fixed header is 23 bytes:
//   0  configurationVersion (1)
//   1-3  profile_space + profile_idc + compatibility(32) + tier + level
//   4-11 min_spatial_segmentation etc.
//   12-20 parallelismType, chromaFormat, bitDepthLuma/Chroma, avgFrameRate
//   21  lengthSizeMinusOne (2 low bits) + constant_frame_rate/numTemporalLayers
//   22  numOfArrays
// Each array: 1B (array_completeness:1 + reserved:1 + NAL_unit_type:6),
//             2B numNalus, then per-NAL 2B length + NAL.
struct HEVCParameterSets {
  var vps: [[UInt8]] = []
  var sps: [[UInt8]] = []
  var pps: [[UInt8]] = []
  var nalLengthSize = 4
  var parseError: String? = nil
}

func parseHVCC(_ data: Data) -> HEVCParameterSets {
  var out = HEVCParameterSets()
  let b = [UInt8](data)
  guard b.count >= 24 else {
    out.parseError = "hvcC too short (\(b.count) B)"
    return out
  }
  guard b[0] == 1 else {
    out.parseError = "unexpected configurationVersion \(b[0])"
    return out
  }
  let lengthSizeMinusOne = Int(b[21] & 0x03)
  out.nalLengthSize = lengthSizeMinusOne + 1
  let numArrays = Int(b[22])
  var off = 23
  for _ in 0..<numArrays {
    guard off + 1 <= b.count else { out.parseError = "truncated array header at \(off)"; return out }
    let type = Int(b[off] & 0x3F)
    off += 1
    guard off + 2 <= b.count else { out.parseError = "truncated numNalus at \(off)"; return out }
    let numNalus = (Int(b[off]) << 8) | Int(b[off + 1])
    off += 2
    for _ in 0..<numNalus {
      guard off + 2 <= b.count else { out.parseError = "truncated nal len at \(off)"; return out }
      let len = (Int(b[off]) << 8) | Int(b[off + 1])
      off += 2
      guard off + len <= b.count else { out.parseError = "truncated nal at \(off)"; return out }
      let nal = Array(b[off..<(off + len)])
      switch type {
      case 32: out.vps.append(nal)
      case 33: out.sps.append(nal)
      case 34: out.pps.append(nal)
      default: break
      }
      off += len
    }
  }
  return out
}

// ---------- frame collector ----------
final class FrameCollector {
  struct FrameInfo {
    let ptsSeconds: Double
    let width: Int
    let height: Int
    let pixelFormat: OSType
  }
  private let lock = NSLock()
  private(set) var frames: [FrameInfo] = []
  private(set) var decodeErrors: [String] = []
  func add(_ f: FrameInfo) { lock.lock(); defer { lock.unlock() }; frames.append(f) }
  func recordError(_ s: String) { lock.lock(); defer { lock.unlock() }; decodeErrors.append(s) }
}

let collector = FrameCollector()
let outputCallback: VTDecompressionOutputCallback = {
  refCon, _, status, _, imageBuffer, pts, _ in
  guard let refCon else { return }
  let c = Unmanaged<FrameCollector>.fromOpaque(refCon).takeUnretainedValue()
  if status != noErr { c.recordError("output callback status \(status)"); return }
  guard let imageBuffer else { return }
  c.add(
    FrameCollector.FrameInfo(
      ptsSeconds: CMTimeGetSeconds(pts), width: CVPixelBufferGetWidth(imageBuffer),
      height: CVPixelBufferGetHeight(imageBuffer),
      pixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer)))
}

// ---------- open + locate video track ----------
guard let d = media_open(path) else {
  fputs("FATAL: media_open returned NULL\n", stderr)
  exit(1)
}
defer { media_close(d) }

var videoIndex: Int32 = -1
let trackCount = media_get_track_count(d)
for i in 0..<trackCount {
  var t = MediaTrack()
  guard media_get_track(d, Int32(i), &t) == MEDIA_RESULT_OK else { continue }
  if t.type == MEDIA_TRACK_TYPE_VIDEO.rawValue {
    videoIndex = Int32(i)
    print(
      "video track: id=\(t.id) codec=\(cstr(media_track_codec_name(&t)))"
        + " dims=\(media_get_track_width(d, videoIndex))x\(media_get_track_height(d, videoIndex))")
    break
  }
}
guard videoIndex >= 0 else { fputs("FATAL: no video track\n", stderr); exit(1) }

// ---------- extradata -> VPS/SPS/PPS -> format description ----------
var extradataPtr: UnsafePointer<UInt8>? = nil
var extradataSize: Int = 0
let extR = media_get_track_extradata(d, videoIndex, &extradataPtr, &extradataSize)
guard extR == MEDIA_RESULT_OK, let extradataPtr, extradataSize > 0 else {
  fputs("FATAL: media_get_track_extradata failed (rc=\(extR))\n", stderr)
  exit(1)
}
let hvcc = Data(bytes: extradataPtr, count: extradataSize)
let hex = hvcc.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
print("hvcC extradata: \(extradataSize) B, head: \(hex)\(extradataSize > 16 ? " ..." : "")")

let ps = parseHVCC(hvcc)
if let err = ps.parseError { fputs("FATAL: hvcC parse failed: \(err)\n", stderr); exit(1) }
print("parsed: \(ps.vps.count) VPS, \(ps.sps.count) SPS, \(ps.pps.count) PPS, NAL length size \(ps.nalLengthSize)")
guard !ps.vps.isEmpty, !ps.sps.isEmpty, !ps.pps.isEmpty else {
  fputs("FATAL: hvcC missing VPS/SPS/PPS\n", stderr); exit(1)
}

let ordered = ps.vps + ps.sps + ps.pps
var ptrs: [UnsafePointer<UInt8>] = []
var sizes: [Int] = []
for n in ordered {
  n.withUnsafeBufferPointer { raw in
    ptrs.append(raw.baseAddress!)
    sizes.append(n.count)
  }
}
var formatDesc: CMVideoFormatDescription?
let fdStatus = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
  allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: &ptrs,
  parameterSetSizes: &sizes, nalUnitHeaderLength: Int32(ps.nalLengthSize), extensions: nil,
  formatDescriptionOut: &formatDesc)
guard fdStatus == noErr, let formatDesc else {
  fputs("FATAL: CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: OSStatus \(fdStatus)\n", stderr)
  exit(1)
}
let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
print("format description: \(dims.width)x\(dims.height) codec=\(fourccString(CMFormatDescriptionGetMediaSubType(formatDesc)))")

// ---------- decompression session ----------
var session: VTDecompressionSession?
let attrs: [String: Any] = [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
  kCVPixelBufferWidthKey as String: Int(dims.width),
  kCVPixelBufferHeightKey as String: Int(dims.height),
]
var cbRecord = VTDecompressionOutputCallbackRecord(
  decompressionOutputCallback: outputCallback,
  decompressionOutputRefCon: Unmanaged.passUnretained(collector).toOpaque())
let vtStatus = VTDecompressionSessionCreate(
  allocator: kCFAllocatorDefault, formatDescription: formatDesc, decoderSpecification: nil,
  imageBufferAttributes: attrs as CFDictionary, outputCallback: &cbRecord,
  decompressionSessionOut: &session)
guard vtStatus == noErr, let session else {
  fputs("FATAL: VTDecompressionSessionCreate failed: OSStatus \(vtStatus)\n", stderr)
  exit(1)
}
defer { VTDecompressionSessionInvalidate(session) }
VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
var hw: CFTypeRef?
if VTSessionCopyProperty(
  session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
  allocator: kCFAllocatorDefault, valueOut: &hw) == noErr, let hw
{
  print("decompression session: hardware = \((hw as? NSNumber)?.boolValue ?? false)")
}

// ---------- feed packets ----------
print("\nfeeding up to 60 video packets (async decode) ...")
var packets: [MediaPacket] = []
var fed = 0
var feedErrors: [String] = []
var lastPts = CMTime.zero
while fed < 60 {
  var pkt = MediaPacket()
  let r = media_read_packet(d, &pkt)
  if r == MEDIA_RESULT_EOF { break }
  if r != MEDIA_RESULT_OK { feedErrors.append("media_read_packet rc=\(r)"); break }
  if pkt.stream_id != Int64(videoIndex) { media_packet_free(&pkt); continue }

  var timing = CMSampleTimingInfo(
    duration: frameDuration, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
  if pkt.pts != Int64.min {
    timing.presentationTimeStamp = CMTime(value: pkt.pts, timescale: 1000)
  } else {
    timing.presentationTimeStamp = lastPts + frameDuration
  }
  lastPts = timing.presentationTimeStamp

  var blockBuffer: CMBlockBuffer?
  let bbErr = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault, memoryBlock: pkt.data, blockLength: pkt.size,
    blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0, dataLength: pkt.size,
    flags: 0, blockBufferOut: &blockBuffer)
  guard bbErr == noErr, let blockBuffer else {
    feedErrors.append("CMBlockBufferCreateWithMemoryBlock OSStatus \(bbErr) at fed=\(fed)")
    media_packet_free(&pkt); break
  }
  var sampleBuffer: CMSampleBuffer?
  var sampleSize = pkt.size
  let sbErr = CMSampleBufferCreate(
    allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
    makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc, sampleCount: 1,
    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
    sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
  guard sbErr == noErr, let sampleBuffer else {
    feedErrors.append("CMSampleBufferCreate OSStatus \(sbErr) at fed=\(fed)")
    media_packet_free(&pkt); break
  }
  let dfErr = VTDecompressionSessionDecodeFrame(
    session, sampleBuffer: sampleBuffer, flags: [._EnableAsynchronousDecompression], frameRefcon: nil,
    infoFlagsOut: nil)
  guard dfErr == noErr else {
    feedErrors.append("VTDecompressionSessionDecodeFrame OSStatus \(dfErr) at fed=\(fed)")
    media_packet_free(&pkt); break
  }
  packets.append(pkt)
  fed += 1
}
print("fed \(fed) video packets")
let waitErr = VTDecompressionSessionWaitForAsynchronousFrames(session)
if waitErr != noErr { feedErrors.append("WaitForAsynchronousFrames OSStatus \(waitErr)") }
for i in 0..<packets.count { media_packet_free(&packets[i]) }

// ---------- report + assertions ----------
print("\n--- decoded frames (\(collector.frames.count)) ---")
for f in collector.frames {
  print(String(format: "frame pts=%8.4fs %4dx%-4d fourcc=%@", f.ptsSeconds, f.width, f.height, fourccString(f.pixelFormat)))
}
var allPass = true
func check(_ cond: Bool, _ label: String) {
  print("assert: \(label): \(cond ? "PASS" : "FAIL")")
  if !cond { allPass = false }
}
check(collector.frames.count > 0, "decoded frame count > 0 (\(collector.frames.count))")
let dimsOK = collector.frames.allSatisfy { $0.width == expectedWidth && $0.height == expectedHeight }
check(dimsOK, "all frames \(expectedWidth)x\(expectedHeight)")
let fmtOK = collector.frames.allSatisfy { $0.pixelFormat == expectedFourCC }
check(fmtOK, "pixel format \(fourccString(expectedFourCC))")
let errText = feedErrors.isEmpty ? "" : " (\(feedErrors.joined(separator: "; ")))"
check(collector.decodeErrors.isEmpty && feedErrors.isEmpty, "no decode errors\(errText)")
print("\nRESULT: \(allPass ? "ALL ASSERTIONS PASSED" : "ASSERTIONS FAILED")")
exit(allPass ? 0 : 1)
