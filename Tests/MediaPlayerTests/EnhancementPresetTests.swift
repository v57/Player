import XCTest

@testable import MediaPlayer

final class EnhancementPresetTests: XCTestCase {
  // MARK: - Pinned preset values (build expected structs from the same literals as the spec)

  private func makePreset(
    centerGainDB: Float, compressionEnabled: Bool, compressorThresholdDB: Float,
    compressorHeadroomDB: Float, compressorAttack: Float, compressorRelease: Float,
    compressorMasterGainDB: Float, limiterEnabled: Bool, limiterPreGainDB: Float,
    limiterAttack: Float, limiterRelease: Float, eqEnabled: Bool, eqFrequency: Float,
    eqGainDB: Float, eqQ: Float
  ) -> AudioEnhancementPreset {
    AudioEnhancementPreset(
      centerGainDB: centerGainDB, compressionEnabled: compressionEnabled,
      compressorThresholdDB: compressorThresholdDB, compressorHeadroomDB: compressorHeadroomDB,
      compressorAttack: compressorAttack, compressorRelease: compressorRelease,
      compressorMasterGainDB: compressorMasterGainDB, limiterEnabled: limiterEnabled,
      limiterPreGainDB: limiterPreGainDB, limiterAttack: limiterAttack,
      limiterRelease: limiterRelease, eqEnabled: eqEnabled, eqFrequency: eqFrequency,
      eqGainDB: eqGainDB, eqQ: eqQ)
  }

  private var expectedOriginal: AudioEnhancementPreset {
    makePreset(
      centerGainDB: 0, compressionEnabled: false, compressorThresholdDB: -18,
      compressorHeadroomDB: 12, compressorAttack: 0.015, compressorRelease: 0.250,
      compressorMasterGainDB: 0, limiterEnabled: false, limiterPreGainDB: 0, limiterAttack: 0.012,
      limiterRelease: 0.250, eqEnabled: false, eqFrequency: 2000, eqGainDB: 0, eqQ: 1.0)
  }

  private var expectedBalanced: AudioEnhancementPreset {
    makePreset(
      centerGainDB: 1, compressionEnabled: true, compressorThresholdDB: -18,
      compressorHeadroomDB: 12, compressorAttack: 0.015, compressorRelease: 0.250,
      compressorMasterGainDB: 2, limiterEnabled: true, limiterPreGainDB: 0, limiterAttack: 0.012,
      limiterRelease: 0.250, eqEnabled: false, eqFrequency: 2000, eqGainDB: 0, eqQ: 1.0)
  }

  private var expectedDialogue: AudioEnhancementPreset {
    makePreset(
      centerGainDB: 3, compressionEnabled: true, compressorThresholdDB: -22,
      compressorHeadroomDB: 12, compressorAttack: 0.020, compressorRelease: 0.200,
      compressorMasterGainDB: 3, limiterEnabled: true, limiterPreGainDB: 1, limiterAttack: 0.012,
      limiterRelease: 0.250, eqEnabled: true, eqFrequency: 2000, eqGainDB: 2, eqQ: 1.0)
  }

  // MARK: - preset(for:) mapping

  func testPresetForOriginalPinsValues() {
    XCTAssertEqual(AudioEnhancementPreset.preset(for: .original), expectedOriginal)
  }

  func testPresetForBalancedPinsValues() {
    XCTAssertEqual(AudioEnhancementPreset.preset(for: .balanced), expectedBalanced)
  }

  func testPresetForDialoguePinsValues() {
    XCTAssertEqual(AudioEnhancementPreset.preset(for: .dialogue), expectedDialogue)
  }

  // MARK: - Mode identity

  func testDisplayNames() {
    XCTAssertEqual(AudioEnhancementMode.original.displayName, "Original")
    XCTAssertEqual(AudioEnhancementMode.balanced.displayName, "Balanced")
    XCTAssertEqual(AudioEnhancementMode.dialogue.displayName, "Enhance Dialogue")
  }

  func testRawValueRoundTripAndAllCases() {
    XCTAssertEqual(AudioEnhancementMode(rawValue: "original"), .original)
    XCTAssertEqual(AudioEnhancementMode(rawValue: "balanced"), .balanced)
    XCTAssertEqual(AudioEnhancementMode(rawValue: "dialogue"), .dialogue)
    XCTAssertNil(AudioEnhancementMode(rawValue: "surround"))
    XCTAssertEqual(AudioEnhancementMode.allCases.count, 3)
    XCTAssertEqual(
      AudioEnhancementMode.allCases.map(\.rawValue), ["original", "balanced", "dialogue"])
  }

  func testIdentifiableIDIsRawValue() {
    XCTAssertEqual(AudioEnhancementMode.dialogue.id, "dialogue")
  }

  // MARK: - Preset invariants

  func testOriginalIsPassthrough() {
    let preset = AudioEnhancementPreset.preset(for: .original)
    XCTAssertFalse(preset.compressionEnabled)
    XCTAssertFalse(preset.limiterEnabled)
    XCTAssertFalse(preset.eqEnabled)
    XCTAssertEqual(preset.centerGainDB, 0)
    XCTAssertEqual(preset.compressorMasterGainDB, 0)
    XCTAssertEqual(preset.limiterPreGainDB, 0)
    XCTAssertEqual(preset.eqGainDB, 0)
  }

  func testBalancedHasCompressionAndLimiterButNoEQ() {
    let preset = AudioEnhancementPreset.preset(for: .balanced)
    XCTAssertTrue(preset.compressionEnabled)
    XCTAssertTrue(preset.limiterEnabled)
    XCTAssertFalse(preset.eqEnabled)
  }

  func testDialogueHasFullChain() {
    let preset = AudioEnhancementPreset.preset(for: .dialogue)
    XCTAssertTrue(preset.compressionEnabled)
    XCTAssertTrue(preset.limiterEnabled)
    XCTAssertTrue(preset.eqEnabled)
  }

  func testCenterGainOrdering() {
    let dialogue = AudioEnhancementPreset.preset(for: .dialogue).centerGainDB
    let balanced = AudioEnhancementPreset.preset(for: .balanced).centerGainDB
    let original = AudioEnhancementPreset.preset(for: .original).centerGainDB
    XCTAssertGreaterThan(dialogue, balanced)
    XCTAssertGreaterThan(balanced, original)
  }

  // MARK: - Headroom guard

  func testHeadroomAboveCeilingForAllPresets() {
    for mode in AudioEnhancementMode.allCases {
      XCTAssertLessThanOrEqual(
        AudioEnhancementPreset.preset(for: mode).headroomAboveCeiling(), -1.0,
        "\(mode.rawValue) preset must keep its own gains at least 1 dB below the ceiling")
    }
  }

  func testOriginalHeadroomIsExactlyNegativeOne() {
    XCTAssertEqual(AudioEnhancementPreset.preset(for: .original).headroomAboveCeiling(), -1.0)
  }
}
