import XCTest

@testable import SomePlayer

/// The shipped dylibs must match the license notice (About window, README):
/// the pinned release, LGPL v2.1+ only, and no GPL or nonfree components.
final class FFmpegLibraryTests: XCTestCase {
  func testVersionMatchesThePinnedRelease() throws {
    let pin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "../../Sources/FFmpeg/source-version.txt")
    let text = try String(contentsOf: pin, encoding: .utf8)
    let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("FFmpeg pinned") })
    let pinned = line.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)
    XCTAssertEqual(FFmpegLibrary.version, pinned)
    XCTAssertEqual(FFmpegLibrary.version, "n7.1.5", "update the README's FFmpeg notice too")
  }

  func testLicenseIsLGPLOnly() {
    XCTAssertEqual(FFmpegLibrary.license, "LGPL version 2.1 or later")
    XCTAssertFalse(FFmpegLibrary.configuration.contains("--enable-gpl"))
    XCTAssertFalse(FFmpegLibrary.configuration.contains("--enable-nonfree"))
    XCTAssertFalse(FFmpegLibrary.configuration.contains("--enable-version3"))
  }

  func testSourceURLPointsAtTheReleaseTag() {
    XCTAssertEqual(
      FFmpegLibrary.sourceURL.absoluteString, "https://github.com/FFmpeg/FFmpeg/tree/n7.1.5")
  }
}
