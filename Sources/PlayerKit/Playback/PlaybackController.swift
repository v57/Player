import AVFoundation
import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import PlayerCDemux
import VideoToolbox

/// One decoded video frame ready for presentation.
///
/// `@unchecked Sendable`: the frame is immutable after construction and is
/// only ever consumed on the main actor (the presentation path), so sending
/// it into `Task { @MainActor }` from the pipeline thread is safe. The
/// CVPixelBuffer is owned by the VideoToolbox session and stays alive for
/// the frame's lifetime.
public final class NativeVideoFrame: @unchecked Sendable {
  let pts: Double  // presentation time, seconds
  let pixelBuffer: CVPixelBuffer
  init(pts: Double, pixelBuffer: CVPixelBuffer) {
    self.pts = pts
    self.pixelBuffer = pixelBuffer
  }
}

/// Sink for decoded frames — the Metal view registers as this (KANBAN rule:
/// pixel delivery stays engine-private; player pushes, view consumes).
///
/// `Sendable`: the protocol is @MainActor-bound, so conforming types are
/// MainActor-isolated and implicitly Sendable; the annotation lets the
/// pipeline thread send the sink reference into `Task { @MainActor }`
/// without a region-isolation error.
@MainActor public protocol VideoFrameSink: AnyObject, Sendable {
  func present(frame: NativeVideoFrame)
  func clear()
}

/// One subtitle cue (SRT Phase A). `text` is the plain SRT text; presentation
/// is the view's job (CoreText/AppKit overlay).
struct SubtitleCue: Equatable {
  let start: Double  // seconds
  let end: Double
  let text: String
}

/// Result of opening a media file through the native pipeline.
struct NativeMediaInfo {
  let duration: Double?
  let video: NativeTrackInfo?
  let audio: NativeTrackInfo?
  let allTracks: [NativeTrackInfo]
  let chapters: [NativeChapter]
}

/// Errors from the native engine, translated at the boundary (plan §31).
public enum NativePlayerError: Error {
  case cannotOpen
  case unsupportedVideoCodec(String)
  case unsupportedAudioCodec(String)
  case videoDecoderFailed
  case audioDecoderFailed
  case outputDeviceFailed
  case seekFailed
}

/// The native playback engine: demux -> decode -> schedule -> present.
///
/// Threading model:
/// - `pipelineQueue` (serial, userInitiated) runs the demux loop, feeds both
///   decoders, and drives the audio engine. All FFmpeg bridge access happens
///   here — the bridge is not thread-safe.
/// - VideoToolbox delivers decoded frames on its own thread; frames are
///   collected into `videoQueue` (locked) and reordered by PTS.
/// - The UI sink is MainActor; frames hop via `Task { @MainActor }`.
/// - The master clock is audio: AVAudioPlayerNode's render time. When a file
///   has no audio, a monotonic clock is used instead.
///
/// `@unchecked Sendable`: engine state is confined to `pipelineQueue`; the
/// few values the MainActor reads (play/pause/ended flags, published clock,
/// active audio stream, mailbox, sinks, cues, enhancement mode) are behind
/// their own locks.
public final class PlaybackController: @unchecked Sendable {
  // MARK: - Configuration (plan §16: conservative buffering)

  /// Demux stops when this many packets are queued ahead.
  private let maxQueuedPackets = 240  // ~10 s of 24 fps video
  /// Video queue target: decode ahead at most this many frames.
  private let maxDecodedVideoFrames = 12
  /// Audio ahead: keep at most this many seconds of PCM scheduled.
  private let maxAudioAheadSeconds = 1.5
  /// Present frames whose PTS is within this much of the clock (plan §29:
  /// tiny error → ignore).
  private let displaySlack = 0.030

  // MARK: - State

  /// Serial queue that owns ALL engine state: probe/open, the demux loop and
  /// teardown. The probe used to run on a separate queue, so a second open's
  /// stop() could close the demuxer while the first probe was still reading
  /// it; everything that touches the demuxer, VT session or audio graph now
  /// runs here.
  private let pipelineQueue = DispatchQueue(label: "Player.native-pipeline", qos: .userInitiated)
  private var generation: UInt64 = 0

  // Command mailbox (transport fix): the demux loop OWNS pipelineQueue
  // while playing, so pause/seek/stop/track-switch must be delivered via a
  // lock-protected FIFO the loop polls every iteration — enqueueing them on
  // pipelineQueue deadlocks behind the spinning loop.
  enum PipelineCommand: Equatable {
    case pause
    case resume
    case seek(Double, exact: Bool)
    case switchAudio(Int)
    case switchSubtitle(Int?)
    case stop

    /// Commands that reposition the demuxer (they also cancel an EOF drain).
    var repositions: Bool {
      switch self {
      case .resume, .seek, .switchAudio, .switchSubtitle: return true
      case .pause, .stop: return false
      }
    }

    /// Commands that still mean something when a NEW loop starts: a seek or a
    /// track switch issued while nothing was running (e.g. arrow keys after
    /// the end) applies to the next play. Transport commands (pause, resume,
    /// stop) belong to the loop that is gone and must never leak into the next
    /// one — a leftover `.stop` used to tear down the next file right after
    /// it opened.
    var survivesLoopRestart: Bool {
      switch self {
      case .seek, .switchAudio, .switchSubtitle: return true
      case .pause, .resume, .stop: return false
      }
    }
  }

  /// Appends `cmd` to the mailbox. Consecutive seeks are coalesced (the newest
  /// target replaces a still-pending one): a slider drag submits a seek per
  /// tick, and executing every one rebuilt the decoder per tick and left the
  /// engine seconds behind the pointer.
  static func enqueue(_ cmd: PipelineCommand, into queue: inout [PipelineCommand]) {
    if case .seek = cmd, let last = queue.last, case .seek = last {
      queue[queue.count - 1] = cmd
    } else {
      queue.append(cmd)
    }
  }

  private let commandLock = NSLock()
  private var commandQueue: [PipelineCommand] = []
  private let commandSignal = DispatchSemaphore(value: 0)
  private var loopRunning = false

  private func submit(_ cmd: PipelineCommand) {
    commandLock.lock()
    Self.enqueue(cmd, into: &commandQueue)
    commandLock.unlock()
    commandSignal.signal()
  }

  private func takeCommand() -> PipelineCommand? {
    commandLock.lock()
    defer { commandLock.unlock() }
    return commandQueue.isEmpty ? nil : commandQueue.removeFirst()
  }

  private var hasPendingCommand: Bool {
    commandLock.lock()
    defer { commandLock.unlock() }
    return !commandQueue.isEmpty
  }

  /// Marks the loop as exited — but only when the mailbox is empty, atomically
  /// with that check. A command that arrives while the loop is winding down is
  /// therefore always handled by this loop (the caller keeps iterating),
  /// instead of being stranded for the next one.
  private func tryExitLoop() -> Bool {
    commandLock.lock()
    defer { commandLock.unlock() }
    guard commandQueue.isEmpty else { return false }
    loopRunning = false
    return true
  }

  // MARK: - Shared state (pipeline writes, MainActor reads)

  private let stateLock = NSLock()
  private var _isPlaying = false
  private var _isPaused = false
  private var _isEnded = false
  private var _publishedClock: Double = 0
  private var _hasMedia = false
  private var _activeAudioStream: Int?

  /// The audio stream actually being decoded (MainActor-safe mirror of the
  /// pipeline-owned `audioStreamIndex`), so the UI can reflect a refused or
  /// failed switch.
  var activeAudioStreamIndex: Int? { withState { _activeAudioStream } }
  private func publishAudioStream() {
    let index = audioStreamIndex
    withState { _activeAudioStream = index }
  }

  /// True while a probed file is loaded (MainActor-safe; `demuxer` itself is
  /// pipeline-owned).
  private var hasMedia: Bool {
    get { withState { _hasMedia } }
    set { withState { _hasMedia = newValue } }
  }

