import XCTest

@testable import SomePlayer

final class EnhancementPresetTests: XCTestCase {
  // MARK: - Pinned preset values (build expected structs from the same literals as the spec)

  private func makePreset(
    centerGainDB: Float, compressionEnabled: Bool, compressorThresholdDB: Float,
    compressorHeadroomDB: Float, compressorAttack: Float, compressorRelease: Float,
    compressorMasterGainDB: Float, limiterEnabled: Bool, limiterPreGainDB: Float,
    limiterAttack: Float, limiterRelease: Float, eqEnabled: Bool, eqFrequency: Float,
    eqGainDB: Float, eqQ: Float, sideGainDB: Float = 0, bassShelfGainDB: Float = 0
  ) -> AudioEnhancementPreset {
    AudioEnhancementPreset(
      centerGainDB: centerGainDB, compressionEnabled: compressionEnabled,
      compressorThresholdDB: compressorThresholdDB, compressorHeadroomDB: compressorHeadroomDB,
      compressorAttack: compressorAttack, compressorRelease: compressorRelease,
      compressorMasterGainDB: compressorMasterGainDB, limiterEnabled: limiterEnabled,
      limiterPreGainDB: limiterPreGainDB, limiterAttack: limiterAttack,
      limiterRelease: limiterRelease, eqEnabled: eqEnabled, eqFrequency: eqFrequency,
      eqGainDB: eqGainDB, eqQ: eqQ, sideGainDB: sideGainDB, bassShelfGainDB: bassShelfGainDB)
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
      limiterRelease: 0.250, eqEnabled: true, eqFrequency: 2000, eqGainDB: 2, eqQ: 1.0,
      sideGainDB: -4)
  }

  private var expectedNight: AudioEnhancementPreset {
    makePreset(
      centerGainDB: 3, compressionEnabled: true, compressorThresholdDB: -32,
      compressorHeadroomDB: 4, compressorAttack: 0.005, compressorRelease: 0.300,
      compressorMasterGainDB: 6, limiterEnabled: true, limiterPreGainDB: 0, limiterAttack: 0.012,
      limiterRelease: 0.250, eqEnabled: true, eqFrequency: 2000, eqGainDB: 2, eqQ: 1.0,
      sideGainDB: -4, bassShelfGainDB: -6)
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

  func testPresetForNightPinsValues() {
    XCTAssertEqual(AudioEnhancementPreset.preset(for: .night), expectedNight)
  }

  // MARK: - Mode identity

  func testDisplayNames() {
    XCTAssertEqual(AudioEnhancementMode.original.displayName, "Original")
    XCTAssertEqual(AudioEnhancementMode.balanced.displayName, "Balanced")
    XCTAssertEqual(AudioEnhancementMode.dialogue.displayName, "Enhance Dialogue")
    XCTAssertEqual(AudioEnhancementMode.night.displayName, "Reduce Loud Sounds")
  }

  func testRawValueRoundTripAndAllCases() {
    XCTAssertEqual(AudioEnhancementMode(rawValue: "original"), .original)
    XCTAssertEqual(AudioEnhancementMode(rawValue: "balanced"), .balanced)
    XCTAssertEqual(AudioEnhancementMode(rawValue: "dialogue"), .dialogue)
    XCTAssertEqual(AudioEnhancementMode(rawValue: "night"), .night)
    XCTAssertNil(AudioEnhancementMode(rawValue: "surround"))
    XCTAssertEqual(AudioEnhancementMode.allCases.count, 4)
    XCTAssertEqual(
      AudioEnhancementMode.allCases.map(\.rawValue), ["original", "balanced", "dialogue", "night"])
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
    XCTAssertEqual(preset.sideGainDB, 0)
    XCTAssertEqual(preset.bassShelfGainDB, 0)
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

  func testNightCompressesHarderThanDialogue() {
    let night = AudioEnhancementPreset.preset(for: .night)
    let dialogue = AudioEnhancementPreset.preset(for: .dialogue)
    XCTAssertLessThan(night.compressorThresholdDB, dialogue.compressorThresholdDB)
    XCTAssertLessThan(night.compressorHeadroomDB, dialogue.compressorHeadroomDB)
    XCTAssertLessThan(night.compressorAttack, dialogue.compressorAttack)
    XCTAssertLessThan(night.bassShelfGainDB, 0)
    XCTAssertTrue(night.limiterEnabled)
  }

  func testSideLevelOnlyLowersAndOnlyInDialogueModes() {
    for mode in AudioEnhancementMode.allCases {
      let preset = AudioEnhancementPreset.preset(for: mode)
      XCTAssertLessThanOrEqual(preset.sideGainDB, 0, "\(mode.rawValue): side level never boosts")
      XCTAssertEqual(preset.sideGainDB < 0, mode == .dialogue || mode == .night)
    }
  }

  func testEveryGainingPresetEngagesTheLimiter() {
    // Clipping-safe by construction: any stage that adds gain feeds the limiter.
    for mode in AudioEnhancementMode.allCases {
      let p = AudioEnhancementPreset.preset(for: mode)
      let gains =
        p.centerGainDB > 0 || p.compressorMasterGainDB > 0 || p.limiterPreGainDB > 0
        || (p.eqEnabled && p.eqGainDB > 0)
      if gains { XCTAssertTrue(p.limiterEnabled, "\(mode.rawValue) adds gain without the limiter") }
    }
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
