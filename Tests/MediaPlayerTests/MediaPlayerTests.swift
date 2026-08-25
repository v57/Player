import XCTest

@testable import MediaPlayer

final class MediaTimeTests: XCTestCase {
  func testDisplayStringFormats() {
    XCTAssertEqual(MediaTime(seconds: 0).displayString, "0:00")
    XCTAssertEqual(MediaTime(seconds: 65).displayString, "1:05")
    XCTAssertEqual(MediaTime(seconds: 3661).displayString, "1:01:01")
    XCTAssertEqual(MediaTime(seconds: .nan).displayString, "0:00")
  }

  func testComparable() { XCTAssertLessThan(MediaTime(seconds: 1), MediaTime(seconds: 2)) }
}

final class SeamTests: XCTestCase {
  /// The seam protocol must keep the exact PlaybackStore method names, so
  /// the app's conformance extension stays a one-liner.
  @MainActor func testPersistenceProtocolShape() {
    // Compile-time check only: the protocol must expose these signatures.
    func _assert(_ p: any PlayerPersistence) {
      _ = p.resumePosition(for: "x")
      _ = p.latestTrackPick(kind: "audio")
      p.saveCurrentPosition(path: "x", position: 1, duration: 2)
      p.storeTrackPick(kind: "audio", lang: nil, title: nil, trackID: 0, isOff: false)
      p.storeBookmark(path: "x", bookmark: Data())
    }
    // Keep the function referenced so it type-checks.
    _ = _assert
  }

  func testPlayerTrackPickFields() {
    let pick = PlayerTrackPick(kind: "sub", lang: "eng", title: nil, trackID: 3, isOff: false)
    XCTAssertEqual(pick.kind, "sub")
    XCTAssertEqual(pick.lang, "eng")
    XCTAssertFalse(pick.isOff)
  }
}