  private func withState<T>(_ body: () -> T) -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return body()
  }

  /// Published state (read from MainActor).
  private(set) var isPlaying: Bool {
    get { withState { _isPlaying } }
    set { withState { _isPlaying = newValue } }
  }
  private(set) var isPaused: Bool {
    get { withState { _isPaused } }
    set { withState { _isPaused = newValue } }
  }
  /// True once playback ran to the end of the file (drain finished). Cleared
  /// by any reposition, a new play session, or stop.
  private(set) var isEnded: Bool {
    get { withState { _isEnded } }
    set { withState { _isEnded = newValue } }
  }

  /// Records the media clock for MainActor readers. The clock itself reads the
  /// audio node and a dozen pipeline-owned fields, so the UI must not compute it
  /// directly; the pipeline publishes it every tick and at every reposition.
  private func publishClock(_ value: Double) { withState { _publishedClock = value } }

  private var demuxer: FFmpegDemuxer?
  private var videoStreamIndex: Int?
  private var audioStreamIndex: Int?
  private var subtitleStreamIndex: Int?
  private var videoTB: (num: Int64, den: Int32) = (1, 1000)

  // Subtitle cues (SRT Phase A): parsed from subtitle-stream packets.
  private var subtitleCues: [SubtitleCue] = []
  private var subtitleCuesLock = NSLock()
  /// Codec of the active subtitle stream (decides how packet text is parsed).
  private var subtitleCodec = ""

  // Video decode
  private var vtSession: VTDecompressionSession?
  private var vtFormatDesc: CMVideoFormatDescription?
  private var pendingVideoPackets: [DemuxPacket] = []
  /// Seconds of video currently stashed in `pendingVideoPackets` (bounds it).
  private var pendingVideoSeconds: Double = 0
  /// Cap on the stashed video (compressed packets, ~200 KB each at 4K) — see
  /// the video-queue gate in tick.
  private let maxStashedVideoSeconds = 3.0
  /// Seek verification: the target of the most recent seek, logged against the
  /// FIRST video packet actually read after it. A seek that "succeeds" but
  /// leaves the demuxer elsewhere (the HEVC in-band rewind bug) shows up here
  /// as a first-pts far from the target — it is the cheap, direct check for the
  /// silent-seek-discard class, so keep it.
  private var verifySeekTarget: Double?
  /// Retains the VT output-callback context (the collector box must live
  /// as long as the session).
  private var videoCollectorBox: VideoCollectorBox?

  // Audio decode + output
  private var audioDecoder: UnsafeMutablePointer<MediaAudioDecoder>?
  private var audioEngine: AVAudioEngine?
  private var audioPlayer: AVAudioPlayerNode?
  private var audioFormat: AVAudioFormat?
  /// Node-time seconds at which the currently scheduled audio content runs out
  /// (the player node's OWN timeline). Maintained at SCHEDULE time as
  /// `max(nodeSeconds, previous end) + frameDuration` for every scheduled PCM
  /// frame, so it is exact and needs no tap.
  ///
  /// Why this exists — the accumulating audio-lag bug: the master clock is the
  /// player node's render time, and that clock FREE-RUNS. The node's render
  /// callback keeps producing output (silence) while there is nothing
  /// scheduled, so its clock advances even when no audio can advance. Every
  /// starved second therefore adds a permanent second to the audio's distance
  /// behind the clock — and video follows the clock, so the audio ends up that
  /// far behind the picture for the rest of the session (nothing re-bases it
  /// until the next seek). Measured on video.mkv (4K HEVC + 7 audio tracks):
  /// the open/resume seek walks the keyframe->target window (~2 s of dropped
  /// 4K decode) with nothing scheduled, and the 1 s summary reported
  /// `aud=-2.03s` — i.e. the audio landed 2.03 s behind the picture.
  ///
  /// The clamp (see currentClock) holds the media clock at this content end
  /// while the node is dry, and `reanchorAudioClock` shifts the offset when
  /// feeding resumes so the media timeline continues where it held. The audio
  /// PCM we schedule is contiguous in media time, so the clock stays equal to
  /// the media position of the audio actually being rendered: a starvation
  /// becomes a brief freeze of BOTH streams (video holds its frame) instead of
  /// a permanent desync.
  private var audioContentEndNode: Double = 0
  /// Seconds of audio starvation absorbed by the clamp (diagnostics: this is
  /// exactly the audio lag that would have accumulated without it).
  private var audioStarvedSeconds: Double = 0
  private var audioStarvedWindow: Double = 0
  /// A starvation longer than this is treated as "the audio pipeline is dead"
  /// rather than "content not ready yet": the clamp is released so the video
  /// can still play out (a 10 s hold would freeze a broken stream forever).
  /// The keyframe->target warm-up it is designed for is a GOP long, ~2 s here.
  private let audioStarveHoldMaxSeconds = 10.0
  /// Set once the demuxer has no more packets (EOF / partial end). No audio can
  /// follow, so the clamp is lifted and the clock may run out the video tail.
  private var audioSourceExhausted = false
  private var audioBytesPerFrame: Int = 0
  private var audioIsRunning = false
  /// The channel count the audio DECODER emits for the current track (the
  /// player format's channel count differs when the source is being
  /// downmixed app-side to stereo). The buffer-fill invariant compares
  /// decoded frames against THIS, not the player format.
  private var audioSourceChannels = 0

  // Audio enhancement (dialogue modes). The mode, the chain reference and
  // the downmix tables are read per decoded frame from the pipeline queue
  // and written from the main thread (menu selection), so they all live
  // behind a lock.
  private let enhancementLock = NSLock()
  private var enhancementMode: AudioEnhancementMode = .original
  private var _enhancementChain: AudioEnhancementChain?
  private var enhancementChain: AudioEnhancementChain? {
    get {
      enhancementLock.lock()
      defer { enhancementLock.unlock() }
      return _enhancementChain
    }
    set {
      enhancementLock.lock()
      _enhancementChain = newValue
      enhancementLock.unlock()
    }
  }
  /// Source roles when the source goes through a matrix: a multichannel
  /// source downmixed app-side to stereo, or a stereo source (side level,
  /// DownmixMatrix.stereoCoefficients); nil otherwise.
  private var downmixRoles: [ChannelRole]?
  /// Precomputed Nx2 matrices per mode for the current source layout —
  /// buffer fill picks a matrix by mode with no per-sample math. A mode with
  /// no entry passes the source through.
  private var downmixMatrices: [AudioEnhancementMode: [[Float]]] = [:]
  /// Loudness normalization ("Even Out Loudness"). The flag is written from
  /// the main thread; `limiterHeld` keeps the chain's limiter engaged while
  /// normalization may have boosted scheduled audio (on, and for
  /// `normalizationReleaseSeconds` after it is turned off — longer than
  /// the scheduled lead plus the gain's release ramp).
  private var normalizesLoudness = false
  private var limiterHeld = false
  private var limiterReleaseGeneration = 0
  private let normalizationReleaseSeconds = 3.0
  /// Measures and scales scheduled PCM; pipeline queue only.
  private var loudnessNormalizer: LoudnessNormalizer?
  /// Frames since the last loudness log line (every 10 s of audio).
  private var loudnessLogFrames = 0
  private var audioFormatMismatchLogged = false

  private func currentMode() -> AudioEnhancementMode {
    enhancementLock.lock()
    defer { enhancementLock.unlock() }
    return enhancementMode
  }

  /// The active downmix matrix for the current mode, or nil when the source
  /// is not being downmixed. Called per decoded frame (pipeline queue).
  private func currentDownmixMatrix() -> [[Float]]? {
    enhancementLock.lock()
    defer { enhancementLock.unlock() }
    guard let roles = downmixRoles, roles.count >= 2 else { return nil }
    return downmixMatrices[enhancementMode]
  }

  /// Sets the enhancement mode (UI entry). Parameter-only when the chain is
  /// live — no graph changes, no restart, pop-free (the plan's runtime
  /// switching requirement); stashed and applied at the next setupAudio when
  /// no chain exists yet (mode picked before open / after stop).
  func setEnhancementMode(_ mode: AudioEnhancementMode) {
    enhancementLock.lock()
    enhancementMode = mode
    let chain = _enhancementChain
    let limiterRequired = limiterHeld
    enhancementLock.unlock()
    if let chain {
      chain.apply(preset: AudioEnhancementPreset.preset(for: mode), limiterRequired: limiterRequired)
    }
    NSLog("[Native] enhancement mode: %@", mode.rawValue)
  }

  /// Turns loudness normalization on or off (UI entry). On engages the
  /// limiter at once (boosts rely on it); off lets the gain ramp back to
  /// unity and releases the limiter only after the boosted buffers already
  /// scheduled have played.
  func setNormalizesLoudness(_ on: Bool) {
    enhancementLock.lock()
    normalizesLoudness = on
    limiterReleaseGeneration += 1
    let generation = limiterReleaseGeneration
    if on { limiterHeld = true }
    let chain = _enhancementChain
    let mode = enhancementMode
    enhancementLock.unlock()
    NSLog("[Native] loudness normalization: %@", on ? "on" : "off")
    if on {
      chain?.apply(preset: AudioEnhancementPreset.preset(for: mode), limiterRequired: true)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + normalizationReleaseSeconds) {
      [weak self] in
      guard let self else { return }
      self.enhancementLock.lock()
      guard generation == self.limiterReleaseGeneration else {
        self.enhancementLock.unlock()
        return
      }
      self.limiterHeld = false
      let chain = self._enhancementChain
      let mode = self.enhancementMode
      self.enhancementLock.unlock()
      chain?.apply(preset: AudioEnhancementPreset.preset(for: mode), limiterRequired: false)
    }
  }

  private func normalizationEnabled() -> Bool {
    enhancementLock.lock()
    defer { enhancementLock.unlock() }
    return normalizesLoudness
  }

  /// Current mode (MainActor-safe read for the UI).
  func enhancementModeValue() -> AudioEnhancementMode { currentMode() }

  // Video presentation
  private var videoQueueLock = NSLock()
  private var videoQueue: [NativeVideoFrame] = []
  private var videoQueueGeneration: UInt64 = 0
  private var lastPresentedPTS: Double?
  private var droppedFrames = 0
  private var presentedFrames = 0
  /// VideoToolbox pipeline counters, for the 1 s summary. `vtSubmitted` counts
  /// frames handed to the decoder, `vtReturned` every output callback (decoded,
  /// dropped or failed), `vtDropped`/`vtErrors` the bad outcomes, and `vtStale`
  /// frames discarded by the generation gate (a stale decode after a seek).
  /// `vtSubmitted - vtReturned` is the DECODER's in-flight depth — the quantity
  /// that must be bounded. This is a client-side backpressure requirement, not
  /// an optimisation: VideoToolbox's asynchronous decompression DROPS frames it
  /// cannot keep up with and reports them only via `kVTDecodeInfo_FrameDropped`
  /// in the output callback's info flags. Measured on a 4K HEVC file before the
  /// bound existed: 1977 frames submitted over 79 s against 450 returned — VT
  /// discarded ~75 % of the video, which surfaced as "video shows ~6 fps while
  /// the audio plays normally" (and, over a longer run, as growing memory from
  /// the un-returned sample buffers).
  private var vtSubmitted = 0
  private var vtReturned = 0
  private var vtDropped = 0
  private var vtErrors = 0
  private var vtStale = 0
  /// Distinct non-noErr statuses seen from the decoder (logged once each, so a
  /// failure mode is identifiable without per-frame log spam).
  private var loggedStatuses: Set<OSStatus> = []
  private var summaryVTSubmitted = 0
  private var summaryVTReturned = 0
  /// Max frames allowed in flight inside the decoder (see vtSubmitted).
  private let maxVTInFlight = 6
  /// Video packets read from the demuxer and frames handed to the decoder, plus
  /// submissions whose pts did not advance. `vid` vs `sub` detects a packet that
  /// never reached the decoder (a silently dropped frame breaks HEVC reference
  /// chains and shows up as kVTVideoDecoderMalfunctionErr); `nonmono` detects the
  /// SAME frame being submitted repeatedly (duplicate feeds).
  private var videoPacketsRead = 0
  private var lastSubmittedPTS: Double?
  private var vtNonMonotonic = 0

  /// Records one VT output outcome (VT's thread). Counts the slot as finished
  /// whatever the status — a dropped frame is not "still decoding".
  private func recordVTOutcome(status: OSStatus, flags: VTDecodeInfoFlags, pts: Double) {
    var firstSeen: OSStatus?
    var logThisFrame = false
    videoQueueLock.lock()
    vtReturned += 1
    if status != noErr {
      vtErrors += 1
      if loggedStatuses.insert(status).inserted { firstSeen = status }
      // First few failing frames in full: their pts shows whether the failures
      // cluster at one place in the stream (a bitstream/reference problem) or
      // are spread through it (a lifetime/ordering problem).
      if vtErrors <= 3 { logThisFrame = true }
    }
    if flags.contains(.frameDropped) { vtDropped += 1 }
    videoQueueLock.unlock()
    if let firstSeen {
      NSLog("[Native] VT decode returned status %d (first occurrence)", firstSeen)
    }
    if logThisFrame {
      NSLog("[Native] VT decode failed at pts=%.3f status=%d flags=%u", pts, status, flags.rawValue)
    }
  }

  /// True when the decoder is at its in-flight limit and must not be fed more.
  /// Unbounded submission is what makes VT drop frames.
  private func videoDecoderSaturated() -> Bool {
    videoQueueLock.lock()
    defer { videoQueueLock.unlock() }
    return vtSubmitted - vtReturned >= maxVTInFlight
  }

  /// Resets the decoder accounting when the session is replaced (seek / track
  /// switch): outstanding callbacks from the invalidated session never arrive,
  /// so their slots would otherwise count as in flight forever and the
  /// backpressure would stall video permanently.
  private func resetVTCounters() {
    videoQueueLock.lock()
    vtSubmitted = 0
    vtReturned = 0
    vtDropped = 0
    vtErrors = 0
    vtStale = 0
    videoQueueLock.unlock()
    summaryVTSubmitted = 0
    summaryVTReturned = 0
  }

  // MARK: - Periodic diagnostics (1 s aggregate, spam-free)

  /// Content frame rate — the engine's H.264 target (24000/1001, matches
  /// the hardcoded frameDur in feedVideoPacket). Shown as the fps target.
  private let contentFps = 24_000.0 / 1001.0
  private var summaryLastTime: CFTimeInterval = 0
  private var summaryPresented = 0
  private var summaryPackets = 0
  private var summaryDroppedBase = 0
  /// pts - clock of the last presented frame (negative = early, positive = late).
  private var summaryDrift: Double = 0
  private var audioSendFailedLogged = false

  /// After a coarse (keyframe) seek, the demuxer position is at the keyframe
  /// BEFORE the target. Audio packets with pts < this (seconds) are skipped
  /// so the audio pipeline starts at the target — otherwise the pre-target
  /// audio backlog trips the audio-ahead gate, which starves video reads.
  /// Cleared once a packet at/after the target is seen.
  private var discardAudioBefore: Double?

  /// When the demux loop ends because the file is likely incomplete (a
  /// downloader is still writing it), this holds the end position + flag
  /// while stepLoop decides how to stop. Consumed there instead of the
  /// normal drain-and-finish path so the engine can wait for the file to
  /// grow and retry. nil = no partial end pending.
  private var prematureEnd: (position: Double, wasError: Bool)?
  /// End of the EOF drain window (audio plays out) while it is in progress.
  /// The drain runs one short step per loop iteration so transport commands
  /// stay responsive during it; nil = not draining.
  private var drainDeadline: CFTimeInterval?
  /// Media time up to which packets have been READ since the last demuxer
  /// reposition (max pts + duration). The read cursor runs up to
  /// maxAudioAheadSeconds ahead of the playback clock, so this — not the
  /// clock — is what an EOF has to be compared with to tell a short file
  /// from a complete one.
  private var readEnd: Double?

  // Clock
  private var startMonotonic: CFTimeInterval = 0
  private var clockBaseAudio = false
  /// Offset added to the audio player clock after a seek: the player restarts
  /// at 0 while frame PTS stay absolute, so clock = playerTime + offset.
  private var audioClockOffset: Double = 0
  /// Media time at pause, so the monotonic clock continues across resume.
  private var pausedClock: Double = 0

  /// Cached player-node clock. `AVAudioPlayerNode.playerTime(forNodeTime:)`
  /// allocates a fresh ObjC AVAudioTime (plus node-time object) on EVERY
  /// call, and `lastRenderTime` allocates too; reading them per demux tick
  /// leaked ~150k AVAudioTime objects in 30 s of playback. The cache is
  /// refreshed AT MOST ONCE PER LOOP ITERATION (the loop start marks it
  /// dirty; the first read of the iteration pays one allocation, all
  /// further reads in that iteration reuse it) and additionally
  /// invalidated by every event that moves or restarts the node clock.
  /// Guarded by a lock: the MainActor position timer reads it too.
  private var cachedNodeSeconds: Double?
  private var nodeClockDirty = true
  private let nodeClockLock = NSLock()
  private func invalidateNodeClock() {
    nodeClockLock.lock()
    nodeClockDirty = true
    nodeClockLock.unlock()
  }

  /// Frames are broadcast to every registered view. A single weak slot was
  /// stealable: with two windows, updateNSView re-registered both views on
  /// every publish and the loser's view went permanently black ("video
  /// channel missing until window reopen"). Each view registers once per
  /// window creation and re-registration is idempotent, so every window
  /// renders the shared engine.
  private final class VideoSinkBox {
    weak var sink: (any VideoFrameSink)?
    init(_ sink: any VideoFrameSink) { self.sink = sink }
  }
  private var sinkBoxes: [VideoSinkBox] = []
  private let sinkLock = NSLock()
  /// Hop from pipeline thread to MainActor.
  private var onMain: (@MainActor () -> Void)?
  /// Fired on the MainActor when the demux loop stops because the file is
  /// likely INCOMPLETE (a downloader is still writing it): a clean EOF reached
  /// before the container's declared duration, or a read error mid-stream.
  /// Carries the position playback should resume from once the file has
  /// grown, and whether the stop was a hard read error (vs a clean EOF).
  /// The engine uses this to enter its "waiting for file update" flow.
  private var onPartialEnd: (@MainActor (_ position: Double, _ wasError: Bool) -> Void)?

  // MARK: - Lifecycle

  init() {}

  /// Installs the MainActor callbacks. Called ONCE, at engine init, before the
  /// pipeline ever runs: the callbacks are read from the pipeline thread
  /// without a lock, so they must never be reassigned afterwards (views
  /// register through `addSink`, which touches only the locked sink list).
  func configure(
    onStateChange: @escaping @MainActor () -> Void,
    onPartialEnd: @escaping @MainActor (_ position: Double, _ wasError: Bool) -> Void
  ) {
    self.onMain = onStateChange
    self.onPartialEnd = onPartialEnd
  }

  /// Adds a frame sink (MainActor). Registering the same view twice is a no-op.
  func addSink(_ sink: any VideoFrameSink) {
    sinkLock.lock()
    defer { sinkLock.unlock() }
    sinkBoxes.removeAll { $0.sink == nil || ($0.sink === sink) }
    sinkBoxes.append(VideoSinkBox(sink))
  }

  private func snapshotSinks() -> [any VideoFrameSink] {
    sinkLock.lock()
    defer { sinkLock.unlock() }
    sinkBoxes.removeAll { $0.sink == nil }
    return sinkBoxes.compactMap { $0.sink }
  }

  /// Drops every sink's current frame. The sinks stay registered: a view
  /// registers once per window, so removing it here left the next file with
  /// no surface to present to.
  private func clearAllSinks() {
    for s in snapshotSinks() { Task { @MainActor in s.clear() } }
  }

  // MARK: - Open

  /// Opens + probes the file. Stops any running pipeline first (so the
  /// probe can take over the demuxer slot), then runs the synchronous probe
  /// on the pipeline queue, serialized with every other engine operation.
  /// Returns media info (MainActor-safe values only).
  func open(_ url: URL) async throws -> NativeMediaInfo {
    stop()
    return try await withCheckedThrowingContinuation { cont in
      pipelineQueue.async { [weak self] in
        guard let self else {
          cont.resume(throwing: NativePlayerError.cannotOpen)
          return
        }
        do {
          let info = try self.probe(url)
          cont.resume(returning: info)
        } catch { cont.resume(throwing: error) }
      }
    }
  }

  private func probe(_ url: URL) throws -> NativeMediaInfo {
    NSLog("[Native] probe begin: %@", url.lastPathComponent)
    let demuxer = FFmpegDemuxer()
    try demuxer.open(url)
    self.demuxer = demuxer

    var video: NativeTrackInfo?
    var audioTracks: [NativeTrackInfo] = []
    var subtitle: NativeTrackInfo?
    var all: [NativeTrackInfo] = []
    for i in 0..<demuxer.trackCount {
      guard let t = demuxer.track(at: i) else { continue }
      all.append(t)
      switch t.type {
      case MEDIA_TRACK_TYPE_VIDEO.rawValue where video == nil: video = t
      case MEDIA_TRACK_TYPE_AUDIO.rawValue: audioTracks.append(t)
      case MEDIA_TRACK_TYPE_SUBTITLE.rawValue where subtitle == nil: subtitle = t
      default: break
      }
    }

    guard let video else { throw NativePlayerError.unsupportedVideoCodec("no video track") }
    // Supported video codecs: VideoToolbox decodes H.264 (AVC) and HEVC
    // (H.265) natively on hardware. H.264 uses avcC extradata + the
    // H264ParameterSets format-description builder; HEVC uses hvcC extradata
    // + the HEVCParameterSets builder (VPS+SPS+PPS). Demux/schedule/present
    // is codec-agnostic, so only the gate and the format-description path
    // branch on codec.
    let videoCodec = video.codecName.lowercased()
    let isH264 = videoCodec == "h264" || video.codecID == 27
    let isHEVC = videoCodec == "hevc" || videoCodec == "h265" || videoCodec == "hev1"
    guard isH264 || isHEVC else {
      throw NativePlayerError.unsupportedVideoCodec(video.codecName)
    }
    // Audio: the container's default-flagged track among the DECODABLE ones,
    // else the first decodable one. Only gating the first audio track used to
    // reject e.g. a remux whose first track is TrueHD with an AC3 track after
    // it. A file whose audio tracks are all undecodable is still refused.
    let playable = audioTracks.filter { Self.isSupportedAudioCodec($0.codecName) }
    let audio = playable.first(where: { $0.isDefault }) ?? playable.first
    if audio == nil, let first = audioTracks.first {
      throw NativePlayerError.unsupportedAudioCodec(first.codecName)
    }

    self.videoStreamIndex = video.id
    self.audioStreamIndex = audio?.id
    publishAudioStream()
    // Subtitles default OFF. Auto-assigning the first subtitle stream here
    // made the engine render subtitles even when the app's stored pick (or the
    // UI) said off, and re-enabled the container default on every open / the
    // partial-download retry. An explicit selection (applyPendingTrackPicks /
    // the menu) sets subtitleStreamIndex; probe only records that the stream
    // exists for the track list.
    self.subtitleStreamIndex = nil
    self.videoTB = (Int64(video.timeBase.num), video.timeBase.den)

    try setupVideoToolbox(demuxer: demuxer, video: video)
    if let audio { try setupAudio(streamIndex: audio.id) }
    let chapters = demuxer.chapters
    NSLog(
      "[Native] opened %@: video %@ tb=%d/%d audio=%@ (%d ch %@) subs=%@ (%d chapters)",
      url.lastPathComponent, video.codecName, video.timeBase.num, video.timeBase.den,
      audio?.codecName ?? "none", audio?.channelCount ?? 0, audio?.layoutName ?? "-",
      subtitle?.codecName ?? "none", chapters.count)
    hasMedia = true
    return NativeMediaInfo(
      duration: demuxer.duration, video: video, audio: audio, allTracks: all, chapters: chapters)
  }

  // MARK: - Codec support

  /// Audio codecs the C bridge can decode: DTS/dca, Dolby Digital and Dolby
  /// Digital Plus through the vendored FFmpeg (planar float, which the bridge's
  /// interleaving assumes), and AAC (LC, HE-AAC v1/v2) through AudioToolbox.
  static let supportedAudioCodecs: Set<String> = ["dts", "dca", "ac3", "eac3", "aac"]
  static func isSupportedAudioCodec(_ name: String) -> Bool {
    supportedAudioCodecs.contains(name.lowercased())
  }

  /// Text subtitle codecs the overlay can render. Bitmap subtitles (PGS,
  /// VobSub, DVB) carry images, not text — decoding their packets as strings
  /// produced garbage on screen.
  static let supportedSubtitleCodecs: Set<String> = [
    "subrip", "srt", "text", "ass", "ssa", "webvtt",
  ]
  static func isSupportedSubtitleCodec(_ name: String) -> Bool {
    supportedSubtitleCodecs.contains(name.lowercased())
  }

  // MARK: - Video decoder setup

  private func setupVideoToolbox(demuxer: FFmpegDemuxer, video: NativeTrackInfo) throws {
    guard let avccPointer = fetchExtradata(demuxer: demuxer, video: video) else {
      throw NativePlayerError.videoDecoderFailed
    }
    let bytes = avccPointer
    let isHEVC = Self.isHevcCodec(video)
    if isHEVC {
      // HEVC (H.265): hvcC (HEVCDecoderConfigurationRecord). Fixed header is
      // 23 bytes; then numOfArrays (byte 22); each array = 1B array_completeness
      // + 6B NAL_unit_type, 2B numNalus, then per-NAL 2B length + NAL. We
      // collect VPS (32), SPS (33) and PPS (34) and feed them to
      // CMVideoFormatDescriptionCreateFromHEVCParameterSets, which requires at
      // least one of each (VPS+SPS+PPS).
      guard let par = hevcParameterSets(demuxer: demuxer, streamIndex: video.id, extradata: bytes)
      else { throw NativePlayerError.videoDecoderFailed }
      guard let fd = makeFormatDescription(
        params: par.vps + par.sps + par.pps, lengthSize: par.lengthSize, hevc: true)
      else { throw NativePlayerError.videoDecoderFailed }
      vtFormatDesc = fd
      try setupVTCommon(formatDesc: fd)
    } else {
      // H.264: avcC (AVCDecoderConfigurationRecord).
      let avcc = parseAVCC(bytes)
      guard !avcc.sps.isEmpty, !avcc.pps.isEmpty else {
        throw NativePlayerError.videoDecoderFailed
      }
      guard let fd = makeFormatDescription(
        params: avcc.sps + avcc.pps, lengthSize: avcc.lengthSize, hevc: false)
      else { throw NativePlayerError.videoDecoderFailed }
      vtFormatDesc = fd
      try setupVTCommon(formatDesc: fd)
    }
  }

  /// Fetches the video stream's extradata as a [UInt8] copy (owned by us).
  private func fetchExtradata(demuxer: FFmpegDemuxer, video: NativeTrackInfo) -> [UInt8]? {
    var ptr: UnsafePointer<UInt8>?
    var size: Int = 0
    guard
      media_get_track_extradata(demuxerHandle(demuxer), Int32(video.id), &ptr, &size)
        == MEDIA_RESULT_OK, let ptr, size > 0
    else { return nil }
    return [UInt8](UnsafeBufferPointer(start: ptr, count: size))
  }

  /// AVC decoder configuration record (avcC): 1B configVersion, profile/compat/
  /// level (3B), 1B (lengthSizeMinusOne + numSPS) then per-SPS 2B length + SPS,
  /// 1B numPPS, per-PPS 2B length + PPS. Returns SPS+PPS (in order) + NAL length
  /// size, or nil on a malformed record.
  private struct AVCParameters {
    let sps: [[UInt8]]
    let pps: [[UInt8]]
    let lengthSize: Int
  }

  private func parseAVCC(_ b: [UInt8]) -> AVCParameters {
    guard b.count >= 7, b[0] == 1 else { return AVCParameters(sps: [], pps: [], lengthSize: 4) }
    let lengthSize = Int(b[4] & 0x03) + 1
    let numSPS = Int(b[5] & 0x1F)
    var off = 6
    var sps: [[UInt8]] = []
    for _ in 0..<numSPS {
      guard off + 2 <= b.count else { return AVCParameters(sps: [], pps: [], lengthSize: lengthSize) }
      let len = (Int(b[off]) << 8) | Int(b[off + 1])
      off += 2
      guard off + len <= b.count else { return AVCParameters(sps: [], pps: [], lengthSize: lengthSize) }
      sps.append(Array(b[off..<(off + len)]))
      off += len
    }
    guard off < b.count else { return AVCParameters(sps: sps, pps: [], lengthSize: lengthSize) }
    let numPPS = Int(b[off]); off += 1
    var pps: [[UInt8]] = []
    for _ in 0..<numPPS {
      guard off + 2 <= b.count else { return AVCParameters(sps: sps, pps: pps, lengthSize: lengthSize) }
      let len = (Int(b[off]) << 8) | Int(b[off + 1])
      off += 2
      guard off + len <= b.count else { return AVCParameters(sps: sps, pps: pps, lengthSize: lengthSize) }
      pps.append(Array(b[off..<(off + len)]))
      off += len
    }
    return AVCParameters(sps: sps, pps: pps, lengthSize: lengthSize)
  }

  /// HEVC decoder configuration record (hvcC): fixed 23-byte header, then
  /// numOfArrays (1B), each array = 1B (array_completeness + NAL_unit_type),
  /// 2B numNalus, per-NAL 2B length + NAL. Returns the NALs (type + data) and
  /// the NAL length size, or nil on a malformed record.
  private struct HVCCParameters {
    let nals: [(type: Int, data: [UInt8])]
    let lengthSize: Int
  }

  private func parseHVCC(_ b: [UInt8]) -> HVCCParameters? {
    guard b.count >= 24, b[0] == 1 else { return nil }
    let lengthSize = Int(b[21] & 0x03) + 1
    let numArrays = Int(b[22])
    var off = 23
    var nals: [(type: Int, data: [UInt8])] = []
    for _ in 0..<numArrays {
      guard off < b.count else { return nil }
      let type = Int(b[off] & 0x3F)
      off += 1
      guard off + 2 <= b.count else { return nil }
      let numNalus = (Int(b[off]) << 8) | Int(b[off + 1])
      off += 2
      for _ in 0..<numNalus {
        guard off + 2 <= b.count else { return nil }
        let len = (Int(b[off]) << 8) | Int(b[off + 1])
        off += 2
        guard off + len <= b.count else { return nil }
        nals.append((type, Array(b[off..<(off + len)])))
        off += len
      }
    }
    return HVCCParameters(nals: nals, lengthSize: lengthSize)
  }

  /// Builds a CMVideoFormatDescription from parameter-set NALs, holding the
  /// byte storage alive for the whole CoreMedia call.
  ///
  /// The previous code captured `baseAddress` from `withUnsafeBufferPointer`
  /// into a `[UnsafePointer<UInt8>]` and passed it to
  /// `CMVideoFormatDescriptionCreateFrom*ParameterSets` AFTER the loop and the
  /// temporaries (e.g. `par.vps + par.sps + par.pps`) went out of scope. That
  /// is undefined behavior: under whole-module optimization (`-O`) the
  /// optimizer proves those arrays have no later *direct* use and ends their
  /// lifetime before the C call, so the escaped pointers dangle and CoreMedia
  /// returns `-12712` (`kCMFormatDescriptionBridgeError_InvalidParameter`).
  /// `-Onone` (Debug) keeps the arrays heap-resident for the whole function
  /// scope, masking the bug — the classic "works in Debug, fails in Release".
  ///
  /// Fix: pack all NALs into ONE contiguous `[UInt8]`, then build the pointer
  /// array and make the CoreMedia call INSIDE the same `withUnsafeBufferPointer`
  /// closure that wraps it. The `withUnsafeBufferPointer` contract guarantees
  /// `packed`'s storage is valid for the whole closure body, so the pointers
  /// cannot dangle — at any optimization level. CoreMedia copies the bytes at
  /// creation, so the pointers only need to live for the call.
  private func makeFormatDescription(
    params: [[UInt8]], lengthSize: Int, hevc: Bool
  ) -> CMVideoFormatDescription? {
    var packed = [UInt8]()
    var offsets = [Int](repeating: 0, count: params.count)
    var sizes = [Int](repeating: 0, count: params.count)
    for (i, n) in params.enumerated() {
      offsets[i] = packed.count
      sizes[i] = n.count
      packed.append(contentsOf: n)
    }
    var fd: CMVideoFormatDescription?
    let status = packed.withUnsafeBufferPointer { pk in
      let base = pk.baseAddress!
      let pts: [UnsafePointer<UInt8>] = offsets.map { base + $0 }
      if hevc {
        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: pts.count,
          parameterSetPointers: pts, parameterSetSizes: sizes,
          nalUnitHeaderLength: Int32(lengthSize), extensions: nil,
          formatDescriptionOut: &fd)
      } else {
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: pts.count,
          parameterSetPointers: pts, parameterSetSizes: sizes,
          nalUnitHeaderLength: Int32(lengthSize), formatDescriptionOut: &fd)
      }
    }
    return status == noErr ? fd : nil
  }

  /// VPS/SPS/PPS collected for the VideoToolbox HEVC format description.
  /// `isComplete` means at least one of each is present, which is what
  /// CMVideoFormatDescriptionCreateFromHEVCParameterSets requires.
  private struct HVCCParSets {
    var vps: [[UInt8]] = []
    var sps: [[UInt8]] = []
    var pps: [[UInt8]] = []
    var lengthSize: Int
    var isComplete: Bool { !vps.isEmpty && !sps.isEmpty && !pps.isEmpty }
  }

  /// Collects HEVC VPS/SPS/PPS for the format description.
  ///
  /// Most MKVs carry the parameter sets in CodecPrivate (hvcC). Some muxers
  /// (and some downloaders' remuxes) ship a bare 23-byte hvcC header with
  /// `numOfArrays == 0` and carry the sets IN-BAND — the first video packet is
  /// an IRAP keyframe whose leading NALs (types 32/33/34) hold VPS/SPS/PPS.
  /// VideoToolbox requires at least one of each, so when CodecPrivate is empty
  /// or incomplete we recover the sets from the first video packet(s), then
  /// rewind the demuxer to the start so the playback loop re-reads the
  /// SPS/PPS keyframe from the beginning.
  private func hevcParameterSets(
    demuxer: FFmpegDemuxer, streamIndex: Int, extradata: [UInt8]
  ) -> HVCCParSets? {
    var par = HVCCParSets(lengthSize: extradata.count > 21 ? Int(extradata[21] & 0x03) + 1 : 4)
    if let hvcc = parseHVCC(extradata) {
      par.lengthSize = hvcc.lengthSize
      for (type, nal) in hvcc.nals {
        switch type {
        case 32: par.vps.append(nal)
        case 33: par.sps.append(nal)
        case 34: par.pps.append(nal)
        default: break
        }
      }
    }
    if !par.isComplete {
      // CodecPrivate gave us nothing (or a partial set) — recover in-band.
      if let inband = inBandHVCC(
        demuxer: demuxer, streamIndex: streamIndex, lengthSize: par.lengthSize)
      {
        par = inband
      }
    }
    return par.isComplete ? par : nil
  }

  /// Reads the first video packet(s) and pulls VPS/SPS/PPS out of the
  /// length-prefixed NAL stream (MKV HEVC is AVCC-style — a 4-byte length per
  /// NAL). Rewinds the demuxer to the start both before and after so the
  /// playback loop sees the SPS/PPS keyframe at its natural position.
  ///
  /// OPEN-ONLY CONTRACT: this is only valid while the demuxer is at the file
  /// start (probe()). It ends with `seek(to: 0)`, so calling it from the SEEK
  /// path leaves the demuxer at 0 and silently discards the seek — which is
  /// exactly what happened when performSeek re-ran setupVideoToolbox (see the
  /// note in performSeek). Do not add other callers.
  private func inBandHVCC(
    demuxer: FFmpegDemuxer, streamIndex: Int, lengthSize: Int
  ) -> HVCCParSets? {
    let len = max(1, lengthSize)
    _ = try? demuxer.seek(to: 0)
    var par = HVCCParSets(lengthSize: lengthSize)
    for _ in 0..<64 {
      guard let pkt = try? demuxer.readPacket() else { break }
      guard pkt.streamID == streamIndex else { continue }
      let b = [UInt8](pkt.data)
      var off = 0
      while off + len <= b.count {
        var nlen = 0
        for i in 0..<len { nlen = (nlen << 8) | Int(b[off + i]) }
        off += len
        guard nlen > 0, off + nlen <= b.count else { break }
        let nalType = (b[off] >> 1) & 0x3F
        let nal = Array(b[off..<(off + nlen)])
        if nalType == 32 { par.vps.append(nal) }
        else if nalType == 33 { par.sps.append(nal) }
        else if nalType == 34 { par.pps.append(nal) }
        off += nlen
        if par.isComplete { break }
      }
      if par.isComplete { break }
    }
    _ = try? demuxer.seek(to: 0)
    return par
  }

  /// Session creation shared by H.264 and HEVC: collector box, output callback,
  /// and a VTDecompressionSession sized to the format description's coded dims.
  private func setupVTCommon(formatDesc fd: CMVideoFormatDescription) throws {
    // The session's generation, captured here on the pipeline queue: the VT
    // callback compares it with `videoQueueGeneration` (lock-protected)
    // instead of reading `generation`, which only the pipeline may touch.
    let sessionGeneration = generation
    // Collector box: VT callback fills the queue on VT's thread.
    let box = VideoCollectorBox(
      onFrame: { [weak self] frame in
        guard let self else { return }
        self.videoQueueLock.lock()
        if self.videoQueueGeneration == sessionGeneration {
          self.videoQueue.append(frame)
        } else {
          self.vtStale += 1
        }
        self.videoQueueLock.unlock()
      },
      onOutcome: { [weak self] status, flags, pts in
        self?.recordVTOutcome(status: status, flags: flags, pts: pts)
      })
    var cbRecord = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { refCon, sourceFrameRefCon, status, infoFlags, imageBuffer, pts, _ in
        // Release the sample-buffer retain made at submission (see
        // VTSampleBufferHolder in feedVideoPacket). Every callback — decoded,
        // dropped or failed — balances exactly one submit.
        if let sourceFrameRefCon {
          Unmanaged<VTSampleBufferHolder>.fromOpaque(sourceFrameRefCon).release()
        }
        let box = Unmanaged<VideoCollectorBox>.fromOpaque(refCon!).takeUnretainedValue()
        // Account for the outcome first: a dropped/failed frame still finishes a
        // slot in flight, so it must be counted or the in-flight backpressure
        // (videoDecoderSaturated) would think the decoder is still busy and
        // starve the pipeline forever.
        box.onOutcome(status, infoFlags, CMTimeGetSeconds(pts))
        guard status == noErr, let imageBuffer else { return }
        box.onFrame(NativeVideoFrame(pts: CMTimeGetSeconds(pts), pixelBuffer: imageBuffer))
      }, decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())

    var session: VTDecompressionSession?
    // Output pixel buffers at the CODEC's native dimensions (from the
    // format description). Previously hardcoded 1920x816 — VideoToolbox then
    // SCALED every stream to 1920x816, which squeezed 16:9 content into a
    // 2.35:1 aspect. Coded dims keep the rendered aspect correct for every
    // file, HEVC or H.264. HEVC 10-bit sources are requested as 8-bit limited
    // range (VideoToolbox downconverts); the Metal shader picks the YCbCr
    // matrix (BT.601/709/2020) from the pixel buffer's attachments. To
    // preserve 10-bit later, request 420YpCbCr10BiPlanarVideoRange and update
    // the shader to 1023-based math (HDR transfer functions are not mapped).
    let codedDims = CMVideoFormatDescriptionGetDimensions(fd)
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferWidthKey as String: Int(codedDims.width),
      kCVPixelBufferHeightKey as String: Int(codedDims.height),
    ]
    let vts = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
      imageBufferAttributes: attrs as CFDictionary, outputCallback: &cbRecord,
      decompressionSessionOut: &session)
    guard vts == noErr, let session else { throw NativePlayerError.videoDecoderFailed }
    vtSession = session
    videoCollectorBox = box
  }

  /// True for HEVC/H.265 codecs (codec name hevc/h265/hev1, or AVCodecID 175);
  /// VideoToolbox decodes HEVC natively, so these are the only two video codec
  /// families the native engine accepts.
  static func isHevcCodec(_ video: NativeTrackInfo) -> Bool {
    let n = video.codecName.lowercased()
    return n == "hevc" || n == "h265" || n == "hev1" || video.codecID == 175
  }

  private func demuxerHandle(_ d: FFmpegDemuxer) -> UnsafeMutablePointer<MediaDemuxer>? {
    // The FFmpegDemuxer owns its handle; we need it for extradata during
    // setup. Handle is stable for the demuxer's lifetime.
    return d.unsafeHandle
  }

  // MARK: - Audio setup

  /// How the decoded source is routed to the player node.
  enum AudioRoute: Equatable {
    /// Player format == source format (stereo, or 5.1 to a >= 6 ch device).
    case passthrough
    /// Mono source duplicated into both channels of a stereo player format.
    case monoToStereo
    /// App-side weighted downmix of a multichannel source to stereo.
    case downmix([ChannelRole])
  }

  /// Chooses the route for a source. CHANNEL-COUNT INVARIANT (plan Task 8):
  /// buffer fill must be able to produce every player-format channel from the
  /// decoded frame, so the only outcomes are an exact passthrough, mono
  /// duplicated to stereo, or an explicit stereo downmix.
  ///
  /// Passthrough is limited to layouts whose Core Audio order provably matches
  /// FFmpeg's: stereo, and 5.1/5.1(side) (FL FR FC LFE xL xR == MPEG_5_1_A).
  /// Anything else multichannel is downmixed even on a multichannel device —
  /// previously such sources fell back to a STEREO player format, which kept
  /// only the front pair (no dialogue), and a mono source was given a stereo
  /// format while decoding one channel, which indexed past the decoded buffer.
  static func audioRoute(
    sourceChannels: Int, layoutMask: UInt64, layoutName: String?, deviceChannels: Int
  ) -> AudioRoute {
    if sourceChannels <= 1 { return .monoToStereo }
    if sourceChannels == 2 { return .passthrough }
    if sourceChannels == 6, layoutName == "5.1" || layoutName == "5.1(side)", deviceChannels >= 6 {
      return .passthrough
    }
    if let roles = ChannelRoleMap.roles(forMask: layoutMask), roles.count == sourceChannels {
      return .downmix(roles)
    }
    // No usable native mask: assume the front pair leads (FFmpeg's default
    // order for every layout) and fold the rest in at the surround gain.
    return .downmix(
      [.frontL, .frontR] + Array(repeating: ChannelRole.unknown, count: sourceChannels - 2))
  }

  private func setupAudio(streamIndex: Int) throws {
    guard let demuxer else { throw NativePlayerError.audioDecoderFailed }
    guard let track = demuxer.track(at: streamIndex),
      Self.isSupportedAudioCodec(track.codecName)
    else { throw NativePlayerError.audioDecoderFailed }
    guard let dec = media_audio_decoder_create(demuxer.unsafeHandle, Int32(streamIndex)) else {
      throw NativePlayerError.audioDecoderFailed
    }
    // The decoder's output format, not the track header: an HE-AAC header
    // describes the core layer (e.g. 24 kHz mono for 48 kHz stereo output).
    var sourceChannels: Int32 = 0
    var sourceRate: Int32 = 0
    var layoutMask: UInt64 = 0
    var layoutBuf = [CChar](repeating: 0, count: 64)
    guard
      media_audio_decoder_get_format(
        dec, &sourceChannels, &sourceRate, &layoutMask, &layoutBuf, layoutBuf.count)
        == MEDIA_RESULT_OK, sourceChannels > 0, sourceRate > 0
    else {
      media_audio_decoder_free(dec)
      throw NativePlayerError.audioDecoderFailed
    }
    let channelCount = Int(sourceChannels)
    let layoutName = String(
      decoding: layoutBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    if let old = audioDecoder { media_audio_decoder_free(old) }
    audioDecoder = dec
    audioSourceChannels = channelCount
    audioFormatMismatchLogged = false
    // The previous graph (track switch) must stop rendering before it is
    // replaced; dropping a running engine left its render thread alive.
    audioEngine?.stop()

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)

    // --- Audio enhancement (dialogue modes) ---
    // Channel roles come from the FFmpeg native mask; the output-device
    // channel count decides whether a 5.1 source stays multichannel
    // (passthrough) or is downmixed app-side to stereo.
    let deviceChannels = Int(engine.outputNode.outputFormat(forBus: 0).channelCount)
    let route = Self.audioRoute(
      sourceChannels: channelCount, layoutMask: layoutMask, layoutName: layoutName,
      deviceChannels: deviceChannels)
    let sampleRate = Double(sourceRate)
    let playerFormat: AVAudioFormat
    var matrices: [AudioEnhancementMode: [[Float]]] = [:]
    var roles: [ChannelRole]?
    // BS.1770 channel weights for the loudness meter, in player-format order.
    var loudnessWeights: [Double] = [1, 1]
    switch route {
    case .passthrough where channelCount == 6:
      guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A) else {
        throw NativePlayerError.outputDeviceFailed
      }
      playerFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
      loudnessWeights = [1, 1, 1, 0, 1.41, 1.41]  // L R C LFE Ls Rs
    case .passthrough:
      // Stereo: the modes' side level goes through a 2x2 matrix.
      guard let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
        throw NativePlayerError.outputDeviceFailed
      }
      playerFormat = f
      roles = [.frontL, .frontR]
      for mode in AudioEnhancementMode.allCases {
        matrices[mode] = DownmixMatrix.stereoCoefficients(
          sideGainDB: AudioEnhancementPreset.preset(for: mode).sideGainDB)
      }
    case .monoToStereo:
      guard let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
        throw NativePlayerError.outputDeviceFailed
      }
      playerFormat = f
    case .downmix(let downmixRoles):
      guard let f = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
        throw NativePlayerError.outputDeviceFailed
      }
      playerFormat = f
      roles = downmixRoles
      for mode in AudioEnhancementMode.allCases {
        matrices[mode] = DownmixMatrix.coefficients(
          roles: downmixRoles, centerGainDB: AudioEnhancementPreset.preset(for: mode).centerGainDB)
      }
      NSLog(
        "[Audio] downmix %d ch -> stereo (device %d ch) roles=%@", channelCount,
        deviceChannels, String(describing: downmixRoles))
    }
    enhancementLock.lock()
    downmixRoles = roles
    downmixMatrices = matrices
    let limiterRequired = limiterHeld
    enhancementLock.unlock()
    loudnessNormalizer = LoudnessNormalizer(sampleRate: sampleRate, weights: loudnessWeights)
    loudnessLogFrames = 0
    audioFormat = playerFormat
    audioBytesPerFrame = Int(playerFormat.streamDescription.pointee.mBytesPerFrame)

    // Processing chain (dynamics -> limiter -> EQ) whenever the player
    // outputs stereo; multichannel passthrough (multichannel device) stays
    // untouched in every mode (phase-1 scope — documented follow-up).
    // The chain is ALWAYS present for stereo output, even in original mode
    // (everything bypassed), so mode switches are parameter-only and never
    // recreate the graph.
    if let chain = AudioEnhancementChain(engine: engine), playerFormat.channelCount <= 2 {
      enhancementChain = chain
      chain.install(player: player, mainMixer: engine.mainMixerNode, format: playerFormat)
      let mode = currentMode()
      chain.apply(preset: AudioEnhancementPreset.preset(for: mode), limiterRequired: limiterRequired)
      // Task 11: fixed downstream latency. The master clock is the
      // player node (UPSTREAM of the chain), so this latency does not
      // move the clock — it only shifts the fixed output path. Logged
      // for the record; expected << 30 ms (single render quantum + AU
      // lookahead), no video compensation needed.
      let latMs = engine.outputNode.presentationLatency * 1000
      NSLog(
        "[Audio] enhancement chain installed (mode %@, %d ch, device latency %.1f ms)",
        mode.rawValue, playerFormat.channelCount, latMs)
    } else {
      enhancementChain = nil
      engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
    }
    // Headless/muted testing: PLAYER_MUTE=1 silences the OUTPUT while the
    // full decode->schedule->render pipeline (and the audio master clock)
    // keeps running — the mute-autoplay pattern for automated runs.
    // PLAYER_VOLUME=<0..1> is the graded form (e.g. 0.01 to leave the run
    // technically audible at ~1%), for when a fully zeroed output is not
    // wanted; both are loggable evidence that the run was silent.
    if let raw = ProcessInfo.processInfo.environment["PLAYER_VOLUME"], let v = Double(raw) {
      engine.mainMixerNode.outputVolume = Float(min(max(v, 0), 1))
      NSLog("[Audio] output volume %.3f (PLAYER_VOLUME)", min(max(v, 0), 1))
    } else {
      engine.mainMixerNode.outputVolume =
        ProcessInfo.processInfo.environment["PLAYER_MUTE"] == "1" ? 0 : 1.0
      NSLog(
        "[Audio] output %@ (PLAYER_MUTE)",
        ProcessInfo.processInfo.environment["PLAYER_MUTE"] == "1" ? "muted" : "volume 1.0")
    }
    audioEngine = engine
    audioPlayer = player
    audioIsRunning = false
  }

  /// Stops the audio RENDER path without tearing down the graph. A running
  /// AVAudioEngine keeps its realtime render thread active even when every
  /// node is stopped — it renders silence at audio-buffer rate, which is
  /// measurable CPU/power while paused or after EOF. pause() halts the
  /// output unit cheaply (no graph teardown); restartAudioPlayer() resumes
  /// it on play/resume via `!engine.isRunning → start()`.
  private func pauseAudioEngine() {
    guard let engine = audioEngine, engine.isRunning else { return }
    engine.pause()
    audioIsRunning = false
  }

  /// Puts the audio player node back into the playing state. Starts the
  /// engine first only if it isn't running; the NODE always needs play()
  /// after stop()/reset()/pause() — the engine keeps running across a
  /// seek, so a `!engine.isRunning` gate would never restart the node,
  /// leaving scheduled buffers unplayed (silent audio) while
  /// audioSecondsAhead grows past the cap, which starves the demux loop
  /// (video dies, timeline keeps moving via the monotonic fallback).
  private func restartAudioPlayer() {
    if let engine = audioEngine, !engine.isRunning { try? engine.start() }
    if let player = audioPlayer {
      player.play()
      invalidateNodeClock()  // the node clock restarted at 0
      audioIsRunning = true
    }
  }

  // MARK: - Play / pause / seek / stop

  /// Starts playback. First start launches the demux loop on the pipeline
  /// queue (the loop then owns the queue until stop/EOF); a resume-while-
  /// paused goes through the command mailbox instead. Playing again after
  /// the end restarts from the beginning (unless a seek was issued since).
  func play() {
    guard hasMedia else { return }
    commandLock.lock()
    if loopRunning {
      Self.enqueue(.resume, into: &commandQueue)
      commandLock.unlock()
      commandSignal.signal()
      return
    }
    // Claim the loop BEFORE dispatching, under the same lock stop() checks:
    // a stop() issued between this call and the block starting must see the
    // loop as running and hand it `.stop`, not tear down underneath it.
    loopRunning = true
    commandQueue.removeAll { !$0.survivesLoopRestart }
    let restartFromTop =
      isEnded && !commandQueue.contains { if case .seek = $0 { true } else { false } }
    if restartFromTop { commandQueue.insert(.seek(0, exact: true), at: 0) }
    commandLock.unlock()
    pipelineQueue.async { [weak self] in
      guard let self else { return }
      guard let demuxer = self.demuxer else {
        self.commandLock.lock()
        self.commandQueue.removeAll()
        self.loopRunning = false
        self.commandLock.unlock()
        return
      }
      self.isPlaying = true
      self.isPaused = false
      self.isEnded = false
      self.startMonotonic = CACurrentMediaTime() - self.withState { self._publishedClock }
      self.clockBaseAudio = self.audioPlayer != nil
      // Fresh playback session: nothing scheduled on this node yet and the
      // demuxer may well have audio for us, so clear the starvation bookkeeping
      // (`audioContentEndNode`/`audioSourceExhausted` are the clock anchor and
      // its EOF release — see their declarations).
      self.audioContentEndNode = 0
      self.audioSourceExhausted = false
      self.drainDeadline = nil
      self.restartAudioPlayer()
      NSLog("[Native] play (audio clock: %@)", self.clockBaseAudio ? "yes" : "no")
      self.demuxLoop(demuxer)
    }
  }

  /// Pauses the running loop. A no-op when nothing is running (a pause
  /// queued for a loop that does not exist used to start the next file
  /// paused).
  func pause() {
    commandLock.lock()
    let running = loopRunning
    if running { Self.enqueue(.pause, into: &commandQueue) }
    commandLock.unlock()
    if running { commandSignal.signal() }
  }

  /// Stops everything and tears down the pipeline. Synchronous: returns once
  /// the teardown has run, so callers can safely open a new file right after.
  /// Safe to call when nothing is running.
  ///
  /// The wait is a `pipelineQueue.sync`, which serializes with whatever owns
  /// the queue — the running loop (handed `.stop` through the mailbox), a
  /// probe in flight, or a loop that is just winding down — so the teardown
  /// never races any of them.
  func stop() {
    commandLock.lock()
    let running = loopRunning
    if running {
      Self.enqueue(.stop, into: &commandQueue)
    } else {
      commandQueue.removeAll()
    }
    commandLock.unlock()
    if running { commandSignal.signal() }
    pipelineQueue.sync {
      guard !running else { return }  // the loop ran performStop itself
      performStop()
      stateChanged()
    }
  }

  /// Flush + demuxer seek + VT rebuild, run inside the demux loop. PTS
  /// before target is discarded by the scheduler (generation-protected).
  /// `exact == false` (live scrubbing) lets a paused preview show the
  /// nearest decodable frame instead of decoding all the way to the target.
  /// Issued while nothing runs, the seek is applied when playback resumes.
  func seek(to seconds: Double, exact: Bool = true) {
    submit(.seek(seconds, exact: exact))
    if !isPlaying { publishClock(seconds) }
  }

  // MARK: - Demux loop

  /// Reads packets, feeds decoders, schedules audio, presents video.
  /// Runs on the pipeline queue and owns it until stop/EOF; transport
  /// commands are consumed from the mailbox each iteration (a paused loop
  /// blocks on the command semaphore instead of spinning).
  private func demuxLoop(_ demuxer: FFmpegDemuxer) {
    // Drain pending video packets first (carryover across seeks).
    if !pendingVideoPackets.isEmpty { feedPendingVideoPackets() }

    var eof = false
    while true {
      var keepRunning = true
      // The node clock advances continuously while playing, so every
      // iteration starts dirty: the FIRST read this iteration (clock,
      // backpressure gate, summary) pays one playerTime allocation and
      // the rest reuse it. Without this the cache would serve a stale
      // value forever (observed: clock frozen mid-file, video queue
      // pinned full, demux starved).
      invalidateNodeClock()
      // Drain ObjC autorelease temporaries every iteration. The loop
      // runs as ONE dispatch block on the pipeline queue, so without a
      // pool here the AVAudioTime objects allocated by every
      // playerTime(forNodeTime:) call (plus PCM/sample-buffer
      // temporaries) are never released for the file's lifetime
      // (measured: ~150k live AVAudioTime after 30 s of playback,
      // 630 MB after one movie).
      autoreleasepool { keepRunning = stepLoop(demuxer: demuxer, eof: &eof) }
      if !keepRunning { return }
    }
  }

  /// One mailbox + demux iteration. Returns false when the loop must exit
  /// (.stop handled or EOF fully drained); the caller wraps it in an
  /// autoreleasepool.
  private func stepLoop(demuxer: FFmpegDemuxer, eof: inout Bool) -> Bool {
    if let cmd = takeCommand() {
      // Anything that moves the read cursor makes the stream readable again:
      // cancel a pending end (EOF drain / partial end) so the loop resumes
      // feeding from the new position instead of finishing.
      if cmd.repositions {
        readEnd = nil
        eof = false
        prematureEnd = nil
        drainDeadline = nil
        audioSourceExhausted = false
        isEnded = false
      }
      switch cmd {
      case .resume:
        isPlaying = true
        isPaused = false
        startMonotonic = CACurrentMediaTime() - pausedClock
        clockBaseAudio = audioPlayer != nil
        // The pause reset the node and DISCARDED its pre-buffered
        // audio; meanwhile the demux read cursor had already
        // advanced up to maxAudioAheadSeconds past the audio
        // position. Rewinding to the paused position re-reads that
        // block, so audio resumes EXACTLY at pausedClock (no
        // underrun gap / audio delay) instead of ~1.5s late.
        // discardAudioBefore drops the already-heard (< pausedClock)
        // prefix; video packets re-read are dropped by
        // lastPresentedPTS.
        if pausedClock > 0 {
          discardAudioBefore = pausedClock
          _ = try? demuxer.seek(to: max(0, pausedClock - 0.05))
        }
        restartAudioPlayer()
        invalidateNodeClock()
        NSLog("[Native] resume at %.3f", pausedClock)
        stateChanged()
      case .pause:
        pausedClock = currentClock()
        publishClock(pausedClock)
        NSLog("[Native] pause at %.3f", pausedClock)
        isPlaying = false
        isPaused = true
        if let player = audioPlayer {
          // Reset the node clock so resume is exact: the engine
          // keeps rendering a paused node, so playerTime would
          // otherwise keep advancing during pause. (The pre-
          // buffered audio is discarded here; .resume rewinds the
          // read cursor to pausedClock so no audio is lost.)
          player.stop()
          player.reset()
          audioClockOffset = pausedClock
        }
        audioContentEndNode = 0
        pauseAudioEngine()
        invalidateNodeClock()
        stateChanged()
      case .seek(let seconds, let exact):
        performSeek(seconds: seconds, exact: exact, demuxer: demuxer)
      case .switchAudio(let streamIndex):
        performAudioSwitch(streamIndex: streamIndex, demuxer: demuxer)
      case .switchSubtitle(let streamIndex):
        performSubtitleSwitch(streamIndex: streamIndex, demuxer: demuxer)
      case .stop:
        performStop()
        commandLock.lock()
        loopRunning = false
        // Anything queued behind the stop targeted the file just torn down.
        commandQueue.removeAll()
        commandLock.unlock()
        stateChanged()
        return false
      }
      return true
    }
    // Paused with no command pending: block until signaled. The pool
    // around this call makes each blocked wait a drain point too.
    if isPaused {
      commandSignal.wait()
      return true
    }
    if let pe = prematureEnd {
      // Incomplete file (still being downloaded): stop WITHOUT the drain
      // path — there is no trailing audio to play out (the data simply is not
      // on disk yet), so draining would wait ~2 s pointlessly before "ending".
      // Signal the engine so it can wait for the file to grow and retry.
      // A command that raced in first is handled before giving up the loop.
      guard tryExitLoop() else { return true }
      prematureEnd = nil
      performStop()
      stateChanged()
      if let cb = onPartialEnd {
        let pos = pe.position
        let err = pe.wasError
        Task { @MainActor in cb(pos, err) }
      }
      return false
    }
    if eof {
      // Let audio play out one short step at a time, so pause/seek/stop issued
      // during the drain are handled immediately instead of after it.
      if drainStep() { return true }
      // Published before the loop is released, so a play() racing the exit
      // already sees the end and restarts from the top.
      isEnded = true
      guard tryExitLoop() else { return true }
      finishPlayback()
      return false
    }
    tick(demuxer: demuxer, eof: &eof)
    return true
  }

  /// One iteration of the old demux loop body.
  private func tick(demuxer: FFmpegDemuxer, eof: inout Bool) {
    let videoIndex = videoStreamIndex
    let audioIndex = audioStreamIndex
    let subIndex = subtitleStreamIndex

    // Present anything due (audio clock master).
    presentDueFrames()
    // Backpressure: audio ahead cap.
    if audioIndex != nil, let player = audioPlayer {
      let ahead = audioSecondsAhead(player: player)
      if ahead > maxAudioAheadSeconds {
        usleep(4000)  // 4 ms
        return
      }
    }
    // Backpressure: video decode-ahead cap. When the decoder is at its cap,
    // surplus video packets are STASHED (compressed, ~200 KB each) instead of
    // stopping the loop. Stopping the loop also stops the AUDIO feed, and while
    // the master clock is held (currentClock clamps during a starvation) that
    // is a deadlock: the clock cannot advance (no audio), so the video queue
    // cannot drain, so no packet — including the audio that would unblock it —
    // is ever read again. The stash keeps audio flowing through a starvation,
    // bounded by maxStashedVideoSeconds.
    // Flush stashed packets FIRST (they precede anything read now) as far as the
    // decoder allows, then decide whether the fresh packet may be fed directly.
    if !pendingVideoPackets.isEmpty { feedPendingVideoPackets() }
    // Never feed a fresh packet while an older one is still stashed (see
    // feedPendingVideoPackets: HEVC decode order), and respect both limits —
    // our decoded queue and VideoToolbox's in-flight depth (see vtSubmitted).
    let videoDecoderFull = videoFeedBlocked() || !pendingVideoPackets.isEmpty
    if videoDecoderFull, pendingVideoSeconds >= maxStashedVideoSeconds {
      usleep(4000)
      return
    }

    do {
      guard let pkt = try demuxer.readPacket() else {
        // EOF: clean only if we reached the container's declared duration.
        // A downloader still writing the file (reserved space, filled
        // progressively) hits a clean read EOF well before the real end —
        // treat that as a partial end so the engine waits for it to grow.
        if isPrematureEOF(demuxer: demuxer) {
          let pos = currentClock()
          NSLog("[Native] premature EOF at %.3f (file likely still downloading)", pos)
          prematureEnd = (position: pos, wasError: false)
        } else {
          NSLog("[Native] EOF")
        }
        // No more audio can follow: lift the clock clamp so the last frames and
        // the audio already scheduled can play out instead of the timeline
        // freezing at the audio content end.
        audioSourceExhausted = true
        eof = true
        return
      }
      summaryPackets += 1
      if let pts = pkt.ptsSeconds {
        let end = pts + (pkt.durationSeconds ?? 0)
        if end > (readEnd ?? -.infinity) { readEnd = end }
      }
      if let videoIndex, pkt.streamID == videoIndex {
        videoPacketsRead += 1
        if let target = verifySeekTarget {
          verifySeekTarget = nil
          NSLog(
            "[Native] seek landed: first video pts %.3f (target %.3f, delta %+.3f)",
            pkt.ptsSeconds ?? -1, target, (pkt.ptsSeconds ?? -1) - target)
        }
        // Stash instead of blocking the loop while the decoder is at its cap
        // (see the backpressure note above — blocking would also stop the audio
        // feed). Ordered: a fresh packet is only fed when nothing is stashed.
        if videoDecoderFull { stashVideoPacket(pkt) } else { feedVideoPacket(pkt) }
      } else if let audioIndex, pkt.streamID == audioIndex {
        // Skip pre-target audio after a coarse seek (see
        // discardAudioBefore); the demuxer position is at the
        // keyframe BEFORE the target, and playing that backlog would
        // trip the audio-ahead gate and starve video reads.
        if let cutoff = discardAudioBefore {
          if let pts = pkt.ptsSeconds, pts < cutoff { return }
          discardAudioBefore = nil
        }
        feedAudioPacket(pkt)
      } else if let subIndex, pkt.streamID == subIndex {
        collectSubtitlePacket(pkt)
      }
    } catch {
      // A read error can be a genuinely corrupt stream or the boundary of a
      // not-yet-downloaded file. It is never a clean end, so always surface
      // it as a partial end and let the engine decide (wait vs hard error).
      let pos = currentClock()
      NSLog("[Native] demux read error at %.3f: %@", pos, error.localizedDescription)
      prematureEnd = (position: pos, wasError: true)
      audioSourceExhausted = true  // no audio beyond a read error — see EOF above
      eof = true
    }
  }

  /// True when a clean EOF was reached before the container's declared
  /// duration — the file is incomplete (a downloader is still writing it),
  /// so playback should wait for the file to grow and retry rather than
  /// ending. A file with no known duration is treated as a real end (we
  /// cannot distinguish, and ending is the safe non-sticky choice).
  ///
  /// Compared against the read cursor (`readEnd`): the playback clock trails
  /// the reader by up to maxAudioAheadSeconds, so comparing the CLOCK flagged
  /// every complete file as still downloading ~1.5 s before its end — the
  /// tail was cut and the "Waiting" badge shown instead of ending.
  private func isPrematureEOF(demuxer: FFmpegDemuxer) -> Bool {
    guard let duration = demuxer.duration, duration > 0 else { return false }
    return (readEnd ?? currentClock()) < duration - 1.0
  }

  /// Seek internals (flush, keyframe seek, VT rebuild, clock reset). Runs
  /// inside the demux loop — the loop continues after, no restart needed.
  private func performSeek(seconds: Double, exact: Bool, demuxer: FFmpegDemuxer) {
    generation &+= 1
    let gen = generation
    publishClock(seconds)

    // Flush decode state.
    if let vtSession {
      VTDecompressionSessionInvalidate(vtSession)
      self.vtSession = nil
    }
    videoQueueLock.lock()
    videoQueue.removeAll()
    videoQueueGeneration = gen
    videoQueueLock.unlock()
    clearPendingVideoPackets()
    // Discard pre-target video frames: the coarse (keyframe) seek lands
    // BEFORE the target, and presenting the keyframe->target window would
    // fast-forward the video (clock is already at the target) while the
    // shallow queue drops B-frames en masse (choppy ~0.5x). Seeding the
    // regression guard with the target drops those frames at the
    // scheduler — mirror of discardAudioBefore for audio.
    lastPresentedPTS = seconds
    verifySeekTarget = seconds
    NSLog("[Native] seek -> %.3f (gen %llu)", seconds, gen)

    if let audioDecoder { media_audio_decoder_flush(audioDecoder) }
    audioContentEndNode = 0
    if let player = audioPlayer {
      player.stop()
      player.reset()
      if !isPaused {
        // The node must be restarted after reset, or scheduled
        // buffers never play and audioSecondsAhead starves the demux
        // loop.
        restartAudioPlayer()
      } else {
        audioIsRunning = false
      }
    }
    invalidateNodeClock()

    do {
      try demuxer.seek(to: seconds)
      // Coarse seek lands on the keyframe BEFORE the target; skip
      // pre-target audio so the audio pipeline starts at the target.
      discardAudioBefore = seconds
      // Rebuild the VT SESSION from the format description parsed at open.
      //
      // NEVER re-run setupVideoToolbox here. It re-parses CodecPrivate and, for
      // streams whose parameter sets are IN-BAND (a bare 23-byte hvcC with
      // numOfArrays == 0 — video.mkv is exactly this), falls into inBandHVCC,
      // which REWINDS THE DEMUXER TO 0. That silently discards the seek: the
      // demux loop then walks the media from the start while the audio clock
      // free-runs, and playback resumes with the picture that far behind the
      // sound. Measured before the fix (seek to 287.269 s on a 4K HEVC file):
      // 23.6 s of walking at ~300 dropped frames/s, `aud=-23.2s`, then
      // `drift=-22.07s` with the picture stuck ~7 fps behind the audio.
      //
      // Codec parameters cannot change across a seek within one file, and
      // `vtFormatDesc` survives the session invalidation above (it is a
      // separate CoreMedia object we still own), so the session is simply
      // recreated from it. setupVTCommon is the shared session builder.
      if let fd = vtFormatDesc {
        try setupVTCommon(formatDesc: fd)
      } else if let vStream = videoStreamIndex, let vTrack = demuxer.track(at: vStream) {
        try setupVideoToolbox(demuxer: demuxer, video: vTrack)
      }
      // New session: restart the decoder accounting (in-flight frames of the
      // invalidated session never come back).
      resetVTCounters()
      startMonotonic = CACurrentMediaTime() - seconds
      audioClockOffset = seconds
      // A seek while paused moves the frozen position, so the timer
      // reflects the new target and resume resumes there.
      if isPaused {
        pausedClock = seconds
        // Present the frame at the new position so a pause-time seek
        // (arrow-arrow skip, slider scrub) shows it immediately instead of
        // freezing on the old frame until resume. Decode + present the
        // nearest frame at/after the target and hold it.
        presentPausedPreview(target: seconds, exact: exact, demuxer: demuxer)
      }
      stateChanged()
    } catch { stateChanged() }
  }

  /// Decode + present the single video frame at/after `target` while paused,
  /// so a pause-time seek (arrow-arrow skip, slider scrub) shows the frame at
  /// the new position immediately instead of freezing on the old frame until
  /// resume. Runs on the pipeline queue after a paused seek: VT decodes
  /// asynchronously on its own thread, so we feed video packets and poll the
  /// collected queue for a frame at/after the target (or EOF/timeout). Every
  /// poll PRUNES pre-target frames so the queue stays shallow on long-GOP
  /// files (otherwise decoding the keyframe->target window piles up a whole
  /// GOP of decoded frames before the target appears). Leaves the frame held
  /// by every sink; resume re-reads from pausedClock-0.05.
  ///
  /// A non-exact (scrubbing) preview shows the FIRST decoded frame — the
  /// keyframe at/before the target — which is one decode instead of a GOP's
  /// worth. The preview also yields as soon as another command is pending, so
  /// a drag's next position is never queued behind this one's decode.
  private func presentPausedPreview(target: Double, exact: Bool, demuxer: FFmpegDemuxer) {
    let deadline = CACurrentMediaTime() + 1.5
    while CACurrentMediaTime() < deadline, !hasPendingCommand {
      videoQueueLock.lock()
      // Drop pre-target frames each poll (keeps the queue bounded) and look
      // for a candidate at/after the target.
      if exact { videoQueue.removeAll { $0.pts < target - displaySlack } }
      videoQueue.sort { $0.pts < $1.pts }
      var frame: NativeVideoFrame?
      if let first = videoQueue.first, !exact || first.pts >= target - displaySlack {
        frame = first
        videoQueue.removeFirst()
      }
      videoQueueLock.unlock()
      if let frame {
        presentPausedFrame(frame)
        // Clear any extra decoded frames so resume re-reads the GOP cleanly
        // (no stale-burst presentation at the target).
        videoQueueLock.lock()
        videoQueue.removeAll()
        videoQueueLock.unlock()
        return
      }
      // Keep decoding forward from the keyframe until the target frame lands.
      guard let pkt = try? demuxer.readPacket() else { return }  // EOF before target
      if pkt.streamID == videoStreamIndex { feedVideoPacket(pkt) }
      usleep(1000)
    }
  }

  /// Present one frame to every sink (MainActor hop), bypassing the isPlaying
  /// gate so a paused seek previews the target frame. Updates lastPresentedPTS
  /// so a later resume continues from this frame with no pre-target replay.
  private func presentPausedFrame(_ frame: NativeVideoFrame) {
    lastPresentedPTS = frame.pts
    presentedFrames += 1
    let f = frame
    for s in snapshotSinks() { Task { @MainActor in s.present(frame: f) } }
  }

  /// Teardown shared by stop() (idle path) and the loop's .stop command.
  private func performStop() {
    generation &+= 1
    NSLog("[Native] stop")
    videoQueueLock.lock()
    videoQueueGeneration = generation  // keep the VT collector's gate in sync
    videoQueueLock.unlock()
    isPlaying = false
    isPaused = false
    isEnded = false
    hasMedia = false
    publishClock(0)
    audioClockOffset = 0
    pausedClock = 0
    discardAudioBefore = nil
    prematureEnd = nil
    drainDeadline = nil
    readEnd = nil
    // Per-file diagnostics restart with the file.
    videoPacketsRead = 0
    vtNonMonotonic = 0
    lastSubmittedPTS = nil
    summaryLastTime = 0
    // Per-file counters that must NOT survive a teardown. `audioContentEndNode`
    // anchors the audio clock to the scheduled content; a left-over value makes
    // the next file's audioSecondsAhead compute as `stale - 0` on a freshly
    // started node, tripping the audio-ahead backpressure gate on every tick so
    // video is never demuxed/presented — the "frozen last frame until pause and
    // unpause" bug (pause resets this to 0). `lastPresentedPTS` would otherwise
    // drop every frame of the new file (pts << stale value). Mirrors the resets
    // in pause()/performSeek()/performAudioSwitch(), and `play()` (a stop()
    // followed by play() without a re-open keeps the same node).
    audioContentEndNode = 0
    audioSourceExhausted = false
    resetVTCounters()
    lastPresentedPTS = nil
    videoQueueLock.lock()
    videoQueue.removeAll()
    videoQueueLock.unlock()
    if let vtSession {
      VTDecompressionSessionInvalidate(vtSession)
      self.vtSession = nil
    }
    if let audioEngine { audioEngine.stop() }
    audioEngine = nil
    audioPlayer = nil
    audioFormat = nil
    if let audioDecoder {
      media_audio_decoder_free(audioDecoder)
      self.audioDecoder = nil
    }
    clearPendingVideoPackets()
    clearSubtitleCues()
    subtitleCodec = ""
    vtFormatDesc = nil
    enhancementChain = nil
    enhancementLock.lock()
    downmixRoles = nil
    downmixMatrices = [:]
    enhancementLock.unlock()
    loudnessNormalizer = nil
    invalidateNodeClock()
    demuxer?.close()
    demuxer = nil
    videoStreamIndex = nil
    audioStreamIndex = nil
    publishAudioStream()
    subtitleStreamIndex = nil
    clearAllSinks()
  }

  /// True when the decoder must not be handed another frame: the decoded queue
  /// is at its target depth, or VideoToolbox already has too many frames in
  /// flight (past that point it drops what it cannot keep up with).
  private func videoFeedBlocked() -> Bool {
    if videoQueueDepth > maxDecodedVideoFrames { return true }
    return videoDecoderSaturated()
  }

  /// Feeds stashed video packets in order, while the decoder has room.
  ///
  /// STRICT ORDER IS MANDATORY: HEVC frames reference earlier frames in DECODE
  /// order (the container's packet order), so feeding a newly read packet ahead
  /// of an earlier stashed one corrupts the reference chain — VideoToolbox then
  /// answers kVTVideoDecoderMalfunctionErr (-12909) for every frame until the
  /// next IRAP and the picture stops. Measured on a 4K Main10 file: ~10 s of
  /// total decode failure followed by a short recovery, repeating (the file's
  /// IRAP spacing). The caller therefore stashes whenever this stash is still
  /// non-empty, never feeding "fresh" frames past it.
  private func feedPendingVideoPackets() {
    while !pendingVideoPackets.isEmpty, !videoFeedBlocked() {
      let pkt = pendingVideoPackets.removeFirst()
      pendingVideoSeconds = max(0, pendingVideoSeconds - stashSeconds(pkt))
      feedVideoPacket(pkt)
    }
  }

  /// Buffers one surplus video packet (compressed bytes only) for later decode.
  private func stashVideoPacket(_ pkt: DemuxPacket) {
    pendingVideoPackets.append(pkt)
    pendingVideoSeconds += stashSeconds(pkt)
  }

  /// Seconds of video one stashed packet represents (packet duration in the
  /// video stream time base; a frame duration fallback for unknown durations).
  private func stashSeconds(_ pkt: DemuxPacket) -> Double {
    guard pkt.duration > 0 else { return 1.0 / contentFps }
    return Double(pkt.duration) * Double(videoTB.num) / Double(videoTB.den)
  }

  private func clearPendingVideoPackets() {
    pendingVideoPackets.removeAll()
    pendingVideoSeconds = 0
  }

  private func feedVideoPacket(_ pkt: DemuxPacket) {
    guard let vtSession, let fd = vtFormatDesc else { return }
    // The packet's own duration when the container has one; 23.976 fps is
    // only the fallback for packets without it.
    let frameDur =
      pkt.duration > 0
      ? CMTime(value: pkt.duration * videoTB.num, timescale: videoTB.den)
      : CMTime(value: 1001, timescale: 24000)
    var timing = CMSampleTimingInfo(
      duration: frameDur, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    if pkt.pts != Int64.min {
      timing.presentationTimeStamp = CMTime(value: pkt.pts * videoTB.num, timescale: videoTB.den)
    } else if let last = lastPresentedPTS {
      timing.presentationTimeStamp = CMTime(
        seconds: last + frameDur.seconds, preferredTimescale: 24000)
    } else {
      timing.presentationTimeStamp = .zero
    }

    var block: CMBlockBuffer?
    // The block buffer OWNS its bytes (allocated here, packet copied in), so
    // its lifetime is the sample buffer's lifetime rather than the local
    // `Data`'s. Referencing the `Data` storage with `kCFAllocatorNull` is only
    // safe while decode is synchronous; when the session ran with
    // asynchronous decompression it decoded from dangling storage (measured:
    // `vterr` climbing at the content rate, video ~12 fps of 24).
    let n = pkt.data.count
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: n, flags: 0, blockBufferOut: &block) == noErr, let block
    else { return }
    let copied = pkt.data.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(
        with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: n)
    }
    guard copied == noErr else { return }

    var sbuf: CMSampleBuffer?
    var sampleSize = pkt.data.count
    guard
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize, sampleBufferOut: &sbuf) == noErr, let sbuf
    else { return }
    // Keep the sample buffer alive until the decoder's output callback fires:
    // the callback receives this holder as `sourceFrameRefCon` and releases
    // it. With the synchronous decode below that happens before DecodeFrame
    // returns; the holder keeps the lifetime correct should asynchronous
    // decompression ever be re-enabled (it once produced -12909 for every
    // frame whose sample buffer was freed mid-decode).
    if let last = lastSubmittedPTS, let t = pkt.ptsSeconds, t <= last {
      vtNonMonotonic += 1
    }
    lastSubmittedPTS = pkt.ptsSeconds
    let holder = VTSampleBufferHolder(sbuf)
    // Decode synchronously (no _EnableAsynchronousDecompression). Isolated
    // verification of this configuration — same file, same in-band parameter-set
    // recovery, same attributes — decodes 600/600 frames with zero failures
    // (Tests/NativePoC/VTDecode/hevc-decode-probe.swift). Synchronous decode
    // also keeps the sample-buffer lifetime trivially correct: the callback has
    // already run by the time this call returns.
    VTDecompressionSessionDecodeFrame(
      vtSession, sampleBuffer: sbuf, flags: [],
      frameRefcon: Unmanaged.passRetained(holder).toOpaque(), infoFlagsOut: nil)
    _ = holder  // the output callback releases it (sync: during the call above)
    videoQueueLock.lock()
    vtSubmitted += 1
    videoQueueLock.unlock()
  }

  private func feedAudioPacket(_ pkt: DemuxPacket) {
    guard let audioDecoder, let audioFormat, let engine = audioEngine, let player = audioPlayer
    else { return }

    var cpkt = MediaPacket()
    cpkt.stream_id = Int64(pkt.streamID)
    cpkt.pts = pkt.pts
    cpkt.dts = pkt.dts
    cpkt.duration = pkt.duration
    cpkt.keyframe = pkt.keyframe ? 1 : 0
    cpkt.skip_start = pkt.skipStart
    cpkt.skip_end = pkt.skipEnd
    // The bridge only reads the bytes during the call (libavcodec copies a
    // non-refcounted packet), so lend it the Data's storage — no malloc copy.
    let sent = pkt.data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      cpkt.data = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self))
      cpkt.size = raw.count
      return media_audio_decoder_send(audioDecoder, &cpkt) == MEDIA_RESULT_OK
    }
    guard sent else {
      if !audioSendFailedLogged {
        audioSendFailedLogged = true
        NSLog("[Native] audio decoder send failed (corrupt stream?)")
      }
      return
    }

    // Pull all available frames and schedule them.
    while engine.isRunning {
      var frame = MediaAudioFrame()
      let r = media_audio_decoder_receive(audioDecoder, &frame)
      if r == MEDIA_RESULT_EOF { break }
      if r != MEDIA_RESULT_OK { break }
      defer { media_audio_frame_free(&frame) }

      let n = Int(frame.nb_samples)
      let decodeChannels = Int(frame.channels)
      // Channel-count invariant (dialogue-enhancement plan, Task 8): the
      // decoder frame's channels must equal the track's source channel
      // count or the deinterleave/downmix below reads misaligned data.
      // (The old code silently broke 7.1 sources, which collapsed to a
      // 2-ch player format while the decoder emitted 8 channels. Note
      // the player format may legitimately differ — app-side downmix.)
      guard decodeChannels > 0, decodeChannels == audioSourceChannels else {
        if !audioFormatMismatchLogged {
          audioFormatMismatchLogged = true
          NSLog(
            "[Native] audio format mismatch: decoder %d ch vs source %d ch — buffer skipped",
            decodeChannels, audioSourceChannels)
        }
        continue
      }
      guard let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(n))
      else { continue }
      pcm.frameLength = AVAudioFrameCount(n)
      let outChannels = Int(audioFormat.channelCount)
      let interleaved = [Float](UnsafeBufferPointer(start: frame.data, count: n * decodeChannels))

      if let matrix = currentDownmixMatrix() {
        // App-side weighted downmix — the enhancement plan's sanctioned
        // custom stage (no stock mixer AU: AUMatrixMixer/
        // AUMultiChannelMixer render silence in real-time graphs on this
        // SDK — see AudioEnhancementChain header). Vectorized with vDSP
        // directly on the interleaved data (stride = channel count);
        // runs in the demux loop, OFF the realtime thread.
        for outCh in 0..<2 {
          guard let dst = pcm.floatChannelData?[outCh] else { continue }
          vDSP_vclr(dst, 1, vDSP_Length(n))
          for (inCh, row) in matrix.enumerated() where row[outCh] != 0 {
            var coeff = row[outCh]
            interleaved.withUnsafeBufferPointer { src in
              vDSP_vsma(
                src.baseAddress!.advanced(by: inCh), decodeChannels, &coeff, dst, 1, dst, 1,
                vDSP_Length(n))
            }
          }
        }
      } else {
        // Passthrough maps channel-for-channel; a mono source feeds both
        // stereo channels (audioRoute guarantees outChannels == decodeChannels
        // except for that case).
        for ch in 0..<outChannels {
          guard let dst = pcm.floatChannelData?[ch] else { continue }
          let src = min(ch, decodeChannels - 1)
          for i in 0..<n { dst[i] = interleaved[i * decodeChannels + src] }
        }
      }
      // Loudness normalization (measures always; scales when enabled). Boost
      // only when the chain's limiter follows; multichannel passthrough has
      // no chain, so it can only be cut there.
      if let normalizer = loudnessNormalizer {
        normalizer.process(
          pcm, frames: n, enabled: normalizationEnabled(),
          maxBoostDB: enhancementChain != nil ? LoudnessNormalizer.maxBoostDB : 0)
        loudnessLogFrames += n
        if Double(loudnessLogFrames) >= 10 * playerFormatSampleRate() {
          loudnessLogFrames = 0
          NSLog(
            "[Audio] loudness %.1f LUFS, normalization gain %+.1f dB",
            normalizer.meter.integratedLoudness ?? -.infinity, normalizer.gainDB)
        }
      }
      // Land this content on the node's timeline before scheduling it: if the
      // node has already run past the previously scheduled content, it was
      // starved and the media clock held at the content end (see currentClock).
      // Re-anchoring here makes the resuming content continue the media
      // timeline instead of landing a starvation further behind it.
      let nodeNow = nodeSeconds(player: player) ?? 0
      reanchorAudioClockIfStarved(nodeNow: nodeNow)
      player.scheduleBuffer(pcm, at: nil)
      audioContentEndNode = max(audioContentEndNode, nodeNow) + Double(n) / playerFormatSampleRate()
    }
  }

  /// Called from feedAudioPacket for every PCM frame scheduled (pipeline queue).
  ///
  /// `audioContentEndNode` is the node-time at which the scheduled audio runs
  /// out. When the node has already passed it the node was STARVED: the media
  /// clock (currentClock) held at the content end while the node's own clock ran
  /// on through silence. Shifting the offset by the starved duration moves the
  /// media timeline's mapping so the content resuming now continues from the
  /// held position — leaving the offset alone would place it exactly one
  /// starvation behind the picture, forever (the accumulating audio-delay bug).
  private func reanchorAudioClockIfStarved(nodeNow: Double) {
    guard nodeNow > audioContentEndNode else { return }
    let starved = nodeNow - audioContentEndNode
    // A gap far longer than a decode warm-up (or a dead audio pipeline): the
    // media clock already ran on because currentClock released the clamp at
    // audioStarveHoldMaxSeconds, so re-anchoring here would jump the timeline
    // BACKWARDS. Leave the mapping alone — this is the pre-clamp behavior, and
    // the only case where the audio really can end up behind the picture.
    if starved >= audioStarveHoldMaxSeconds {
      NSLog("[Native] audio starved %.1fs — clock left free-running (no re-anchor)", starved)
      return
    }
    audioClockOffset -= starved
    audioStarvedSeconds += starved
    audioStarvedWindow += starved
    NSLog(
      "[Native] audio starved %.3fs — clock re-anchored (offset %.3f, held total %.3f)",
      starved, audioClockOffset, audioStarvedSeconds)
  }

  /// The sample rate the scheduled PCM runs at (the player format's rate).
  private func playerFormatSampleRate() -> Double {
    audioFormat?.sampleRate ?? 48000
  }

  /// Seconds of audio currently scheduled ahead of the player's position.
  /// Negative = the node is STARVED (the clock clamp in currentClock is holding
  /// the media timeline while the node renders silence) — the honest starvation
  /// signal, logged as `aud=` in the 1 s summary.
  private func audioSecondsAhead(player: AVAudioPlayerNode) -> Double {
    // Same allocation-avoidance as currentClock(): read the node clock
    // through the per-tick cache instead of calling playerTime directly.
    let played = nodeSeconds(player: player) ?? 0
    return audioContentEndNode - played
  }

  /// Player-node time in seconds via the per-iteration cache (one
  /// playerTime(forNodeTime:) call per loop iteration at most; nil when the
  /// node hasn't started or has no render time yet).
  private func nodeSeconds(player: AVAudioPlayerNode) -> Double? {
    nodeClockLock.lock()
    defer { nodeClockLock.unlock() }
    if !nodeClockDirty, let cached = cachedNodeSeconds { return cached }
    nodeClockDirty = false
    guard let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime)
    else {
      cachedNodeSeconds = nil
      return nil
    }
    cachedNodeSeconds = Double(pt.sampleTime) / pt.sampleRate
    return cachedNodeSeconds
  }

  // MARK: - Presentation

  /// Called on the pipeline queue at ~each demux tick: presents frames whose
  /// PTS is within the clock (audio master, else monotonic).
  private func presentDueFrames() {
    guard isPlaying else { return }
    let clock = currentClock()
    publishClock(clock)
    videoQueueLock.lock()
    // Reorder by PTS (VT emits decode order with B-frames).
    videoQueue.sort { $0.pts < $1.pts }
    var toPresent: [NativeVideoFrame] = []
    while let first = videoQueue.first, first.pts <= clock + displaySlack {
      toPresent.append(first)
      videoQueue.removeFirst()
    }
    videoQueueLock.unlock()

    for frame in toPresent {
      if let last = lastPresentedPTS, frame.pts < last - 0.001 {
        droppedFrames += 1
        continue
      }
      lastPresentedPTS = frame.pts
      presentedFrames += 1
      summaryPresented += 1
      summaryDrift = frame.pts - clock
      // Diagnostic cadence: log every 60th presented frame.
      if presentedFrames % 60 == 1 {
        NSLog(
          "[Native] presented frame %d at pts=%.3f clock=%.3f (dropped=%d qdepth=%d)",
          presentedFrames, frame.pts, clock, droppedFrames, videoQueueDepth)
      }
      let f = frame
      let sinks = snapshotSinks()
      for s in sinks { Task { @MainActor in s.present(frame: f) } }
    }
    flushSummaryIfDue(clock: clock)
  }

  /// Emits one aggregate health line per second instead of per-frame spam:
  /// achieved fps vs the content target, drops in the window, sync drift of
  /// the last presented frame, video queue depth, demux packet rate, and
  /// audio scheduled ahead. This is the primary live-problem indicator.
  private func flushSummaryIfDue(clock: Double) {
    let now = CACurrentMediaTime()
    if summaryLastTime == 0 {
      summaryLastTime = now
      summaryDroppedBase = droppedFrames
      summaryPresented = 0
      summaryPackets = 0
      return
    }
    let dt = now - summaryLastTime
    guard dt >= 1.0 else { return }
    // Decoder/scheduler split for the window, plus the queue's pts relation to
    // the clock: `qhead`/`qtail` are the queued frames' pts minus the clock
    // (negative = overdue but not presented, positive = waiting for the clock).
    // An empty queue logs `empty`.
    videoQueueLock.lock()
    let head = videoQueue.map { $0.pts }.min()
    let tail = videoQueue.map { $0.pts }.max()
    let vtR = vtReturned
    let vtS = vtStale
    videoQueueLock.unlock()
    let sub = max(0, vtSubmitted - summaryVTSubmitted)
    let ret = max(0, vtR - summaryVTReturned)
    let headStr = head.map { String(format: "%+.3f", $0 - clock) } ?? "empty"
    let tailStr = tail.map { String(format: "%+.3f", $0 - clock) } ?? "empty"
    NSLog(
      "[Native] 1s pos=%.3f fps=%.1f/%.2f drop=%d drift=%+.3f vq=%d qhead=%@ qtail=%@ pkt=%d vid=%d aud=%.2fs starve=%.2fs sub=%d ret=%d nonmono=%d vtdrop=%d vterr=%d stale=%d (mode=%@ ch=%d)",
      clock, Double(summaryPresented) / dt, contentFps, droppedFrames - summaryDroppedBase,
      summaryDrift, videoQueueDepth, headStr, tailStr, summaryPackets, videoPacketsRead,
      audioSecondsAheadNow(), audioStarvedWindow, sub, ret, vtNonMonotonic, vtDropped, vtErrors,
      vtS, currentMode().rawValue, audioFormat?.channelCount ?? 0)
    summaryLastTime = now
    summaryPresented = 0
    summaryPackets = 0
    summaryDroppedBase = droppedFrames
    summaryVTSubmitted = vtSubmitted
    summaryVTReturned = vtR
    audioStarvedWindow = 0
  }

  /// Seconds of audio scheduled ahead of the player (0 when no audio engine).
  private func audioSecondsAheadNow() -> Double {
    guard let player = audioPlayer else { return 0 }
    return audioSecondsAhead(player: player)
  }

  private func currentClock() -> Double {
    // While paused the clock is FROZEN at the captured position. Reading
    // a live clock here (audio playerTime or monotonic) would keep the
    // position/timer advancing during a pause.
    if isPaused { return pausedClock }
    if clockBaseAudio, let player = audioPlayer, let nodeSeconds = nodeSeconds(player: player) {
      // Clamp to the scheduled audio content. The player node's clock free-runs
      // through a starvation (its render callback keeps producing silence), so
      // without this every starved second would slide the audio that far behind
      // the clock — and the video with it, permanently. Holding at the content
      // end freezes the media timeline instead; feedAudioPacket (reanchor, below)
      // shifts the offset when feeding resumes so playback continues from the
      // held position rather than behind it.
      if !audioSourceExhausted, audioContentEndNode > 0,
        nodeSeconds > audioContentEndNode + 0.002,
        nodeSeconds - audioContentEndNode < audioStarveHoldMaxSeconds
      {
        return audioContentEndNode + audioClockOffset
      }
      return nodeSeconds + audioClockOffset
    }
    return CACurrentMediaTime() - startMonotonic
  }

  /// MainActor-safe clock read (see NativeSomePlayer.refreshFromController):
  /// the value the pipeline last published (every tick, pause and seek).
  /// Computing the clock here would read the audio node and pipeline-owned
  /// fields from the main thread.
  func currentClockSafe() -> Double { withState { _publishedClock } }

  // MARK: - Subtitles (SRT Phase A)

  /// Parses a subtitle packet into a cue. SubRip packets in MKV carry the
  /// plain text (with SRT markup stripped); ASS/SSA packets carry the event
  /// fields in front of the text. Timing comes from pts/duration in the
  /// packet's stream time base.
  private func collectSubtitlePacket(_ pkt: DemuxPacket) {
    guard let start = pkt.ptsSeconds,
      let text = Self.subtitleText(from: pkt.data, codec: subtitleCodec)
    else { return }
    let cue = SubtitleCue(start: start, end: start + (pkt.durationSeconds ?? 2.0), text: text)
    subtitleCuesLock.lock()
    let inserted = Self.insertCue(cue, into: &subtitleCues)
    let count = subtitleCues.count
    subtitleCuesLock.unlock()
    // Diagnostic: log the first few cues.
    if inserted, count <= 4 {
      NSLog("[Native] subtitle cue %.3f-%.3f: %@", cue.start, cue.end, cue.text)
    }
  }

  /// Display text of one subtitle packet, or nil when there is nothing to show
  /// (empty, undecodable, or a codec the overlay cannot render).
  static func subtitleText(from data: Data, codec: String) -> String? {
    let codec = codec.lowercased()
    guard isSupportedSubtitleCodec(codec),
      var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    else { return nil }
    if codec == "ass" || codec == "ssa" {
      // Matroska ASS block: ReadOrder,Layer,Style,Name,MarginL,MarginR,
      // MarginV,Effect,Text — the text is everything after the 8th comma (it
      // may itself contain commas). A full "Dialogue:" line has 9 fields
      // before the text.
      let isDialogueLine = text.hasPrefix("Dialogue:")
      let fields = text.split(
        separator: ",", maxSplits: isDialogueLine ? 9 : 8, omittingEmptySubsequences: false)
      text = fields.count > (isDialogueLine ? 9 : 8) ? String(fields.last!) : ""
      // Override blocks ({\i1}, {\pos(..)}) and ASS escapes.
      text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
      text = text.replacingOccurrences(of: "\\N", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\h", with: " ")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// Inserts `cue` keeping `cues` sorted by start time, skipping an exact
  /// duplicate. A backward seek, a resume rewind or a track re-seek re-reads
  /// packets that were already collected; appending them used to leave the
  /// array unsorted and full of duplicates, and the binary search in
  /// `activeCue` then missed cues (subtitles vanished after seeking back).
  /// Returns false when the cue was already present.
  @discardableResult
  static func insertCue(_ cue: SubtitleCue, into cues: inout [SubtitleCue]) -> Bool {
    var lo = 0
    var hi = cues.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if cues[mid].start <= cue.start { lo = mid + 1 } else { hi = mid }
    }
    // `lo` is the first index with a later start; equal starts sit before it.
    var i = lo - 1
    while i >= 0, cues[i].start == cue.start {
      if cues[i] == cue { return false }
      i -= 1
    }
    cues.insert(cue, at: lo)
    return true
  }

  /// The cue on screen at `time` in start-sorted `cues`: the latest-starting
  /// cue that has started and not yet ended. Looks back a few cues so a long
  /// cue overlapped by a shorter later one is still found.
  static func activeCue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
    var lo = 0
    var hi = cues.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if cues[mid].start <= time { lo = mid + 1 } else { hi = mid }
    }
    var i = lo - 1
    var checked = 0
    while i >= 0, checked < 8 {
      if time <= cues[i].end { return cues[i] }
      i -= 1
      checked += 1
    }
    return nil
  }

  /// Active subtitle cue at `time` (seconds), or nil when subtitles are off
  /// or none is active. MainActor-safe read.
  func subtitleCue(at time: Double) -> SubtitleCue? {
    subtitleCuesLock.lock()
    defer { subtitleCuesLock.unlock() }
    return Self.activeCue(at: time, in: subtitleCues)
  }

  /// Clears collected cues (track switch / seek).
  private func clearSubtitleCues() {
    subtitleCuesLock.lock()
    subtitleCues.removeAll()
    subtitleCuesLock.unlock()
  }

  // MARK: - Track switching

  /// Switches the active audio stream. Flushes the audio decoder, builds a
  /// new one for the target stream, re-seeks to the current position (plan
  /// section 19). Delivered via the command mailbox so it runs inside the
  /// demux loop.
  func selectAudioTrack(streamIndex: Int) { submit(.switchAudio(streamIndex)) }

  private func performAudioSwitch(streamIndex: Int, demuxer: FFmpegDemuxer) {
    guard streamIndex != audioStreamIndex else { return }
    // Validate BEFORE tearing anything down: switching to a track the build
    // cannot decode used to free the working decoder first and leave the
    // file silent with no error.
    guard let track = demuxer.track(at: streamIndex),
      track.type == MEDIA_TRACK_TYPE_AUDIO.rawValue, Self.isSupportedAudioCodec(track.codecName)
    else {
      NSLog("[Native] audio switch to stream %d refused (not a decodable audio track)", streamIndex)
      stateChanged()
      return
    }
    // The position must be read before the node is reset below: afterwards
    // the node clock restarts at 0 and currentClock() would report the last
    // seek/pause anchor instead, jumping playback back to it.
    let current = currentClock()
    let previous = audioStreamIndex

    generation &+= 1
    let gen = generation
    videoQueueLock.lock()
    videoQueue.removeAll()
    videoQueueGeneration = gen  // in-flight frames from the old stream are stale
    videoQueueLock.unlock()
    clearPendingVideoPackets()
    // Flush the old audio decoder + scheduled buffers.
    if let audioDecoder {
      media_audio_decoder_free(audioDecoder)
      self.audioDecoder = nil
    }
    audioContentEndNode = 0
    if let player = audioPlayer {
      player.stop()
      player.reset()
    }
    invalidateNodeClock()
    do {
      try setupAudio(streamIndex: streamIndex)
      audioStreamIndex = streamIndex
      NSLog("[Native] audio track switched to stream %d", streamIndex)
    } catch {
      // Keep the file audible: fall back to the stream that was playing.
      NSLog("[Native] audio switch to stream %d failed; restoring %d", streamIndex, previous ?? -1)
      if let previous, (try? setupAudio(streamIndex: previous)) != nil {
        audioStreamIndex = previous
      } else {
        audioStreamIndex = nil
      }
    }
    publishAudioStream()
    // Re-seek so both pipelines restart at the current position.
    lastPresentedPTS = current
    _ = try? demuxer.seek(to: current)
    discardAudioBefore = current
    startMonotonic = CACurrentMediaTime() - current
    audioClockOffset = current
    clockBaseAudio = audioPlayer != nil && audioDecoder != nil
    if isPaused {
      pausedClock = current
      audioIsRunning = false
    } else {
      // Restart the node so the new stream's buffers actually play.
      restartAudioPlayer()
    }
    stateChanged()
  }

  /// Enables/disables the subtitle stream. Clears collected cues and
  /// re-seeks so cues are re-collected from the new stream's packets.
  func selectSubtitleTrack(streamIndex: Int?) { submit(.switchSubtitle(streamIndex)) }

  private func performSubtitleSwitch(streamIndex: Int?, demuxer: FFmpegDemuxer) {
    // No-op when the subtitle state isn't actually changing (e.g. the
    // partial-download retry re-applies an already-off preference). Without
    // this the re-seek below runs once per open for a permanently-off subtitle.
    // Only text subtitles can be rendered; anything else is treated as off.
    var streamIndex = streamIndex
    var codec = ""
    if let index = streamIndex {
      if let track = demuxer.track(at: index), track.type == MEDIA_TRACK_TYPE_SUBTITLE.rawValue,
        Self.isSupportedSubtitleCodec(track.codecName)
      {
        codec = track.codecName
      } else {
        NSLog("[Native] subtitle stream %d is not a text subtitle track — off", index)
        streamIndex = nil
      }
    }
    guard streamIndex != subtitleStreamIndex else { return }
    clearSubtitleCues()
    subtitleStreamIndex = streamIndex
    subtitleCodec = codec
    // The seek below re-positions the demuxer BACKWARD to a keyframe, so the
    // loop re-reads VIDEO from the keyframe before the target. Reset video
    // presentation state (mirror of performSeek) so that window is dropped
    // instead of re-plays or stalling: a stale lastPresentedPTS would drop
    // every re-decoded frame in the keyframe..target window (pts < last), and
    // the still-queued pre-switch frames would replay. discardAudioBefore
    // (below) keeps the audio side from backlogging.
    generation &+= 1
    let gen = generation
    videoQueueLock.lock()
    videoQueue.removeAll()
    videoQueueGeneration = gen
    videoQueueLock.unlock()
    clearPendingVideoPackets()
    do {
      let current = currentClock()
      lastPresentedPTS = current
      try demuxer.seek(to: current)
      // The demuxer re-seeks BACKWARD to a keyframe (GOP-granular, ~10 s on
      // this corpus), so the loop re-reads VIDEO and AUDIO from that
      // keyframe. Without this guard every pre-target audio packet
      // (keyframe -> current) is re-decoded and re-scheduled, ballooning
      // audioSecondsAhead far past the maxAudioAheadSeconds cap — the demux
      // loop then spends every tick in the audio backpressure sleep
      // (usleep(4000); return) instead of reading video or presenting
      // frames. That is the "serious fps drop until I pause and unpause":
      // pause resets the node + audioFramesScheduled=0, and resume rewinds
      // the demuxer to pausedClock and re-arms discardAudioBefore, clearing
      // the backlog. Mirrors performSeek / performAudioSwitch.
      discardAudioBefore = current
      NSLog("[Native] subtitle track set to %@", streamIndex.map(String.init) ?? "off")
    } catch { stateChanged() }
  }

  // MARK: - EOF

  /// One step of the EOF drain (~plan §30: display the final frames and let
  /// the scheduled audio play out, then transition to ended). Returns true
  /// while the drain window is still open.
  private func drainStep() -> Bool {
    guard clockBaseAudio, audioEngine != nil else { return false }
    let now = CACurrentMediaTime()
    if drainDeadline == nil {
      NSLog("[Native] EOF drain (audio plays out)")
      drainDeadline = now + 2.0
    }
    guard let deadline = drainDeadline, now < deadline else { return false }
    presentDueFrames()
    usleep(8000)
    return true
  }

  /// Ends a drained session. Runs after the loop has given up the queue
  /// (tryExitLoop), so the demuxer stays open for a later seek/replay.
  private func finishPlayback() {
    drainDeadline = nil
    // Audio played out; stop its render thread (same cost as pause).
    pauseAudioEngine()
    isPlaying = false
    isEnded = true
    stateChanged()
  }

  private func stateChanged() {
    guard let onMain else { return }
    Task { @MainActor in onMain() }
  }

  // MARK: - Metrics

  struct Metrics {
    let presented: Int
    let dropped: Int
    let queueDepth: Int
  }

  var metrics: Metrics {
    videoQueueLock.lock()
    defer { videoQueueLock.unlock() }
    return Metrics(presented: presentedFrames, dropped: droppedFrames, queueDepth: videoQueue.count)
  }

  /// Queue depth for diagnostics (read under the lock).
  private var videoQueueDepth: Int {
    videoQueueLock.lock()
    defer { videoQueueLock.unlock() }
    return videoQueue.count
  }
}

