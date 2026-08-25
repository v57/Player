// audio-play.swift — DTS -> PCM -> AVAudioEngine PoC (Wave-2).
//
// Opens video.mkv via the MediaDemuxer bridge, reads the channel layout of
// the default audio track (stream 1, DTS 5.1(side) 48 kHz), decodes ~2 s of
// PCM with the dca decoder (libavcodec via the bridge), builds an AVAudioFormat
// whose channel layout matches the source (5.1(side) -> kAudioChannelLayoutTag_MPEG_5_1_B),
// schedules the samples on an AVAudioPlayerNode, and renders OFFLINE (silent —
// no audio is audible) to prove the pipeline produces real PCM output.
//
// Build (Homebrew ffmpeg 8.1.2 dev PoC):
//   xcrun swiftc audio-play.swift MediaDemuxer.o -I /opt/homebrew/include \
//       -L /opt/homebrew/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o audio-play \
//       -framework AVFoundation -framework AudioToolbox
//
// ThirdParty build:
//   xcrun swiftc audio-play.swift MediaDemuxer.o -I ../../ThirdParty/FFmpeg/include \
//       -L ../../ThirdParty/FFmpeg/lib -lavformat -lavcodec -lavutil \
//       -import-objc-header MediaDemuxer.h -o audio-play \
//       -framework AVFoundation -framework AudioToolbox
//   DYLD_LIBRARY_PATH=../../ThirdParty/FFmpeg/lib ./audio-play

import AVFoundation
import AudioToolbox
import Foundation

let path = "/Users/v57/Projects/Player/video.mkv"
let targetAudioStream = 1  // default DTS track (lang rus)
let decodeSeconds = 2.0

func cstr(_ p: UnsafePointer<CChar>?) -> String {
  guard let p = p else { return "" }
  return String(cString: p)
}

// ---------- open + track metadata ----------
guard let d = media_open(path) else {
  fputs("FATAL: media_open failed\n", stderr)
  exit(1)
}
defer { media_close(d) }

var track = MediaTrack()
guard media_get_track(d, Int32(targetAudioStream), &track) == MEDIA_RESULT_OK else {
  fputs("FATAL: media_get_track(\(targetAudioStream)) failed\n", stderr)
  exit(1)
}
print(
  "audio track \(track.id): codec=\(cstr(media_track_codec_name(&track))) lang=\(cstr(media_track_language(&track))) channels=\(track.channel_count) rate=\(track.sample_rate)"
)

// ---------- channel layout (the 5.1 vs 5.1(side) distinction) ----------
var layoutMask: UInt64 = 0
var layoutNameBuf = [CChar](repeating: 0, count: 64)
guard
  media_get_track_channel_layout(
    d, Int32(targetAudioStream), &layoutMask, &layoutNameBuf, layoutNameBuf.count)
    == MEDIA_RESULT_OK
else {
  fputs("FATAL: media_get_track_channel_layout failed\n", stderr)
  exit(1)
}
let layoutName = String(cString: layoutNameBuf)
print("channel layout: mask=0x\(String(layoutMask, radix: 16)) name=\"\(layoutName)\"")

// Map FFmpeg layout name -> Core Audio layout tag. 5.1(side) is FL FR FC LFE
// BL BR (side surround) = kAudioChannelLayoutTag_MPEG_5_1_B; 5.1 is FL FR FC
// LFE SL SR (rear) = kAudioChannelLayoutTag_MPEG_5_1_A.
let layoutTag: AudioChannelLayoutTag
switch layoutName {
case "5.1(side)": layoutTag = kAudioChannelLayoutTag_MPEG_5_1_B
case "5.1": layoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
default: layoutTag = kAudioChannelLayoutTag_Unknown
}
print(
  "core audio layout tag: \(layoutTag == kAudioChannelLayoutTag_MPEG_5_1_B ? "MPEG_5_1_B (5.1 side)" : layoutTag == kAudioChannelLayoutTag_MPEG_5_1_A ? "MPEG_5_1_A (5.1 rear)" : "unknown/\(layoutTag)")"
)

