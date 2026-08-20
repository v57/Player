import Foundation

/// A point in media time, in seconds.
///
/// Engines publish positions and durations as plain `Double` seconds on
/// `MediaPlayer` (that's what the timeline bindings consume); `MediaTime` is
/// the shared value type for formatting and arithmetic on those values.
public struct MediaTime: Equatable, Comparable, Hashable, Sendable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        lhs.seconds < rhs.seconds
    }

    /// m:ss or h:mm:ss display string ("0:00" for empty/non-finite times).
    public var displayString: String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
