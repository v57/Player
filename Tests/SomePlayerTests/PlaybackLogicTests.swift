import XCTest

@testable import SomePlayer

/// Pure-logic regressions for the playback engine's transport mailbox, audio
/// routing, subtitle handling and colour conversion. None of these need a
/// media file.
final class MailboxTests: XCTestCase {
  typealias Command = PlaybackController.PipelineCommand

  func testConsecutiveSeeksCoalesceToTheNewest() {
    var queue: [Command] = []
    PlaybackController.enqueue(.seek(1, exact: false), into: &queue)
    PlaybackController.enqueue(.seek(2, exact: false), into: &queue)
    PlaybackController.enqueue(.seek(3, exact: true), into: &queue)
    XCTAssertEqual(queue, [.seek(3, exact: true)])
  }

  func testSeeksSeparatedByOtherCommandsAreKept() {
    var queue: [Command] = []
    PlaybackController.enqueue(.seek(1, exact: false), into: &queue)
    PlaybackController.enqueue(.pause, into: &queue)
    PlaybackController.enqueue(.seek(2, exact: false), into: &queue)
    XCTAssertEqual(queue, [.seek(1, exact: false), .pause, .seek(2, exact: false)])
  }

  /// A `.stop`/`.pause` left behind by a finished loop must never reach the
  /// next one (it used to tear down the next file right after it opened).
  func testOnlyRepositioningCommandsSurviveALoopRestart() {
    let queue: [Command] = [.stop, .pause, .resume, .seek(5, exact: true), .switchAudio(2)]
    XCTAssertEqual(
      queue.filter(\.survivesLoopRestart), [.seek(5, exact: true), .switchAudio(2)])
  }
}

final class AudioRouteTests: XCTestCase {
  // FFmpeg native masks.
  let mono: UInt64 = 0x4  // FC
  let stereo: UInt64 = 0x3
  let surround51Side: UInt64 = 0x60F  // FL FR FC LFE SL SR
  let surround71: UInt64 = 0x63F  // FL FR FC LFE BL BR SL SR

  /// A mono source used to get a stereo player format and index past the
  /// decoded buffer (crash).
  func testMonoIsDuplicatedToStereo() {
    XCTAssertEqual(
      PlaybackController.audioRoute(
        sourceChannels: 1, layoutMask: mono, layoutName: "mono", deviceChannels: 2),
      .monoToStereo)
  }

  func testStereoPassesThrough() {
    XCTAssertEqual(
      PlaybackController.audioRoute(
        sourceChannels: 2, layoutMask: stereo, layoutName: "stereo", deviceChannels: 2),
      .passthrough)
  }

  func test51DownmixesOnStereoDeviceAndPassesThroughOnSurroundDevice() {
    guard
      case .downmix(let roles) = PlaybackController.audioRoute(
        sourceChannels: 6, layoutMask: surround51Side, layoutName: "5.1(side)", deviceChannels: 2)
    else { return XCTFail("5.1 on a stereo device must downmix") }
    XCTAssertEqual(roles, [.frontL, .frontR, .center, .lfe, .sideL, .sideR])
    XCTAssertEqual(
      PlaybackController.audioRoute(
        sourceChannels: 6, layoutMask: surround51Side, layoutName: "5.1(side)", deviceChannels: 6),
      .passthrough)
  }

  /// 7.1 on an 8-channel device used to fall back to a stereo player format
  /// that kept only the front pair (no centre/dialogue).
  func test71AlwaysDownmixes() {
    guard
      case .downmix(let roles) = PlaybackController.audioRoute(
        sourceChannels: 8, layoutMask: surround71, layoutName: "7.1", deviceChannels: 8)
    else { return XCTFail("7.1 must downmix") }
    XCTAssertEqual(roles.count, 8)
    XCTAssertTrue(roles.contains(.center))
  }

  func testUnknownLayoutDownmixesWithFrontPairFirst() {
    guard
      case .downmix(let roles) = PlaybackController.audioRoute(
        sourceChannels: 4, layoutMask: 0, layoutName: nil, deviceChannels: 2)
    else { return XCTFail("an unknown 4 ch layout must downmix") }
    XCTAssertEqual(roles, [.frontL, .frontR, .unknown, .unknown])
  }

  func testCodecSupport() {
    for codec in ["dts", "ac3", "eac3", "AC3"] {
      XCTAssertTrue(PlaybackController.isSupportedAudioCodec(codec), codec)
    }
    for codec in ["truehd", "aac", "flac", "opus"] {
      XCTAssertFalse(PlaybackController.isSupportedAudioCodec(codec), codec)
    }
  }
}

final class SubtitleTests: XCTestCase {
  func cue(_ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
    SubtitleCue(start: start, end: end, text: text)
  }

