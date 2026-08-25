// sync-play.swift — A/V synchronization PoC (Wave-3, plan milestone 7).
//
// The complete native pipeline in miniature, HEADLESS and deterministic:
//   - demux: two MediaDemuxer handles (audio + video) over video.mkv
//   - audio: dca decode (media_decode_audio) -> AVAudioPCMBuffer scheduled on
//     an AVAudioPlayerNode in OFFLINE manual rendering mode. The engine clock
//     advances exactly `renderedFrames / sampleRate` seconds per renderOffline
//     call — this IS the master clock (audio = master, plan section 14).
//   - video: VideoToolbox decode of the same window (hardware, 420v)
//   - sync: decoded frames are reordered by PTS (VT emits decode order; the
//     37/120 out-of-order finding from Wave-2), then presented when
//     framePTS <= masterClock (+ display slack). Drift is measured per frame.
//
// Offline mode = silent by construction (no audio hardware is touched).
//
// Build (ThirdParty minimal FFmpeg):
//   xcrun swiftc sync-play.swift MediaDemuxer.o -I ../../ThirdParty/FFmpeg/include \
//       -L ../../ThirdParty/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o sync-play \
//       -framework AVFoundation -framework AudioToolbox \
//       -framework VideoToolbox -framework CoreMedia -framework CoreVideo
//   DYLD_LIBRARY_PATH=../../ThirdParty/FFmpeg/lib ./sync-play

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let path = "/Users/v57/Projects/Player/video.mkv"
let audioStream = 1  // default DTS track
let videoStream = 0
let windowSeconds = 5.0  // sync window
let sampleRate = 48000

func cstr(_ p: UnsafePointer<CChar>?) -> String {
  guard let p = p else { return "" }
  return String(cString: p)
}

// ---------- open two demuxers (audio + video advance independently) ----------
guard let da = media_open(path), let dv = media_open(path) else {
  fputs("FATAL: media_open failed\n", stderr)
  exit(1)
}
defer {
  media_close(da)
  media_close(dv)
}

// ---------- decode the audio window (dca -> interleaved float32) ----------
let audioSamples = Int32(Double(sampleRate) * windowSeconds)
var aframe = MediaAudioFrame()
let dr = media_decode_audio(da, Int32(audioStream), audioSamples, &aframe)
guard dr == MEDIA_RESULT_OK, let audioData = aframe.data, aframe.channels == 6 else {
  fputs("FATAL: audio decode rc=\(dr)\n", stderr)
  exit(1)
}
defer { media_audio_frame_free(&aframe) }
print(
  "audio: \(aframe.nb_samples) samples, \(aframe.channels) ch, \(cstr(media_audio_frame_layout_name(&aframe)))"
)

// ---------- AVAudioFormat + buffer (5.1(side) -> MPEG_5_1_B) ----------
let layoutTag: AudioChannelLayoutTag =
  cstr(media_audio_frame_layout_name(&aframe)) == "5.1(side)"
  ? kAudioChannelLayoutTag_MPEG_5_1_B : kAudioChannelLayoutTag_MPEG_5_1_A
let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag)!
let aformat = AVAudioFormat(
  standardFormatWithSampleRate: Double(sampleRate), channelLayout: channelLayout)
let nFrames = Int(aframe.nb_samples)
let pcmBuffer = AVAudioPCMBuffer(pcmFormat: aformat, frameCapacity: AVAudioFrameCount(nFrames))!
pcmBuffer.frameLength = AVAudioFrameCount(nFrames)
let interleaved = [Float](UnsafeBufferPointer(start: audioData, count: nFrames * 6))
for ch in 0..<6 {
  guard let dst = pcmBuffer.floatChannelData?[ch] else { continue }
  for i in 0..<nFrames { dst[i] = interleaved[i * 6 + ch] }
}

// ---------- offline engine = the master clock ----------
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: aformat)
engine.mainMixerNode.outputVolume = 0.0  // offline mode anyway; belt and braces
try! engine.enableManualRenderingMode(.offline, format: aformat, maximumFrameCount: 4096)
try! engine.start()
player.scheduleBuffer(pcmBuffer, at: nil)
// In offline mode the clock is deterministic: renderedFrames / sampleRate.
let renderChunk = AVAudioFrameCount(2048)
let totalRenderFrames = nFrames
var renderedSoFar = 0
var masterClock: Double { Double(renderedSoFar) / Double(sampleRate) }

