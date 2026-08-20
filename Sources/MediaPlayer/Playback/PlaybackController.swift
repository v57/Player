import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AVFoundation
import MediaPlayerCDemux

/// One decoded video frame ready for presentation.
///
/// `@unchecked Sendable`: the frame is immutable after construction and is
/// only ever consumed on the main actor (the presentation path), so sending
/// it into `Task { @MainActor }` from the pipeline thread is safe. The
/// CVPixelBuffer is owned by the VideoToolbox session and stays alive for
/// the frame's lifetime.
public final class NativeVideoFrame: @unchecked Sendable {
    let pts: Double            // presentation time, seconds
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
@MainActor
public protocol VideoFrameSink: AnyObject, Sendable {
    func present(frame: NativeVideoFrame)
    func clear()
}

/// One subtitle cue (SRT Phase A). `text` is the plain SRT text; presentation
/// is the view's job (CoreText/AppKit overlay).
struct SubtitleCue {
    let start: Double   // seconds
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
    private let maxQueuedPackets = 240          // ~10 s of 24 fps video
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
    private var audioFramesScheduled = 0     // samples ahead of clock
    private var audioBytesPerFrame: Int = 0
    private var audioIsRunning = false

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

    // Clock
    private var startMonotonic: CFTimeInterval = 0
    private var clockBaseAudio = false
    /// Offset added to the audio player clock after a seek: the player restarts
    /// at 0 while frame PTS stay absolute, so clock = playerTime + offset.
    private var audioClockOffset: Double = 0
    /// Media time at pause, so the monotonic clock continues across resume.
    private var pausedClock: Double = 0

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

    // MARK: - Lifecycle

    init() {}

    /// Sets the frame sink list (MainActor) and a callback run on MainActor
    /// after each state change. Registering the same view twice is a no-op.
    func configure(sink: (any VideoFrameSink)?, onStateChange: (@MainActor () -> Void)?) {
        if let sink { registerSink(sink) }
        if onStateChange != nil { self.onMain = onStateChange }
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
        for s in sinks {
            Task { @MainActor in s.clear() }
        }
    }

    private func snapshotSinksLocked() -> [any VideoFrameSink] {
        sinkBoxes.compactMap { $0.sink }
    }

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
                } catch {
                    cont.resume(throwing: error)
                }
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
        guard video.codecName == "h264" || video.codecID == 27 else {
            throw NativePlayerError.unsupportedVideoCodec(video.codecName)
        }
        // Supported audio codecs (decoders compiled into the FFmpeg build):
        // DTS/dca, Dolby Digital (ac3) and Dolby Digital Plus (eac3).
        if let audio, audio.codecName != "dts" && audio.codecName != "dca"
            && audio.codecName != "ac3" && audio.codecName != "eac3" {
            throw NativePlayerError.unsupportedAudioCodec(audio.codecName)
        }

        self.videoStreamIndex = video.id
        self.audioStreamIndex = audio?.id
        self.subtitleStreamIndex = subtitle?.id
        self.videoTB = (Int64(video.timeBase.num), video.timeBase.den)

