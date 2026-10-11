import SomePlayerCDemux
import XCTest

@testable import SomePlayer

/// The C bridge's AudioToolbox AAC decoder against the generated MP4 corpus
/// (a 440 Hz tone from t = 0). Skipped unless the corpus exists:
///
///     Tests/Scripts/build-robustness-corpus.sh
final class AACDecoderTests: XCTestCase {
  private struct Decoded {
    /// The track list's channel count and rate (what the UI shows).
    var track: NativeTrackInfo?
    var channels = 0
    var sampleRate = 0
    var layoutMask: UInt64 = 0
    var layoutName = ""
    var frames = 0
    /// Interleaved samples of the first decoded packet's output.
    var first: [Float] = []
    /// Per-channel RMS over the whole stream.
    var rms: [Float] = []
  }

  private func decodeAudio(_ name: String) throws -> Decoded {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Corpus/\(name)")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("\(name) missing — run Tests/Scripts/build-robustness-corpus.sh")
    }
    let demuxer = FFmpegDemuxer()
    try demuxer.open(url)
    guard
      let audio = (0..<demuxer.trackCount).compactMap({ demuxer.track(at: $0) }).first(where: {
        $0.type == MEDIA_TRACK_TYPE_AUDIO.rawValue
      })
    else { throw XCTSkip("\(name) has no audio") }
    let dec = try XCTUnwrap(media_audio_decoder_create(demuxer.unsafeHandle, Int32(audio.id)))
    defer { media_audio_decoder_free(dec) }

    var out = Decoded()
    out.track = audio
    var channels: Int32 = 0
    var rate: Int32 = 0
    var name = [CChar](repeating: 0, count: 64)
    XCTAssertEqual(
      Int(
        media_audio_decoder_get_format(dec, &channels, &rate, &out.layoutMask, &name, name.count)),
      MEDIA_RESULT_OK)
    out.channels = Int(channels)
    out.sampleRate = Int(rate)
    out.layoutName = String(
      decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var sums = [Float](repeating: 0, count: out.channels)

    while let pkt = try demuxer.readPacket() {
      guard pkt.streamID == audio.id else { continue }
      var cpkt = MediaPacket()
      cpkt.pts = pkt.pts
      cpkt.skip_start = pkt.skipStart
      cpkt.skip_end = pkt.skipEnd
      let sent = pkt.data.withUnsafeBytes { raw -> Int32 in
        cpkt.data = UnsafeMutablePointer(
          mutating: raw.baseAddress!.assumingMemoryBound(to: UInt8.self))
        cpkt.size = raw.count
        return media_audio_decoder_send(dec, &cpkt)
      }
      XCTAssertEqual(Int(sent), MEDIA_RESULT_OK)
      var frame = MediaAudioFrame()
      while media_audio_decoder_receive(dec, &frame) == MEDIA_RESULT_OK {
        defer { media_audio_frame_free(&frame) }
        XCTAssertEqual(Int(frame.channels), out.channels)
        let samples = UnsafeBufferPointer(
          start: frame.data, count: Int(frame.nb_samples) * out.channels)
        if out.first.isEmpty { out.first = Array(samples) }
        for (i, v) in samples.enumerated() { sums[i % out.channels] += v * v }
        out.frames += Int(frame.nb_samples)
      }
    }
    out.rms = sums.map { ($0 / Float(max(out.frames, 1))).squareRoot() }
    return out
  }

  private func rms(_ samples: ArraySlice<Float>) -> Float {
    (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
  }

  /// Stereo AAC-LC decodes to 10 s of the tone. The edit list's 1024 priming
  /// frames are trimmed, so the very first output is already the tone (the
  /// untrimmed first packet is the encoder's near-silent lead-in).
  func testMP4StereoDecodesWithPrimingTrimmed() throws {
    let d = try decodeAudio("h264-aac.mp4")
    XCTAssertEqual(d.channels, 2)
    XCTAssertEqual(d.sampleRate, 48000)
    XCTAssertEqual(d.layoutName, "stereo")
    XCTAssertEqual(Double(d.frames) / 48000, 10, accuracy: 0.05)
    XCTAssertGreaterThan(rms(d.first.prefix(512)), 0.05, "priming not trimmed")
    XCTAssertGreaterThan(d.rms[0], 0.05)
  }

  /// HE-AAC v2: the header describes a 24 kHz mono core; the decoder outputs
  /// (and the player and track list show) 48 kHz stereo.
  func testHEAACv2DecodesAtFullRateAndChannels() throws {
    let d = try decodeAudio("h264-heaacv2.mp4")
    XCTAssertEqual(d.channels, 2)
    XCTAssertEqual(d.sampleRate, 48000)
    XCTAssertEqual(d.track?.channelCount, 2)
    XCTAssertEqual(d.track?.sampleRate, 48000)
    XCTAssertEqual(Double(d.frames) / 48000, 10, accuracy: 0.2)
    XCTAssertGreaterThan(d.rms[0], 0.05)
    XCTAssertGreaterThan(d.rms[1], 0.05)
  }

  /// 5.1 AAC comes out in FFmpeg's native order with a native mask: the mono
  /// tone upmixed into the centre lands on FC (index 2), not on AAC's
  /// centre-first slot 0.
  func testSurroundAACIsReorderedToNativeOrder() throws {
    let d = try decodeAudio("h264-aac-51.mp4")
    XCTAssertEqual(d.channels, 6)
    XCTAssertEqual(d.layoutMask, 0x60F)  // FL FR FC LFE SL SR
    XCTAssertEqual(d.layoutName, "5.1(side)")
    XCTAssertGreaterThan(d.rms[2], 0.05)
    for ch in [0, 1, 3, 4, 5] { XCTAssertLessThan(d.rms[ch], 0.01, "channel \(ch)") }
  }

  /// Matroska AAC (CodecDelay, first packet timestamped before zero) decodes
  /// with its priming trimmed too. This track is a mono 44.1 kHz tone.
  func testMatroskaAACDecodes() throws {
    let d = try decodeAudio("h264-aac-then-ac3-51.mkv")
    XCTAssertEqual(d.channels, 1)
    XCTAssertEqual(d.sampleRate, 44100)
    XCTAssertEqual(d.layoutName, "mono")
    XCTAssertGreaterThan(rms(d.first.prefix(512)), 0.05, "priming not trimmed")
  }

  @MainActor func testMP4AndQuickTimeFilesAreAccepted() {
    for name in ["a.mkv", "a.mp4", "a.M4V", "a.mov"] {
      XCTAssertTrue(NativeSomePlayer.isSupportedFile(URL(fileURLWithPath: name)), name)
    }
    XCTAssertFalse(NativeSomePlayer.isSupportedFile(URL(fileURLWithPath: "a.avi")))
  }
}
