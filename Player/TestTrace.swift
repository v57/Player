import AppKit

/// Test-harness trace: window/app activity, visibility and user interaction.
///
/// Enabled with `PLAYER_TRACE_WINDOW=1` (same env-hook pattern as
/// `PLAYER_MUTE` / `PLAYER_VOLUME` / `PLAYER_ENHANCEMENT_MODE` /
/// `PLAYER_IGNORE_INPUT`). When it is off, nothing is installed and nothing is
/// logged.
///
/// Why it exists: headless playback runs share the machine with the user, so
/// the player log mixes our playback evidence (the engine's 1 s `pos/fps/drift`
/// summary) with the user's own interactions. The engine cannot tell them
/// apart, because a click that focuses the window, a Space press, or Reactivation
/// can reach the transport path exactly like a scripted command. This trace
/// labels those events so the run can be filtered afterwards:
///
///   [Trace] t=12.345 app active
///   [Trace] t=12.345 window key ON
///   [Trace] t=12.400 user keyDown code=49 (Space -> play/pause)
///   [Trace] t=12.400 user leftMouseDown
///   [Trace] t=30.100 window miniaturized
///   [Trace] t=35.000 hb app=active key=1 mini=0 visible=1 occluded=0
///
/// Every line carries `t=` (seconds since launch), so it correlates directly
/// with the engine's own cadence and with the macOS timestamp NSLog prepends.
/// The 5 s heartbeat is the filter of last resort: if an unexplained transport
/// change appears between two heartbeats with no interaction line, it came from
/// the app itself, not the user.
///
/// `PLAYER_MINIATURIZE=1` additionally minimizes the window shortly after a file
/// opens (and logs it), so runs can proceed in the background while the machine
/// stays usable.
@MainActor
final class TestTrace {
  static let isEnabled = ProcessInfo.processInfo.environment["PLAYER_TRACE_WINDOW"] == "1"

  private let start = CACurrentMediaTime()
  private var observers: [NSObjectProtocol] = []
  private var monitors: [Any] = []
  private var heartbeat: Timer?
  private weak var window: NSWindow?
  /// Input shield, when installed — only for the heartbeat's blocked-event
  /// summary (the shield itself is wired in PlayerApp, after this trace, so its
  /// consuming monitor cannot hide the user's attempts from the trace lines).
  weak var shield: InputShield?

  /// Installs the trace. No-op unless PLAYER_TRACE_WINDOW=1.
  init() {
    guard Self.isEnabled else { return }
    let center = NotificationCenter.default
    func observe(_ name: NSNotification.Name, _ body: @escaping (Notification) -> Void) {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
        MainActor.assumeIsolated { body(note) }
      })
    }

    observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in self?.log("app active") }
    observe(NSApplication.didResignActiveNotification) { [weak self] _ in self?.log("app inactive") }
    observe(NSWindow.didBecomeKeyNotification) { [weak self] note in
      self?.adopt(note.object as? NSWindow)
      self?.log("window key ON")
    }
    observe(NSWindow.didResignKeyNotification) { [weak self] _ in self?.log("window key OFF") }
    observe(NSWindow.didMiniaturizeNotification) { [weak self] _ in self?.log("window miniaturized") }
    observe(NSWindow.didDeminiaturizeNotification) { [weak self] _ in self?.log("window deminiaturized") }
    observe(NSWindow.didChangeOcclusionStateNotification) { [weak self] note in
      guard let w = note.object as? NSWindow else { return }
      self?.log("window occlusion changed (visible=\(w.occlusionState.contains(.visible) ? 1 : 0))")
    }

    // Local monitors: only events delivered to THIS app, which is what we want
    // — the user's activity in other apps must not be attributed to the player.
    let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      self?.log("user mouseDown (window=\(event.window != nil ? 1 : 0))")
      return event
    }
    let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.log("user keyDown code=\(event.keyCode) repeat=\(event.isARepeat ? 1 : 0)")
      return event
    }
    monitors = [mouse as Any, keys as Any]

    let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.heartbeatTick() }
    }
    timer.tolerance = 1.0
    RunLoop.main.add(timer, forMode: .common)
    heartbeat = timer

    log("trace installed (PLAYER_MINIATURIZE=\(Self.wantsMiniaturize ? 1 : 0))")
  }

  /// PLAYER_MINIATURIZE=1 — run minimized so the machine stays usable.
  static let wantsMiniaturize = ProcessInfo.processInfo.environment["PLAYER_MINIATURIZE"] == "1"

  private func adopt(_ w: NSWindow?) {
    guard let w, window == nil else { return }
    window = w
    log("window adopted: \(w.title.isEmpty ? "Player" : w.title)")
    if Self.wantsMiniaturize {
      // Short delay only: enough for the first frames to come up, but the
      // window is out of the way almost immediately. Input is separately
      // blocked by InputShield (PLAYER_IGNORE_INPUT) so the window being up
      // for a moment cannot let the user's actions reach the transport.
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        self.log("miniaturizing window (PLAYER_MINIATURIZE)")
        w.miniaturize(nil)
      }
    }
  }

  private func heartbeatTick() {
    let w = window ?? NSApp.windows.first
    let key = w?.isKeyWindow == true ? 1 : 0
    let mini = w?.isMiniaturized == true ? 1 : 0
    let visible = w?.occlusionState.contains(.visible) == true ? 1 : 0
    let appActive = NSApp.isActive ? 1 : 0
    let playing = w?.isVisible == true ? 1 : 0
    let input = shield?.summary() ?? "shield off"
    log("hb app=\(appActive) key=\(key) mini=\(mini) visible=\(visible) shown=\(playing) \(input)")
  }

  func log(_ message: String) {
    guard Self.isEnabled else { return }
    NSLog("[Trace] t=%.3f %@", CACurrentMediaTime() - start, message)
  }
}
