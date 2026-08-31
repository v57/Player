import AppKit
import Combine
import Foundation
import MediaPlayer

/// Pure UI state that doesn't belong on the playback protocol. Owned by the
/// App and injected alongside the player box, so both ContentView and the
/// menu commands can drive it.
///
/// Owns the controls auto-hide: while media plays, the controls overlay (and
/// the cursor in fullscreen) hide after `idleHideDelay` of no pointer/
/// keyboard activity in the window. Any interaction (hover, click, key)
/// re-shows them. Both hides are driven from `NSEvent.addLocalMonitor` on
/// the window — the only mechanism that fires regardless of which first
/// responder consumed the event. The cursor is hidden with
/// NSCursor.setHiddenUntilMouseMoves (re-shows on the next mouse movement).
@MainActor final class PlayerUIState: ObservableObject {
  /// Drives the file importer sheet; also triggered by File > Open….
  @Published var showFileImporter = false

  /// True while the pointer is over the video area; reveals the controls
  /// overlay during playback.
  @Published var hovering = false

  /// True while the controls overlay is hidden. Hidden only while media is
  /// actually playing; the overlay stays up on pause/stop (and when there's
  /// no file), so the controls can never get stuck off-screen.
  @Published var controlsHidden = false

  /// True while the fullscreen idle timer has hidden the cursor (via
  /// NSCursor.setHiddenUntilMouseMoves; re-shows on the next mouse move).
  @Published var cursorHidden = false

  /// How long (s) with no pointer/keyboard activity before the controls
  /// overlay (and, in fullscreen, the cursor) auto-hide while playing.
  private let idleHideDelay: TimeInterval = 2.5

  /// The player box to ask about the playing state (weak — the box owns
  /// the engine; the UI state is a UI-layer observer only). Injected by
  /// the App before any window exists.
  private weak var player: MediaPlayerBox?

  init(player: MediaPlayerBox? = nil) { self.player = player }

  private var idleTimer: Timer?
  /// Local event monitor: sees every event routed to this window (mouse,
  /// key, scroll), regardless of first responder — the only hook that can
  /// drive both the overlay hide and the fullscreen cursor hide together.
  private var eventMonitor: Any?
  private var isFullScreen = false

  // MARK: - Window lifecycle (called from ContentView)

