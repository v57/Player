import XCTest
@testable import SomePlayer

/// Regression test for HEVC files that carry VPS/SPS/PPS IN-BAND (a bare
/// 23-byte hvcC header with numOfArrays == 0 in CodecPrivate) instead of in
/// the container's CodecPrivate. The engine used to reject these at open with
/// `.videoDecoderFailed` because parseHVCC demands >= 24 bytes; the fix
/// recovers the parameter sets from the first video packet.
///
/// video.mkv in the repo root is exactly such a file (HEVC, hvcC numOfArrays=0,
/// sets in the first video packet). This exercises the real open path against
/// it. Skipped when the file isn't present so the suite stays portable.
final class HEVCInBandParameterSetTests: XCTestCase {
  func testOpenInBandHEVCMkvNoLongerThrows() async throws {
    // Resolve the repo root (this file lives in Tests/SomePlayerTests/).
    let fileURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/SomePlayerTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("video.mkv")
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw XCTSkip("video.mkv not present — cannot exercise in-band HEVC open")
    }

    let controller = PlaybackController()
    // Before the fix this threw .videoDecoderFailed (hvcC numOfArrays=0 → nil).
    let info = try await controller.open(fileURL)

    XCTAssertNotNil(info.video, "expected a video track")
    XCTAssertEqual(info.video?.codecName.lowercased(), "hevc")
    // The in-band sets were recovered, so the format description built and the
    // video track is present; a nil would mean setupVideoToolbox still failed.
    XCTAssertNotNil(info.duration, "expected the container duration")
    controller.stop()
  }
}
