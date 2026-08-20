// vt-decode.swift — VideoToolbox H.264 decoder PoC over the MediaDemuxer bridge.
//
// Opens video.mkv via MediaDemuxer, parses the avcC (AVCDecoderConfigurationRecord)
// extradata to extract SPS/PPS, builds a CMVideoFormatDescription and a
// VTDecompressionSession ('420v' biplanar video-range), then feeds the first
// ~120 video packets as CMSampleBuffers (MKV packets are already AVCC
// length-prefixed, so they go in as-is) and collects the decoded frames.
//
// Build (dev PoC vs Homebrew ffmpeg 8.1.2):
//   clang -c MediaDemuxer.c -I/opt/homebrew/include -o MediaDemuxer.o
//   xcrun swiftc vt-decode.swift MediaDemuxer.o -I /opt/homebrew/include \
//       -L /opt/homebrew/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o vt-decode
//   (VideoToolbox / CoreMedia / CoreVideo / Foundation auto-link via import)

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

let path = "/Users/v57/Projects/Player/video.mkv"
let packetLimit = 120
let expectedWidth = 1920
let expectedHeight = 816
let expectedFourCC: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
let frameDuration = CMTime(value: 1001, timescale: 24000)  // 23.976 fps

struct TB { let num: Int64; let den: Int64 }

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

// ---------- avcC (AVCDecoderConfigurationRecord) parser ----------
// Layout: 1B configurationVersion, profile/compat/level (3B),
// 1B (2b reserved + lengthSizeMinusOne + 3b reserved + numSPS), per-SPS
// 2B length + SPS, 1B numPPS, per-PPS 2B length + PPS.
struct H264ParameterSets {
    var sps: [[UInt8]] = []
    var pps: [[UInt8]] = []
    var nalLengthSize = 4
    var parseError: String? = nil
}

func parseAVCC(_ data: Data) -> H264ParameterSets {
    var out = H264ParameterSets()
    let bytes = [UInt8](data)
    guard bytes.count >= 7 else {
        out.parseError = "avcC too short (\(bytes.count) B)"
        return out
    }
    guard bytes[0] == 1 else {
        out.parseError = "unexpected configurationVersion \(bytes[0])"
        return out
    }
    // byte 4: 6 reserved bits + 2 bits lengthSizeMinusOne
    let lengthSizeMinusOne = Int(bytes[4] & 0x03)
    out.nalLengthSize = lengthSizeMinusOne + 1
    // byte 5: 3 reserved bits + 5 bits numSPS
    let numSPS = Int(bytes[5] & 0x1F)
    var off = 6
    for _ in 0..<numSPS {
        guard off + 2 <= bytes.count else {
            out.parseError = "truncated SPS length at offset \(off)"
            return out
        }
        let len = (Int(bytes[off]) << 8) | Int(bytes[off + 1])
        off += 2
        guard off + len <= bytes.count else {
            out.parseError = "truncated SPS (\(len) B) at offset \(off)"
            return out
        }
        out.sps.append(Array(bytes[off..<off + len]))
        off += len
    }
    guard off < bytes.count else {
        out.parseError = "missing numPPS"
        return out
    }
    let numPPS = Int(bytes[off])
    off += 1
    for _ in 0..<numPPS {
        guard off + 2 <= bytes.count else {
            out.parseError = "truncated PPS length at offset \(off)"
            return out
        }
        let len = (Int(bytes[off]) << 8) | Int(bytes[off + 1])
        off += 2
        guard off + len <= bytes.count else {
            out.parseError = "truncated PPS (\(len) B) at offset \(off)"
            return out
        }
        out.pps.append(Array(bytes[off..<off + len]))
        off += len
    }
    return out
}

// ---------- frame collector (VT output callback runs on a VT thread) ----------
final class FrameCollector {
    struct FrameInfo {
        let index: Int
        let ptsSeconds: Double
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let planeCount: Int
        let bytesPerRow0: Int
    }

    private let lock = NSLock()
    private(set) var frames: [FrameInfo] = []
    private(set) var decodeErrors: [String] = []
    private(set) var dropped = 0

