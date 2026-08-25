import AVFoundation
import XCTest

@testable import MediaPlayer

/// Offline (manual rendering) tests for the dialogue-enhancement AU chain.
///
/// Silent by construction: AVAudioEngine manual rendering mode never touches
/// an output device. The downmix MATH is covered by the pure DownmixMatrix/
/// ChannelRole/preset tests; these tests exercise the live AU chain —
/// passthrough identity, compression behavior, the -1 dBFS ceiling, runtime
/// mode switching, EQ behavior, and added latency.
final class AudioChainRenderTests: XCTestCase {
  private let rate = 48_000.0

  private var stereo: AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
  }

  private func makeChain(_ engine: AVAudioEngine) throws -> AudioEnhancementChain {
    guard let chain = AudioEnhancementChain(engine: engine) else {
      throw XCTSkip("Audio enhancement units unavailable on this machine")
    }
    return chain
  }

  /// Fills a stereo buffer with a sine tone.
  private func tone(_ amplitude: Float, frequency: Double = 1000, frames: Int) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
      let v = amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / rate))
      buf.floatChannelData![0][i] = v
      buf.floatChannelData![1][i] = v
    }
    return buf
  }

  /// Renders one 1024-frame chunk from the running offline engine and appends
  /// it to `out` at the current frameLength. Returns false at end-of-data.
  @discardableResult private func renderChunk(engine: AVAudioEngine, into out: AVAudioPCMBuffer)
    -> Bool
  {
    guard let scratch = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 1024) else {
      return false
    }
    let want = min(AVAudioFrameCount(1024), out.frameCapacity - out.frameLength)
    guard want > 0 else { return false }
    let status = try? engine.renderOffline(want, to: scratch)
    guard status == .success, scratch.frameLength > 0 else { return false }
    let n = Int(scratch.frameLength)
    let start = Int(out.frameLength)
    for ch in 0..<2 {
      let dst = out.floatChannelData![ch]
      let src = scratch.floatChannelData![ch]
      for i in 0..<n { dst[start + i] = src[i] }
    }
    out.frameLength += scratch.frameLength
    return true
  }

  /// Renders everything through a fresh chain+engine. Returns the output.
  private func renderOnce(preset: AudioEnhancementPreset, input: AVAudioPCMBuffer) throws
    -> AVAudioPCMBuffer
  {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let chain = try makeChain(engine)
    chain.install(player: player, mainMixer: engine.mainMixerNode, format: stereo)
    chain.apply(preset: preset)
    try? engine.start()
    player.scheduleBuffer(input, at: nil)
    player.play()
    let out = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: input.frameLength)!
    while renderChunk(engine: engine, into: out) {}
    return out
  }

  private func rms(_ buf: AVAudioPCMBuffer) -> Float {
    guard let d = buf.floatChannelData?[0] else { return -1 }
    var acc: Float = 0
    let n = Int(buf.frameLength)
    for i in 0..<n { acc += d[i] * d[i] }
    return (acc / Float(max(n, 1))).squareRoot()
  }

  private func peak(_ buf: AVAudioPCMBuffer) -> Float {
    guard let d0 = buf.floatChannelData?[0], let d1 = buf.floatChannelData?[1] else { return -1 }
    var p: Float = 0
    for i in 0..<Int(buf.frameLength) { p = max(p, abs(d0[i]), abs(d1[i])) }
    return p
  }

  // MARK: - Passthrough identity (original)

  func testOriginalIsPassthrough() throws {
    let input = tone(0.5, frames: 12_000)
    let out = try renderOnce(preset: .preset(for: .original), input: input)
    // All units bypassed, no trim: sine RMS = amp/sqrt(2) must survive.
    XCTAssertEqual(
      rms(out), 0.5 * 0.7071, accuracy: 0.04, "bypassed chain must not alter the signal")
  }

  // MARK: - Compression (balanced)

  func testCompressorTamesLoudInput() throws {
    let quiet = try renderOnce(preset: .preset(for: .balanced), input: tone(0.05, frames: 12_000))
    let loud = try renderOnce(preset: .preset(for: .balanced), input: tone(0.8, frames: 12_000))
    let quietRMS = rms(quiet)
    let loudRMS = rms(loud)
    // Input ratio is 16x; the compressor must narrow it substantially (a
    // static tone under deep reduction; real program material responds
    // dynamically). The loud signal must be restrained, quiet must survive.
    print(
      "[Audio] compressor test: quiet \(quietRMS) loud \(loudRMS) ratio \(loudRMS / max(quietRMS, 1e-6)) (input ratio 16)"
    )
    XCTAssertLessThan(
      loudRMS / max(quietRMS, 1e-6), 10.0,
      "compression must narrow the quiet/loud gap (input ratio 16x)")
    XCTAssertLessThan(loudRMS, 0.4, "loud input must be restrained")
    XCTAssertGreaterThan(quietRMS, 0.02, "quiet content must survive")
  }

  // MARK: - Limiter / ceiling (dialogue)

  func testOutputStaysBelowCeiling() throws {
    // Full-scale simultaneous 5.1(side) input downmixed per the dialogue
    // preset (matrix L = FL + FC*1.0 + SL*0.707 = 2.7) through the chain.
    let roles: [ChannelRole] = [.frontL, .frontR, .center, .lfe, .sideL, .sideR]
    let matrix = DownmixMatrix.coefficients(roles: roles, centerGainDB: 3)!
    let frames = 12_000
    let srcCh = 6
    let input = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
    input.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
      var l: Float = 0
      var r: Float = 0
      for (ch, row) in matrix.enumerated() {
        let v: Float = 0.9
        l += v * row[0]
        r += v * row[1]
      }
      input.floatChannelData![0][i] = l
      input.floatChannelData![1][i] = r
    }
    let out = try renderOnce(preset: .preset(for: .dialogue), input: input)
    XCTAssertLessThanOrEqual(
      peak(out), 0.93, "end-to-end output must stay at/below the -1 dBFS ceiling (0.89 + tolerance)"
    )
  }

  func testLimiterEngagesInsteadOfHardClipping() throws {
    // Custom preset: limiter only (+6 dB pre-gain) on a full-scale signal.
    // The stock limiter must hold the peak near its internal ceiling, not
    // distort or pass > 1.0.
    let base = AudioEnhancementPreset.preset(for: .balanced)
    let limiterOnly = AudioEnhancementPreset(
      centerGainDB: 0, compressionEnabled: false, compressorThresholdDB: base.compressorThresholdDB,
      compressorHeadroomDB: base.compressorHeadroomDB, compressorAttack: base.compressorAttack,
      compressorRelease: base.compressorRelease, compressorMasterGainDB: 0, limiterEnabled: true,
      limiterPreGainDB: 6, limiterAttack: base.limiterAttack, limiterRelease: base.limiterRelease,
      eqEnabled: false, eqFrequency: base.eqFrequency, eqGainDB: 0, eqQ: base.eqQ)
    let out = try renderOnce(preset: limiterOnly, input: tone(1.0, frames: 12_000))
    let p = peak(out)
    XCTAssertLessThanOrEqual(p, 1.02, "limiter output must never exceed digital full scale")
    XCTAssertGreaterThan(p, 0.3, "limiter engaged: hot signal held near the ceiling")
  }

  // MARK: - Runtime switching (no restart, no stale state)

  func testModeSwitchKeepsEngineRunning() throws {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let chain = try makeChain(engine)
    chain.install(player: player, mainMixer: engine.mainMixerNode, format: stereo)
    chain.apply(preset: .preset(for: .original))
    try? engine.start()

    let input = tone(0.6, frames: 24_000)  // 0.5 s
    player.scheduleBuffer(input, at: nil)
    player.play()

    // One 0.125 s chunk rendered per mode; the mode is applied (parameter
    // ramps only) between chunks — exactly the runtime-switch path.
    let chunkFrames: AVAudioFrameCount = 6000
    var rmsByMode: [Float] = []
    for mode in [AudioEnhancementMode.original, .dialogue, .balanced, .original] {
      chain.apply(preset: .preset(for: mode))
      let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: chunkFrames)!
      var got: AVAudioFrameCount = 0
      while got < chunkFrames {
        guard renderChunk(engine: engine, into: buf) else { break }
        got = buf.frameLength
      }
      XCTAssertEqual(got, chunkFrames, "engine kept rendering through mode switches")
      rmsByMode.append(rms(buf))
    }
    XCTAssertEqual(rmsByMode.count, 4)
    XCTAssertGreaterThan(rmsByMode[0], rmsByMode[1], "dialogue must reduce level vs original")
    XCTAssertGreaterThan(rmsByMode[0], rmsByMode[2], "balanced must reduce level vs original")
    XCTAssertEqual(
      rmsByMode[0], rmsByMode[3], accuracy: 0.06,
      "returning to original restores the passthrough level")
  }

  // MARK: - EQ (dialogue only)

  func testEqBoostsSpeechRangeOnlyInDialogue() throws {
    let speechTone = tone(0.3, frequency: 2000, frames: 12_000)
    let bassTone = tone(0.3, frequency: 200, frames: 12_000)
    let dSpeech = rms(try renderOnce(preset: .preset(for: .dialogue), input: speechTone))
    let dBass = rms(try renderOnce(preset: .preset(for: .dialogue), input: bassTone))
    let bSpeech = rms(try renderOnce(preset: .preset(for: .balanced), input: speechTone))
    let bBass = rms(try renderOnce(preset: .preset(for: .balanced), input: bassTone))
    // Dialogue lifts ~2 kHz (+2 dB) relative to 200 Hz; balanced has no EQ.
    let dialogueRatio = dSpeech / max(dBass, 1e-6)
    let balancedRatio = bSpeech / max(bBass, 1e-6)
    XCTAssertGreaterThan(
      dialogueRatio, balancedRatio * 1.15,
      "dialogue must lift the speech region relative to bass more than balanced does")
  }

  // MARK: - Latency (Task 11 evidence)

  func testChainAddsNegligibleLatency() throws {
    let frames = 6000
    func impulse() -> AVAudioPCMBuffer {
      let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
      buf.frameLength = AVAudioFrameCount(frames)
      buf.floatChannelData![0][0] = 1.0
      buf.floatChannelData![1][0] = 1.0
      return buf
    }
    func onset(_ buf: AVAudioPCMBuffer) -> Int {
      let d0 = buf.floatChannelData![0]
      for i in 0..<Int(buf.frameLength) where abs(d0[i]) > 1e-3 { return i }
      return Int(buf.frameLength)
    }

    // Direct graph (no chain) onset.
    let engineDirect = AVAudioEngine()
    try engineDirect.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
    let playerDirect = AVAudioPlayerNode()
    engineDirect.attach(playerDirect)
    engineDirect.connect(playerDirect, to: engineDirect.mainMixerNode, format: stereo)
    try? engineDirect.start()
    playerDirect.scheduleBuffer(impulse(), at: nil)
    playerDirect.play()
    let outDirect = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
    while renderChunk(engine: engineDirect, into: outDirect) {}

    // Dialogue-active chain onset.
    let engineChain = AVAudioEngine()
    try engineChain.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 1024)
    let playerChain = AVAudioPlayerNode()
    engineChain.attach(playerChain)
    let chain = try makeChain(engineChain)
    chain.install(player: playerChain, mainMixer: engineChain.mainMixerNode, format: stereo)
    chain.apply(preset: .preset(for: .dialogue))
    try? engineChain.start()
    playerChain.scheduleBuffer(impulse(), at: nil)
    playerChain.play()
    let outChain = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(frames))!
    while renderChunk(engine: engineChain, into: outChain) {}

    let delta = onset(outChain) - onset(outDirect)
    // SPEC threshold: compensate video only if added latency > 30 ms.
    // 30 ms at 48 kHz = 1440 frames. Measured (dialogue, worst case) ~17 ms.
    XCTAssertLessThanOrEqual(
      delta, 1440,
      "chain adds ≤ 30 ms fixed latency (measured \(delta) frames = \(Double(delta) / rate * 1000) ms)"
    )
    print(
      "[Audio] measured chain latency: \(delta) frames (\(Double(delta) / rate * 1000) ms) — below the 30 ms compensation threshold"
    )
  }
}
