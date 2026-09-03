import XCTest
@testable import SomePlayer

/// Regression test for the partial-download retry resetting the user's track
/// selections to the container default. `openInternal` used to load the
/// remembered audio/subtitle picks from the store AFTER mapTracks (which is
/// where applyPendingTrackPicks runs), so a stored pick was silently ignored
/// on every open/retry. The fix loads the picks before mapping so they take
/// effect; the engine then restores the chosen audio stream and keeps
/// subtitles off instead of falling back to the default audio + first subtitle.
///
/// video.mkv: default-flagged audio is stream 1 ("DUB [Red Head Sound]"); a
/// stored pick for stream 5 ("MVO [LostFilm]") must be restored, not stream 1.
final class TrackPickRestoreTests: XCTestCase {
  @MainActor
  func testStoredAudioPickIsRestoredAndSubtitleOffOnOpen() async throws {
    let fileURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("video.mkv")
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw XCTSkip("video.mkv not present — cannot exercise track-pick restore")
    }

    let store = MockPersistence()
    store.audioPick = PlayerTrackPick(
      kind: "audio", lang: "rus", title: "MVO [LostFilm]", trackID: 5, isOff: false)
    store.subPick = PlayerTrackPick(kind: "sub", lang: nil, title: nil, trackID: 0, isOff: true)

    let player = NativeSomePlayer()
    player.store = store
    try await player.open(fileURL)

    // The container default audio is stream 1; the stored pick is stream 5.
    XCTAssertEqual(player.audioTrackID, 5, "stored audio pick must be restored, not the default (1)")
    XCTAssertNil(player.subtitleTrackID, "stored subtitles-off preference must be respected")
    player.stop()
  }
}

/// Minimal PlayerPersistence stub. PlayerPersistence is @MainActor, so the
/// conformance is as well; the stored pick is returned by latestTrackPick.
@MainActor
private final class MockPersistence: PlayerPersistence {
  var audioPick: PlayerTrackPick?
  var subPick: PlayerTrackPick?

  func resumePosition(for path: String) -> Double? { nil }
  func latestTrackPick(kind: String) -> PlayerTrackPick? {
    switch kind {
    case "audio": return audioPick
    case "sub": return subPick
    default: return nil
    }
  }
  func saveCurrentPosition(path: String?, position: Double, duration: Double) {}
  func storeTrackPick(kind: String, lang: String?, title: String?, trackID: Int, isOff: Bool) {}
  func storeBookmark(path: String, bookmark: Data) {}
}
