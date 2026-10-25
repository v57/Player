import AppKit

/// Keeps the app dark, and closes it when its last window is closed (standard macOS behavior).
/// Without the latter, a SwiftUI WindowGroup app stays running (and in the Dock)
/// after every window is closed. Returns true from
/// applicationShouldTerminateAfterLastWindowClosed so the app quits. AppKit
/// calls this on the main thread; the target compiles with
/// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so the class is MainActor-isolated
/// by default, which matches where these calls arrive.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Always dark, whatever the system's setting: the window, its sheets, the menus and the Open panel.
  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.appearance = NSAppearance(named: .darkAqua)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
