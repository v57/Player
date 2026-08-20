import Foundation

/// High-level playback state machine, engine-agnostic.
///
/// The native engine reports the full machine (opening/buffering/seeking/
/// ended).
public enum PlaybackState: Equatable, Sendable {
    /// Nothing loaded.
    case idle
    /// A file open is in flight.
    case opening
    /// Data is being read into the pipeline (native engine).
    case buffering
    /// Loaded and ready, not yet playing.
    case ready
    /// Playing.
    case playing
    /// Paused.
    case paused
    /// A seek is in flight.
    case seeking
    /// Playback reached the end of the media.
    case ended
    /// The last operation failed; see `errorMessage`.
    case failed
}
