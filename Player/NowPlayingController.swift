import Combine
import Foundation
import PlatformMedia
import PlayerKit

/// Registers the player as the system's "Now Playing" app and routes the
/// Play/Next/Previous media keys to it, through PlatformMedia's NowPlaying
/// (MPNowPlayingInfoCenter + MPRemoteCommandCenter on macOS, MPRIS on Linux).
///
/// macOS delivers media-key events ONLY to the app currently registered as
/// the Now Playing app. That eligibility is established by (a) setting a
/// non-nil `nowPlayingInfo` on `MPNowPlayingInfoCenter` and (b) registering
/// `MPRemoteCommandCenter` handlers. Before this controller existed the
/// player did neither, so the physical Play/Next/Previous keys always fell
/// through to Music (the system default) — the "keys just open Music" report.
///
/// Created once in `PlayerApp` and held for the process lifetime; the box is
/// held weakly and owned by the app's @StateObject.
@MainActor final class NowPlayingController {
  private weak var player: SomePlayerBox?
  private var cancellables: Set<AnyCancellable> = []

  private var nowPlaying: NowPlaying?

  init(player: SomePlayerBox) {
    self.player = player
    nowPlaying = NowPlaying(name: "Player") { [weak self] command in self?.handle(command) ?? false }
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

  // MARK: - Media keys

  private func handle(_ command: NowPlaying.Command) -> Bool {
    guard let player, player.fileName != nil else { return false }
    switch command {
    case .play: player.play()
    case .pause: player.pause()
    case .togglePlayPause: if player.isPlaying { player.pause() } else { player.play() }
    case .nextTrack: player.nextTrack()
    case .previousTrack: player.previousTrack()
    }
    return true
  }

  // MARK: - Now Playing info

  private func refreshNowPlaying() {
    guard let player, let title = player.fileName else {
      nowPlaying?.update(nil)
      return
    }
    nowPlaying?.update(
      NowPlaying.Item(title: title, duration: player.duration, position: player.position, isPlaying: player.isPlaying))
  }
}