  func install(in window: NSWindow) {
    removeEventMonitor()
    isFullScreen = window.styleMask.contains(.fullScreen)
    let monitor = NSEvent.addLocalMonitorForEvents(matching: [
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown,
      .scrollWheel, .keyDown, .keyUp,
    ]) { [weak self] event in
      self?.noteInteraction(event: event)
      return event
    }
    eventMonitor = monitor
    // Transport-key fallback (Space, arrows, chapter keys): the video
    // view's keyDown handles these when it's first responder, but if
    // some other control (timeline slider, button) holds focus — or the
    // window itself does — they never reach the view. Catch them here so
    // transport works no matter what has focus, matching how the
    // auto-hide monitor sees every event.
    let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleTransportKey(event) ?? event
    }
    transportKeyMonitors.append(keyMonitor)
  }

  private var transportKeyMonitors: [Any?] = []

  /// Routes transport keys that must work regardless of first responder.
  /// Returns nil (consumed) when handled, the event otherwise. Mirrors the
  /// video view's keyDown cases: bare Space/Return = play/pause, bare
  /// Left/Right = seek ∓5 s, Cmd+Left/Right and bare F5/F6 = chapters.
  private func handleTransportKey(_ event: NSEvent) -> NSEvent? {
    guard let player, player.fileName != nil else { return event }
    if event.isARepeat { return event }  // parity with the view
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasCmd = mods.contains(.command)
    let hasCtrl = mods.contains(.control)
    let hasOpt = mods.contains(.option)
    let bare = !hasCmd && !hasCtrl && !hasOpt
    switch event.keyCode {
    case 49:  // kVK_Space
      if bare {
        togglePlayPauseFromMonitor()
        return nil
      }
    case 36:  // kVK_Return (and keypad Return 76)
      if bare {
        togglePlayPauseFromMonitor()
        return nil
      }
    case 76:  // kVK_ANSI_KeypadEnter
      if bare {
        togglePlayPauseFromMonitor()
        return nil
      }
    case 123:  // kVK_LeftArrow
      if hasCmd {
        player.skipChapter(-1)
        return nil
      }
      if bare {
        player.seekRelative(-5)
        return nil
      }
    case 124:  // kVK_RightArrow
      if hasCmd {
        player.skipChapter(1)
        return nil
      }
      if bare {
        player.seekRelative(5)
        return nil
      }
    case 96:  // kVK_F5
      if bare {
        player.skipChapter(-1)
        return nil
      }
    case 97:  // kVK_F6
      if bare {
        player.skipChapter(1)
        return nil
      }
    default: break
    }
    return event
  }

  private func togglePlayPauseFromMonitor() {
    guard let player, player.fileName != nil else { return }
    if player.isPlaying { player.pause() } else { player.play() }
  }

  func removeEventMonitor() {
    for monitor in transportKeyMonitors { if let monitor { NSEvent.removeMonitor(monitor) } }
    transportKeyMonitors.removeAll()
    if let monitor = eventMonitor {
      NSEvent.removeMonitor(monitor)
      eventMonitor = nil
    }
  }

  func fullScreenChanged(_ entered: Bool) {
    isFullScreen = entered
    // Fresh timer in the new window context.
    restartIdleTimer()
    noteInteraction()
  }

  // MARK: - Auto-hide

  /// Called on every pointer/keyboard event delivered to the app: re-shows
  /// the controls and restarts the idle timer that hides them (and the
  /// cursor in fullscreen) while playing.
  func noteInteraction(event: NSEvent? = nil) {
    // NOTE: a LOCAL event monitor only ever sees THIS app's events, so a
    // mouseMoved with `event.window == nil` is not "another app" — it is
    // exactly the system menu / menu-bar tracking case (the menu runs in a
    // separate tracking window an NSView won't see as its own). Counting
    // those as interaction keeps the controls and cursor up while the user
    // navigates a menu, instead of the idle timer firing mid-menu and (after
    // the menu closes) leaving the cursor visible while the controls are
    // hidden.
    showControls()
    restartIdleTimer()
  }

  /// Whether the controls overlay should be visible right now.
  var controlsVisible: Bool {
    guard hovering || !isFullScreen else { return false }
    return !controlsHidden
  }

  func showControls() {
    controlsHidden = false
    setCursorHidden(false)
  }

  private func restartIdleTimer() {
    idleTimer?.invalidate()
    // REPEATING (not one-shot) so the cursor re-hide is self-correcting:
    // NSCursor.setHiddenUntilMouseMoves is ONE-SHOT — the system re-shows
    // the cursor on any mouse movement, including ones that close a menu
    // without reaching this monitor as a tracked interaction. A one-shot
    // timer that already fired cannot re-hide it, so a stray cursor stays
    // visible until the next interaction. Firing every idleHideDelay (and
    // reset on each interaction) re-arms the hide each tick even if the
    // overlay is already hidden.
    let timer = Timer(timeInterval: idleHideDelay, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.hideControlsIfPlaying() }
    }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
    idleTimer = timer
  }

  /// Hides the controls overlay (and the cursor in fullscreen) — but only
  /// while media is actually playing. Pausing or stopping re-shows them.
  private func hideControlsIfPlaying() {
    guard player?.isPlaying == true else { return }
    // Cursor hide stays INDEPENDENT of the overlay transition. The overlay
    // only needs to flip once (below), but NSCursor.setHiddenUntilMouseMoves
    // is one-shot and cleared by the system on any mouse move — one that may
    // not reach this monitor (closing a system menu re-shows the cursor
    // without an event we track). Re-arming it on every idle tick while
    // playing keeps the hidden state correct after such a move; gating on
    // `!controlsHidden` would leave a re-shown cursor visible forever once
    // the overlay is already hidden.
    if isFullScreen { setCursorHidden(true) }
    guard !controlsHidden else { return }
    controlsHidden = true
  }

  /// Applies the cursor hidden state. Hiding ALWAYS re-arms the one-shot
  /// `NSCursor.setHiddenUntilMouseMoves(true)` even if our `cursorHidden`
  /// bookkeeping says already-hidden — the system re-shows the cursor on any
  /// mouse move we may not have tracked (menu close), so the bool can be
  /// stale-true while the cursor is actually visible; re-arming is idempotent
  /// when it really is hidden. Showing cancels the hide (setHiddenUntilMouseMoves
  /// only adds the hide-until-move behavior, so the next move is what reveals;
  /// showControls runs off an interaction, so the cursor is already shown).
  private func setCursorHidden(_ hidden: Bool) {
    if hidden {
      cursorHidden = true
      NSCursor.setHiddenUntilMouseMoves(true)
    } else {
      guard cursorHidden else { return }
      cursorHidden = false
      NSCursor.setHiddenUntilMouseMoves(false)
    }
  }
}