/// Owns the retain that keeps one submitted sample buffer alive until the
/// decoder's output callback runs. Submission `passRetained`s one of these
/// and the output callback `release`s it, so the sample buffer (and the block
/// buffer's bytes) cannot be deallocated mid-decode. Decode is currently
/// synchronous, so the callback always runs before submission returns; under
/// asynchronous decode a frame the decoder never reports on (session
/// invalidated by a seek) would leak one holder, bounded by the in-flight limit.
final class VTSampleBufferHolder {
  let sampleBuffer: CMSampleBuffer
  init(_ sampleBuffer: CMSampleBuffer) { self.sampleBuffer = sampleBuffer }
}

/// Retains the VT callback closure context.
final class VideoCollectorBox {
  let onFrame: (NativeVideoFrame) -> Void
  /// Called for EVERY output callback (before the frame is filtered), with the
  /// decode status, info flags and presentation time, so the engine can account
  /// for frames the decoder dropped or failed on. Without this the client
  /// cannot tell "the decoder is behind" from "the decoder discarded what I
  /// gave it" — the difference between a slow stream and a starving pipeline.
  let onOutcome: (OSStatus, VTDecodeInfoFlags, Double) -> Void
  init(
    onFrame: @escaping (NativeVideoFrame) -> Void,
    onOutcome: @escaping (OSStatus, VTDecodeInfoFlags, Double) -> Void
  ) {
    self.onFrame = onFrame
    self.onOutcome = onOutcome
  }
}

// MARK: - FFmpegDemuxer handle escape (internal to the native engine)

extension FFmpegDemuxer {
  /// The raw C handle. Only the PlaybackController touches it, and only on
  /// the pipeline queue. Exposed via a separate extension to keep the
  /// demuxer API clean for other callers.
  var unsafeHandle: UnsafeMutablePointer<MediaDemuxer>? { handle }
}
