import AVFoundation
import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import SomePlayerCDemux
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
struct SubtitleCue {
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
public final class PlaybackController {
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

  private let pipelineQueue = DispatchQueue(label: "Player.native-pipeline", qos: .userInitiated)
  private let probeQueue = DispatchQueue(label: "Player.native-probe", qos: .userInitiated)
  private var generation: UInt64 = 0

  // Command mailbox (transport fix): the demux loop OWNS pipelineQueue
  // while playing, so pause/seek/stop/track-switch must be delivered via a
  // lock-protected FIFO the loop polls every iteration — enqueueing them on
  // pipelineQueue deadlocks behind the spinning loop.
  private enum PipelineCommand {
    case pause
    case resume
    case seek(Double)
    case switchAudio(Int)
    case switchSubtitle(Int?)
    case stop
  }
  private let commandLock = NSLock()
  private var commandQueue: [PipelineCommand] = []
  private let commandSignal = DispatchSemaphore(value: 0)
  private var loopRunning = false

  private func submit(_ cmd: PipelineCommand) {
    commandLock.lock()
    commandQueue.append(cmd)
    commandLock.unlock()
    commandSignal.signal()
  }

  private func takeCommand() -> PipelineCommand? {
    commandLock.lock()
    defer { commandLock.unlock() }
    return commandQueue.isEmpty ? nil : commandQueue.removeFirst()
  }

  private var isLoopRunning: Bool {
    commandLock.lock()
    defer { commandLock.unlock() }
    return loopRunning
  }

  private var demuxer: FFmpegDemuxer?
  private var videoStreamIndex: Int?
  private var audioStreamIndex: Int?
  private var subtitleStreamIndex: Int?
  private var videoTB: (num: Int64, den: Int32) = (1, 1000)

  // Subtitle cues (SRT Phase A): parsed from subtitle-stream packets.
  private var subtitleCues: [SubtitleCue] = []
  private var subtitleCuesLock = NSLock()

  // Video decode
  private var vtSession: VTDecompressionSession?
  private var vtFormatDesc: CMVideoFormatDescription?
  private var pendingVideoPackets: [DemuxPacket] = []
  /// Retains the VT output-callback context (the collector box must live
  /// as long as the session).
  private var videoCollectorBox: VideoCollectorBox?

  // Audio decode + output
  private var audioDecoder: UnsafeMutablePointer<MediaAudioDecoder>?
  private var audioEngine: AVAudioEngine?
  private var audioPlayer: AVAudioPlayerNode?
  private var audioFormat: AVAudioFormat?
  private var audioFramesScheduled = 0  // samples ahead of clock
  private var audioBytesPerFrame: Int = 0
  private var audioIsRunning = false
  /// The channel count the audio DECODER emits for the current track (the
  /// player format's channel count differs when the source is being
  /// downmixed app-side to stereo). The buffer-fill invariant compares
  /// decoded frames against THIS, not the player format.
  private var audioSourceChannels = 0

  // Audio enhancement (dialogue modes). The mode and the downmix tables are
  // read per decoded frame from the pipeline queue and written from the
  // main thread (menu selection), so they live behind a lock. The chain
  // pointer itself follows the codebase's existing cross-thread reference
  // pattern (audioEngine/audioPlayer are read on main the same way).
  private let enhancementLock = NSLock()
  private var enhancementMode: AudioEnhancementMode = .original
  private var enhancementChain: AudioEnhancementChain?
  /// Source roles when the multichannel source is being downmixed app-side
  /// to stereo (stereo output device); nil otherwise.
  private var downmixRoles: [ChannelRole]?
  /// Precomputed Nx2 matrices per mode (original/balanced/dialogue) for the
  /// current source layout — buffer fill picks a matrix by mode with no
  /// per-sample math.
  private var downmixMatrices: [AudioEnhancementMode: [[Float]]] = [:]
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
    guard let roles = downmixRoles, roles.count > 2 else { return nil }
    return downmixMatrices[enhancementMode]
  }

