// audio-clock-probe.swift — AVAudioPlayerNode clock semantics probe (Player, Sep 2026).
//
// The app's whole A/V clock is:
//   clock = playerTime(forNodeTime: lastRenderTime).sampleTime / sampleRate + offset
// so three properties of that clock decide whether audio can drift behind video:
//   Q1  Does the clock advance at wall rate while the node has NO scheduled
//       content (starved)?  If yes, a starvation makes the CLOCK lead the audio
//       CONTENT, permanently, and the lag accumulates over a session.
//   Q2  Does content scheduled after a starvation render contiguously after the
//       pre-starvation content (i.e. the content's position in node time is
//       shifted by the gap = the drift)?
//   Q3  Does the clock restart at ~0 after player.stop()+reset()+play()?
//   Q4  Same across engine.pause() → engine.start() → player.play()?
//
// Method: real-time engine, silent (mixer volume 0). The feeder keeps a target
// number of 0.1 s buffers queued (like the app's audio-ahead cap), so starving
// is done by setting the target to 0. Each scheduled buffer is a square wave
// whose amplitude encodes its index, so a tap on the player node maps rendered
// CONTENT index ↔ node time. Two CSVs are emitted for offline analysis.
//
// Build: xcrun swiftc audio-clock-probe.swift -o /tmp/audio-clock-probe \
//            -framework AVFoundation -framework AudioToolbox
// Run:   /tmp/audio-clock-probe > /tmp/acp-timeline.csv 2>/tmp/acp-taps.csv

import AVFoundation
import Foundation
import QuartzCore

let sr: Double = 48000
let bufFrames = 4800  // 0.1 s per buffer
let ampPerIndex: Float = 0.0005  // amp = ampPerIndex * (1 + index % 200)

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else {
  fputs("FATAL: format\n", stderr)
  exit(1)
}
engine.connect(player, to: engine.mainMixerNode, format: fmt)
engine.mainMixerNode.outputVolume = 0.0  // silent — nothing audible

let lock = NSLock()
var scheduled = 0
var targetQueued = 0  // buffers to keep queued ahead of the rendered content
var renderedFrames = 0
var nextIndex = 0
var phaseName = "init"

func makeBuffer(index: Int) -> AVAudioPCMBuffer {
  let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(bufFrames))!
  b.frameLength = AVAudioFrameCount(bufFrames)
  let amp = ampPerIndex * Float(1 + index % 200)
  let half = bufFrames / 2
  for ch in 0..<2 {
    guard let p = b.floatChannelData?[ch] else { continue }
    for i in 0..<bufFrames { p[i] = i < half ? amp : -amp }
  }
  return b
}

player.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, when in
  var peak: Float = 0
  if let p = buf.floatChannelData?[0] {
    for i in 0..<Int(buf.frameLength) { let a = abs(p[i]); if a > peak { peak = a } }
  }
  let nodeSample = when.isSampleTimeValid ? Double(when.sampleTime) / when.sampleRate : -1
  lock.lock()
  renderedFrames += Int(buf.frameLength)
  lock.unlock()
  FileHandle.standardError.write(
    Data("tap,\(CACurrentMediaTime()),\(nodeSample),\(when.sampleRate),\(buf.frameLength),\(peak)\n".utf8))
}

/// Feeder: keeps `targetQueued` buffers ahead of the rendered content.
let feeder = Thread {
  while true {
    lock.lock()
    let want = targetQueued
    let out = renderedFrames / bufFrames + 1
    let queued = scheduled - out
    if want > 0, queued < want {
      let idx = nextIndex
      nextIndex += 1
      scheduled += 1
      lock.unlock()
      player.scheduleBuffer(makeBuffer(index: idx), at: nil)
    } else {
      lock.unlock()
    }
    usleep(5_000)
  }
}
feeder.stackSize = 1 << 20
feeder.start()

let t0 = CACurrentMediaTime()
func wall() -> Double { CACurrentMediaTime() - t0 }

func logSample() {
  var playerSample: Double = -1
  var playerRate: Double = -1
  var renderSample: Double = -1
  var renderRate: Double = -1
  if let nodeTime = player.lastRenderTime {
    renderSample = nodeTime.isSampleTimeValid ? Double(nodeTime.sampleTime) : -1
    renderRate = nodeTime.sampleRate
    if let pt = player.playerTime(forNodeTime: nodeTime) {
      playerSample = pt.isSampleTimeValid ? Double(pt.sampleTime) : -1
      playerRate = pt.sampleRate
    }
  }
  lock.lock()
  let sc = scheduled
  let out = renderedFrames
  let ni = nextIndex
  lock.unlock()
  print(
    "\(phaseName),\(wall()),\(ni),\(sc),\(out),\(playerSample),\(playerRate),"
      + "\(renderSample),\(renderRate)")
}

func runPhase(_ name: String, seconds: Double) {
  phaseName = name
  let end = CACurrentMediaTime() + seconds
  while CACurrentMediaTime() < end {
    logSample()
    usleep(100_000)
  }
}

print("# phase,t,nextIdx,scheduled,renderedFrames,playerSample,playerRate,renderSample,renderRate")

try? engine.start()
player.play()
targetQueued = 3
runPhase("A_feed", seconds: 5)

targetQueued = 0  // starve: nothing more scheduled, queue drains
runPhase("B_starve", seconds: 1.5)

targetQueued = 3
runPhase("C_refeed", seconds: 4)

// Q3: stop + reset + play
targetQueued = 0
phaseName = "D_reset"
player.stop()
player.reset()
player.play()
logSample()
targetQueued = 3
runPhase("D_refeed", seconds: 4)

// Q4: engine pause / start, node restart
targetQueued = 0
engine.pause()
runPhase("E_paused", seconds: 1.0)
try? engine.start()
player.stop()
player.reset()
try? engine.start()
player.play()
phaseName = "E_restarted"
logSample()
targetQueued = 3
runPhase("E_refeed", seconds: 4)

targetQueued = 0
usleep(300_000)
phaseName = "end"
logSample()