  /// Re-reading packets after a backward seek must keep the cues sorted and
  /// free of duplicates (out-of-order appends broke the binary search).
  func testInsertKeepsCuesSortedAndDeduplicated() {
    var cues: [SubtitleCue] = []
    for c in [cue(10, 12, "c"), cue(20, 22, "d"), cue(1, 3, "a"), cue(5, 7, "b"), cue(10, 12, "c")]
    {
      PlaybackController.insertCue(c, into: &cues)
    }
    XCTAssertEqual(cues.map(\.text), ["a", "b", "c", "d"])
    XCTAssertFalse(PlaybackController.insertCue(cue(5, 7, "b"), into: &cues))
  }

  func testActiveCueLookup() {
    let cues = [cue(1, 3, "a"), cue(5, 7, "b"), cue(10, 30, "long"), cue(12, 13, "short")]
    XCTAssertEqual(PlaybackController.activeCue(at: 2, in: cues)?.text, "a")
    XCTAssertNil(PlaybackController.activeCue(at: 4, in: cues))
    XCTAssertEqual(PlaybackController.activeCue(at: 12.5, in: cues)?.text, "short")
    // The long cue is still found once the shorter overlapping one ended.
    XCTAssertEqual(PlaybackController.activeCue(at: 20, in: cues)?.text, "long")
    XCTAssertNil(PlaybackController.activeCue(at: 0.5, in: cues))
  }

  func testSubRipTextPassesThrough() {
    XCTAssertEqual(
      PlaybackController.subtitleText(from: Data(" Hello\nworld ".utf8), codec: "subrip"),
      "Hello\nworld")
  }

  func testASSFieldsAndOverridesAreStripped() {
    let packet = "3,0,Default,,0,0,0,,{\\i1}Hello, there{\\i0}\\Nnext line"
    XCTAssertEqual(
      PlaybackController.subtitleText(from: Data(packet.utf8), codec: "ass"),
      "Hello, there\nnext line")
  }

  /// Bitmap subtitles used to be decoded as text and shown as garbage.
  func testBitmapSubtitlesProduceNoText() {
    let pgs = Data([0x50, 0x47, 0x00, 0x01, 0x16, 0x00, 0x00, 0x13])
    XCTAssertNil(PlaybackController.subtitleText(from: pgs, codec: "hdmv_pgs_subtitle"))
    XCTAssertFalse(PlaybackController.isSupportedSubtitleCodec("dvd_subtitle"))
  }
}

final class TimeBaseTests: XCTestCase {
  func testPacketSecondsUseTheStreamTimeBase() {
    XCTAssertEqual(Rational(num: 1, den: 1000).seconds(1500), 1.5)
    XCTAssertEqual(Rational(num: 1, den: 90000).seconds(180_000), 2.0)
    // Degenerate base falls back to Matroska's default.
    XCTAssertEqual(Rational(num: 0, den: 0).seconds(2000), 2.0)
  }
}

final class YCbCrMatrixTests: XCTestCase {
  typealias Matrix = MediaMetalRenderer.YCbCrMatrix

  func rgb(_ m: Matrix, y: Float, cb: Float, cr: Float) -> (Float, Float, Float) {
    let yp = (y - 16) / 219
    let cbp = (cb - 128) / 224
    let crp = (cr - 128) / 224
    return (yp + m.rCr * crp, yp - m.gCb * cbp - m.gCr * crp, yp + m.bCb * cbp)
  }

  /// Video-range black/white/mid-grey must land on 0, 1 and 0.5 exactly (the
  /// old shader rendered Y=235 at 1.16 and mid-grey at 0.585).
  func testNeutralLevels() {
    for m in [Matrix.bt601, .bt709, .bt2020] {
      XCTAssertEqual(rgb(m, y: 16, cb: 128, cr: 128).0, 0, accuracy: 1e-6)
      XCTAssertEqual(rgb(m, y: 235, cb: 128, cr: 128).1, 1, accuracy: 1e-6)
      XCTAssertEqual(rgb(m, y: 125.5, cb: 128, cr: 128).2, 0.5, accuracy: 1e-6)
    }
  }

  /// The coefficients must invert the standard's luma equation:
  /// Kr*R + Kg*G + Kb*B == Y' for any chroma.
  func testCoefficientsInvertTheLumaEquation() {
    let standards: [(Matrix, Float, Float)] = [
      (.bt601, 0.299, 0.114), (.bt709, 0.2126, 0.0722), (.bt2020, 0.2627, 0.0593),
    ]
    for (m, kr, kb) in standards {
      let (r, g, b) = rgb(m, y: 100, cb: 70, cr: 200)
      let luma = kr * r + (1 - kr - kb) * g + kb * b
      XCTAssertEqual(luma, (100 - 16) / 219, accuracy: 1e-4)
    }
  }
}
