import Combine
import Foundation
import SomePlayer
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject private var player: SomePlayerBox
  @EnvironmentObject private var uiState: PlayerUIState

  /// True while a file drag hovers over the window; drives the drop
  /// affordance overlay.
  @State private var isDropTargeted = false
  var body: some View {
    ZStack {
      videoSurface
      if player.fileName == nil { emptyState }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      // Whole-window drop target: files dragged onto the window open
      // through the same path as Open…/Open With. The engine's open()
      // handles the security-scoped access and bookmark persistence.
      .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
        handleDrop(providers)
        return true
      }.overlay(alignment: .bottom) {
        if player.fileName != nil, uiState.controlsVisible {
          TimelineBar(player: player).transition(.blurReplace)
        }
      }.overlay(alignment: .topLeading) {
        // Playback hit the end of a still-downloading file; the engine is
        // waiting for it to grow and will retry. Shown while that wait is
        // active, in the top-leading corner above the video.
        if player.isWaitingForFileUpdate { waitingBadge }
      }.overlay { if isDropTargeted { dropTargetOverlay } }.onHover { uiState.hovering = $0 }
      .animation(.easeInOut(duration: 0.2), value: uiState.hovering).animation(
        .easeInOut(duration: 0.2), value: uiState.controlsHidden
      ).animation(.easeInOut(duration: 0.2), value: player.isPlaying).animation(
        .easeInOut(duration: 0.15), value: isDropTargeted
      ).navigationTitle(player.fileName ?? "Player").onReceive(
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
      ) { note in
        guard let window = note.object as? NSWindow else { return }
        uiState.install(in: window)
      }.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
        note in
        guard let window = note.object as? NSWindow else { return }
        if let appWindow = NSApp.keyWindow, appWindow === window { return }
        uiState.removeEventMonitor()
      }.onReceive(
        NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
      ) { note in
        // Edge-to-edge video: let the content extend under the title bar,
        // which only appears on hover at the top of the screen.
        guard let window = note.object as? NSWindow else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        uiState.fullScreenChanged(true)
      }.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))
    { note in
      guard let window = note.object as? NSWindow else { return }
      window.titlebarAppearsTransparent = false
      window.styleMask.remove(.fullSizeContentView)
      uiState.fullScreenChanged(false)
    }.fileImporter(
      isPresented: Binding(
        get: { uiState.showFileImporter }, set: { uiState.showFileImporter = $0 }),
      allowedContentTypes: [.movie, .mkv], allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        Task { try? await player.open(url) }
      }
    }.alert("Player Error", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(player.errorMessage ?? "")
    }
  }
  /// The native engine's video surface: a Metal sink the player pushes
  /// decoded frames into. Cursor auto-hide in fullscreen is owned by
  /// PlayerUIState (NSCursor.setHiddenUntilMouseMoves from the window
  /// event monitor) — the view itself does no cursor management.
  private var videoSurface: some View { SomePlayerView(player: player) }
  private var emptyState: some View {
    let recent = recentVideos
    return VStack(spacing: 16) {
      GeometryReader { view in
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(recent) { record in
              Button {
                openRecent(record)
              } label: {
                VStack(alignment: .leading) {
                  Text(URL(fileURLWithPath: record.filePath).lastPathComponent).truncationMode(
                    .middle)
                  let duration: Range<Date> =
                    Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: record.duration)
                  HStack {
                    Text(duration, format: .timeDuration).frame(minWidth: 48, alignment: .leading)
                    Text(record.lastPlayedAt, format: .relative(presentation: .named))
                  }.foregroundStyle(.secondary).font(.caption)
                }
              }.buttonStyle(.plain)
            }
          }.lineLimit(1).padding(.horizontal, 16).frame(
            minWidth: 400, maxWidth: .infinity, minHeight: view.size.height)
        }
      }.safeAreaInset(edge: .bottom) {
        Button("Open", systemImage: "folder.fill") { uiState.showFileImporter = true }.padding(
          .bottom)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  /// The 5 most recently played files that still exist on disk, newest
  /// first. Re-fetched on each render, so the list reflects the latest
  /// additions the moment the empty state appears.
  private var recentVideos: [PlaybackRecord] {
    PlaybackStore.shared.recentVideos(limit: 5).filter {
      FileManager.default.fileExists(atPath: $0.filePath)
    }
  }
  private func openRecent(_ record: PlaybackRecord) {
    // Prefer the persisted security-scoped bookmark: the sandbox can't
    // read a bare path outside its container (e.g. ~/Downloads). If no
    // bookmark exists yet (older history), fall back to the plain path.
    let url: URL
    var isStale = false
    if let data = record.bookmarkData,
      let resolved = try? URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &isStale)
    {
      url = resolved
    } else {
      url = URL(fileURLWithPath: record.filePath)
    }
    Task { try? await player.open(url) }
  }

  // MARK: - Drag & drop

  /// Loads every dropped provider's URL and opens it. Completion hops to
  /// main (loadObject's callback is off-main) before touching the player.
  private func handleDrop(_ providers: [NSItemProvider]) {
    for provider in providers {
      _ = provider.loadObject(ofClass: URL.self) { item, _ in
        Task { @MainActor in
          guard let url = item else { return }
          openDropped(url)
        }
      }
    }
  }

  /// Opens a dropped file after validating it's a video — a text file or
  /// folder dropped on the player shouldn't silently vanish; surface it
  /// through the existing error alert instead.
  private func openDropped(_ url: URL) {
    guard Self.isVideoURL(url) else {
      player.errorMessage = "\"\(url.lastPathComponent)\" is not a video file."
      return
    }
    Task { try? await player.open(url) }
  }

  /// True for anything macOS classifies as a movie plus the extensions it
  /// leaves as non-conforming dynamic UTIs that the FFmpeg engine still
  /// plays.
  private static func isVideoURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext), type.conforms(to: .movie) { return true }
    return Self.extraVideoExtensions.contains(ext)
  }

  /// Extensions whose UTI resolves to a dynamic (non-public.movie) type on
  /// macOS 27 (probed): mkv, vob, divx, asf. rmvb/m2v are included for the
  /// same reason — the engine is FFmpeg and plays them regardless.
  private static let extraVideoExtensions: Set<String> = [
    "mkv", "vob", "divx", "asf", "rmvb", "m2v",
  ]

  /// Red "Waiting" capsule shown in the top-leading corner while the engine
  /// waits for a still-downloading file to update.
  private var waitingBadge: some View {
    Text("Waiting")
      .padding(.horizontal, 12).padding(.vertical, 4).background(.red, in: .capsule).padding()
  }

  /// Full-window drop highlight, shown while a file drag hovers over the
  /// window: dim, accent stroke, and a centered label.
  private var dropTargetOverlay: some View {
    ZStack {
      Color.black.opacity(0.35)
      RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2).padding(12)
      Label("Drop to Play", systemImage: "play.circle.fill").font(.title2).padding(.horizontal, 24)
        .padding(.vertical, 12).background(.regularMaterial, in: Capsule())
    }.allowsHitTesting(false).transition(.opacity)
  }
  private var errorBinding: Binding<Bool> {
    Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })
  }
}

extension UTType { static var mkv: UTType { UTType(filenameExtension: "mkv") ?? .movie } }