  /// Sets the enhancement mode (UI entry). Parameter-only when the chain is
  /// live — no graph changes, no restart, pop-free (the plan's runtime
  /// switching requirement); stashed and applied at the next setupAudio when
  /// no chain exists yet (mode picked before open / after stop).
  func setEnhancementMode(_ mode: AudioEnhancementMode) {
    enhancementLock.lock()
    enhancementMode = mode
    enhancementLock.unlock()
    if let chain = enhancementChain {
      chain.apply(preset: AudioEnhancementPreset.preset(for: mode))
    }
    NSLog("[Native] enhancement mode: %@", mode.rawValue)
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

  /// Published state (read from MainActor).
  private(set) var isPlaying = false
  private(set) var isPaused = false

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

  /// Sets the frame sink list (MainActor) and a callback run on MainActor
  /// after each state change. Registering the same view twice is a no-op.
  func configure(
    sink: (any VideoFrameSink)?, onStateChange: (@MainActor () -> Void)?,
    onPartialEnd: (@MainActor (_ position: Double, _ wasError: Bool) -> Void)? = nil
  ) {
    if let sink { registerSink(sink) }
    if onStateChange != nil { self.onMain = onStateChange }
    // Only overwrite when provided: `registerSink` re-calls configure with no
    // onPartialEnd (a default nil), which would otherwise clobber the one set
    // at engine init.
    if onPartialEnd != nil { self.onPartialEnd = onPartialEnd }
  }

  private func registerSink(_ sink: any VideoFrameSink) {
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

  private func clearAllSinks() {
    sinkLock.lock()
    let sinks = snapshotSinksLocked()
    sinkBoxes.removeAll()
    sinkLock.unlock()
    for s in sinks { Task { @MainActor in s.clear() } }
  }

  private func snapshotSinksLocked() -> [any VideoFrameSink] { sinkBoxes.compactMap { $0.sink } }

  // MARK: - Open

  /// Opens + probes the file. Stops any running pipeline first (so the
  /// probe can take over the demuxer slot), then runs the synchronous probe
  /// on the dedicated probe queue. Returns media info (MainActor-safe
  /// values only).
  func open(_ url: URL) async throws -> NativeMediaInfo {
    stop()
    return try await withCheckedThrowingContinuation { cont in
      probeQueue.async { [weak self] in
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
    var audio: NativeTrackInfo?
    var subtitle: NativeTrackInfo?
    var all: [NativeTrackInfo] = []
    for i in 0..<demuxer.trackCount {
      guard let t = demuxer.track(at: i) else { continue }
      all.append(t)
      switch t.type {
      case MEDIA_TRACK_TYPE_VIDEO.rawValue where video == nil: video = t
      case MEDIA_TRACK_TYPE_AUDIO.rawValue where audio == nil: audio = t
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
    // Supported audio codecs (decoders compiled into the FFmpeg build):
    // DTS/dca, Dolby Digital (ac3) and Dolby Digital Plus (eac3).
    if let audio,
      audio.codecName != "dts" && audio.codecName != "dca" && audio.codecName != "ac3"
        && audio.codecName != "eac3"
    {
      throw NativePlayerError.unsupportedAudioCodec(audio.codecName)
    }

    self.videoStreamIndex = video.id
    self.audioStreamIndex = audio?.id
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
    return NativeMediaInfo(
      duration: demuxer.duration, video: video, audio: audio, allTracks: all, chapters: chapters)
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
      let ordered = par.vps + par.sps + par.pps
      var ptrs: [UnsafePointer<UInt8>] = []
      var sizes: [Int] = []
      for n in ordered {
        n.withUnsafeBufferPointer {
          ptrs.append($0.baseAddress!)
          sizes.append(n.count)
        }
      }
      var fd: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count,
        parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
        nalUnitHeaderLength: Int32(par.lengthSize), extensions: nil,
        formatDescriptionOut: &fd)
      guard status == noErr, let fd else { throw NativePlayerError.videoDecoderFailed }
      vtFormatDesc = fd
      try setupVTCommon(formatDesc: fd)
    } else {
      // H.264: avcC (AVCDecoderConfigurationRecord).
      let avcc = parseAVCC(bytes)
      guard !avcc.sps.isEmpty, !avcc.pps.isEmpty else {
        throw NativePlayerError.videoDecoderFailed
      }
      var ptrs: [UnsafePointer<UInt8>] = []
      var sizes: [Int] = []
      for n in avcc.sps + avcc.pps {
        n.withUnsafeBufferPointer {
          ptrs.append($0.baseAddress!)
          sizes.append(n.count)
        }
      }
      var fd: CMVideoFormatDescription?
      let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count,
        parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
        nalUnitHeaderLength: Int32(avcc.lengthSize), formatDescriptionOut: &fd)
      guard status == noErr, let fd else { throw NativePlayerError.videoDecoderFailed }
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
    // Collector box: VT callback fills the queue on VT's thread.
    let box = VideoCollectorBox { [weak self] frame in
      guard let self else { return }
      self.videoQueueLock.lock()
      if self.videoQueueGeneration == self.generation { self.videoQueue.append(frame) }
      self.videoQueueLock.unlock()
    }
    var cbRecord = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, _ in
        guard status == noErr, let imageBuffer else { return }
        let box = Unmanaged<VideoCollectorBox>.fromOpaque(refCon!).takeUnretainedValue()
        let pb = imageBuffer
        let t = CMTimeGetSeconds(pts)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let frame = NativeVideoFrame(pts: t, pixelBuffer: pb)
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        box.onFrame(frame)
      }, decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())

    var session: VTDecompressionSession?
    // Output pixel buffers at the CODEC's native dimensions (from the
    // format description). Previously hardcoded 1920x816 — VideoToolbox then
    // SCALED every stream to 1920x816, which squeezed 16:9 content into a
    // 2.35:1 aspect. Coded dims keep the rendered aspect correct for every
    // file, HEVC or H.264. HEVC 10-bit sources are requested as 8-bit limited
    // range (VideoToolbox downconverts); the Metal shader's 8-bit BT.709 math
    // applies unchanged. To preserve 10-bit later, request
    // 420YpCbCr10BiPlanarVideoRange and update the shader to 1023-based math.
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

  private func setupAudio(streamIndex: Int) throws {
    guard let demuxer else { throw NativePlayerError.audioDecoderFailed }
    guard let dec = media_audio_decoder_create(demuxer.unsafeHandle, Int32(streamIndex)) else {
      throw NativePlayerError.audioDecoderFailed
    }
    audioDecoder = dec

    guard let track = demuxer.track(at: streamIndex) else {
      throw NativePlayerError.audioDecoderFailed
    }
    audioSourceChannels = track.channelCount
    let tag: AudioChannelLayoutTag =
      (track.layoutName == "5.1(side)")
      ? kAudioChannelLayoutTag_MPEG_5_1_B
      : (track.layoutName == "5.1")
        ? kAudioChannelLayoutTag_MPEG_5_1_A : kAudioChannelLayoutTag_Unknown
    let layout: AVAudioChannelLayout
    if tag != kAudioChannelLayoutTag_Unknown, let l = AVAudioChannelLayout(layoutTag: tag) {
      layout = l
    } else if let l = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_B),
      track.channelCount == 6
    {
      layout = l
    } else {
      layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
    }
    let sourceFormat = AVAudioFormat(
      standardFormatWithSampleRate: Double(track.sampleRate), channelLayout: layout)

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)

    // --- Audio enhancement (dialogue modes) ---
    // Channel roles come from the FFmpeg native mask; the output-device
    // channel count decides whether the multichannel source stays
    // multichannel (passthrough) or is downmixed app-side to stereo.
    // CHANNEL-COUNT INVARIANT (plan Task 8): the player format's channel
    // count must equal the decoder frame's channels — the selection below
    // always yields either the exact source channel count or an explicit
    // stereo downmix format.
    let roles = track.layoutMask != 0 ? ChannelRoleMap.roles(forMask: track.layoutMask) : nil
    let deviceChannels = engine.outputNode.outputFormat(forBus: 0).channelCount
    // roles.count == channelCount sanity: FFmpeg guarantees mask bitcount ==
    // channels, but degrade to passthrough if a layout ever disagrees.
    let needsDownmix =
      roles != nil && roles!.count == track.channelCount && Int(deviceChannels) < track.channelCount
    let playerFormat: AVAudioFormat
    if needsDownmix, let roles {
      playerFormat = AVAudioFormat(
        standardFormatWithSampleRate: Double(track.sampleRate), channels: 2)!
      enhancementLock.lock()
      downmixRoles = roles
      downmixMatrices = Dictionary(
        uniqueKeysWithValues: AudioEnhancementMode.allCases.map { mode in
          (
            mode,
            DownmixMatrix.coefficients(
              roles: roles, centerGainDB: AudioEnhancementPreset.preset(for: mode).centerGainDB)!
          )
        })
      enhancementLock.unlock()
      NSLog(
        "[Audio] downmix %d ch -> stereo (device %d ch) roles=%@", track.channelCount,
        deviceChannels, String(describing: roles))
    } else {
      playerFormat = sourceFormat
      enhancementLock.lock()
      downmixRoles = nil
      downmixMatrices = [:]
      enhancementLock.unlock()
    }
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
      chain.apply(preset: AudioEnhancementPreset.preset(for: mode))
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
    engine.mainMixerNode.outputVolume =
      ProcessInfo.processInfo.environment["PLAYER_MUTE"] == "1" ? 0 : 1.0
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
  /// paused goes through the command mailbox instead.
  func play() {
    guard demuxer != nil else { return }
    if isLoopRunning {
      submit(.resume)
      return
    }
    pipelineQueue.async { [weak self] in
      guard let self, let demuxer = self.demuxer else { return }
      self.commandLock.lock()
      self.loopRunning = true
      self.commandLock.unlock()
      self.isPlaying = true
      self.isPaused = false
      self.startMonotonic = CACurrentMediaTime()
      self.clockBaseAudio = self.audioPlayer != nil
      self.restartAudioPlayer()
      NSLog("[Native] play (audio clock: %@)", self.clockBaseAudio ? "yes" : "no")
      self.demuxLoop(demuxer)
    }
  }

  func pause() { submit(.pause) }

  /// Stops everything and tears down the pipeline. Synchronous: blocks
  /// (briefly) until the demux loop has exited, so callers can safely open
  /// a new file right after. Safe to call when nothing is running.
  func stop() {
    if isLoopRunning {
      submit(.stop)
      while isLoopRunning { usleep(1000) }
    } else {
      performStop()
      stateChanged()
    }
  }

  /// Flush + demuxer seek + VT rebuild, run inside the demux loop. PTS
  /// before target is discarded by the scheduler (generation-protected).
  func seek(to seconds: Double) { submit(.seek(seconds)) }

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
        audioFramesScheduled = 0
        pauseAudioEngine()
        invalidateNodeClock()
        stateChanged()
      case .seek(let seconds): performSeek(seconds: seconds, demuxer: demuxer)
      case .switchAudio(let streamIndex):
        performAudioSwitch(streamIndex: streamIndex, demuxer: demuxer)
      case .switchSubtitle(let streamIndex):
        performSubtitleSwitch(streamIndex: streamIndex, demuxer: demuxer)
      case .stop:
        performStop()
        commandLock.lock()
        loopRunning = false
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
      prematureEnd = nil
      // Incomplete file (still being downloaded): stop WITHOUT the drain
      // path — there is no trailing audio to play out (the data simply is not
      // on disk yet), so draining would wait ~2 s pointlessly before "ending".
      // Signal the engine so it can wait for the file to grow and retry.
      performStop()
      commandLock.lock()
      loopRunning = false
      commandLock.unlock()
      stateChanged()
      if let cb = onPartialEnd {
        let pos = pe.position
        let err = pe.wasError
        Task { @MainActor in cb(pos, err) }
      }
      return false
    }
    if eof {
      drainAndFinish()
      commandLock.lock()
      loopRunning = false
      commandLock.unlock()
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
    if audioIndex != nil, let engine = audioEngine, let player = audioPlayer {
      let ahead = audioSecondsAhead(engine: engine, player: player)
      if ahead > maxAudioAheadSeconds {
        usleep(4000)  // 4 ms
        return
      }
    }
    // Backpressure: video queue cap.
    videoQueueLock.lock()
    let vq = videoQueue.count
    videoQueueLock.unlock()
    if vq > maxDecodedVideoFrames {
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
        eof = true
        return
      }
      summaryPackets += 1
      if let videoIndex, pkt.streamID == videoIndex {
        feedVideoPacket(pkt)
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
      eof = true
    }
  }

  /// True when a clean EOF was reached before the container's declared
  /// duration — the file is incomplete (a downloader is still writing it),
  /// so playback should wait for the file to grow and retry rather than
  /// ending. A file with no known duration is treated as a real end (we
  /// cannot distinguish, and ending is the safe non-sticky choice).
  private func isPrematureEOF(demuxer: FFmpegDemuxer) -> Bool {
    guard let duration = demuxer.duration, duration > 0 else { return false }
    return currentClock() < duration - 1.0
  }

  /// Seek internals (flush, keyframe seek, VT rebuild, clock reset). Runs
  /// inside the demux loop — the loop continues after, no restart needed.
  private func performSeek(seconds: Double, demuxer: FFmpegDemuxer) {
    generation &+= 1
    let gen = generation

    // Flush decode state.
    if let vtSession {
      VTDecompressionSessionInvalidate(vtSession)
      self.vtSession = nil
    }
    videoQueueLock.lock()
    videoQueue.removeAll()
    videoQueueGeneration = gen
    videoQueueLock.unlock()
    pendingVideoPackets.removeAll()
    // Discard pre-target video frames: the coarse (keyframe) seek lands
    // BEFORE the target, and presenting the keyframe->target window would
    // fast-forward the video (clock is already at the target) while the
    // shallow queue drops B-frames en masse (choppy ~0.5x). Seeding the
    // regression guard with the target drops those frames at the
    // scheduler — mirror of discardAudioBefore for audio.
    lastPresentedPTS = seconds
    NSLog("[Native] seek -> %.3f (gen %llu)", seconds, gen)

    if let audioDecoder { media_audio_decoder_flush(audioDecoder) }
    audioFramesScheduled = 0
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
      // Rebuild the VT session (stream params may differ after seek).
      if let vStream = videoStreamIndex, let vTrack = demuxer.track(at: vStream) {
        try setupVideoToolbox(demuxer: demuxer, video: vTrack)
      }
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
        presentPausedPreview(target: seconds, demuxer: demuxer)
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
  private func presentPausedPreview(target: Double, demuxer: FFmpegDemuxer) {
    let deadline = CACurrentMediaTime() + 1.5
    while CACurrentMediaTime() < deadline {
      videoQueueLock.lock()
      // Drop pre-target frames each poll (keeps the queue bounded) and look
      // for a candidate at/after the target.
      videoQueue.removeAll { $0.pts < target - displaySlack }
      videoQueue.sort { $0.pts < $1.pts }
      var frame: NativeVideoFrame?
      if let first = videoQueue.first, first.pts >= target - displaySlack {
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
    videoQueueGeneration = generation  // keep the VT collector's gate in sync
    isPlaying = false
    isPaused = false
    audioClockOffset = 0
    pausedClock = 0
    discardAudioBefore = nil
    // Per-file counters that must NOT survive a teardown. `audioFramesScheduled`
    // counts samples scheduled ahead on the (now-stopped) engine; a left-over
    // value makes the next file's audioSecondsAhead compute as `stale/sr - 0`
    // on a freshly-started node, tripping the audio-ahead backpressure gate on
    // every tick so video is never demuxed/presented — the "frozen last frame
    // until pause and unpause" bug (pause resets this to 0). `lastPresentedPTS`
    // would otherwise drop every frame of the new file (pts << stale value).
    // Mirrors the resets in pause()/performSeek()/performAudioSwitch().
    audioFramesScheduled = 0
    lastPresentedPTS = nil
    videoQueueLock.lock()
    videoQueue.removeAll()
    videoQueueLock.unlock()
    if let vtSession {
      VTDecompressionSessionInvalidate(vtSession)
      self.vtSession = nil
    }
    if let audioEngine { audioEngine.stop() }
    if let audioDecoder {
      media_audio_decoder_free(audioDecoder)
      self.audioDecoder = nil
    }
    enhancementChain = nil
    enhancementLock.lock()
    downmixRoles = nil
    downmixMatrices = [:]
    enhancementLock.unlock()
    invalidateNodeClock()
    demuxer?.close()
    demuxer = nil
    videoStreamIndex = nil
    audioStreamIndex = nil
    subtitleStreamIndex = nil
    clearAllSinks()
  }

  private func feedPendingVideoPackets() {
    let pending = pendingVideoPackets
    pendingVideoPackets.removeAll()
    for pkt in pending { feedVideoPacket(pkt) }
  }

  private func feedVideoPacket(_ pkt: DemuxPacket) {
    guard let vtSession, let fd = vtFormatDesc else { return }
    let frameDur = CMTime(value: 1001, timescale: 24000)
    var timing = CMSampleTimingInfo(
      duration: frameDur, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
    if pkt.pts != Int64.min {
      timing.presentationTimeStamp = CMTime(value: pkt.pts * videoTB.num, timescale: videoTB.den)
    } else if let last = lastPresentedPTS {
      timing.presentationTimeStamp = CMTime(seconds: last + 0.0417, preferredTimescale: 24000)
    } else {
      timing.presentationTimeStamp = .zero
    }

    var block: CMBlockBuffer?
    guard
      pkt.data.withUnsafeBytes({ raw in
        CMBlockBufferCreateWithMemoryBlock(
          allocator: kCFAllocatorDefault,
          memoryBlock: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
          blockLength: pkt.data.count, blockAllocator: kCFAllocatorNull, customBlockSource: nil,
          offsetToData: 0, dataLength: pkt.data.count, flags: 0, blockBufferOut: &block) == noErr
      }), let block
    else { return }

    var sbuf: CMSampleBuffer?
    var sampleSize = pkt.data.count
    guard
      CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize, sampleBufferOut: &sbuf) == noErr, let sbuf
    else { return }
    VTDecompressionSessionDecodeFrame(
      vtSession, sampleBuffer: sbuf, flags: [._EnableAsynchronousDecompression], frameRefcon: nil,
      infoFlagsOut: nil)
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
    let copied = pkt.data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      let buf = malloc(pkt.data.count)
      guard let buf else { return false }
      memcpy(buf, base, pkt.data.count)
      cpkt.data = buf.assumingMemoryBound(to: UInt8.self)
      cpkt.size = pkt.data.count
      return true
    }
    guard copied else { return }
    defer { media_packet_free(&cpkt) }

    guard media_audio_decoder_send(audioDecoder, &cpkt) == MEDIA_RESULT_OK else {
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
      guard decodeChannels == audioSourceChannels else {
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
        for ch in 0..<outChannels {
          guard let dst = pcm.floatChannelData?[ch] else { continue }
          for i in 0..<n { dst[i] = interleaved[i * decodeChannels + ch] }
        }
      }
      player.scheduleBuffer(pcm, at: nil)
      audioFramesScheduled += n
    }
  }

  /// Seconds of audio currently scheduled ahead of the player's position.
  private func audioSecondsAhead(engine: AVAudioEngine, player: AVAudioPlayerNode) -> Double {
    // Same allocation-avoidance as currentClock(): read the node clock
    // through the per-tick cache instead of calling playerTime directly.
    let played = nodeSeconds(player: player) ?? 0
    return Double(audioFramesScheduled) / Double(audioFormat?.sampleRate ?? 48000) - played
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
      return
    }
    let dt = now - summaryLastTime
    guard dt >= 1.0 else { return }
    NSLog(
      "[Native] 1s pos=%.3f fps=%.1f/%.2f drop=%d drift=%+.3f vq=%d pkt=%d aud=%.2fs (mode=%@ ch=%d)",
      clock, Double(summaryPresented) / dt, contentFps, droppedFrames - summaryDroppedBase,
      summaryDrift, videoQueueDepth, summaryPackets, audioSecondsAheadNow(), currentMode().rawValue,
      audioFormat?.channelCount ?? 0)
    summaryLastTime = now
    summaryPresented = 0
    summaryPackets = 0
    summaryDroppedBase = droppedFrames
  }

  /// Seconds of audio scheduled ahead of the player (0 when no audio engine).
  private func audioSecondsAheadNow() -> Double {
    guard let engine = audioEngine, let player = audioPlayer else { return 0 }
    return audioSecondsAhead(engine: engine, player: player)
  }

  private func currentClock() -> Double {
    // While paused the clock is FROZEN at the captured position. Reading
    // a live clock here (audio playerTime or monotonic) would keep the
    // position/timer advancing during a pause.
    if isPaused { return pausedClock }
    if clockBaseAudio, let engine = audioEngine, let player = audioPlayer,
      let nodeSeconds = nodeSeconds(player: player)
    {
      return nodeSeconds + audioClockOffset
    }
    return CACurrentMediaTime() - startMonotonic
  }

  /// MainActor-safe clock read (see NativeSomePlayer.refreshFromController).
  func currentClockSafe() -> Double { currentClock() }

  // MARK: - Subtitles (SRT Phase A)

  /// Parses a subtitle packet into a cue. SubRip packets in MKV carry the
  /// plain text (with SRT markup stripped); timing comes from pts/duration
  /// in the stream time base (1/1000 for MKV).
  private func collectSubtitlePacket(_ pkt: DemuxPacket) {
    guard pkt.pts != Int64.min else { return }
    var text = String(data: pkt.data, encoding: .utf8) ?? String(data: pkt.data, encoding: .utf16)
    text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty else { return }

    let start = Double(pkt.pts) / 1000.0
    let durTb = pkt.duration > 0 ? Double(pkt.duration) / 1000.0 : 2.0
    let cue = SubtitleCue(start: start, end: start + durTb, text: text)
    subtitleCuesLock.lock()
    subtitleCues.append(cue)
    subtitleCuesLock.unlock()
    // Diagnostic: log the first few cues.
    if subtitleCues.count <= 4 {
      NSLog("[Native] subtitle cue %.3f-%.3f: %@", cue.start, cue.end, cue.text)
    }
  }

  /// Active subtitle cue at `time` (seconds), or nil when subtitles are off
  /// or none is active. MainActor-safe read.
  func subtitleCue(at time: Double) -> SubtitleCue? {
    subtitleCuesLock.lock()
    defer { subtitleCuesLock.unlock() }
    guard !subtitleCues.isEmpty else { return nil }
    // Cues arrive in demux order (ascending start) — binary search.
    var lo = 0
    var hi = subtitleCues.count - 1
    var result: SubtitleCue?
    while lo <= hi {
      let mid = (lo + hi) / 2
      let c = subtitleCues[mid]
      if time < c.start {
        hi = mid - 1
      } else if time > c.end {
        lo = mid + 1
      } else {
        result = c
        break
      }
    }
    return result
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

    generation &+= 1
    let gen = generation
    videoQueueLock.lock()
    videoQueue.removeAll()
    videoQueueGeneration = gen  // in-flight frames from the old stream are stale
    videoQueueLock.unlock()
    pendingVideoPackets.removeAll()
    // Flush the old audio decoder + scheduled buffers.
    if let audioDecoder {
      media_audio_decoder_free(audioDecoder)
      self.audioDecoder = nil
    }
    audioFramesScheduled = 0
    if let player = audioPlayer {
      player.stop()
      player.reset()
      // Restart the node so the new stream's buffers actually play
      // (the engine itself stays running across the switch).
      restartAudioPlayer()
    }
    invalidateNodeClock()
    guard let track = demuxer.track(at: streamIndex), track.type == MEDIA_TRACK_TYPE_AUDIO.rawValue
    else {
      stateChanged()
      return
    }
    do {
      try setupAudio(streamIndex: streamIndex)
      audioStreamIndex = streamIndex
      // Re-seek so both pipelines restart at the current position.
      let current = currentClock()
      lastPresentedPTS = current
      try demuxer.seek(to: current)
      discardAudioBefore = current
      restartAudioPlayer()
      startMonotonic = CACurrentMediaTime() - current
      audioClockOffset = current
      NSLog("[Native] audio track switched to stream %d", streamIndex)
    } catch { stateChanged() }
  }

  /// Enables/disables the subtitle stream. Clears collected cues and
  /// re-seeks so cues are re-collected from the new stream's packets.
  func selectSubtitleTrack(streamIndex: Int?) { submit(.switchSubtitle(streamIndex)) }

  private func performSubtitleSwitch(streamIndex: Int?, demuxer: FFmpegDemuxer) {
    // No-op when the subtitle state isn't actually changing (e.g. the
    // partial-download retry re-applies an already-off preference). Without
    // this the re-seek below runs once per open for a permanently-off subtitle.
    guard streamIndex != subtitleStreamIndex else { return }
    clearSubtitleCues()
    subtitleStreamIndex = streamIndex
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
    pendingVideoPackets.removeAll()
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

  private func drainAndFinish() {
    NSLog("[Native] EOF drain (audio plays out)")
    // Let audio play out (~plan §30: display the final frames, wait for
    // audio, then transition to ended).
    if clockBaseAudio, let engine = audioEngine {
      let start = CACurrentMediaTime()
      while CACurrentMediaTime() - start < 2.0 {
        presentDueFrames()
        usleep(8000)
      }
    }
    // Audio played out; stop its render thread (same cost as pause).
    pauseAudioEngine()
    isPlaying = false
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

/// Retains the VT callback closure context.
final class VideoCollectorBox {
  let onFrame: (NativeVideoFrame) -> Void
  init(onFrame: @escaping (NativeVideoFrame) -> Void) { self.onFrame = onFrame }
}

// MARK: - FFmpegDemuxer handle escape (internal to the native engine)

extension FFmpegDemuxer {
  /// The raw C handle. Only the PlaybackController touches it, and only on
  /// the pipeline queue. Exposed via a separate extension to keep the
  /// demuxer API clean for other callers.
  var unsafeHandle: UnsafeMutablePointer<MediaDemuxer>? { handle }
}
