import Foundation
import Observation
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
/// held weakly and owned by the app's @State.
@MainActor final class NowPlayingController {
  private weak var player: SomePlayerBox?
  private var nowPlaying: NowPlaying?

  init(player: SomePlayerBox) {
    self.player = player
    nowPlaying = NowPlaying(name: "Player") { [weak self] command in self?.handle(command) ?? false }
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

  /// Sends what plays, and again whenever anything read here changes: `position` moves ~5 Hz while playing, so elapsed
  /// time stays current. The change arrives before the new value is stored, so the next read waits for a main-actor hop.
  private func refreshNowPlaying() {
    let item = withObservationTracking {
      player.flatMap { player in
        player.fileName.map {
          NowPlaying.Item(title: $0, duration: player.duration, position: player.position, isPlaying: player.isPlaying)
        }
      }
    } onChange: { [weak self] in
      Task { @MainActor in self?.refreshNowPlaying() }
    }
    nowPlaying?.update(item)
  }
}
