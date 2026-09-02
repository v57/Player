import XCTest

@testable import SomePlayer

final class ChannelRoleTests: XCTestCase {
  /// AV_CH_LAYOUT_5POINT1 (5.1 rear) = 0x3F: FL, FR, FC, LFE, BL, BR.
  func testFivePointOneRear() {
    XCTAssertEqual(
      ChannelRoleMap.roles(forMask: 0x3F), [.frontL, .frontR, .center, .lfe, .rearL, .rearR])
  }

  /// AV_CH_LAYOUT_5POINT1_BACK (5.1 side) = 0x60F: FL, FR, FC, LFE, SL, SR.
  func testFivePointOneSide() {
    XCTAssertEqual(
      ChannelRoleMap.roles(forMask: 0x60F), [.frontL, .frontR, .center, .lfe, .sideL, .sideR])
  }

  /// AV_CH_LAYOUT_7POINT1 = 0x63F: FL, FR, FC, LFE, BL, BR, SL, SR.
  /// Side vs rear must stay distinguished (rear from BL/BR, side from SL/SR).
  func testSevenPointOneDistinguishesSideAndRear() {
    XCTAssertEqual(
      ChannelRoleMap.roles(forMask: 0x63F),
      [.frontL, .frontR, .center, .lfe, .rearL, .rearR, .sideL, .sideR])
  }

  /// Stereo needs no downmix matrix bookkeeping.
  func testStereoMaskReturnsNil() { XCTAssertNil(ChannelRoleMap.roles(forMask: 0x3)) }

  func testZeroMaskReturnsNil() { XCTAssertNil(ChannelRoleMap.roles(forMask: 0)) }

  func testSingleBitMaskReturnsNil() { XCTAssertNil(ChannelRoleMap.roles(forMask: 0x4)) }

  /// Unrecognized bits must degrade to .unknown without dropping channels.
  /// 0x1C0 = FLC|FRC|BC (bits 6, 7, 8): every set bit is unrecognized.
  func testUnknownBitsDegradeToUnknown() {
    XCTAssertEqual(ChannelRoleMap.roles(forMask: 0x1C0), [.unknown, .unknown, .unknown])
    // 0x4C0 = FLC|FRC|SR (bits 6, 7, 10): same 3-channel shape.
    XCTAssertEqual(ChannelRoleMap.roles(forMask: 0x4C0)?.count, 3)
  }

  /// Ordered roles must never lose channels: count == popcount for any
  /// multichannel mask (known bits and unknown bits alike).
  func testRoleCountMatchesPopcount() {
    let masks: [UInt64] = [0x3F, 0x60F, 0x63F, 0x1C0, 0x4C0, 0xFFF, 0x8000_0000_0000_0007]
    for mask in masks {
      XCTAssertEqual(
        ChannelRoleMap.roles(forMask: mask)?.count ?? 0, mask.nonzeroBitCount,
        "mask 0x\(String(mask, radix: 16))")
    }
  }
}
