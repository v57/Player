import XCTest

@testable import MediaPlayer

final class DownmixMatrixTests: XCTestCase {
  private let fiveDotOneSide: [ChannelRole] = [.frontL, .frontR, .center, .lfe, .sideL, .sideR]
  private let sevenDotOne: [ChannelRole] = [
    .frontL, .frontR, .center, .lfe, .rearL, .rearR, .sideL, .sideR,
  ]

  // MARK: - Center gain (5.1 side)

  func test5Point1DialogueBoostedCenter() {
    let m = DownmixMatrix.coefficients(roles: fiveDotOneSide, centerGainDB: 3)
    guard let m else {
      XCTFail("expected a downmix matrix for 5.1 roles")
      return
    }
    XCTAssertEqual(m.count, 6)
    let expected: Float = 0.707 * pow(10.0, 3.0 / 20.0)
    XCTAssertEqual(expected, 0.9986, accuracy: 0.001)
    XCTAssertEqual(m[2][0], expected, accuracy: 0.001)
    XCTAssertEqual(m[2][1], expected, accuracy: 0.001)
  }

  func test5Point1BalancedAndFlatCenter() {
    let balanced = DownmixMatrix.coefficients(roles: fiveDotOneSide, centerGainDB: 1)
    guard let balanced else {
      XCTFail("expected a downmix matrix for 5.1 roles")
      return
    }
    XCTAssertEqual(balanced[2][0], 0.793, accuracy: 0.001)
    XCTAssertEqual(balanced[2][1], 0.793, accuracy: 0.001)

    let flat = DownmixMatrix.coefficients(roles: fiveDotOneSide, centerGainDB: 0)
    guard let flat else {
      XCTFail("expected a downmix matrix for 5.1 roles")
      return
    }
    XCTAssertEqual(flat[2][0], 0.707, accuracy: 0.001)
    XCTAssertEqual(flat[2][1], 0.707, accuracy: 0.001)
  }

  // MARK: - Surrounds are never center-boosted

  func testSurroundRowsNeverCenterBoosted() {
    for gain: Float in [1, 3] {
      let m = DownmixMatrix.coefficients(roles: fiveDotOneSide, centerGainDB: gain)
      guard let m else {
        XCTFail("expected a downmix matrix for 5.1 roles at gain \(gain)")
        return
      }
      // sideL
      XCTAssertEqual(m[4][0], 0.707, accuracy: 0.001)
      XCTAssertEqual(m[4][1], 0.0, accuracy: 0.001)
      // sideR
      XCTAssertEqual(m[5][0], 0.0, accuracy: 0.001)
      XCTAssertEqual(m[5][1], 0.707, accuracy: 0.001)
    }
  }

  // MARK: - Front / LFE rows

  func testFrontAndLFERows() {
    let m = DownmixMatrix.coefficients(roles: fiveDotOneSide, centerGainDB: 3)
    guard let m else {
      XCTFail("expected a downmix matrix for 5.1 roles")
      return
    }
    XCTAssertEqual(m[0], [1, 0])
    XCTAssertEqual(m[1], [0, 1])
    XCTAssertEqual(m[3], [0, 0])
  }

  // MARK: - 7.1

  func test7Point1MatrixAndRearRows() {
    let m = DownmixMatrix.coefficients(roles: sevenDotOne, centerGainDB: 0)
    guard let m else {
      XCTFail("expected a downmix matrix for 7.1 roles")
      return
    }
    XCTAssertEqual(m.count, 8)
    for row in m { XCTAssertEqual(row.count, 2) }
    // rearL
    XCTAssertEqual(m[4][0], 0.707, accuracy: 0.001)
    XCTAssertEqual(m[4][1], 0.0, accuracy: 0.001)
    // rearR
    XCTAssertEqual(m[5][0], 0.0, accuracy: 0.001)
    XCTAssertEqual(m[5][1], 0.707, accuracy: 0.001)
  }

  // MARK: - Edge cases

  func testReturnsNilForTwoOrFewerChannels() {
    XCTAssertNil(DownmixMatrix.coefficients(roles: [.frontL, .frontR], centerGainDB: 3))
    XCTAssertNil(DownmixMatrix.coefficients(roles: [], centerGainDB: 3))
    XCTAssertNil(DownmixMatrix.coefficients(roles: [.center], centerGainDB: 3))
  }

  func testAllCoefficientsFiniteIncludingEmptyEdge() {
    let m = DownmixMatrix.coefficients(roles: fiveDotOneSide, centerGainDB: 3)
    guard let m else {
      XCTFail("expected a downmix matrix for 5.1 roles")
      return
    }
    for row in m {
      for value in row {
        XCTAssertTrue(value.isFinite, "non-finite coefficient \(value)")
        XCTAssertFalse(value.isNaN, "NaN coefficient")
      }
    }
    // The empty edge must not produce NaN/inf from the peak guard,
    // even though the matrix itself is nil.
    let emptyPeak = DownmixMatrix.worstCaseDownmixPeakDB(roles: [], centerGainDB: 0)
    XCTAssertTrue(emptyPeak.isFinite, "empty-role peak must be finite, got \(emptyPeak)")
    XCTAssertFalse(emptyPeak.isNaN)
  }

  func testUnknownRoleFoldsAtSurroundCoefficient() {
    let m = DownmixMatrix.coefficients(roles: [.frontL, .frontR, .unknown], centerGainDB: 3)
    guard let m else {
      XCTFail("expected a downmix matrix for 3 roles")
      return
    }
    XCTAssertEqual(m[2][0], 0.707, accuracy: 0.001)
    XCTAssertEqual(m[2][1], 0.707, accuracy: 0.001)
  }

  // MARK: - Clipping guard

  func testWorstCaseDownmixPeakDialogue() {
    let peak = DownmixMatrix.worstCaseDownmixPeakDB(roles: fiveDotOneSide, centerGainDB: 3)
    // Max column sum = 1 (frontL) + 0.9986 (center) + 0.707 (sideL) = 2.7056
    XCTAssertEqual(peak, 8.65, accuracy: 0.05)
  }
}