// ---------- decode ~2 s of PCM ----------
let sampleRate = Int(track.sample_rate)
let maxSamples = Int32(Double(sampleRate) * decodeSeconds)
var frame = MediaAudioFrame()
let dr = media_decode_audio(d, Int32(targetAudioStream), maxSamples, &frame)
guard dr == MEDIA_RESULT_OK, let data = frame.data else {
  fputs("FATAL: media_decode_audio rc=\(dr)\n", stderr)
  exit(1)
}
defer { media_audio_frame_free(&frame) }

print(
  "decoded: \(frame.nb_samples) samples/ch @ \(frame.sample_rate) Hz, \(frame.channels) ch, layout=\"\(cstr(media_audio_frame_layout_name(&frame)))\" fmt=\(cstr(media_audio_frame_sample_fmt(&frame)))"
)
print("expected ~\(maxSamples) samples for \(decodeSeconds) s")

// ---------- AVAudioFormat matching the source layout ----------
guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else {
  fputs("FATAL: AVAudioChannelLayout(layoutTag:) failed\n", stderr)
  exit(1)
}
let format = AVAudioFormat(
  standardFormatWithSampleRate: Double(sampleRate), channelLayout: channelLayout)
print(
  "AVAudioFormat: rate=\(format.sampleRate) channels=\(format.channelCount) interleaved=\(format.isInterleaved)"
)

// ---------- fill an AVAudioPCMBuffer from the interleaved float32 ----------
let frameCount = AVAudioFrameCount(frame.nb_samples)
guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
  fputs("FATAL: AVAudioPCMBuffer allocation failed\n", stderr)
  exit(1)
}
pcmBuffer.frameLength = frameCount

// Standard-format non-interleaved: copy each channel's samples.
let channels = Int(format.channelCount)
let interleaved = [Float](UnsafeBufferPointer(start: data, count: Int(frame.nb_samples) * channels))
for ch in 0..<channels {
  guard let dst = pcmBuffer.floatChannelData?[ch] else { continue }
  for i in 0..<Int(frame.nb_samples) { dst[i] = interleaved[i * channels + ch] }
}

// ---------- offline render through AVAudioEngine (silent) ----------
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
engine.mainMixerNode.outputVolume = 0.0  // safety: nothing audible

do { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096) } catch
{
  fputs("FATAL: enableManualRenderingMode failed: \(error)\n", stderr)
  exit(1)
}
try? engine.start()
player.scheduleBuffer(pcmBuffer, at: nil)

let renderFrames = AVAudioFrameCount(min(4096, frameCount))
guard
  let outBuf = AVAudioPCMBuffer(
    pcmFormat: engine.manualRenderingFormat, frameCapacity: renderFrames)
else {
  fputs("FATAL: render buffer allocation failed\n", stderr)
  exit(1)
}
let status = try? engine.renderOffline(renderFrames, to: outBuf)
engine.stop()

let rendered = (status == .success) ? Int(outBuf.frameLength) : 0
print(
  "offline render: status=\(status == .success ? "success" : "failed(\(String(describing: status)))") frames=\(rendered)"
)

// ---------- assertions ----------
var pass = true
func check(_ cond: Bool, _ label: String) {
  print("\(cond ? "PASS" : "FAIL")  \(label)")
  if !cond { pass = false }
}

check(frame.channels == 6, "channel count == 6")
check(layoutName == "5.1(side)", "layout name == 5.1(side) (got \"\(layoutName)\")")
check(layoutTag == kAudioChannelLayoutTag_MPEG_5_1_B, "layout tag maps to MPEG_5_1_B")
check(format.channelCount == 6, "AVAudioFormat channel count == 6")
check(frame.nb_samples > 90_000, "decoded samples > 90000 (got \(frame.nb_samples))")
check(rendered > 0, "offline render produced frames (got \(rendered))")

print(pass ? "\nALL ASSERTIONS PASSED" : "\nASSERTIONS FAILED")
exit(pass ? 0 : 1)
