import SwiftUI
import MediaPlayer

@main
struct PlayerApp: App {
    /// The concrete MediaPlayerBox wraps the native engine; views observe the
    /// box (an existential cannot be an @EnvironmentObject — probed, see
    /// MediaPlayerBox). Wave 6 removed the libmpv engine entirely — native is
    /// the only engine now (KANBAN).
    @StateObject private var player: MediaPlayerBox
    @StateObject private var uiState: PlayerUIState

    init() {
        let box = MediaPlayerBox(engine: NativeMediaPlayer())
        // Inject the SwiftData-backed store into the engine's persistence
        // seam (the library never touches SwiftData itself).
        if let engine = box.engine as? NativeMediaPlayer {
            engine.store = PlaybackStore.shared
        }
        _player = StateObject(wrappedValue: box)
        _uiState = StateObject(wrappedValue: PlayerUIState(player: box))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(uiState)
                .frame(minWidth: 800, minHeight: 500)
                // Single-window app. By default WindowGroup opens a NEW
                // window for every external open event (Finder "Open With…",
                // `open`, Dock drops) and delivers the URL to that window's
                // onOpenURL. With a shared player, a second window cannot
                // render the shared engine's video surface — black screen.
                // This VIEW modifier makes the already open scene claim every
                // external event ("*" matches any URL's absoluteString), so
                // events route to the existing window instead of spawning a
                // new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    // Dock-icon drops, Finder "Open With…", and `open` all
                    // arrive here. Verified on macOS 27: with
                    // handlesExternalEvents claiming the event for the
                    // scene, SwiftUI routes it here and an NSApplication
                    // delegate implementing application(_:open:) is never
                    // called. External opens must stay on this path.
                    Task { try? await player.open(url) }
                }
        }
        // The SCENE modifier still accepts external events when no window is
        // open (cold launch with a file), so SwiftUI creates the single
        // initial window for the event instead of dropping it.
        .handlesExternalEvents(matching: ["*"])
        .commands {
            PlayerCommands(player: player, uiState: uiState)
            // WindowGroup also contributes File > New Window (Cmd+N), which
            // would create the same unusable second window.
            CommandGroup(replacing: .newItem) {}
        }
    }
}