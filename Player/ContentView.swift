import SwiftUI
import UniformTypeIdentifiers
import Combine
import Foundation
import MediaPlayer

struct ContentView: View {
    @EnvironmentObject private var player: MediaPlayerBox
    @EnvironmentObject private var uiState: PlayerUIState

    var body: some View {
        ZStack {
            videoSurface
            if player.fileName == nil {
                emptyState
            }
            if player.fileName != nil, uiState.controlsVisible {
                TimelineBar(player: player)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { uiState.hovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: uiState.hovering)
        .animation(.easeInOut(duration: 0.2), value: uiState.controlsHidden)
        .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
        .navigationTitle(player.fileName ?? "Player")
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            uiState.install(in: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            if let appWindow = NSApp.keyWindow, appWindow === window { return }
            uiState.removeEventMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            // Edge-to-edge video: let the content extend under the title bar,
            // which only appears on hover at the top of the screen.
            guard let window = note.object as? NSWindow else { return }
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            uiState.fullScreenChanged(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            window.titlebarAppearsTransparent = false
            window.styleMask.remove(.fullSizeContentView)
            uiState.fullScreenChanged(false)
        }
        .fileImporter(
            isPresented: Binding(
                get: { uiState.showFileImporter },
                set: { uiState.showFileImporter = $0 }
            ),
            allowedContentTypes: [.movie, .mkv],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { try? await player.open(url) }
            }
        }
        .alert("Player Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }

    /// The native engine's video surface: a Metal sink the player pushes
    /// decoded frames into.
    private var videoSurface: some View {
        // The Metal view drives the cursor auto-hide through a tracking area
        // (which only covers the video view); the controls overlay hide is
        // driven by the window event monitor in PlayerUIState.
        MediaPlayerView(player: player, onIdleHideChanged: { uiState.cursorHidden = $0 })
    }

    private var emptyState: some View {
        let recent = recentVideos
        return VStack(spacing: 16) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            if recent.isEmpty {
                Text("No video open")
                    .font(.title2)
            } else {
                Text("Recent")
                    .font(.title3.weight(.semibold))
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(recent) { record in
                            Button {
                                openRecent(record)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "film")
                                        .foregroundStyle(.secondary)
                                    Text(URL(fileURLWithPath: record.filePath).lastPathComponent)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 400, maxHeight: 240)
            }
            Button("Open a video…") {
                uiState.showFileImporter = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The 5 most recently played files that still exist on disk, newest
    /// first. Re-fetched on each render, so the list reflects the latest
    /// additions the moment the empty state appears.
    private var recentVideos: [PlaybackRecord] {
        PlaybackStore.shared.recentVideos(limit: 5)
            .filter { FileManager.default.fileExists(atPath: $0.filePath) }
    }

    private func openRecent(_ record: PlaybackRecord) {
        // Prefer the persisted security-scoped bookmark: the sandbox can't
        // read a bare path outside its container (e.g. ~/Downloads). If no
        // bookmark exists yet (older history), fall back to the plain path.
        let url: URL
        var isStale = false
        if let data = record.bookmarkData,
           let resolved = try? URL(resolvingBookmarkData: data,
                                   options: .withSecurityScope,
                                   relativeTo: nil, bookmarkDataIsStale: &isStale) {
            url = resolved
        } else {
            url = URL(fileURLWithPath: record.filePath)
        }
        Task { try? await player.open(url) }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )
    }
}

extension UTType {
    static var mkv: UTType {
        UTType(filenameExtension: "mkv") ?? .movie
    }
}
