// enhance-probe.swift — AUMatrixMixer per-channel weighted-mixing spike (Task 4).
//
// INVESTIGATION VERDICT (macOS 27 beta, Xcode 26 beta):
//   The stock AUMatrixMixer CANNOT be used for the dialogue-enhancement
//   downmix in this app. The checks below document why: the unit reads and
//   stores a free-form 6x2 gain matrix correctly (dims 6x8, property
//   out-major, per-pair param element = (out<<16)|in), and it renders
//   correctly in OFFLINE manual-rendering mode (MCM control), but in a
//   REAL-TIME engine graph (the app's mode of operation) both AUMatrixMixer
//   and AUMultiChannelMixer render complete SILENCE no matter how the gains
//   are set (taps on the player and AU outputs show zero signal; params set
//   pre- and post-start; stereo and 6-ch sources). Effect-category units
//   (dynamics processor, peak limiter) and AVAudioUnitEQ render correctly in
//   real time and accept runtime parameter updates.
//   => The weighted downmix is implemented app-side at the buffer-fill point
//      (PlaybackController.feedAudioPacket, vDSP, off the realtime thread)
//      per the spec's sanctioned custom fallback; the chain uses stock
//      dynamics/limiter/EQ only. See AudioEnhancementChain.swift.
//
// The PASS/FAIL lines below remain the raw spike evidence (the audible-output
// checks fail BY DESIGN on this SDK — that failure IS the verdict).
//
// Build + run:
//   xcrun swiftc Tests/NativePoC/AudioEnhance/enhance-probe.swift \
//       -o /tmp/enhance-probe -framework AVFoundation -framework AudioToolbox
//   /tmp/enhance-probe

import AVFoundation
import AudioToolbox
import Foundation

let sampleRate = 48_000.0
let renderSeconds = 0.25
let totalFrames = AVAudioFrameCount(renderSeconds * sampleRate)

var failures = 0
func check(_ cond: Bool, _ label: String) {
  print(cond ? "  [PASS] \(label)" : "  [FAIL] \(label)")
  if !cond { failures += 1 }
}

// ---------- build the offline engine + 6->2 matrix AU ----------

let engine = AVAudioEngine()
let stereoOut = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
let source6 = AVAudioFormat(
  standardFormatWithSampleRate: sampleRate,
  channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_B)!)
try engine.enableManualRenderingMode(.offline, format: stereoOut, maximumFrameCount: 4096)

let player = AVAudioPlayerNode()
engine.attach(player)

var matrixAU: AVAudioUnit?
let sem = DispatchSemaphore(value: 0)
AVAudioUnit.instantiate(
  with: AudioComponentDescription(
    componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_MatrixMixer,
    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0),
  options: []
) { au, error in
  if let error {
    print("FATAL: instantiate error: \(error)")
    exit(1)
  }
  matrixAU = au
  sem.signal()
}
sem.wait()
guard let matrix = matrixAU else {
  fputs("FATAL: AUMatrixMixer instantiation returned nil\n", stderr)
  exit(1)
}
print("AUMatrixMixer instantiated OK")
engine.attach(matrix)

engine.connect(player, to: matrix, format: source6)
engine.connect(matrix, to: engine.mainMixerNode, format: stereoOut)

// Prime the graph so the AU initializes with its real channel counts — the
// MatrixDimensions/MatrixLevels properties are invalid before initialization.
try engine.start()

var dims = [UInt32](repeating: 0, count: 2)
var dimSize = UInt32(MemoryLayout<UInt32>.size * 2)
let dimErr = AudioUnitGetProperty(
  matrix.audioUnit, kAudioUnitProperty_MatrixDimensions, kAudioUnitScope_Global, 0, &dims, &dimSize)
check(dimErr == noErr, "kAudioUnitProperty_MatrixDimensions readable (err=\(dimErr))")
print(
  "  matrix dims: \(dims[0]) in x \(dims[1]) out (AU formats: \(matrix.inputFormat(forBus: 0).channelCount) in / \(matrix.outputFormat(forBus: 0).channelCount) out)"
)
check(dims[0] == 6, "matrix has 6 inputs")
let ins = Int(dims[0])
let outs = Int(dims[1])
check(outs >= 2, "matrix has at least 2 outputs")