    func add(_ f: FrameInfo) {
        lock.lock(); defer { lock.unlock() }
        frames.append(f)
    }
    func recordError(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        decodeErrors.append(s)
    }
    func recordDropped() {
        lock.lock(); defer { lock.unlock() }
        dropped += 1
    }
}

let collector = FrameCollector()

let outputCallback: VTDecompressionOutputCallback = { refCon, _, status, infoFlags, imageBuffer, pts, _ in
    guard let refCon else { return }
    let c = Unmanaged<FrameCollector>.fromOpaque(refCon).takeUnretainedValue()
    if status != noErr {
        c.recordError("output callback status \(status)")
        return
    }
    guard let imageBuffer else { return }
    // CVImageBuffer and CVPixelBuffer are the same CVBuffer type in Swift.
    let pb = imageBuffer
    let index = c.frames.count
    c.add(FrameCollector.FrameInfo(
        index: index,
        ptsSeconds: CMTimeGetSeconds(pts),
        width: CVPixelBufferGetWidth(pb),
        height: CVPixelBufferGetHeight(pb),
        pixelFormat: CVPixelBufferGetPixelFormatType(pb),
        planeCount: CVPixelBufferGetPlaneCount(pb),
        bytesPerRow0: CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    ))
}

// ---------- open + locate video track ----------
guard let d = media_open(path) else {
    fputs("FATAL: media_open(\"\(path)\") returned NULL\n", stderr)
    exit(1)
}
defer { media_close(d) }

var videoIndex: Int32 = -1
var videoTB = TB(num: 1, den: 1000)
let trackCount = media_get_track_count(d)
for i in 0..<trackCount {
    var t = MediaTrack()
    guard media_get_track(d, Int32(i), &t) == MEDIA_RESULT_OK else { continue }
    if t.type == MEDIA_TRACK_TYPE_VIDEO.rawValue {
        videoIndex = Int32(i)
        videoTB = TB(num: Int64(t.time_base_num), den: Int64(t.time_base_den))
        print("video track: id=\(t.id) codec=\(cstr(media_track_codec_name(&t)))"
            + " dims=\(media_get_track_width(d, videoIndex))x\(media_get_track_height(d, videoIndex))"
            + " tb=\(videoTB.num)/\(videoTB.den)")
        break
    }
}
guard videoIndex >= 0 else {
    fputs("FATAL: no video track in \(path)\n", stderr)
    exit(1)
}

// ---------- extradata -> SPS/PPS -> format description ----------
var extradataPtr: UnsafePointer<UInt8>? = nil
var extradataSize: Int = 0
let extR = media_get_track_extradata(d, videoIndex, &extradataPtr, &extradataSize)
guard extR == MEDIA_RESULT_OK, let extradataPtr, extradataSize > 0 else {
    fputs("FATAL: media_get_track_extradata failed (rc=\(extR))\n", stderr)
    exit(1)
}
let avcc = Data(bytes: extradataPtr, count: extradataSize)
let hex = avcc.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
print("avcC extradata: \(extradataSize) B, head: \(hex)\(extradataSize > 16 ? " ..." : "")")

let ps = parseAVCC(avcc)
if let err = ps.parseError {
    fputs("FATAL: avcC parse failed: \(err)\n", stderr)
    exit(1)
}
print("parsed: \(ps.sps.count) SPS \(ps.sps.map { $0.count })B, \(ps.pps.count) PPS \(ps.pps.map { $0.count })B, NAL length size \(ps.nalLengthSize)")

guard !ps.sps.isEmpty && !ps.pps.isEmpty else {
    fputs("FATAL: avcC has no SPS/PPS\n", stderr)
    exit(1)
}

// NOTE: build the pointers from [UInt8] arrays with withUnsafeBufferPointer —
// pointers from Data.withUnsafeBytes that escape the closure are invalid and
// make CMVideoFormatDescriptionCreateFromH264ParameterSets return -12712.
var spsPtrs: [UnsafePointer<UInt8>] = []
var spsSizes: [Int] = []
for s in ps.sps {
    s.withUnsafeBufferPointer { raw in
        spsPtrs.append(raw.baseAddress!)
        spsSizes.append(s.count)
    }
}
var ppsPtrs: [UnsafePointer<UInt8>] = []
var ppsSizes: [Int] = []
for p in ps.pps {
    p.withUnsafeBufferPointer { raw in
        ppsPtrs.append(raw.baseAddress!)
        ppsSizes.append(p.count)
    }
}
var allPtrs = spsPtrs + ppsPtrs
var allSizes = spsSizes + ppsSizes

