import Accelerate
import Foundation

/// Integrated loudness (LUFS) per ITU-R BS.1770-4 / EBU R128: K-weighting,
/// 400 ms blocks with 75 % overlap, the -70 LUFS absolute gate and the
/// -10 LU relative gate.
///
/// Fed with the decoded PCM as it is scheduled (pipeline queue, off the
/// realtime thread), so a file's loudness is learned while it plays. Gated
/// block energies go into a fixed 0.1 LU histogram (libebur128's approach):
/// constant memory however long the file is.
final class LoudnessMeter {
  /// Loudness of a block = -0.691 + 10 log10(weighted mean square).
  static let offset = -0.691
  private static let absoluteGate = -70.0
  private static let histogramMin = -70.0
  private static let histogramMax = 5.0
  private static let histogramStep = 0.1

  /// Blocks measured so far (each covers 400 ms, one every 100 ms).
  private(set) var blockCount = 0

  private let weights: [Double]
  private let subBlockFrames: Int
  private var filters: [vDSP.Biquad<Float>]
  private var filtered: [Float] = []
  private var channel: [Float] = []
  /// Weighted energy of the current 100 ms sub-block and the last three
  /// finished ones (a block is four sub-blocks).
  private var subBlockEnergy = 0.0
  private var subBlockFill = 0
  private var recentSubBlocks: [Double] = []
  private var histogramCount: [Int]
  private var histogramEnergy: [Double]

  /// `weights` has one entry per channel: 1.0 for L/R/C, 1.41 for
  /// surrounds, 0 for LFE (BS.1770 channel weights).
  init(sampleRate: Double, weights: [Double]) {
    self.weights = weights
    subBlockFrames = max(1, Int((sampleRate * 0.1).rounded()))
    let coefficients = Self.kWeighting(sampleRate: sampleRate)
    filters = weights.map { _ in
      vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Float.self)!
    }
    let bins = Int(((Self.histogramMax - Self.histogramMin) / Self.histogramStep).rounded()) + 1
    histogramCount = Array(repeating: 0, count: bins)
    histogramEnergy = Array(repeating: 0, count: bins)
  }

  /// Integrated loudness of everything measured so far, or nil before the
  /// first block or when every block is below the absolute gate (silence).
  var integratedLoudness: Double? {
    var count = 0
    var energy = 0.0
    for i in histogramCount.indices {
      count += histogramCount[i]
      energy += histogramEnergy[i]
    }
    guard count > 0 else { return nil }
    let relativeGate = Self.loudness(energy / Double(count)) - 10
    let first = max(0, Self.bin(for: relativeGate))
    count = 0
    energy = 0
    for i in first..<histogramCount.count {
      count += histogramCount[i]
      energy += histogramEnergy[i]
    }
    guard count > 0 else { return nil }
    return Self.loudness(energy / Double(count))
  }

  /// Measures planar float PCM: one pointer per channel (in `weights`
  /// order), `frames` samples each.
  func measure(channels data: [UnsafePointer<Float>], frames: Int) {
    guard frames > 0, data.count == weights.count else { return }
    var offset = 0
    while offset < frames {
      let n = min(frames - offset, subBlockFrames - subBlockFill)
      if filtered.count < n {
        filtered = Array(repeating: 0, count: n)
        channel = Array(repeating: 0, count: n)
      }
      for (ch, weight) in weights.enumerated() where weight > 0 {
        channel.withUnsafeMutableBufferPointer { dst in
          dst.baseAddress!.update(from: data[ch].advanced(by: offset), count: n)
        }
        filters[ch].apply(input: channel[0..<n], output: &filtered[0..<n])
        subBlockEnergy += weight * Double(vDSP.sumOfSquares(filtered[0..<n]))
      }
      subBlockFill += n
      offset += n
      if subBlockFill == subBlockFrames { finishSubBlock() }
    }
  }

  private func finishSubBlock() {
    recentSubBlocks.append(subBlockEnergy / Double(subBlockFrames))
    subBlockEnergy = 0
    subBlockFill = 0
    guard recentSubBlocks.count == 4 else { return }
    let blockEnergy = recentSubBlocks.reduce(0, +) / 4
    recentSubBlocks.removeFirst()
    blockCount += 1
    let loudness = Self.loudness(blockEnergy)
    guard loudness >= Self.absoluteGate else { return }
    let bin = min(Self.bin(for: loudness), histogramCount.count - 1)
    histogramCount[bin] += 1
    histogramEnergy[bin] += blockEnergy
  }

  private static func loudness(_ energy: Double) -> Double {
    energy > 0 ? offset + 10 * log10(energy) : -.infinity
  }

  private static func bin(for loudness: Double) -> Int {
    Int(((loudness - histogramMin) / histogramStep).rounded(.down))
  }

  /// The two K-weighting biquads (high shelf, then high-pass) for any sample
  /// rate, from the BS.1770 analog prototypes (libebur128's derivation).
  /// vDSP order per section: b0, b1, b2, a1, a2.
  static func kWeighting(sampleRate fs: Double) -> [Double] {
    var f0 = 1681.974450955533
    let g = 3.999843853973347
    var q = 0.7071752369554196
    var k = tan(Double.pi * f0 / fs)
    let vh = pow(10, g / 20)
    let vb = pow(vh, 0.4996667741545416)
    var a0 = 1 + k / q + k * k
    let shelf = [
      (vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
      2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0,
    ]
    f0 = 38.13547087602444
    q = 0.5003270373238773
    k = tan(Double.pi * f0 / fs)
    a0 = 1 + k / q + k * k
    let highPass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
    return shelf + highPass
  }
}