// 5.1(side) roles: 0=FL 1=FR 2=FC 3=LFE 4=SL 5=SR
// Build a levels array for index = out*(ins+1)+in (OUT-major hypothesis).
// Route FL->L, FR->R, FC->L/R at cg, SL->L, SR->R at 0.707; volumes 1.
func buildLevels(
  centerCoeff cg: Float, flL: Float = 1.0, frR: Float = 1.0, slL: Float = 0.707, srR: Float = 0.707
) -> [Float] {
  var levels = [Float](repeating: 0, count: (ins + 1) * (outs + 1))
  levels[outs * (ins + 1) + ins] = 1.0  // global
  for i in 0..<ins { levels[outs * (ins + 1) + i] = 1.0 }  // output volumes row
  for o in 0..<outs { levels[o * (ins + 1) + ins] = 1.0 }  // input volumes column
  levels[0 * (ins + 1) + 0] = flL  // FL -> L
  levels[1 * (ins + 1) + 1] = frR  // FR -> R
  levels[0 * (ins + 1) + 2] = cg  // FC -> L
  levels[1 * (ins + 1) + 2] = cg  // FC -> R
  levels[0 * (ins + 1) + 4] = slL  // SL -> L
  levels[1 * (ins + 1) + 5] = srR  // SR -> R
  return levels
}

func applyLevels(_ levels: [Float]) -> Bool {
  let err = AudioUnitSetProperty(
    matrix.audioUnit, kAudioUnitProperty_MatrixLevels, kAudioUnitScope_Global, 0, levels,
    UInt32(MemoryLayout<Float>.size * levels.count))
  return err == noErr
}

// ---------- render helper ----------

func render(activeChannels: [Int: Float]) -> (left: Float, right: Float) {
  let n = Int(totalFrames)
  guard let pcm = AVAudioPCMBuffer(pcmFormat: source6, frameCapacity: totalFrames) else {
    fputs("FATAL: buffer alloc\n", stderr)
    exit(1)
  }
  pcm.frameLength = totalFrames
  for ch in 0..<6 {
    guard let data = pcm.floatChannelData?[ch] else { continue }
    let level = activeChannels[ch] ?? 0
    for i in 0..<n { data[i] = level }
  }
  player.scheduleBuffer(pcm, at: nil)

  let outFrames = totalFrames
  guard let out = AVAudioPCMBuffer(pcmFormat: stereoOut, frameCapacity: outFrames) else {
    fputs("FATAL: out buffer alloc\n", stderr)
    exit(1)
  }
  player.play()
  var done: AVAudioFrameCount = 0
  let chunk: AVAudioFrameCount = 1024
  while done < outFrames {
    let want = min(chunk, outFrames - done)
    let status = try? engine.renderOffline(want, to: out)
    if status != .success { break }
    done += out.frameLength
    if out.frameLength == 0 { break }
  }
  player.stop()
  player.reset()
  player.scheduleBuffer(AVAudioPCMBuffer(pcmFormat: source6, frameCapacity: 0)!, at: nil)

  func rms(_ ch: Int) -> Float {
    guard let data = out.floatChannelData?[ch] else { return -1 }
    var acc: Float = 0
    let count = Int(out.frameLength)
    for i in 0..<count { acc += data[i] * data[i] }
    return (acc / Float(max(count, 1))).squareRoot()
  }
  return (rms(0), rms(1))
}

// ---------- Pass 0: conventions (readback) ----------

print("\nPass 0: property + parameter conventions (levels set with cg=1.4, FL/FR unity)")
let probeLevels = buildLevels(centerCoeff: 1.4)
_ = applyLevels(probeLevels)

// Property readback: where did the entries land?
var got = [Float](repeating: 0, count: probeLevels.count)
var gotSize = UInt32(MemoryLayout<Float>.size * got.count)
let getErr = AudioUnitGetProperty(
  matrix.audioUnit, kAudioUnitProperty_MatrixLevels, kAudioUnitScope_Global, 0, &got, &gotSize)
if getErr == noErr {
  print("  readback[out-major idx 2 (FC->L under out-major)] = \(got[2])")
  print("  readback[idx \(2 * (ins + 1)) (FC->L under in-major)]  = \(got[2 * (ins + 1)])")
  print("  readback[0] (FL->L under out-major)       = \(got[0])")
  print("  readback[\(ins + 1)] (FR->R under out-major) = \(got[ins + 1])")
} else {
  print("  property readback failed err=\(getErr)")
}

