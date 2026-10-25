import DevScreenshots
import Foundation
import PlayerKit

/// Debug builds: `--screenshot-demo` plays a demo video for the screenshots (`.dev/screenshots.json`). A debug build
/// shares the installed app's Application Support, so in this mode the playback store (resume points, track picks)
/// stays in memory.
///
///   --screenshot-demo        the demo
///   --open <file>            opens a video
///   --subtitle <stream>      then shows that subtitle stream
///   --seek <seconds>         then seeks there
///   --pause                  then pauses, so the picture holds still with the controls up
///   --subtitle-style         then opens Edit Style (the subtitle style panel)
///   --idle                   then lets the controls and the title bar hide after the idle delay, as with the
///                            pointer at rest
///   --recents <folder>       lists the folder's videos as played over the last days (the welcome's recent videos)
///   --hub-library <page>     shows Open from Device on demo devices: `devices` (with a failed connection) or `folder`
///
/// `dev-screenshots` takes every scene in one launch: the first comes from the launch arguments, each later one
/// arrives through DevScreenshots' scene handler with the same options, and opens in place.
enum ScreenshotDemo {
  /// The Open from Device page the scene shows (`--hub-library`): the sheet's library fills itself with demo devices.
  @MainActor static var hubLibraryPage: String?

  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  /// Called once the window is up: opens the launch's scene, then each later one in this launch.
  @MainActor static func start(player: SomePlayerBox, ui: PlayerUIState) async {
    Screenshots.prepare(waitsForReady: true) { scene in
      await open(scene.arguments, in: player, ui: ui)
    }
    await open(CommandLine.arguments, in: player, ui: ui)
    Screenshots.ready()
  }

  /// One scene, from its arguments. What the scene before opened is closed first, and its resume point forgotten,
  /// so a scene without `--open` shows the empty window with no recent videos.
  @MainActor static func open(_ arguments: [String], in player: SomePlayerBox, ui: PlayerUIState) async {
    guard isOn else { return }
    func value(_ option: String) -> String? {
      guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
      return arguments[index + 1]
    }
    if player.fileName != nil { player.stop() }
    PlaybackStore.shared.forgetDemoHistory()
    ui.showHubLibrary = false
    if let folder = value("--recents") { PlaybackStore.shared.seedDemoHistory(folder: URL(fileURLWithPath: folder)) }
    hubLibraryPage = value("--hub-library")
    if hubLibraryPage != nil {
      // A frame for the sheet to close in before it opens on the new page.
      try? await Task.sleep(for: .milliseconds(300))
      ui.showHubLibrary = true
      return
    }
    guard let path = value("--open") else { return }
    // Each step waits for the engine, so the scene is on screen when this returns: no settling delay needed.
    try? await player.open(URL(fileURLWithPath: path))
    await waitUntil { player.isPlaying }
    if let stream = value("--subtitle").flatMap(Int.init) { player.selectSubtitleTrack(stream) }
    if let seconds = value("--seek").flatMap(Double.init) {
      player.seek(to: seconds, exact: true)
      // The clock passes the target once the seek's first frames are showing.
      await waitUntil { player.position >= seconds && player.position < seconds + 2 }
    }
    if arguments.contains("--pause") {
      player.pause()
      await waitUntil { player.state == .paused }
    }
    ui.showControls()
    ui.showSubtitleStyle = arguments.contains("--subtitle-style")
    // The idle timer starts on an interaction, which a background launch never gets.
    if arguments.contains("--idle") { ui.noteInteraction() }
  }

  /// Polls the engine's state until `condition` holds, for at most `timeout` seconds.
  @MainActor private static func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition(), Date.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
  }
}
