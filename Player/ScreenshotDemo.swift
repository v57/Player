import Foundation
import PlayerKit

/// Debug builds: `--screenshot-demo` plays a demo video for the screenshots (`.dev/screenshots.json`). A debug build
/// shares the installed app's Application Support, so in this mode the playback store (resume points, track picks)
/// stays in memory.
///
///   --screenshot-demo        the demo
///   --open <file>            opens a video
///   --seek <seconds>         then seeks there
///   --pause                  then pauses, so the picture holds still with the controls up
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  static func value(_ option: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
  }

  @MainActor static func apply(to player: SomePlayerBox, ui: PlayerUIState) async {
    guard isOn, let path = value("--open") else { return }
    try? await player.open(URL(fileURLWithPath: path))
    if let seconds = value("--seek").flatMap(Double.init) {
      try? await Task.sleep(for: .milliseconds(500))
      player.seek(to: seconds, exact: true)
    }
    if CommandLine.arguments.contains("--pause") {
      try? await Task.sleep(for: .milliseconds(800))
      player.pause()
    }
    ui.showControls()
  }
}
