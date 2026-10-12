import AVFoundation
import XCTest

@testable import PlayerKit

final class LoudnessMeterTests: XCTestCase {
  /// Planar stereo sine, `seconds` long, the same on both channels.
  private func measureSine(
    amplitude: Float, frequency: Double = 997, seconds: Double, rate: Double = 48_000,
    weights: [Double] = [1, 1], chunk: Int = 1024, meter: LoudnessMeter? = nil
  ) -> LoudnessMeter {
    let meter = meter ?? LoudnessMeter(sampleRate: rate, weights: weights)
    let total = Int(seconds * rate)
    var buf = [Float](repeating: 0, count: chunk)
    var done = 0
    while done < total {
      let n = min(chunk, total - done)
      for i in 0..<n {
        buf[i] = amplitude * Float(sin(2 * .pi * frequency * Double(done + i) / rate))
      }
      buf.withUnsafeBufferPointer { p in
        meter.measure(channels: Array(repeating: p.baseAddress!, count: weights.count), frames: n)
      }
      done += n
    }
    return meter
  }

  func testFullScaleSineOnBothChannelsIsZeroLUFS() throws {
    // BS.1770: a 997 Hz 0 dBFS sine on one channel reads -3.01 LUFS, so on
    // two channels 0 LUFS.
    let loudness = try XCTUnwrap(measureSine(amplitude: 1, seconds: 5).integratedLoudness)
    XCTAssertEqual(loudness, 0, accuracy: 0.1)
  }

  func testMinus20DBFSSineIsMinus20LUFSAtEverySampleRate() throws {
    for rate in [44_100.0, 48_000, 96_000] {
      let loudness = try XCTUnwrap(
        measureSine(amplitude: 0.1, seconds: 5, rate: rate).integratedLoudness)
      XCTAssertEqual(loudness, -20, accuracy: 0.1, "at \(rate) Hz")
    }
  }

  func testLFEIsIgnoredAndSurroundsWeighted() throws {
    // Same sine on L R C LFE Ls Rs: L+R+C weigh 1 each, the surrounds 1.41,
    // LFE 0 → 10 log10(3 + 2 * 1.41) = +7.65 dB over one channel (-23.01).
    let weights = [1, 1, 1, 0, 1.41, 1.41]
    let loudness = try XCTUnwrap(
      measureSine(amplitude: 0.1, seconds: 5, weights: weights).integratedLoudness)
    XCTAssertEqual(loudness, -23.01 + 10 * log10(3 + 2 * 1.41), accuracy: 0.1)
  }

  func testSilenceIsGatedOut() {
    XCTAssertNil(measureSine(amplitude: 0, seconds: 3).integratedLoudness)
  }

  func testRelativeGateIgnoresQuietPassages() throws {
    // 5 s at -20 LUFS then 5 s at -50 LUFS (more than 10 LU below): the
    // quiet half is gated out, so the result stays near -20.
    let meter = measureSine(amplitude: 0.1, seconds: 5)
    _ = measureSine(amplitude: 0.003_162, seconds: 5, meter: meter)
    XCTAssertEqual(try XCTUnwrap(meter.integratedLoudness), -20, accuracy: 0.3)
  }

  func testKWeightingMatchesBS1770At48kHz() {
    // BS.1770-4 Table 1/2 coefficients at 48 kHz.
    let c = LoudnessMeter.kWeighting(sampleRate: 48_000)
    let expected = [
      1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
      1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621,
    ]
    for (a, b) in zip(c, expected) { XCTAssertEqual(a, b, accuracy: 1e-6) }
  }
}

final class LoudnessNormalizerTests: XCTestCase {
  private let rate = 48_000.0
  private var stereo: AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
  }

  /// Runs `seconds` of a 997 Hz sine through the normalizer in 1024-frame
  /// buffers; returns the processed samples of channel 0.
  @discardableResult private func run(
    _ normalizer: LoudnessNormalizer, amplitude: Float, seconds: Double, enabled: Bool = true,
    maxBoostDB: Double = LoudnessNormalizer.maxBoostDB
  ) -> [Float] {
    var out: [Float] = []
    var t = 0
    let total = Int(seconds * rate)
    while t < total {
      let n = min(1024, total - t)
      let buf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 1024)!
      buf.frameLength = AVAudioFrameCount(n)
      for i in 0..<n {
        let v = amplitude * Float(sin(2 * .pi * 997 * Double(t + i) / rate))
        buf.floatChannelData![0][i] = v
        buf.floatChannelData![1][i] = v
      }
      normalizer.process(buf, frames: n, enabled: enabled, maxBoostDB: maxBoostDB)
      out.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))
      t += n
    }
    return out
  }

  func testLoudFileIsCutToTarget() {
    // -10 LUFS → -13 dB to reach -23; falls at 3 dB/s after 3 s measured.
    let n = LoudnessNormalizer(sampleRate: rate, weights: [1, 1])
    run(n, amplitude: 0.316, seconds: 12)
    XCTAssertEqual(n.gainDB, -13, accuracy: 0.2)
  }

  func testQuietFileBoostIsCappedAndNeedsALimiter() {
    // -40 LUFS wants +17 dB: capped at +6 with a limiter, none without.
    let withLimiter = LoudnessNormalizer(sampleRate: rate, weights: [1, 1])
    run(withLimiter, amplitude: 0.01, seconds: 12)
    XCTAssertEqual(withLimiter.gainDB, LoudnessNormalizer.maxBoostDB, accuracy: 0.01)

    let without = LoudnessNormalizer(sampleRate: rate, weights: [1, 1])
    let out = run(without, amplitude: 0.01, seconds: 12, maxBoostDB: 0)
    XCTAssertEqual(without.gainDB, 0)
    XCTAssertLessThanOrEqual(out.map(abs).max()!, 0.01 + 1e-6, "no boost without a limiter")
  }

  func testGainHoldsUntilEnoughIsMeasured() {
    let n = LoudnessNormalizer(sampleRate: rate, weights: [1, 1])
    run(n, amplitude: 0.316, seconds: 2.5)
    XCTAssertEqual(n.gainDB, 0)
  }

  func testDisabledMeasuresButLeavesTheSignalAlone() throws {
    let n = LoudnessNormalizer(sampleRate: rate, weights: [1, 1])
    let out = run(n, amplitude: 0.316, seconds: 5, enabled: false)
    XCTAssertEqual(n.gainDB, 0)
    XCTAssertEqual(out.map(abs).max()!, 0.316, accuracy: 1e-3)
    XCTAssertEqual(try XCTUnwrap(n.meter.integratedLoudness), -10, accuracy: 0.1)
  }

  func testTurningOffReleasesToUnity() {
    let n = LoudnessNormalizer(sampleRate: rate, weights: [1, 1])
    run(n, amplitude: 0.316, seconds: 12)
    run(n, amplitude: 0.316, seconds: 1.5, enabled: false)
    XCTAssertEqual(n.gainDB, 0)
  }

  func testGainChangesWithoutSteps() {
    // The ramp is continuous across buffers: no sample-to-sample jump beyond
    // what the sine itself does.
    let n = LoudnessNormalizer(sampleRate: rate, weights: [1, 1])
    let out = run(n, amplitude: 0.316, seconds: 8)
    let maxSineStep = 0.316 * 2 * Float.pi * 997 / Float(rate)
    var worst: Float = 0
    for i in 1..<out.count { worst = max(worst, abs(out[i] - out[i - 1])) }
    XCTAssertLessThanOrEqual(worst, maxSineStep * 1.01)
  }
}