var formatDesc: CMVideoFormatDescription?
let fdStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(
    allocator: kCFAllocatorDefault,
    parameterSetCount: allPtrs.count,
    parameterSetPointers: &allPtrs,
    parameterSetSizes: &allSizes,
    nalUnitHeaderLength: Int32(ps.nalLengthSize),
    formatDescriptionOut: &formatDesc)
guard fdStatus == noErr, let formatDesc else {
    fputs("FATAL: CMVideoFormatDescriptionCreateFromH264ParameterSets failed: OSStatus \(fdStatus)\n", stderr)
    exit(1)
}
let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
print("format description: \(dims.width)x\(dims.height) codec=\(fourccString(CMFormatDescriptionGetMediaSubType(formatDesc)))")

// ---------- decompression session ----------
var session: VTDecompressionSession?
let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferWidthKey as String: expectedWidth,
    kCVPixelBufferHeightKey as String: expectedHeight,
]
var cbRecord = VTDecompressionOutputCallbackRecord(
    decompressionOutputCallback: outputCallback,
    decompressionOutputRefCon: Unmanaged.passUnretained(collector).toOpaque())
let vtStatus = VTDecompressionSessionCreate(
    allocator: kCFAllocatorDefault,
    formatDescription: formatDesc,
    decoderSpecification: nil,
    imageBufferAttributes: attrs as CFDictionary,
    outputCallback: &cbRecord,
    decompressionSessionOut: &session)
guard vtStatus == noErr, let session else {
    fputs("FATAL: VTDecompressionSessionCreate failed: OSStatus \(vtStatus) (\(fourccString(UInt32(bitPattern: vtStatus))))\n", stderr)
    exit(1)
}
defer { VTDecompressionSessionInvalidate(session) }

// macOS 27 SDK: session property access moved from VTDecompressionSession* to
// the shared VTSession* functions; the hw-accel property key gained "Video".
VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
var hw: CFTypeRef?
if VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: &hw) == noErr, let hw {
    print("decompression session: hardware = \((hw as? NSNumber)?.boolValue ?? false)")
}

// ---------- feed ~120 video packets ----------
print("\nfeeding up to \(packetLimit) video packets (async decode) ...")
var packets: [MediaPacket] = []   // keep packet data alive until the drain
var fed = 0
var feedErrors: [String] = []
var lastPts: CMTime? = nil

while fed < packetLimit {
    var pkt = MediaPacket()
    let r = media_read_packet(d, &pkt)
    if r == MEDIA_RESULT_EOF { break }
    if r != MEDIA_RESULT_OK {
        feedErrors.append("media_read_packet rc=\(r)")
        break
    }
    if pkt.stream_id != Int64(videoIndex) {
        media_packet_free(&pkt)
        continue
    }

    // Timing: pts in stream time base -> CMTime seconds; AV_NOPTS_VALUE
    // (Int64.min) -> previous pts + frame duration (or zero for the first).
    var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    if pkt.pts != Int64.min {
        let ptsCM = CMTime(value: pkt.pts * videoTB.num, timescale: Int32(videoTB.den))
        timing.presentationTimeStamp = ptsCM
        lastPts = ptsCM
    } else if let prev = lastPts {
        timing.presentationTimeStamp = prev + frameDuration
        lastPts = timing.presentationTimeStamp
    } else {
        timing.presentationTimeStamp = .zero
        lastPts = .zero
    }

    var blockBuffer: CMBlockBuffer?
    let bbErr = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: pkt.data,
        blockLength: pkt.size,
        blockAllocator: kCFAllocatorNull,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: pkt.size,
        flags: 0,
        blockBufferOut: &blockBuffer)
    guard bbErr == noErr, let blockBuffer else {
        feedErrors.append("CMBlockBufferCreateWithMemoryBlock OSStatus \(bbErr) at fed=\(fed)")
        media_packet_free(&pkt)
        break
    }

    var sampleBuffer: CMSampleBuffer?
    var sampleSize = pkt.size
    let sbErr = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDesc,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize,
        sampleBufferOut: &sampleBuffer)
    guard sbErr == noErr, let sampleBuffer else {
        feedErrors.append("CMSampleBufferCreate OSStatus \(sbErr) at fed=\(fed)")
        media_packet_free(&pkt)
        break
    }

    let dfErr = VTDecompressionSessionDecodeFrame(
        session,
        sampleBuffer: sampleBuffer,
        // macOS 27 SDK: VTDecodeFrameFlags cases import with the prefix
        // stripped to a bare underscore (kVTDecodeFrame_ -> _).
        flags: [._EnableAsynchronousDecompression],
        frameRefcon: nil,
        infoFlagsOut: nil)
    guard dfErr == noErr else {
        feedErrors.append("VTDecompressionSessionDecodeFrame OSStatus \(dfErr) at fed=\(fed)")
        media_packet_free(&pkt)
        break
    }

    packets.append(pkt)
    fed += 1
}
print("fed \(fed) video packets")

