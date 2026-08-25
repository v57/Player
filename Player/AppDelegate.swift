import AppKit

/// Closes the app when its last window is closed (standard macOS behavior).
/// Without this, a SwiftUI WindowGroup app stays running (and in the Dock)
/// after every window is closed. Returns true from
/// applicationShouldTerminateAfterLastWindowClosed so the app quits. AppKit
/// calls this on the main thread; the target compiles with
/// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so the class is MainActor-isolated
/// by default, which matches where these calls arrive.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
