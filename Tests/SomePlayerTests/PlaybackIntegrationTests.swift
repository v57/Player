import XCTest

@testable import SomePlayer

/// End-to-end transport tests against the real engine (demux, VideoToolbox,
/// AVAudioEngine) using the generated corpus. Skipped unless the corpus exists:
///
///     Tests/Scripts/build-robustness-corpus.sh
///
/// Playback runs muted (PLAYER_MUTE is read by the engine at audio setup).
@MainActor
final class PlaybackIntegrationTests: XCTestCase {
  private var corpus: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Corpus")
  }

  private func media(_ name: String) throws -> URL {
    let url = corpus.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("\(name) missing — run Tests/Scripts/build-robustness-corpus.sh")
    }
    return url
  }

  override func setUp() async throws {
    setenv("PLAYER_MUTE", "1", 1)
  }

  /// Polls `condition` on the main actor until it holds or `timeout` passes.
  private func waitUntil(
    _ timeout: TimeInterval, _ what: String, _ condition: () -> Bool
  ) async throws {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition() {
      guard Date.now < deadline else { return XCTFail("timed out waiting for \(what)") }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  /// A mono AC3 track first used to crash buffer fill. Also covers switching
  /// to the stereo track and rendering both SRT and ASS subtitles.
  func testMonoFirstFilePlaysSwitchesAudioAndShowsSubtitles() async throws {
    let url = try media("h264-ac3-mono-stereo-subs.mkv")
    let player = NativeSomePlayer()
    try await player.open(url)
    XCTAssertNil(player.errorMessage)
    XCTAssertEqual(player.audioTrackID, 1)
    XCTAssertNil(player.subtitleTrackID, "subtitles start off")
    try await waitUntil(5, "playing") { player.state == .playing }

    player.selectAudioTrack(2)
    player.selectSubtitleTrack(3)  // SRT: "Corpus sub one" 0.5-2.5 s
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(player.audioTrackID, 2)
    player.seek(to: 1.0, exact: true)
    try await waitUntil(5, "SRT cue") { player.activeSubtitleCue == "Corpus sub one" }

    player.selectSubtitleTrack(4)  // ASS: "Corpus ASS line" 0.5-2.5 s
    player.seek(to: 1.0, exact: true)
    try await waitUntil(5, "ASS cue") { player.activeSubtitleCue == "Corpus ASS line" }
    XCTAssertTrue(player.isPlaying)
    player.stop()
    XCTAssertNil(player.audioTrackID, "selection does not leak past stop")
  }

  /// Playing to the end reports `.ended` (not the download "Waiting" state),
  /// and play() afterwards restarts from the top.
  func testEndThenReplayRestartsFromTheBeginning() async throws {
    let url = try media("h264-ac3-short.mkv")
    let player = NativeSomePlayer()
    try await player.open(url)
    try await waitUntil(12, "end of file") { player.state == .ended }
    XCTAssertFalse(player.isWaitingForFileUpdate, "a complete file must not wait for a download")
    player.play()
    try await waitUntil(5, "replay") { player.state == .playing }
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertLessThan(player.position, 2.0, "replay must start from the beginning")
    player.stop()
  }

  /// Opening a new file while the previous one drains its last audio used to
  /// leave a stale `.stop` in the mailbox that tore the new file down.
  func testOpenDuringEndDrainKeepsTheNewFilePlaying() async throws {
    let short = try media("h264-ac3-short.mkv")
    let next = try media("h264-ac3-mono-stereo-subs.mkv")
    let player = NativeSomePlayer()
    try await player.open(short)
    // The reader reaches EOF ~1.5 s before the clock; the drain follows.
    try await waitUntil(10, "near the end") { player.position >= 3.0 }
    try await player.open(next)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    XCTAssertEqual(player.fileName, next.lastPathComponent)
    XCTAssertEqual(player.state, .playing)
    XCTAssertGreaterThan(player.position, 0.5)
    player.stop()
  }

  /// Two overlapping opens (e.g. Next pressed twice): the newest one wins and
  /// plays; the older one's result is discarded.
  func testOverlappingOpensResolveToTheNewest() async throws {
    let first = try media("h264-ac3-short.mkv")
    let second = try media("h264-ac3-mono-stereo-subs.mkv")
    let player = NativeSomePlayer()
    // Both tasks are enqueued on the main actor back to back: the first runs
    // up to its probe and suspends, then the second starts while that probe
    // is still in flight.
    let a = Task { try await player.open(first) }
    let b = Task { try await player.open(second) }
    _ = try await (a.value, b.value)
    try await waitUntil(5, "playing") { player.state == .playing }
    XCTAssertEqual(player.fileName, second.lastPathComponent)
    XCTAssertEqual(player.audioTracks.count, 2)
    player.stop()
  }

  /// An undecodable first audio track no longer rejects the file; the
  /// decodable one plays and the undecodable one cannot be selected.
  func testUndecodableFirstAudioTrackIsSkipped() async throws {
    let url = try media("h264-aac-then-ac3-51.mkv")
    let player = NativeSomePlayer()
    try await player.open(url)
    XCTAssertNil(player.errorMessage)
    XCTAssertEqual(player.audioTrackID, 2)
    XCTAssertEqual(player.audioTracks.map(\.isPlayable), [false, true])
    player.selectAudioTrack(1)
    XCTAssertEqual(player.audioTrackID, 2)
    XCTAssertNotNil(player.errorMessage)
    player.stop()
  }

  /// A file whose only audio cannot be decoded fails with an error even when
  /// it was just written (it used to sit on "Waiting" forever).
  func testFreshUnsupportedFileFailsInsteadOfWaiting() async throws {
    let url = try media("h264-aac.mkv")
    try FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
    let player = NativeSomePlayer()
    try await player.open(url)
    XCTAssertEqual(player.state, .failed)
    XCTAssertFalse(player.isWaitingForFileUpdate)
    XCTAssertEqual(player.errorMessage, "Unsupported audio codec: aac")
  }
}
