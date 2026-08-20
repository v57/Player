import Foundation

/// The persistence seam the engine needs (resume positions + remembered
/// track picks). The app injects its SwiftData-backed store; the library
/// never touches SwiftData itself.
///
/// Method names deliberately match the app's PlaybackStore surface so the
/// conformance extension stays a one-liner.
@MainActor
public protocol PlayerPersistence: AnyObject {
    func resumePosition(for path: String) -> Double?
    func latestTrackPick(kind: String) -> PlayerTrackPick?
    func saveCurrentPosition(path: String?, position: Double, duration: Double)
    func storeTrackPick(kind: String, lang: String?, title: String?, trackID: Int, isOff: Bool)
    /// Persists (updates) a security-scoped bookmark so a sandboxed app can
    /// reopen the file from a recent list.
    func storeBookmark(path: String, bookmark: Data)
}

/// Library-side mirror of the app's TrackPick (@Model) — same fields, no
/// SwiftData dependency. The app's store converts its @Model to this value
/// type when answering the seam.
public struct PlayerTrackPick: Sendable {
    public let kind: String
    public let lang: String?
    public let title: String?
    public let trackID: Int
    public let isOff: Bool
    public let pickedAt: Date

    public init(kind: String, lang: String?, title: String?, trackID: Int,
                isOff: Bool, pickedAt: Date = .now) {
        self.kind = kind
        self.lang = lang
        self.title = title
        self.trackID = trackID
        self.isOff = isOff
        self.pickedAt = pickedAt
    }
}
