import Foundation

/// Immutable tuning snapshot for the audio enhancement chain: downmix center
/// boost, compressor, limiter, and EQ. Values are pinned per mode by
/// `preset(for:)`; a preset never mutates after construction.
public struct AudioEnhancementPreset: Equatable, Sendable {
  /// Center-channel boost applied IN the downmix matrix (multichannel
  /// sources only).
  public let centerGainDB: Float
  public let compressionEnabled: Bool
  /// Compressor threshold, dB.
  public let compressorThresholdDB: Float
  /// Headroom over threshold in dB (the spec's ~3:1 ratio ≈ 12 dB headroom
  /// over threshold).
  public let compressorHeadroomDB: Float
  /// Compressor attack, seconds.
  public let compressorAttack: Float
  /// Compressor release, seconds.
  public let compressorRelease: Float
  /// Make-up gain added after the compressor, dB.
  public let compressorMasterGainDB: Float
  public let limiterEnabled: Bool
  /// Gain applied ahead of the limiter, dB.
  public let limiterPreGainDB: Float
  /// Limiter attack, seconds.
  public let limiterAttack: Float
  /// Limiter release (decay), seconds.
  public let limiterRelease: Float
  public let eqEnabled: Bool
  /// EQ center frequency, Hz.
  public let eqFrequency: Float
  /// EQ gain, dB.
  public let eqGainDB: Float
  /// EQ bandwidth (Q).
  public let eqQ: Float

  public init(
    centerGainDB: Float, compressionEnabled: Bool, compressorThresholdDB: Float,
    compressorHeadroomDB: Float, compressorAttack: Float, compressorRelease: Float,
    compressorMasterGainDB: Float, limiterEnabled: Bool, limiterPreGainDB: Float,
    limiterAttack: Float, limiterRelease: Float, eqEnabled: Bool, eqFrequency: Float,
    eqGainDB: Float, eqQ: Float
  ) {
    self.centerGainDB = centerGainDB
    self.compressionEnabled = compressionEnabled
    self.compressorThresholdDB = compressorThresholdDB
    self.compressorHeadroomDB = compressorHeadroomDB
    self.compressorAttack = compressorAttack
    self.compressorRelease = compressorRelease
    self.compressorMasterGainDB = compressorMasterGainDB
    self.limiterEnabled = limiterEnabled
    self.limiterPreGainDB = limiterPreGainDB
    self.limiterAttack = limiterAttack
    self.limiterRelease = limiterRelease
    self.eqEnabled = eqEnabled
    self.eqFrequency = eqFrequency
    self.eqGainDB = eqGainDB
    self.eqQ = eqQ
  }

  /// The pinned preset for the given mode. Values are spec-mandated and
  /// must not drift: sibling pipeline agents rely on these exact numbers.
  public static func preset(for mode: AudioEnhancementMode) -> AudioEnhancementPreset {
    switch mode {
    case .original:
      return AudioEnhancementPreset(
        centerGainDB: 0, compressionEnabled: false, compressorThresholdDB: -18,
        compressorHeadroomDB: 12, compressorAttack: 0.015, compressorRelease: 0.250,
        compressorMasterGainDB: 0, limiterEnabled: false, limiterPreGainDB: 0, limiterAttack: 0.012,
        limiterRelease: 0.250, eqEnabled: false, eqFrequency: 2000, eqGainDB: 0, eqQ: 1.0)
    case .balanced:
      return AudioEnhancementPreset(
        centerGainDB: 1, compressionEnabled: true, compressorThresholdDB: -18,
        compressorHeadroomDB: 12, compressorAttack: 0.015, compressorRelease: 0.250,
        compressorMasterGainDB: 2, limiterEnabled: true, limiterPreGainDB: 0, limiterAttack: 0.012,
        limiterRelease: 0.250, eqEnabled: false, eqFrequency: 2000, eqGainDB: 0, eqQ: 1.0)
    case .dialogue:
      return AudioEnhancementPreset(
        centerGainDB: 3, compressionEnabled: true, compressorThresholdDB: -22,
        compressorHeadroomDB: 12, compressorAttack: 0.020, compressorRelease: 0.200,
        compressorMasterGainDB: 3, limiterEnabled: true, limiterPreGainDB: 1, limiterAttack: 0.012,
        limiterRelease: 0.250, eqEnabled: true, eqFrequency: 2000, eqGainDB: 2, eqQ: 1.0)
    }
  }

  /// Clipping-by-construction guard. The dB by which the preset's own
  /// intended gain additions sit BELOW the -1 dBFS ceiling:
  ///
  ///     returns -1.0 - gainStackDB
  ///
  /// where `gainStackDB = max(0, centerGainDB) + compressorMasterGainDB +
  /// limiterPreGainDB`. Every preset must keep this <= -1.0 (at least 1 dB
  /// margin below the ceiling for the preset's own gains; the downmix
  /// fold-sum overshoot on simultaneous full-scale channels is handled by
  /// the mandated limiter).
  public func headroomAboveCeiling() -> Float {
    let gainStackDB = max(0, centerGainDB) + compressorMasterGainDB + limiterPreGainDB
    return -1.0 - gainStackDB
  }
}
