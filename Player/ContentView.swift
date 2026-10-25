import Combine
import ComponentKit
import Foundation
import PlayerKit
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
      // Hidden while nothing is open: after a stop the Metal layer keeps the last frame it drew.
      // Edge to edge: under the title bar, which hides with the controls.
      videoSurface.opacity(player.fileName == nil ? 0 : 1).ignoresSafeArea()
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
          TimelineBar(player: player).transition(.opacity)
        }
      }.overlay(alignment: .topLeading) {
        // Playback hit the end of a still-downloading file; the engine is
        // waiting for it to grow and will retry. Shown while that wait is
        // active, in the top-leading corner above the video.
        if player.isWaitingForFileUpdate { waitingBadge }
      }.background { WindowReader { uiState.attach(to: $0) } }
      .kitDropTarget(isDropTargeted, cornerRadius: KitMetrics.radiusWindow)
      .overlay { if isDropTargeted { dropTargetLabel } }.onHover { uiState.hovering = $0 }
      .animation(.kit, value: uiState.hovering).animation(.kit, value: uiState.controlsHidden)
      .animation(.kit, value: player.isPlaying).animation(.kit, value: player.isWaitingForFileUpdate)
      .animation(.kitFast, value: isDropTargeted)
      .navigationTitle(player.fileName ?? "Player")
      .toolbar {
        // The open video's rich title replaces the window's own.
        if let name = player.fileName {
          KitToolbarItem(placement: .navigation) {
            KitTitle(name, meta: videoMeta, systemImage: "film", hue: .indigo).padding(.leading, 6)
          }
        }
      }
      .kitHidesSystemTitle(player.fileName != nil)
      // The video runs under the title bar (PlayerUIState.applyWindowChrome).
      .toolbarBackground(player.fileName != nil ? .hidden : .automatic, for: .windowToolbar)
      .onReceive(
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
      ) { _ in
        // Edge-to-edge video under the title bar, which only appears on hover at the top of the screen.
        uiState.fullScreenChanged(true)
      }.onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification))
    { _ in
      uiState.fullScreenChanged(false)
    }.onChange(of: player.fileName != nil) {
      uiState.applyWindowChrome()
    }.fileImporter(
      isPresented: Binding(
        get: { uiState.showFileImporter }, set: { uiState.showFileImporter = $0 }),
      allowedContentTypes: UTType.playableMovies, allowsMultipleSelection: false
    ) { result in
      if case .success(let urls) = result, let url = urls.first {
        Task { try? await player.open(url) }
      }
    }.kitSheet(isPresented: Binding(get: { uiState.showHubLibrary }, set: { uiState.showHubLibrary = $0 })) {
      HubLibrarySheet()
    }.kitSheet(isPresented: errorBinding) {
      ErrorSheet(message: player.errorMessage ?? "")
    }
  }
  /// The native engine's video surface: a Metal sink the player pushes
  /// decoded frames into. Cursor auto-hide in fullscreen is owned by
  /// PlayerUIState (NSCursor.setHiddenUntilMouseMoves from the window
  /// event monitor) — the view itself does no cursor management.
  private var videoSurface: some View { SomePlayerView(player: player) }
  /// No video open: the inline welcome, with Open and Open from Device beside the videos played last.
  private var emptyState: some View {
    let recent = recentVideos
    return KitWelcome(
      emptyTitle: "No Recent Videos",
      emptyMessage: "Open an MKV, MP4 or MOV file, or drop one on this window. Videos you play show up here."
    ) {
      WelcomeAction("Open…", detail: "An MKV, MP4 or MOV file on this Mac", systemImage: "folder") {
        uiState.showFileImporter = true
      }
      WelcomeAction(
        "Open from Device…", detail: "A video on another of your devices", systemImage: "point.3.connected.trianglepath.dotted"
      ) { uiState.showHubLibrary = true }
    } recents: {
      ForEach(recent) { record in
        RecentItem(
          URL(fileURLWithPath: record.filePath).lastPathComponent, subtitle: Self.recentLine(record),
          date: record.lastPlayedAt.formatted(.relative(presentation: .named)), systemImage: "film",
          id: record.filePath
        ) { openRecent(record) }
      }
    }
    .kitPane(.content)
  }

  /// "12:48 · ~/Movies": the length and the folder.
  private static func recentLine(_ record: PlaybackRecord) -> String {
    let duration = Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond))
    let folder = (URL(fileURLWithPath: record.filePath).deletingLastPathComponent().path as NSString)
      .abbreviatingWithTildeInPath
    return "\(duration) · \(folder)"
  }

  /// The title's meta line: the video codec and the length ("H264 · 1:00").
  private var videoMeta: [String] {
    var parts: [String] = []
    if let codec = player.videoTracks.first?.codec { parts.append(codec.uppercased()) }
    if player.duration > 0 { parts.append(MediaTime(seconds: player.duration).displayString) }
    return parts
  }

  /// The 20 most recently played files that still exist on disk, newest
  /// first. Re-fetched on each render, so the list reflects the latest
  /// additions the moment the empty state appears.
  private var recentVideos: [PlaybackRecord] {
    PlaybackStore.shared.recentVideos(limit: 20).filter {
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
    guard NativeSomePlayer.isSupportedFile(url) else {
      player.errorMessage =
        "\"\(url.lastPathComponent)\" is not a supported video file (MKV, MP4 or MOV only)."
      return
    }
    Task { try? await player.open(url) }
  }

  /// Shown in the top-leading corner while the engine waits for a still-downloading file to grow: the wait lives in
  /// the live icon's work indicator.
  private var waitingBadge: some View {
    HStack(spacing: 8) {
      LiveIcon(systemImage: "arrow.down", hue: .orange, status: .working(), size: 20)
      Text("Waiting for the download").kitFont(.callout)
    }
    .padding(.leading, 6)
    .padding(.trailing, 12)
    .padding(.vertical, 6)
    .kitSurface(.floating, cornerRadius: KitMetrics.radiusCard)
    .environment(\.colorScheme, .dark)
    .padding(KitMetrics.gutter * 2)
    .transition(.opacity)
  }

  /// The label in the middle of the window while a file drag hovers over it (the window wears the kit's drop ring).
  private var dropTargetLabel: some View {
    Label("Drop to Play", systemImage: "play.fill")
      .kitFont(.headline)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .kitSurface(.floating, cornerRadius: KitMetrics.radiusCard)
      .allowsHitTesting(false)
      .transition(.opacity)
  }
  private var errorBinding: Binding<Bool> {
    Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })
  }
}