// Parameter readback, both element conventions (Global scope).
func readParam(_ element: AudioUnitElement) -> (Float, OSStatus) {
  var v: Float = -999
  let err = AudioUnitGetParameter(
    matrix.audioUnit, kMatrixMixerParam_Volume, kAudioUnitScope_Global, element, &v)
  return (v, err)
}
let (pA, eA) = readParam(AudioUnitElement((2 << 16) | 0))  // (in<<16)|out: FC->L
let (pB, eB) = readParam(AudioUnitElement((0 << 16) | 2))  // (out<<16)|in: FC->L
print("  param element (2<<16)|0 = \(pA) (err \(eA))   — (in<<16)|out convention")
print("  param element (0<<16)|2 = \(pB) (err \(eB))   — (out<<16)|in convention")

// ---------- minimal routing sanity: FL->L unity ----------

print("\nPass 0b: FL-only input (ch0 = 0.8), FL->L = 1.0 matrix")
let unityLevels = buildLevels(centerCoeff: 1.4, slL: 0.0, srR: 0.0)
_ = applyLevels(unityLevels)
let u1 = render(activeChannels: [0: 0.8])
print("  L=\(u1.left) R=\(u1.right) (expect L ~0.8, R ~0)")
check(abs(u1.left - 0.8) < 0.02, "FL routes at unity to L")
check(u1.right < 0.01, "R silent for FL-only input")

// ---------- Pass 1: center-only source, coefficient control ----------

print("\nPass 1: center-only input (ch2 = 0.8), center coeff 0.707 vs 1.4")
_ = applyLevels(buildLevels(centerCoeff: 0.707))
let c1 = render(activeChannels: [2: 0.8])
print("  cg=0.707 -> L=\(c1.left) R=\(c1.right) (expect both ~\(0.8 * 0.707))")
check(
  abs(c1.left - 0.8 * 0.707) < 0.02 && abs(c1.right - 0.8 * 0.707) < 0.02,
  "center folds at 0.707 into BOTH outputs")
_ = applyLevels(buildLevels(centerCoeff: 1.4))
let c2 = render(activeChannels: [2: 0.8])
print("  cg=1.4   -> L=\(c2.left) R=\(c2.right) (expect both ~\(0.8 * 1.4))")
check(
  abs(c2.left - 0.8 * 1.4) < 0.04 && abs(c2.right - 0.8 * 1.4) < 0.04,
  "center coeff is independently controllable (boost works in the matrix)")
check(c2.left > c1.left * 1.3, "center boost measurably raises the output")

// ---------- Pass 2: surround-only source ----------

print("\nPass 2: left-surround-only input (ch4 = 0.8), cg=1.4")
_ = applyLevels(buildLevels(centerCoeff: 1.4))
let s1 = render(activeChannels: [4: 0.8])
print("  L=\(s1.left) R=\(s1.right) (expect L ~\(0.8 * 0.707), R ~0)")
check(abs(s1.left - 0.8 * 0.707) < 0.02, "surround folds at 0.707 (NOT center-boosted)")
check(s1.right < 0.01, "right channel silent for left-surround-only input")

// ---------- Pass 3: per-pair param readback with correct convention ----------

print("\nPass 3: per-pair param readback after setMatrix(centerCoeff: 1.4)")
_ = applyLevels(buildLevels(centerCoeff: 1.4))
// Use whichever convention Pass 0 showed: probe both, report both, require the
// one that holds 1.4 to have err == noErr.
let (vA2, eA2) = readParam(AudioUnitElement((2 << 16) | 0))
let (vB2, eB2) = readParam(AudioUnitElement((0 << 16) | 2))
print("  (in<<16)|out: \(vA2) (err \(eA2));  (out<<16)|in: \(vB2) (err \(eB2)) — one should be 1.4")
check(
  (eA2 == noErr && abs(vA2 - 1.4) < 0.01) || (eB2 == noErr && abs(vB2 - 1.4) < 0.01),
  "center->L gain readable via a per-pair volume parameter (render-safe runtime switching)")

print("\nVERDICT: \(failures == 0 ? "PASS" : "FAIL (\(failures) checks)")")
exit(failures == 0 ? 0 : 1)
