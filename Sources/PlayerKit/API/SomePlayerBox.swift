import Foundation

/// Concrete `Observable` box around `any SomePlayer`.
///
/// `@Environment((any SomePlayer).self)` doesn't compile: an existential type
/// doesn't conform to `Observable`. This box conforms to `SomePlayer` itself and
/// forwards the whole surface 1:1 to the wrapped engine. It has no state of its
/// own: a view reading `player.position` reads the engine's `@Observable`
/// property, so it's tracked per property, through the box. Views hold the box
/// and never see an engine type.
@MainActor public final class SomePlayerBox: SomePlayer {
  /// The engine behind this box. Views conditional-cast it when they need
  /// the engine's concrete surface (e.g. NativeVideoView -> NativeSomePlayer
  /// to register as the frame sink).
  public let engine: any SomePlayer

  public init(engine: any SomePlayer) { self.engine = engine }

  // MARK: - SomePlayer forwarding

  public var state: PlaybackState { engine.state }
  public var isPlaying: Bool { engine.isPlaying }
  public var fileName: String? { engine.fileName }
  public var position: Double { engine.position }
  public var duration: Double { engine.duration }
  public var currentTime: Double { engine.currentTime }
  public var volume: Double { engine.volume }
  public var isMuted: Bool { engine.isMuted }
  public var errorMessage: String? {
    get { engine.errorMessage }
    set { engine.errorMessage = newValue }
  }
  public var videoTracks: [MediaTrack] { engine.videoTracks }
  public var audioTracks: [MediaTrack] { engine.audioTracks }
  public var subtitleTracks: [MediaTrack] { engine.subtitleTracks }
  public var audioTrackID: Int? { engine.audioTrackID }
  public var subtitleTrackID: Int? { engine.subtitleTrackID }
  public var isWaitingForFileUpdate: Bool { engine.isWaitingForFileUpdate }
  public var enhancementMode: AudioEnhancementMode {
    get { engine.enhancementMode }
    set { engine.enhancementMode = newValue }
  }
  public var normalizesLoudness: Bool {
    get { engine.normalizesLoudness }
    set { engine.normalizesLoudness = newValue }
  }
  public var chapters: [PlayerChapter] { engine.chapters }

  public func open(_ url: URL) async throws { try await engine.open(url) }
  public func play() { engine.play() }
  public func pause() { engine.pause() }
  public func seek(to seconds: Double, exact: Bool = false) {
    engine.seek(to: seconds, exact: exact)
  }
  public func seekRelative(_ seconds: Double) { engine.seekRelative(seconds) }
  public func skipChapter(_ direction: Int) { engine.skipChapter(direction) }
  public func stop() { engine.stop() }
  public func nextTrack() { engine.nextTrack() }
  public func previousTrack() { engine.previousTrack() }
  public func selectAudioTrack(_ id: Int) { engine.selectAudioTrack(id) }
  public func selectSubtitleTrack(_ id: Int?) { engine.selectSubtitleTrack(id) }
}