extension UTType {
  /// Matroska.
  static var mkv: UTType { UTType(filenameExtension: "mkv", conformingTo: .movie) ?? .movie }
  /// What the importer offers: the engine's Matroska and MP4/QuickTime
  /// demuxers (M4V conforms to MPEG-4). Not `.movie`: that would offer AVI,
  /// MPEG-TS and others the engine cannot open.
  static var playableMovies: [UTType] { [.mkv, .mpeg4Movie, .quickTimeMovie] }
}

/// Reports the window the view is in, once it's in one.
private struct WindowReader: NSViewRepresentable {
  let onWindow: (NSWindow) -> Void

  func makeNSView(context: Context) -> ReaderView {
    let view = ReaderView()
    view.onWindow = onWindow
    return view
  }

  func updateNSView(_ view: ReaderView, context: Context) {}

  final class ReaderView: NSView {
    var onWindow: (NSWindow) -> Void = { _ in }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { onWindow(window) }
    }
  }
}

/// The engine's error, as a kit sheet: what went wrong and OK.
private struct ErrorSheet: View {
  let message: String
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(title: "Couldn’t Play the Video", systemImage: "exclamationmark.triangle", hue: .red) {
      Text(message).kitFont(.body).fixedSize(horizontal: false, vertical: true)
    } footer: {
      Spacer()
      Button("OK") { dismiss() }.buttonStyle(.kitPrimary).keyboardShortcut(.defaultAction)
    }
  }
}