// ---------- drain ----------
let waitErr = VTDecompressionSessionWaitForAsynchronousFrames(session)
if waitErr != noErr {
    feedErrors.append("VTDecompressionSessionWaitForAsynchronousFrames OSStatus \(waitErr)")
}
for i in 0..<packets.count { media_packet_free(&packets[i]) }

// ---------- report ----------
print("\n--- decoded frames (\(collector.frames.count)) ---")
for f in collector.frames {
    var line = String(format: "frame %3d pts=%8.4fs %4dx%-4d fourcc=%@ planes=%d",
                      f.index, f.ptsSeconds, f.width, f.height, fourccString(f.pixelFormat), f.planeCount)
    if f.index == 0 { line += String(format: " bytesPerRow0=%d", f.bytesPerRow0) }
    print(line)
}
if collector.dropped > 0 {
    print("note: \(collector.dropped) frames dropped by decoder")
}

// ---------- sanity assertions ----------
var allPass = true
func check(_ cond: Bool, _ label: String) {
    print("assert: \(label): \(cond ? "PASS" : "FAIL")")
    if !cond { allPass = false }
}

check(collector.frames.count > 0, "decoded frame count > 0 (\(collector.frames.count))")
check(collector.frames.count == fed, "all fed packets produced frames (\(collector.frames.count)/\(fed))")
let dimsOK = collector.frames.allSatisfy { $0.width == expectedWidth && $0.height == expectedHeight }
check(dimsOK, "all frames \(expectedWidth)x\(expectedHeight)")
let fmtOK = collector.frames.allSatisfy { $0.pixelFormat == expectedFourCC }
check(fmtOK, "pixel format \(fourccString(expectedFourCC))")
// VT outputs frames in DECODE order; with B-frames the client must reorder by
// pts before presentation. Verify presentation order (sorted by pts) is sane.
var reorderCount = 0
for i in 1..<collector.frames.count where collector.frames[i].ptsSeconds < collector.frames[i - 1].ptsSeconds {
    reorderCount += 1
}
let presentationOrder = collector.frames.sorted { $0.ptsSeconds < $1.ptsSeconds }
var ptsIncreasing = true
for i in 1..<presentationOrder.count where presentationOrder[i].ptsSeconds <= presentationOrder[i - 1].ptsSeconds {
    ptsIncreasing = false
}
check(ptsIncreasing, "pts increasing in presentation order (sorted by pts)")
if reorderCount > 0 {
    print("note: \(reorderCount) frames delivered out of pts order (stream has B-frames; decoder outputs decode order) — client must reorder by pts before display")
}
check(collector.decodeErrors.isEmpty && feedErrors.isEmpty,
      "no decode errors\(feedErrors.isEmpty ? "" : " (\(feedErrors.joined(separator: "; ")))")")

print("\nRESULT: \(allPass ? "ALL ASSERTIONS PASSED" : "ASSERTIONS FAILED")")
exit(allPass ? 0 : 1)