        try setupVideoToolbox(demuxer: demuxer, video: video)
        if let audio {
            try setupAudio(streamIndex: audio.id)
        }
        let chapters = demuxer.chapters
        NSLog("[Native] opened %@: video %@ tb=%d/%d audio=%@ (%d ch %@) subs=%@ (%d chapters)",
              url.lastPathComponent, video.codecName,
              video.timeBase.num, video.timeBase.den,
              audio?.codecName ?? "none", audio?.channelCount ?? 0, audio?.layoutName ?? "-",
              subtitle?.codecName ?? "none", chapters.count)
        return NativeMediaInfo(duration: demuxer.duration, video: video, audio: audio,
                               allTracks: all, chapters: chapters)
    }

    // MARK: - Video decoder setup

    private func setupVideoToolbox(demuxer: FFmpegDemuxer, video: NativeTrackInfo) throws {
        var avcc: UnsafePointer<UInt8>?
        var avccSize: Int = 0
        guard media_get_track_extradata(demuxerHandle(demuxer), Int32(video.id), &avcc, &avccSize) == MEDIA_RESULT_OK,
              let avcc, avccSize > 0 else {
            throw NativePlayerError.videoDecoderFailed
        }
        let bytes = [UInt8](UnsafeBufferPointer(start: avcc, count: avccSize))
        let lengthSize = Int(bytes[4] & 0x03) + 1
        let numSPS = Int(bytes[5] & 0x1F)
        var sps: [[UInt8]] = []
        var off = 6
        for _ in 0..<numSPS {
            let len = (Int(bytes[off]) << 8) | Int(bytes[off + 1]); off += 2
            sps.append(Array(bytes[off..<(off + len)])); off += len
        }
        let numPPS = Int(bytes[off]); off += 1
        var pps: [[UInt8]] = []
        for _ in 0..<numPPS {
            let len = (Int(bytes[off]) << 8) | Int(bytes[off + 1]); off += 2
            pps.append(Array(bytes[off..<(off + len)])); off += len
        }
        guard !sps.isEmpty, !pps.isEmpty else { throw NativePlayerError.videoDecoderFailed }

        var allPtrs: [UnsafePointer<UInt8>] = []
        var allSizes: [Int] = []
        for s in sps { s.withUnsafeBufferPointer { allPtrs.append($0.baseAddress!); allSizes.append(s.count) } }
        for p in pps { p.withUnsafeBufferPointer { allPtrs.append($0.baseAddress!); allSizes.append(p.count) } }

        var fd: CMVideoFormatDescription?
        let fds = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: allPtrs.count,
            parameterSetPointers: &allPtrs, parameterSetSizes: &allSizes,
            nalUnitHeaderLength: Int32(lengthSize), formatDescriptionOut: &fd)
        guard fds == noErr, let fd else { throw NativePlayerError.videoDecoderFailed }
        vtFormatDesc = fd

        // Collector box: VT callback fills the queue on VT's thread.
        let box = VideoCollectorBox { [weak self] frame in
            guard let self else { return }
            self.videoQueueLock.lock()
            if self.videoQueueGeneration == self.generation {
                self.videoQueue.append(frame)
            }
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
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(box).toOpaque())

        var session: VTDecompressionSession?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 816,
        ]
        let vts = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: fd,
            decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &cbRecord, decompressionSessionOut: &session)
        guard vts == noErr, let session else { throw NativePlayerError.videoDecoderFailed }
        vtSession = session
        videoCollectorBox = box
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

        guard let track = demuxer.track(at: streamIndex) else { throw NativePlayerError.audioDecoderFailed }
        let tag: AudioChannelLayoutTag = (track.layoutName == "5.1(side)") ? kAudioChannelLayoutTag_MPEG_5_1_B
            : (track.layoutName == "5.1") ? kAudioChannelLayoutTag_MPEG_5_1_A
            : kAudioChannelLayoutTag_Unknown
        let layout: AVAudioChannelLayout
        if tag != kAudioChannelLayoutTag_Unknown, let l = AVAudioChannelLayout(layoutTag: tag) {
            layout = l
        } else if let l = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_B),
                  track.channelCount == 6 {
            layout = l
        } else {
            layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(track.sampleRate), channelLayout: layout)
        audioFormat = format
        audioBytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        audioEngine = engine
        audioPlayer = player
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
        if let engine = audioEngine, !engine.isRunning {
            try? engine.start()
        }
        if let player = audioPlayer {
            player.play()
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

    func pause() {
        submit(.pause)
    }

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
    func seek(to seconds: Double) {
        submit(.seek(seconds))
    }

    // MARK: - Demux loop

    /// Reads packets, feeds decoders, schedules audio, presents video.
    /// Runs on the pipeline queue and owns it until stop/EOF; transport
    /// commands are consumed from the mailbox each iteration (a paused loop
    /// blocks on the command semaphore instead of spinning).
    private func demuxLoop(_ demuxer: FFmpegDemuxer) {
        // Drain pending video packets first (carryover across seeks).
        if !pendingVideoPackets.isEmpty {
            feedPendingVideoPackets()
        }

        var eof = false
        while true {
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
                    audioIsRunning = false
                    stateChanged()
                case .seek(let seconds):
                    performSeek(seconds: seconds, demuxer: demuxer)
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
                    return
                }
                continue
            }
            // Paused with no command pending: block until signaled.
            if isPaused {
                commandSignal.wait()
                continue
            }
            if eof {
                drainAndFinish()
                commandLock.lock()
                loopRunning = false
                commandLock.unlock()
                return
            }
            tick(demuxer: demuxer, eof: &eof)
        }
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
                usleep(4000)   // 4 ms
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
                eof = true
                NSLog("[Native] EOF")
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
                    if let pts = pkt.ptsSeconds, pts < cutoff {
                        return
                    }
                    discardAudioBefore = nil
                }
                feedAudioPacket(pkt)
            } else if let subIndex, pkt.streamID == subIndex {
                collectSubtitlePacket(pkt)
            }
        } catch {
            eof = true
        }
    }

    /// Seek internals (flush, keyframe seek, VT rebuild, clock reset). Runs
    /// inside the demux loop — the loop continues after, no restart needed.
    private func performSeek(seconds: Double, demuxer: FFmpegDemuxer) {
        generation &+= 1
        let gen = generation

        // Flush decode state.
        if let vtSession { VTDecompressionSessionInvalidate(vtSession); self.vtSession = nil }
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

        if let audioDecoder {
            media_audio_decoder_flush(audioDecoder)
        }
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
            if isPaused { pausedClock = seconds }
            stateChanged()
        } catch {
            stateChanged()
        }
    }

    /// Teardown shared by stop() (idle path) and the loop's .stop command.
    private func performStop() {
        generation &+= 1
        NSLog("[Native] stop")
        videoQueueGeneration = generation   // keep the VT collector's gate in sync
        isPlaying = false
        isPaused = false
        audioClockOffset = 0
        pausedClock = 0
        discardAudioBefore = nil
        videoQueueLock.lock()
        videoQueue.removeAll()
        videoQueueLock.unlock()
        if let vtSession { VTDecompressionSessionInvalidate(vtSession); self.vtSession = nil }
        if let audioEngine { audioEngine.stop() }
        if let audioDecoder { media_audio_decoder_free(audioDecoder); self.audioDecoder = nil }
        demuxer?.close()
        demuxer = nil
        videoStreamIndex = nil
        audioStreamIndex = nil
        clearAllSinks()
    }

    private func feedPendingVideoPackets() {
        let pending = pendingVideoPackets
        pendingVideoPackets.removeAll()
        for pkt in pending {
            feedVideoPacket(pkt)
        }
    }

    private func feedVideoPacket(_ pkt: DemuxPacket) {
        guard let vtSession, let fd = vtFormatDesc else { return }
        let frameDur = CMTime(value: 1001, timescale: 24000)
        var timing = CMSampleTimingInfo(duration: frameDur, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        if pkt.pts != Int64.min {
            timing.presentationTimeStamp = CMTime(value: pkt.pts * videoTB.num, timescale: videoTB.den)
        } else if let last = lastPresentedPTS {
            timing.presentationTimeStamp = CMTime(seconds: last + 0.0417, preferredTimescale: 24000)
        } else {
            timing.presentationTimeStamp = .zero
        }

        var block: CMBlockBuffer?
        guard pkt.data.withUnsafeBytes({ raw in
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                               memoryBlock: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                                               blockLength: pkt.data.count, blockAllocator: kCFAllocatorNull,
                                               customBlockSource: nil, offsetToData: 0, dataLength: pkt.data.count,
                                               flags: 0, blockBufferOut: &block) == noErr
        }), let block else { return }

        var sbuf: CMSampleBuffer?
        var sampleSize = pkt.data.count
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: fd,
                                   sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                   sampleBufferOut: &sbuf) == noErr, let sbuf else { return }
        VTDecompressionSessionDecodeFrame(vtSession, sampleBuffer: sbuf,
                                          flags: [._EnableAsynchronousDecompression],
                                          frameRefcon: nil, infoFlagsOut: nil)
    }

    private func feedAudioPacket(_ pkt: DemuxPacket) {
        guard let audioDecoder, let audioFormat, let engine = audioEngine, let player = audioPlayer else { return }

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
            guard let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(n)) else { continue }
            pcm.frameLength = AVAudioFrameCount(n)
            let channels = Int(audioFormat.channelCount)
            let interleaved = [Float](UnsafeBufferPointer(start: frame.data, count: n * channels))
            for ch in 0..<channels {
                guard let dst = pcm.floatChannelData?[ch] else { continue }
                for i in 0..<n { dst[i] = interleaved[i * channels + ch] }
            }
            player.scheduleBuffer(pcm, at: nil)
            audioFramesScheduled += n
        }
    }

    /// Seconds of audio currently scheduled ahead of the player's position.
    private func audioSecondsAhead(engine: AVAudioEngine, player: AVAudioPlayerNode) -> Double {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return Double(audioFramesScheduled) / Double(audioFormat?.sampleRate ?? 48000)
        }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        return Double(audioFramesScheduled) / Double(audioFormat?.sampleRate ?? 48000) - played
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
                NSLog("[Native] presented frame %d at pts=%.3f clock=%.3f (dropped=%d qdepth=%d)",
                      presentedFrames, frame.pts, clock, droppedFrames, videoQueueDepth)
            }
            let f = frame
            let sinks = snapshotSinks()
            for s in sinks {
                Task { @MainActor in
                    s.present(frame: f)
                }
            }
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
        NSLog("[Native] 1s pos=%.3f fps=%.1f/%.2f drop=%d drift=%+.3f vq=%d pkt=%d aud=%.2fs",
              clock, Double(summaryPresented) / dt, contentFps,
              droppedFrames - summaryDroppedBase, summaryDrift,
              videoQueueDepth, summaryPackets, audioSecondsAheadNow())
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
           let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime) {
            return Double(pt.sampleTime) / pt.sampleRate + audioClockOffset
        }
        return CACurrentMediaTime() - startMonotonic
    }

    /// MainActor-safe clock read (see NativeMediaPlayer.refreshFromController).
    func currentClockSafe() -> Double {
        currentClock()
    }

    // MARK: - Subtitles (SRT Phase A)

    /// Parses a subtitle packet into a cue. SubRip packets in MKV carry the
    /// plain text (with SRT markup stripped); timing comes from pts/duration
    /// in the stream time base (1/1000 for MKV).
    private func collectSubtitlePacket(_ pkt: DemuxPacket) {
        guard pkt.pts != Int64.min else { return }
        var text = String(data: pkt.data, encoding: .utf8)
            ?? String(data: pkt.data, encoding: .utf16)
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
    func selectAudioTrack(streamIndex: Int) {
        submit(.switchAudio(streamIndex))
    }

    private func performAudioSwitch(streamIndex: Int, demuxer: FFmpegDemuxer) {
        guard streamIndex != audioStreamIndex else { return }

        generation &+= 1
        videoQueueGeneration = generation   // in-flight frames from the old stream are stale
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
        guard let track = demuxer.track(at: streamIndex),
              track.type == MEDIA_TRACK_TYPE_AUDIO.rawValue else {
            stateChanged()
            return
        }
        do {
            try setupAudio(streamIndex: streamIndex)
            audioStreamIndex = streamIndex
            // Re-seek so both pipelines restart at the current position.
            let current = currentClock()
            try demuxer.seek(to: current)
            discardAudioBefore = current
            restartAudioPlayer()
            startMonotonic = CACurrentMediaTime() - current
            audioClockOffset = current
            NSLog("[Native] audio track switched to stream %d", streamIndex)
        } catch {
            stateChanged()
        }
    }

    /// Enables/disables the subtitle stream. Clears collected cues and
    /// re-seeks so cues are re-collected from the new stream's packets.
    func selectSubtitleTrack(streamIndex: Int?) {
        submit(.switchSubtitle(streamIndex))
    }

    private func performSubtitleSwitch(streamIndex: Int?, demuxer: FFmpegDemuxer) {
        clearSubtitleCues()
        subtitleStreamIndex = streamIndex
        do {
            let current = currentClock()
            try demuxer.seek(to: current)
            NSLog("[Native] subtitle track set to %@", streamIndex.map(String.init) ?? "off")
        } catch {
            stateChanged()
        }
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