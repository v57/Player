import Foundation

/// The role a decoded audio channel plays in the speaker layout.
///
/// Roles are derived from the FFmpeg native-order channel mask so that
/// downmix matrices can be addressed by speaker role rather than by raw
/// bit position. Unrecognized channel bits decode to `unknown`.
public enum ChannelRole: Equatable, Sendable, CaseIterable {
  case frontL, frontR, center, lfe, sideL, sideR, rearL, rearR, unknown
}

/// Decodes FFmpeg native-order channel masks into ordered channel roles.
public enum ChannelRoleMap {
  /// Decodes an FFmpeg native-order channel mask into ordered roles.
  /// Bit positions (libavutil channel_layout.h AV_CHAN_* enum):
  /// FL=0, FR=1, FC=2, LFE=3, BL=4, BR=5, FLC=6, FRC=7, BC=8, SL=9, SR=10, TC=11.
  /// Returned array is ordered by ascending bit position.
  /// Returns nil when the mask has 0, 1, or 2 channels (no matrix needed).
  /// Unrecognized bits (FLC/FRC/BC/TC...) map to .unknown.
  public static func roles(forMask mask: UInt64) -> [ChannelRole]? {
    let count = mask.nonzeroBitCount
    guard count > 2 else { return nil }

    var roles: [ChannelRole] = []
    roles.reserveCapacity(count)
    for bit in 0..<UInt64.bitWidth where mask & (1 << bit) != 0 { roles.append(role(forBit: bit)) }
    return roles
  }

  /// Maps a single native-order bit position to its channel role.
  private static func role(forBit bit: Int) -> ChannelRole {
    switch bit {
    case 0: return .frontL
    case 1: return .frontR
    case 2: return .center
    case 3: return .lfe
    case 4: return .rearL
    case 5: return .rearR
    case 9: return .sideL
    case 10: return .sideR
    default: return .unknown
    }
  }
}
