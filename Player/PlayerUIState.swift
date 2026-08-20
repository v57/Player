import AppKit
import MediaPlayer
import Combine
import Foundation

/// Pure UI state that doesn't belong on the playback protocol. Owned by the
/// App and injected alongside the player box, so both ContentView and the
/// menu commands can drive it.
///
/// Owns the controls auto-hide: while media plays, the controls overlay and
/// the cursor hide after `idleHideDelay` of no pointer/keyboard activity in
/// the window. Any interaction (hover, click, key) re-shows them. The idle
/// timer runs from `NSEvent.addLocalMonitor` on the window — the only
/// mechanism that fires regardless of which first responder consumed the
/// event, and the same hook the fullscreen cursor hide needs (the cursor is
/// hidden through a tracking area, which only covers the video view).
@MainActor
final class PlayerUIState: ObservableObject {
    /// Drives the file importer sheet; also triggered by File > Open….
    @Published var showFileImporter = false

    /// True while the pointer is over the video area; reveals the controls
    /// overlay during playback.
    @Published var hovering = false

    /// True while the controls overlay is hidden. Hidden only while media is
    /// actually playing; the overlay stays up on pause/stop (and when there's
    /// no file), so the controls can never get stuck off-screen.
    @Published var controlsHidden = false

    /// True while the fullscreen idle timer has hidden the cursor (a tracking
    /// area in NativeVideoView drives this — it only covers the video view).
    @Published var cursorHidden = false

    /// How long (s) with no pointer/keyboard activity before the controls
    /// overlay (and, in fullscreen, the cursor) auto-hide while playing.
    private let idleHideDelay: TimeInterval = 2.5

    /// The player box to ask about the playing state (weak — the box owns
    /// the engine; the UI state is a UI-layer observer only). Injected by
    /// the App before any window exists.
    private weak var player: MediaPlayerBox?

    init(player: MediaPlayerBox? = nil) {
        self.player = player
    }

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
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .rightMouseDown, .scrollWheel,
            .keyDown, .keyUp,
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
        if event.isARepeat { return event }   // parity with the view
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = mods.contains(.command)
        let hasCtrl = mods.contains(.control)
        let hasOpt = mods.contains(.option)
        let bare = !hasCmd && !hasCtrl && !hasOpt
        switch event.keyCode {
        case 49: // kVK_Space
            if bare {
                togglePlayPauseFromMonitor()
                return nil
            }
        case 36: // kVK_Return (and keypad Return 76)
            if bare {
                togglePlayPauseFromMonitor()
                return nil
            }
        case 76: // kVK_ANSI_KeypadEnter
            if bare {
                togglePlayPauseFromMonitor()
                return nil
            }
        case 123: // kVK_LeftArrow
            if hasCmd {
                player.skipChapter(-1)
                return nil
            }
            if bare {
                player.seekRelative(-5)
                return nil
            }
        case 124: // kVK_RightArrow
            if hasCmd {
                player.skipChapter(1)
                return nil
            }
            if bare {
                player.seekRelative(5)
                return nil
            }
        case 96: // kVK_F5
            if bare {
                player.skipChapter(-1)
                return nil
            }
        case 97: // kVK_F6
            if bare {
                player.skipChapter(1)
                return nil
            }
        default:
            break
        }
        return event
    }

    private func togglePlayPauseFromMonitor() {
        guard let player, player.fileName != nil else { return }
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func removeEventMonitor() {
        for monitor in transportKeyMonitors {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
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

    /// Called on every pointer/keyboard event in the window: re-shows the
    /// controls and restarts the idle timer that hides them (and the cursor
    /// in fullscreen) while playing.
    func noteInteraction(event: NSEvent? = nil) {
        if let event, event.type == .mouseMoved, event.window == nil {
            // Not our window (e.g. another app's); ignore.
            return
        }
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
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: idleHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideControlsIfPlaying() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// Hides the controls overlay (and the cursor in fullscreen) — but only
    /// while media is actually playing. Pausing or stopping re-shows them.
    private func hideControlsIfPlaying() {
        guard !controlsHidden else { return }
        guard player?.isPlaying == true else { return }
        controlsHidden = true
        cursorHidden = true
    }
}
