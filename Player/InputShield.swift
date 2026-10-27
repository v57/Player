// macOS only: AppKit.
#if os(macOS)
import AppKit

/// Input shield for headless playback runs (`PLAYER_IGNORE_INPUT=1`).
///
/// The player under test shares the machine with its user. Transport is bound
/// to bare keys (Space / Return / arrows / F5 / F6) and to clicks on the
/// controls (play-pause button, timeline), so a test run's log gets polluted by
/// whatever the user is doing — and the user's media keys/music get hijacked by
/// the app. Two independent guards fix that:
///
///   1. `PLAYER_NO_MEDIA_KEYS=1` (PlayerApp): the app does not register as the
///      macOS Now Playing app, so Play/Next/Previous keep going to Music.
///   2. This shield: a local event monitor matching `.any` that CONSUMES every
///      event delivered to this app (returns nil, so AppKit never dispatches it
///      to the responder chain, SwiftUI controls, menus or the SwiftUI command
///      system). Keyboard and mouse are both inert for the player: no transport
///      keys, no button/slider clicks, no window dragging.
///
/// Install order matters: the monitor is added AFTER TestTrace's monitors, and
/// local monitors run in registration order, so the trace still records what
/// the user tried (`user keyDown ...`) before the event is swallowed. Blocked
/// events are counted and reported once per trace heartbeat rather than logged
/// individually — mouse moves alone would flood the file.
///
/// Consequence to remember: with the shield on, the app cannot be driven or
/// quit through its UI at all. Test runs must be ended by killing the process.
@MainActor
final class InputShield {
  static let isEnabled = ProcessInfo.processInfo.environment["PLAYER_IGNORE_INPUT"] == "1"

  private var monitor: Any?
  /// Events swallowed (read by TestTrace's heartbeat for the summary line).
  private(set) var blocked = 0
  /// Descriptor of the most recent swallowed event, for that summary line.
  private(set) var lastBlocked = "none"

  init() {
    guard Self.isEnabled else { return }
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] event in
      self?.blocked += 1
      // Only describe the meaningful ones; mouseMoved/keyUp would drown the
      // summary in noise.
      switch event.type {
      case .keyDown: self?.lastBlocked = "keyDown code=\(event.keyCode)"
      case .leftMouseDown: self?.lastBlocked = "leftMouseDown"
      case .rightMouseDown: self?.lastBlocked = "rightMouseDown"
      case .scrollWheel: self?.lastBlocked = "scrollWheel"
      default: break
      }
      return nil  // consume: this app sees no keyboard and no mouse
    }
    self.monitor = monitor
    NSLog("[Trace] input shield ON (PLAYER_IGNORE_INPUT=1) — keyboard/mouse inert for this app")
  }

  /// Summary for the heartbeat line, e.g. "blocked=17 (last=keyDown code=49)".
  func summary() -> String { "blocked=\(blocked) (last=\(lastBlocked))" }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
  }
}
#endif
