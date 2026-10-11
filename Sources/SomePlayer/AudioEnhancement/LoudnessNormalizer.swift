import AVFoundation
import Accelerate
import Foundation

/// "Even Out Loudness": steers each file toward the same integrated loudness
/// so switching files doesn't mean reaching for the volume.
///
/// Every scheduled buffer is measured (LoudnessMeter, before this gain), and
/// once a few seconds are known the gain moves toward `targetLUFS -
/// integrated`, slewing slowly (no pumping: the integrated value of a film
/// barely moves after the first minutes) with a linear ramp inside each
/// buffer (no zipper noise). Measuring runs even while disabled, so turning
/// it on mid-file lands on the right gain at once.
///
/// CLIPPING SAFETY: cuts are always safe. A boost is allowed only up to
/// `maxBoostDB`, which the caller passes as 0 unless the stock limiter
/// follows (AudioEnhancementChain with `limiterRequired`, which also applies
/// the -2 dB ceiling trim) — so boosted samples above full scale never reach
/// the output. The ceiling is fixed per normalizer (one per audio setup); a
/// gain still above unity after it is turned off ramps back down while the
/// controller keeps the limiter engaged.
final class LoudnessNormalizer {
  /// EBU R128 programme loudness.
  static let targetLUFS = -23.0
  /// Largest boost (only with the limiter engaged) and cut, dB.
  static let maxBoostDB = 6.0
  static let maxCutDB = -15.0
  /// Measured audio before the gain starts to move.
  static let minimumBlocks = 30  // 3 s
  /// Slew rates in dB per second of audio: rising is slower than falling so
  /// a loud file is corrected sooner than a quiet one is raised.
  static let riseDBPerSecond = 1.0
  static let fallDBPerSecond = 3.0
  /// Back to unity after it is turned off.
  static let releaseDBPerSecond = 12.0

  let meter: LoudnessMeter
  private let sampleRate: Double
  /// Gain at the end of the last processed buffer, dB.
  private(set) var gainDB = 0.0

  init(sampleRate: Double, weights: [Double]) {
    self.sampleRate = sampleRate
    meter = LoudnessMeter(sampleRate: sampleRate, weights: weights)
  }

  /// Gain the normalizer is heading for.
  func targetGainDB(enabled: Bool, maxBoostDB: Double) -> Double {
    guard enabled, meter.blockCount >= Self.minimumBlocks, let loudness = meter.integratedLoudness
    else { return enabled ? min(gainDB, maxBoostDB) : 0 }
    return min(max(Self.targetLUFS - loudness, Self.maxCutDB), maxBoostDB)
  }

  /// Measures `buffer` and applies the gain in place (first `frames` frames,
  /// every channel). `maxBoostDB` is 0 when no limiter follows.
  func process(_ buffer: AVAudioPCMBuffer, frames: Int, enabled: Bool, maxBoostDB: Double) {
    guard frames > 0, let data = buffer.floatChannelData else { return }
    let channels = Int(buffer.format.channelCount)
    meter.measure(channels: (0..<channels).map { UnsafePointer(data[$0]) }, frames: frames)

    let target = targetGainDB(enabled: enabled, maxBoostDB: maxBoostDB)
    let seconds = Double(frames) / sampleRate
    let rate =
      !enabled
      ? Self.releaseDBPerSecond : target > gainDB ? Self.riseDBPerSecond : Self.fallDBPerSecond
    let from = gainDB
    let step = rate * seconds
    gainDB = from + min(max(target - from, -step), step)
    guard from != 0 || gainDB != 0 else { return }

    let g0 = Float(pow(10, from / 20))
    let g1 = Float(pow(10, gainDB / 20))
    let increment = (g1 - g0) / Float(frames)
    for ch in 0..<channels {
      var ramp = g0
      var inc = increment
      vDSP_vrampmul(data[ch], 1, &ramp, &inc, data[ch], 1, vDSP_Length(frames))
    }
  }
}