// ---------- video: VT decode the window, reorder by PTS ----------
// Format description from avcC extradata.
var avcc: UnsafePointer<UInt8>? = nil
var avccSize: Int = 0
guard media_get_track_extradata(dv, Int32(videoStream), &avcc, &avccSize) == MEDIA_RESULT_OK,
  let avcc, avccSize > 0
else {
  fputs("FATAL: extradata\n", stderr)
  exit(1)
}
let avccBytes = [UInt8](UnsafeBufferPointer(start: avcc, count: avccSize))
let lengthSizeMinusOne = Int(avccBytes[4] & 0x03)
let numSPS = Int(avccBytes[5] & 0x1F)
var spsList: [[UInt8]] = []
var off = 6
for _ in 0..<numSPS {
  let len = (Int(avccBytes[off]) << 8) | Int(avccBytes[off + 1])
  off += 2
  spsList.append(Array(avccBytes[off..<(off + len)]))
  off += len
}
let numPPS = Int(avccBytes[off])
off += 1
var ppsList: [[UInt8]] = []
for _ in 0..<numPPS {
  let len = (Int(avccBytes[off]) << 8) | Int(avccBytes[off + 1])
  off += 2
  ppsList.append(Array(avccBytes[off..<(off + len)]))
  off += len
}
var allPtrs: [UnsafePointer<UInt8>] = []
var allSizes: [Int] = []
for s in spsList {
  s.withUnsafeBufferPointer {
    allPtrs.append($0.baseAddress!)
    allSizes.append(s.count)
  }
}
for p in ppsList {
  p.withUnsafeBufferPointer {
    allPtrs.append($0.baseAddress!)
    allSizes.append(p.count)
  }
}
var formatDesc: CMVideoFormatDescription?
let fds = CMVideoFormatDescriptionCreateFromH264ParameterSets(
  allocator: kCFAllocatorDefault, parameterSetCount: allPtrs.count, parameterSetPointers: &allPtrs,
  parameterSetSizes: &allSizes, nalUnitHeaderLength: Int32(lengthSizeMinusOne + 1),
  formatDescriptionOut: &formatDesc)
guard fds == noErr, let formatDesc else {
  fputs("FATAL: format description\n", stderr)
  exit(1)
}

// Frame collector: thread-safe box for decoded frames.
final class FrameBox: @unchecked Sendable {
  let lock = NSLock()
  var frames: [(pts: Double, pixel: CVPixelBuffer)] = []
  var reorderNeeded = 0
  func add(_ pts: Double, _ px: CVPixelBuffer) {
    lock.lock()
    frames.append((pts, px))
    lock.unlock()
  }
}
let box = FrameBox()
let callback: VTDecompressionOutputCallback = { refCon, _, status, _, imageBuffer, pts, _ in
  guard let refCon else { return }
  let b = Unmanaged<FrameBox>.fromOpaque(refCon).takeUnretainedValue()
  if status != noErr { return }
  guard let imageBuffer else { return }
  let pb = imageBuffer
  let t = CMTimeGetSeconds(pts)
  CVPixelBufferLockBaseAddress(pb, .readOnly)
  b.add(t, pb)
  CVPixelBufferUnlockBaseAddress(pb, .readOnly)
}
var cbRecord = VTDecompressionOutputCallbackRecord(
  decompressionOutputCallback: callback,
  decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())
var session: VTDecompressionSession?
let attrs: [String: Any] = [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
  kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 816,
]
let vts = VTDecompressionSessionCreate(
  allocator: kCFAllocatorDefault, formatDescription: formatDesc, decoderSpecification: nil,
  imageBufferAttributes: attrs as CFDictionary, outputCallback: &cbRecord,
  decompressionSessionOut: &session)
guard vts == noErr, let session else {
  fputs("FATAL: VT session\n", stderr)
  exit(1)
}
defer { VTDecompressionSessionInvalidate(session) }
VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

