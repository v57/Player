import Combine
import Foundation
import MediaPlayer  // Apple's framework — no longer shadowed (engine module is `SomePlayer` now)
import SomePlayer   // engine: SomePlayerBox

/// Registers the player as a macOS "Now Playing" app and routes the
/// Play/Next/Previous media keys to it, purely in Swift (no ObjC shim needed:
/// the engine module was renamed `SomePlayer`, so `import MediaPlayer` here is
/// Apple's MediaPlayer.framework, not the engine).
///
/// macOS delivers media-key events ONLY to the app currently registered as
/// the Now Playing app. That eligibility is established by (a) setting a
/// non-nil `nowPlayingInfo` on `MPNowPlayingInfoCenter` and (b) registering
/// `MPRemoteCommandCenter` handlers. Before this controller existed the
/// player did neither, so the physical Play/Next/Previous keys always fell
/// through to Music (the system default) — the "keys just open Music" report.
///
/// Note: on macOS the Now Playing mechanism is `MPRemoteCommandCenter` +
/// `MPNowPlayingInfoCenter`. There is no `AVAudioSession` category step —
/// `AVAudioSession` is `API_UNAVAILABLE(macos)` (it is an iOS/tvOS API).
///
/// Created once in `PlayerApp` and held for the process lifetime; the box is
/// held weakly and owned by the app's @StateObject.
@MainActor final class NowPlayingController {
  private weak var player: SomePlayerBox?
  private var cancellables: Set<AnyCancellable> = []

  init(player: SomePlayerBox) {
    self.player = player
    registerRemoteCommands()
    // Refresh Now Playing info whenever the player publishes a change.
    // objectWillChange fires BEFORE the @Published value commits, so defer
    // the read to the next main-actor hop to see fresh state. `position` is
    // published ~5 Hz while playing, so elapsed time stays current.
    player.objectWillChange.sink { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in self.refreshNowPlaying() }
    }.store(in: &cancellables)
    refreshNowPlaying()
  }

  // MARK: - Remote commands

  private func registerRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      return MainActor.assumeIsolated { self.handlePlay() }
    }
    center.pauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      return MainActor.assumeIsolated { self.handlePause() }
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      return MainActor.assumeIsolated { self.handleTogglePlayPause() }
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      return MainActor.assumeIsolated { self.handleNext() }
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      return MainActor.assumeIsolated { self.handlePrevious() }
    }
  }

  private func handlePlay() -> MPRemoteCommandHandlerStatus {
    guard let player, player.fileName != nil else { return .commandFailed }
    player.play()
    return .success
  }

  private func handlePause() -> MPRemoteCommandHandlerStatus {
    guard let player, player.fileName != nil else { return .commandFailed }
    player.pause()
    return .success
  }

  private func handleTogglePlayPause() -> MPRemoteCommandHandlerStatus {
    guard let player, player.fileName != nil else { return .commandFailed }
    if player.isPlaying { player.pause() } else { player.play() }
    return .success
  }

  private func handleNext() -> MPRemoteCommandHandlerStatus {
    guard let player, player.fileName != nil else { return .commandFailed }
    player.nextTrack()
    return .success
  }

  private func handlePrevious() -> MPRemoteCommandHandlerStatus {
    guard let player, player.fileName != nil else { return .commandFailed }
    player.previousTrack()
    return .success
  }

  // MARK: - Now Playing info

  private func refreshNowPlaying() {
    guard let player, let title = player.fileName else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
      return
    }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: player.position,
      MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
    ]
    // Duration is 0 while the file is opening; only publish it once known.
    if player.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = player.duration }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState =
      player.isPlaying ? MPNowPlayingPlaybackState.playing : MPNowPlayingPlaybackState.paused
  }
}
