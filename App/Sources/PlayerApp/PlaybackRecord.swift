import Foundation
import SwiftData

/// Persistent playback position for one media file, keyed by its absolute
/// path, so the app can resume where the user left off.
@Model final class PlaybackRecord {
  /// Absolute path of the media file.
  @Attribute(.unique) var filePath: String
  /// Seconds from the start of the file at the last save.
  var position: Double
  /// Total duration in seconds at the last save (0 while unknown).
  var duration: Double
  /// When the position was last written.
  var lastPlayedAt: Date
  /// Security-scoped bookmark so the sandbox can reopen the file from the
  /// Recent list — a bare path outside the app container (e.g. ~/Downloads)
  /// is unreadable without the saved grant.
  var bookmarkData: Data?

  init(
    filePath: String, position: Double, duration: Double, lastPlayedAt: Date = .now,
    bookmarkData: Data? = nil
  ) {
    self.filePath = filePath
    self.position = position
    self.duration = duration
    self.lastPlayedAt = lastPlayedAt
    self.bookmarkData = bookmarkData
  }
}