// Feed video packets for the window (stream time base 1/1000).
let videoTB: (num: Int64, den: Int32) = (1, 1000)
let frameDur = CMTime(value: 1001, timescale: 24000)
var fed = 0
var lastPts: CMTime? = nil
while fed < 500 {  // 5 s * 23.976 + margin
  var pkt = MediaPacket()
  let r = media_read_packet(dv, &pkt)
  if r == MEDIA_RESULT_EOF { break }
  if r != MEDIA_RESULT_OK { break }
  defer { media_packet_free(&pkt) }
  if pkt.stream_id != Int64(videoStream) { continue }

  var timing = CMSampleTimingInfo(
    duration: frameDur, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
  if pkt.pts != Int64.min {
    let ptsCM = CMTime(value: pkt.pts * videoTB.num, timescale: videoTB.den)
    timing.presentationTimeStamp = ptsCM
    lastPts = ptsCM
  } else if let prev = lastPts {
    timing.presentationTimeStamp = prev + frameDur
    lastPts = timing.presentationTimeStamp
  } else {
    timing.presentationTimeStamp = .zero
    lastPts = .zero
  }

  var block: CMBlockBuffer?
  let bbe = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault, memoryBlock: pkt.data, blockLength: pkt.size,
    blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0, dataLength: pkt.size,
    flags: 0, blockBufferOut: &block)
  guard bbe == noErr, let block else { continue }
  var sbuf: CMSampleBuffer?
  var sampleSize = pkt.size
  let sbs = CMSampleBufferCreate(
    allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
    refcon: nil, formatDescription: formatDesc, sampleCount: 1, sampleTimingEntryCount: 1,
    sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
    sampleBufferOut: &sbuf)
  guard sbs == noErr, let sbuf else { continue }
  // macOS 27 SDK: kVTDecodeFrame_ prefix strips to a bare underscore.
  VTDecompressionSessionDecodeFrame(
    session, sampleBuffer: sbuf, flags: [._EnableAsynchronousDecompression], frameRefcon: nil,
    infoFlagsOut: nil)
  fed += 1
}
VTDecompressionSessionWaitForAsynchronousFrames(session)

// ---------- reorder by PTS (decode order -> presentation order) ----------
let decoded = box.frames.sorted { $0.pts < $1.pts }
var reordered = 0
for i in 1..<decoded.count where decoded[i].pts < decoded[i - 1].pts { reordered += 1 }
print(
  "video: fed \(fed) packets, decoded \(decoded.count) frames, out-of-order pairs in decode order: \(reordered)"
)

// ---------- the sync loop: present frames as the audio clock passes them ----------
var presented = 0
var maxDrift = 0.0
var maxLatency = 0.0
var idx = 0
let displaySlack = 0.030  // 30 ms: frame may be presented up to this late
var presentedPTS: [Double] = []

let outBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: renderChunk)!
while renderedSoFar < totalRenderFrames {
  let chunk = AVAudioFrameCount(min(Int(renderChunk), totalRenderFrames - renderedSoFar))
  let status = try? engine.renderOffline(chunk, to: outBuf)
  guard status == .success else { break }
  renderedSoFar += Int(chunk)

  let clock = masterClock
  while idx < decoded.count && decoded[idx].pts <= clock + displaySlack {
    let drift = clock - decoded[idx].pts
    maxDrift = max(maxDrift, drift)
    maxLatency = max(maxLatency, decoded[idx].pts - clock)
    presented += 1
    presentedPTS.append(decoded[idx].pts)
    idx += 1
  }
}

// ---------- assertions ----------
var pass = true
func check(_ c: Bool, _ label: String) {
  print("\(c ? "PASS" : "FAIL")  \(label)")
  if !c { pass = false }
}

let expectedFrames = Int(Double(windowSeconds) * 24000.0 / 1001.0)  // ~119.9
print(
  "clock advanced: \(masterClock)s; presented \(presented) frames; max late \(String(format: "%.1f", maxDrift * 1000)) ms; max early \(String(format: "%.1f", maxLatency * 1000)) ms"
)

check(
  presented >= expectedFrames - 2,
  "presented ≈ \(expectedFrames) frames in \(windowSeconds) s (got \(presented))")
check(
  maxDrift < 0.050,
  "no frame presented more than 50 ms late (max \(String(format: "%.1f", maxDrift * 1000)) ms)")
check(
  maxLatency < 0.050,
  "no frame presented more than 50 ms early (max \(String(format: "%.1f", maxLatency * 1000)) ms)")
check(presentedPTS == presentedPTS.sorted(), "frames presented in ascending PTS order")
check(decoded.count >= expectedFrames - 2, "decoded enough frames (got \(decoded.count))")

print(pass ? "\nALL ASSERTIONS PASSED" : "\nASSERTIONS FAILED")
exit(pass ? 0 : 1)
