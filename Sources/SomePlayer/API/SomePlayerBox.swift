import Combine
import Foundation

/// Concrete `ObservableObject` box around `any SomePlayer`.
///
/// `@EnvironmentObject var player: any SomePlayer` does not compile — an
/// existential type cannot conform to `ObservableObject` (#ProtocolType
/// NonConformance; probed with a swiftc -typecheck test before this file was
/// written). This box is the documented fallback from KANBAN: it conforms to
/// `SomePlayer` itself and forwards the whole surface 1:1 to the wrapped
/// engine, re-emitting `objectWillChange` whenever the engine publishes.
/// Views observe the box and never see an engine type.
@MainActor public final class SomePlayerBox: SomePlayer {
  /// Re-published to observers whenever the wrapped engine publishes a
  /// change. Explicit (not synthesized) because the box stores no
  /// @Published properties of its own. `nonisolated(unsafe)`: the
  /// ObservableObject requirement is non-isolated, and the box is
  /// @MainActor — a plain nonisolated let of the non-Sendable
  /// ObservableObjectPublisher is a Swift 6 error. The publisher is only
  /// ever touched from the main actor (the engine publishes on MainActor
  /// and the sink below forwards there), so this is safe.
  public nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()

  /// The engine behind this box. Views conditional-cast it when they need
  /// the engine's concrete surface (e.g. NativeVideoView -> NativeSomePlayer
  /// to register as the frame sink).
  public let engine: any SomePlayer

  private var cancellables: Set<AnyCancellable> = []

  public init(engine: any SomePlayer) {
    self.engine = engine
    engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(
      in: &cancellables)
  }

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
