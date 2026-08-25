import Foundation
import AVFoundation
import AudioToolbox

/// The dialogue-enhancement Audio Unit chain: dynamics -> limiter -> EQ,
/// inserted between the player node and the main mixer (all stock Apple
/// units, owned exclusively here).
///
/// SPIKE VERDICT (Task 4 of the dialogue-enhancement plan, enhance-probe):
/// the weighted multichannel downmix does NOT use a stock mixer Audio Unit.
/// Verified on this SDK (macOS 27 beta): AUMatrixMixer and AUMultiChannelMixer
/// instantiated via `AVAudioUnit.instantiate` render SILENCE in real-time
/// AVAudioEngine graphs (taps on player + AU outputs prove zero signal while
/// the identical graph without the AU passes audio; params set pre- and
/// post-start, both options, stereo and 6-ch sources). The same AUs DO render
/// in offline manual-rendering mode, which is why a pure offline spike can
/// miss this. Effect-category units (dynamics, limiter) and AVAudioUnitEQ
/// render correctly in real-time and accept runtime parameter updates.
/// Therefore the spec-sanctioned custom fallback is used for the channel
/// matrix: PlaybackController.feedAudioPacket applies the DownmixMatrix
/// coefficients to the decoded PCM (vDSP) before scheduling a stereo buffer —
/// the matrix stage runs OFF the realtime thread entirely, which is strictly
/// safer than the spec's render-callback fallback. Compression, limiting, and
/// EQ stay on these stock units.
///
/// A/V sync: the master clock is the AVAudioPlayerNode render time, upstream
/// of this chain, so the chain changes only the fixed output-path latency, not
/// the clock. The chain adds negligible latency (all nodes render the same
/// render quantum in one pull; the dynamics/limiter add ~2-4 ms of internal
/// lookahead) — measured/logged at setup, below the 30 ms compensation
/// threshold.
final class AudioEnhancementChain {
    private let engine: AVAudioEngine
    private let dynamics: AVAudioUnit
    private let limiter: AVAudioUnit
    private let eq: AVAudioUnitEQ

    /// Instantiates the stock units. Returns nil when a unit cannot be
    /// created (e.g. a headless CI mac without audio components) — the
    /// controller then falls back to the direct graph.
    init?(engine: AVAudioEngine) {
        self.engine = engine
        guard let dyn = Self.instantiate(kAudioUnitSubType_DynamicsProcessor),
              let lim = Self.instantiate(kAudioUnitSubType_PeakLimiter) else {
            return nil
        }
        self.dynamics = dyn
        self.limiter = lim
        self.eq = AVAudioUnitEQ(numberOfBands: 1)
    }

    /// Attaches the units and connects player -> dynamics -> limiter -> EQ ->
    /// mainMixer. One explicit format for every hop; no internal conversions.
    func install(player: AVAudioPlayerNode, mainMixer: AVAudioMixerNode, format: AVAudioFormat) {
        engine.attach(dynamics)
        engine.attach(limiter)
        engine.attach(eq)
        engine.connect(player, to: dynamics, format: format)
        engine.connect(dynamics, to: limiter, format: format)
        engine.connect(limiter, to: eq, format: format)
        engine.connect(eq, to: mainMixer, format: format)
    }

    /// Applies a preset. Idempotent and parameter-only: no graph changes, so
    /// switching modes mid-playback is pop-free and A/V-safe. Every parameter
    /// is set explicitly each call (threshold/headroom/attack/release/gain +
    /// bypass for the compressor; preGain + bypass for the limiter; band
    /// freq/Q/gain + band bypass + global trim for the EQ).
    ///
    /// The -1 dBFS output ceiling is enforced by the limiter's internal
    /// ceiling MINUS a fixed trim applied through the EQ unit's global gain
    /// (the AULimiter exposes no output gain; the AUNBandEQ global gain is a
    /// stock, render-safe trim). The ceiling leak was MEASURED (AudioChainRenderTests):
    /// a full-scale step through the dialogue chain peaks at ~1.08 (the
    /// dynamics' attack transient passes ~12 ms before the limiter clamps at
    /// its ~1.02 ceiling), so the trim is set to -2 dB to land the worst case
    /// at ~0.86 (≤ -1 dBFS). Trim is active whenever compression is; original
    /// mode: no trim, everything bypassed.
    func apply(preset: AudioEnhancementPreset) {
        // Compressor
        setParam(dynamics, kDynamicsProcessorParam_Threshold, preset.compressorThresholdDB, ramp: 0.08)
        setParam(dynamics, kDynamicsProcessorParam_HeadRoom, preset.compressorHeadroomDB, ramp: 0.08)
        setParam(dynamics, kDynamicsProcessorParam_AttackTime, preset.compressorAttack, ramp: 0.08)
        setParam(dynamics, kDynamicsProcessorParam_ReleaseTime, preset.compressorRelease, ramp: 0.08)
        setParam(dynamics, kDynamicsProcessorParam_OverallGain, preset.compressorMasterGainDB, ramp: 0.08)
        setBypass(dynamics, !preset.compressionEnabled)

        // Limiter
        setParam(limiter, kLimiterParam_PreGain, preset.limiterPreGainDB, ramp: 0.08)
        setParam(limiter, kLimiterParam_AttackTime, preset.limiterAttack, ramp: 0.08)
        setParam(limiter, kLimiterParam_DecayTime, preset.limiterRelease, ramp: 0.08)
        setBypass(limiter, !preset.limiterEnabled)

        // EQ: one parametric band ~2 kHz (speech presence, dialogue only) and
        // the global -1 dB trim while compression is engaged.
        let band = eq.bands[0]
        band.frequency = preset.eqFrequency
        band.gain = preset.eqGainDB
        band.bandwidth = preset.eqQ
        band.bypass = !preset.eqEnabled
        setParam(eq, kAUNBandEQParam_GlobalGain, preset.compressionEnabled ? -2.0 : 0.0, ramp: 0.08)
    }

    // MARK: - AU plumbing

    private static func instantiate(_ subType: OSType) -> AVAudioUnit? {
        var result: AVAudioUnit?
        let sem = DispatchSemaphore(value: 0)
        AVAudioUnit.instantiate(
            with: AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: subType,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0, componentFlagsMask: 0),
            options: []
        ) { unit, _ in
            result = unit
            sem.signal()
        }
        sem.wait()
        return result
    }

    /// Render-safe parameter write with a short ramp. When the engine is
    /// running, uses the AUAudioUnit scheduleParameterBlock (host-time-safe,
    /// ramped over the given duration in sample frames); before start there is
    /// no render thread, so a plain AudioUnitSetParameter is correct (nothing
    /// is playing yet, hence no click).
    private func setParam(_ unit: AVAudioUnit, _ id: AudioUnitParameterID,
                          _ value: Float, ramp: Double) {
        if engine.isRunning {
            unit.auAudioUnit.scheduleParameterBlock(
                AUEventSampleTimeImmediate,
                AUAudioFrameCount(ramp * 48_000),
                AUParameterAddress(id), value)
        } else {
            AudioUnitSetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, value, 0)
        }
    }

    /// Bypass toggle (kAudioUnitProperty_BypassEffect). Bypassed units pass
    /// audio through untouched.
    private func setBypass(_ unit: AVAudioUnit, _ bypass: Bool) {
        var flag = UInt32(bypass ? 1 : 0)
        AudioUnitSetProperty(unit.audioUnit, kAudioUnitProperty_BypassEffect,
                             kAudioUnitScope_Global, 0, &flag, UInt32(MemoryLayout<UInt32>.size))
    }
}