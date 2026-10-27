import Foundation

/// The media files the player opens, by extension: Matroska and MP4/QuickTime. Shared with the app (file importer,
/// drag and drop, recents, Open from Device) and the engines (the siblings Next/Previous step through).
public enum MediaFiles {
  public static let supportedExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov"]

  public static func isSupported(_ url: URL) -> Bool {
    supportedExtensions.contains(url.pathExtension.lowercased())
  }

  /// The playable files beside `url` in its folder, sorted by name as Finder sorts them (`url` among them).
  static func siblings(of url: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ).filter { isSupported($0) }.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
  }
}

extension SomePlayerBox {
  /// The engine this platform plays with, persisting through `store`: the native engine (FFmpeg demuxing,
  /// VideoToolbox, Metal) on macOS, PlatformMedia's player elsewhere.
  public static func makeDefault(store: (any PlayerPersistence)?) -> SomePlayerBox {
    #if canImport(VideoToolbox)
      let engine = NativeSomePlayer()
    #else
      let engine = PlatformSomePlayer()
    #endif
    engine.store = store
    return SomePlayerBox(engine: engine)
  }
}
