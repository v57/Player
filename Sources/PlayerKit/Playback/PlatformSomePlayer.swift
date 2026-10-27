import Combine
import Foundation
import PlatformMedia

/// The SomePlayer engine on PlatformMedia's player (AVFoundation on Apple platforms, GStreamer on Linux): the
/// engine where the native one (FFmpeg + VideoToolbox + Metal) doesn't run. Same persistence as the native engine
/// (resume points, remembered audio and subtitle picks, subtitles off unless picked); the audio modes, chapters,
/// partial-download waits and `player-stream` sources are the native engine's alone.
@MainActor public final class PlatformSomePlayer: SomePlayer {
  /// Resume points and track picks; the app injects its store.
  public weak var store: (any PlayerPersistence)?
  /// The PlatformMedia player behind this engine (its picture: `PlatformVideoView`).
  public let player = PlatformPlayer()

  @Published public private(set) var state: PlaybackState = .idle
  @Published public private(set) var isPlaying = false
  @Published public private(set) var fileName: String?
  @Published public private(set) var position: Double = 0
  @Published public private(set) var duration: Double = 0
  @Published public private(set) var videoTracks: [MediaTrack] = []
  @Published public private(set) var audioTracks: [MediaTrack] = []
  @Published public private(set) var subtitleTracks: [MediaTrack] = []
  @Published public private(set) var audioTrackID: Int?
  @Published public private(set) var subtitleTrackID: Int?
  @Published public private(set) var chapters: [PlayerChapter] = []
  @Published public var errorMessage: String?
  @Published public private(set) var isWaitingForFileUpdate = false
  /// Kept for the menus; this engine plays the audio as it is.
  @Published public var enhancementMode: AudioEnhancementMode = .original
  @Published public var normalizesLoudness = false

  public var currentTime: Double { position }
  public var volume: Double { player.volume * 100 }
  public var isMuted: Bool { player.isMuted }

  private var currentFileURL: URL?
  private var currentFilePath: String?
  private var lastAutosave = Date.distantPast
  /// The newest open: an older one that finishes later is dropped.
  private var openToken: UInt64 = 0

  public init() {
    player.onEvent = { [weak self] event in self?.handle(event) }
  }

  // MARK: Transport

  public func open(_ url: URL) async throws {
    openToken &+= 1
    let token = openToken
    saveCurrentPosition()
    guard url.scheme != MediaSources.scheme else {
      errorMessage = "Playing from another device isn't supported on this system yet."
      return
    }
    currentFileURL = url.standardizedFileURL
    currentFilePath = nil
    fileName = nil
    errorMessage = nil
    state = .opening
    do {
      try await player.open(url)
    } catch is CancellationError {
      return
    } catch {
      guard token == openToken else { return }
      state = .failed
      errorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
      return
    }
    guard token == openToken else { return }
    currentFilePath = url.standardizedFileURL.path
    fileName = url.lastPathComponent
    syncMedia()
    applyTrackPicks()
    if let resume = store?.resumePosition(for: currentFilePath ?? ""), resume > 0, player.duration > 0 {
      player.seek(to: min(resume, player.duration), exact: true)
    }
    player.play()
    syncState()
  }

  public func play() { player.play() }

  public func pause() {
    player.pause()
    saveCurrentPosition()
  }

  public func seek(to seconds: Double, exact: Bool) {
    player.seek(to: seconds, exact: exact)
    position = player.position
  }

  /// Exact, as the native engine's: a keyframe seek could land before where it started.
  public func seekRelative(_ seconds: Double) { seek(to: max(0, position + seconds), exact: true) }

  public func skipChapter(_ direction: Int) {}

  public func stop() {
    openToken &+= 1
    saveCurrentPosition()
    player.stop()
    currentFileURL = nil
    currentFilePath = nil
    fileName = nil
    position = 0
    duration = 0
    videoTracks = []
    audioTracks = []
    subtitleTracks = []
    audioTrackID = nil
    subtitleTrackID = nil
    syncState()
  }

  public func nextTrack() { advanceTrack(direction: 1) }
  public func previousTrack() { advanceTrack(direction: -1) }

  public func selectAudioTrack(_ id: Int) {
    guard let track = audioTracks.first(where: { $0.id == id }) else { return }
    player.selectAudioTrack(id)
    store?.storeTrackPick(kind: "audio", lang: track.language, title: track.title, trackID: id, isOff: false)
    syncMedia()
  }

