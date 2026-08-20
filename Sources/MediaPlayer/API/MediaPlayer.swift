import Combine
import Foundation

/// A chapter (plan section 22): a named time range in the media. App-owned;
/// the engine fills it from the container's chapter metadata.
public struct PlayerChapter: Equatable, Sendable {
    let title: String?
    let startTime: Double
}

/// The engine-agnostic surface for media playback: state and transport only.
/// No render surface, no engine handles, no FFmpeg types — pixel delivery
/// stays engine-private (the native engine gets a VideoFrameSink).
///
/// Class-bound and MainActor-isolated: every engine publishes its state with
/// `@Published` and is driven from the main actor. `objectWillChange` is
/// pinned to the concrete `ObservableObjectPublisher` (rather than the
/// associated-type form) so the publisher can be forwarded through the
/// existential — e.g. by `MediaPlayerBox`.
///
/// NOTE: views CANNOT hold this as `@EnvironmentObject var player: any
/// MediaPlayer` — an existential type cannot conform to `ObservableObject`
/// (#ProtocolTypeNonConformance; probed with swiftc -typecheck). The app
/// injects the concrete `MediaPlayerBox` instead, which forwards this whole
/// surface 1:1, so views never touch an engine type.
@MainActor
public protocol MediaPlayer: ObservableObject, AnyObject {
    /// Re-published on every engine state change. Pinned concrete type so
    /// forwarding through `any MediaPlayer` compiles.
    var objectWillChange: ObservableObjectPublisher { get }

    // MARK: - State machine

    /// Current high-level playback state.
    var state: PlaybackState { get }

    // MARK: - Transport state

    /// True while media is playing (not paused/stopped).
    var isPlaying: Bool { get }
    /// Last opened file's display name, nil when nothing is loaded.
    var fileName: String? { get }
    /// Current playback position in seconds (clamped to duration).
    var position: Double { get }
    /// Total media duration in seconds (0 while unknown).
    var duration: Double { get }
    /// Current playback position; alias of `position` kept for engines that
    /// distinguish media-clock time from UI position.
    var currentTime: Double { get }
    /// Output volume, 0...100.
    var volume: Double { get }
    /// True when output is muted.
    var isMuted: Bool { get }
    /// User-facing error from the last failed operation, nil when healthy.
    var errorMessage: String? { get set }

    // MARK: - Tracks

    var videoTracks: [MediaTrack] { get }
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    /// Active audio track id (nil = auto/none).
    var audioTrackID: Int? { get }
    /// Active subtitle track id (nil = subtitles off).
    var subtitleTrackID: Int? { get }

    /// Chapter list (title + start time), empty when the file has none.
    var chapters: [PlayerChapter] { get }

    // MARK: - Transport

    /// Opens a media file. Async so the native engine can stream/parse off
    /// the main actor.
    func open(_ url: URL) async throws
    func play()
    func pause()
    /// Seeks to an absolute time in seconds. Plain seeks are keyframe-based
    /// (cheap, live scrubbing); `exact` forces a precise seek.
    func seek(to seconds: Double, exact: Bool)
    /// Seeks relative to the current position (negative = backwards).
    func seekRelative(_ seconds: Double)
    /// Seeks to the chapter boundary before (negative direction) or after
    /// (positive direction) the current position. No-op with no chapters.
    func skipChapter(_ direction: Int)
    func stop()
    func selectAudioTrack(_ id: Int)
    /// nil turns subtitles off.
    func selectSubtitleTrack(_ id: Int?)
}
