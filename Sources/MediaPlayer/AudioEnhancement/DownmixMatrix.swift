import Foundation

/// Nx2 Lo/Ro downmix gain matrix for multi-channel audio.
///
/// Rows are in the same order as the input `roles`; each row holds the
/// (left, right) gain pair. Center is attenuated by the standard 3 dB
/// (0.707) and may be lifted by `centerGainDB` (dialogue boost).
/// Surrounds are NEVER center-boosted — they stay at the fixed 0.707
/// surround coefficient.
public enum DownmixMatrix {
  /// Nx2 gain matrix, or nil when `roles.count <= 2` (no matrix needed).
  /// Standard Lo/Ro coefficients:
  /// frontL -> [1, 0]; frontR -> [0, 1]; center -> 0.707 * 10^(centerGainDB/20) into BOTH;
  /// lfe -> [0, 0]; sideL -> [0.707, 0]; sideR -> [0, 0.707]; rearL -> [0.707, 0]; rearR -> [0, 0.707];
  /// unknown -> [0.707, 0.707] (documented degradation: fold at surround coefficient).
  public static func coefficients(roles: [ChannelRole], centerGainDB: Float) -> [[Float]]? {
    guard roles.count > 2 else { return nil }
    let centerGain: Float = 0.707 * pow(10.0, centerGainDB / 20.0)
    return roles.map { role in
      switch role {
      case .frontL: return [1, 0]
      case .frontR: return [0, 1]
      case .center: return [centerGain, centerGain]
      case .lfe: return [0, 0]
      case .sideL, .rearL: return [0.707, 0]
      case .sideR, .rearR: return [0, 0.707]
      case .unknown: return [0.707, 0.707]
      }
    }
  }

  /// Worst-case pre-limiter peak (dBFS) of a simultaneous full-scale
  /// signal on every source channel: 20*log10(max over L,R of the
  /// per-output coefficient sums). Used by the presets' clipping guard.
  /// Returns 0 dB when no downmix matrix applies (<= 2 channels): the
  /// signal passes through untouched, so no headroom reduction is needed.
  public static func worstCaseDownmixPeakDB(roles: [ChannelRole], centerGainDB: Float) -> Float {
    guard let matrix = coefficients(roles: roles, centerGainDB: centerGainDB) else { return 0 }
    let leftSum = matrix.reduce(Float(0)) { $0 + $1[0] }
    let rightSum = matrix.reduce(Float(0)) { $0 + $1[1] }
    return 20.0 * log10(max(leftSum, rightSum))
  }
}