  public func selectSubtitleTrack(_ id: Int?) {
    player.selectSubtitleTrack(id)
    if let id, let track = subtitleTracks.first(where: { $0.id == id }) {
      store?.storeTrackPick(kind: "sub", lang: track.language, title: track.title, trackID: id, isOff: false)
    } else {
      store?.storeTrackPick(kind: "sub", lang: nil, title: nil, trackID: 0, isOff: true)
    }
    syncMedia()
  }

  // MARK: Player events

  private func handle(_ event: PlatformPlayerEvent) {
    switch event {
    case .state:
      syncState()
    case .time:
      let now = player.position
      if now != position { position = now }
      autosavePosition()
    case .media:
      syncMedia()
    case .videoSize:
      break
    case .ended:
      position = duration
      saveCurrentPosition()
    case .failed(let message):
      errorMessage = message
    }
  }

  private func syncState() {
    let next: PlaybackState =
      switch player.state {
      case .idle: .idle
      case .loading: .opening
      case .ready: .ready
      case .playing: .playing
      case .paused: .paused
      case .ended: .ended
      case .failed: .failed
      }
    if next != state { state = next }
    if player.isPlaying != isPlaying { isPlaying = player.isPlaying }
  }

  private func syncMedia() {
    func mapped(_ tracks: [PlatformMediaTrack], _ kind: MediaTrack.Kind) -> [MediaTrack] {
      tracks.map {
        MediaTrack(
          id: $0.id, kind: kind, codec: $0.codec, language: $0.language, title: $0.title,
          channelCount: $0.channelCount, sampleRate: $0.sampleRate, isDefault: $0.isDefault, isForced: false,
          isPlayable: true)
      }
    }
    let video = mapped(player.videoTracks, .video)
    let audio = mapped(player.audioTracks, .audio)
    let subtitles = mapped(player.subtitleTracks, .subtitle)
    if video != videoTracks { videoTracks = video }
    if audio != audioTracks { audioTracks = audio }
    if subtitles != subtitleTracks { subtitleTracks = subtitles }
    if player.audioTrackID != audioTrackID { audioTrackID = player.audioTrackID }
    if player.subtitleTrackID != subtitleTrackID { subtitleTrackID = player.subtitleTrackID }
    if player.duration != duration { duration = player.duration }
  }

  /// The audio and subtitles picked last (by language and title); subtitles stay off unless one was picked, as
  /// with the native engine.
  private func applyTrackPicks() {
    if let pick = store?.latestTrackPick(kind: "audio"), let id = match(pick, in: audioTracks), id != audioTrackID {
      player.selectAudioTrack(id)
    }
    let subtitlePick = store?.latestTrackPick(kind: "sub")
    if let subtitlePick, !subtitlePick.isOff, let id = match(subtitlePick, in: subtitleTracks) {
      player.selectSubtitleTrack(id)
    } else {
      player.selectSubtitleTrack(nil)
    }
    syncMedia()
  }

  private func match(_ pick: PlayerTrackPick, in tracks: [MediaTrack]) -> Int? {
    if let lang = pick.lang, let title = pick.title,
      let track = tracks.first(where: { $0.language == lang && $0.title == title })
    {
      return track.id
    }
    if let lang = pick.lang, let track = tracks.first(where: { $0.language == lang }) { return track.id }
    if let title = pick.title, let track = tracks.first(where: { $0.title == title }) { return track.id }
    return nil
  }

  // MARK: Siblings and persistence

  private func advanceTrack(direction: Int) {
    guard let current = currentFileURL, let files = try? MediaFiles.siblings(of: current), files.count > 1,
      let index = files.firstIndex(where: { $0.standardizedFileURL == current })
    else { return }
    let target = files[((index + direction) % files.count + files.count) % files.count]
    Task { try? await open(target) }
  }

  private func autosavePosition() {
    guard isPlaying, position > 0, Date.now.timeIntervalSince(lastAutosave) >= 5 else { return }
    lastAutosave = .now
    saveCurrentPosition()
  }

  private func saveCurrentPosition() {
    guard let path = currentFilePath, position > 0 else { return }
    store?.saveCurrentPosition(path: path, position: position, duration: duration)
  }
}
