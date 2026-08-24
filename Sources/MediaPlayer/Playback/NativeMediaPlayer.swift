import Foundation
import Combine
import AppKit
import MediaPlayerCDemux

/// The native engine behind the MediaPlayer protocol: libavformat demux +
/// VideoToolbox + libavcodec dca + AVAudioEngine + Metal (via VideoFrameSink).
///
/// Owns a PlaybackController and mirrors its state onto the @Published
/// surface the UI consumes. Persistence (resume + track picks) goes
/// through PlaybackStore (one shared SwiftData container).
@MainActor
public final class NativeMediaPlayer: MediaPlayer {
    static let shared = NativeMediaPlayer()

    /// Persistence goes through the PlayerPersistence seam — the app
    /// injects its SwiftData-backed PlaybackStore; the library never
    /// touches SwiftData itself. Weak: the app owns the store.
    public weak var store: (any PlayerPersistence)?

    private let controller = PlaybackController()

    @Published public private(set) var isPlaying = false
    @Published public private(set) var fileName: String?
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var videoTracks: [MediaTrack] = []
    @Published public private(set) var audioTracks: [MediaTrack] = []
    @Published public private(set) var subtitleTracks: [MediaTrack] = []
    @Published public private(set) var audioTrackID: Int?
    @Published public private(set) var subtitleTrackID: Int?
    @Published public private(set) var chapters: [PlayerChapter] = []
    @Published public var errorMessage: String?

    private var currentFilePath: String?
    /// The URL whose sandbox file access we hold open (user-selected files
    /// delivered via fileImporter/Open With are security-scoped). Kept for
    /// the whole playback because the demuxer opens the fd on its own queue
    /// and reads it asynchronously; released on stop/error. No-op (returns
    /// false) outside the sandbox.
    private var scopedURL: URL?
    private var pendingResumePosition: Double?
    private var pendingAudioPick: PlayerTrackPick?
    private var pendingSubPick: PlayerTrackPick?
    private var lastAutosave = Date.distantPast
    private var positionTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// Held while media is actually playing to stop the OS from dimming the
    /// display / sleeping the system during playback (standard video-player
    /// behavior). Released on pause/stop/EOF; re-acquired on resume.
    private var playbackActivity: NSObjectProtocol?

    /// Reported state machine. The controller drives the coarse states; the
    /// finer ones (buffering/seeking/ended) are derived here until the
    /// controller exposes its own transitions.
    public private(set) var state: PlaybackState = .idle

    /// Active subtitle cue at the current position (for the Metal overlay).
    public var activeSubtitleCue: String? {
        controller.subtitleCue(at: position)?.text
    }

    public init() {
        controller.configure(sink: nil, onStateChange: { [weak self] in
            self?.refreshFromController()
        })
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveCurrentPosition()
            }
        }
    }

    // MARK: - Transport

    public func open(_ url: URL) async throws {
        saveCurrentPosition()
        // Hold the sandbox grant (security-scoped URL) for the file's whole
        // lifetime; the demuxer reads from the fd asynchronously.
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }
        state = .opening
        do {
            let info = try await controller.open(url)
            currentFilePath = url.standardizedFileURL.path
            fileName = url.lastPathComponent
            duration = info.duration ?? 0
            mapTracks(info.allTracks)
            chapters = info.chapters.map { PlayerChapter(title: $0.title, startTime: $0.startTime) }
            pendingResumePosition = store?.resumePosition(for: currentFilePath ?? "")
            pendingAudioPick = store?.latestTrackPick(kind: "audio")
            pendingSubPick = store?.latestTrackPick(kind: "sub")
            state = .ready
            // Persist a security-scoped bookmark so the file can be reopened
            // from the Recent list (a bare path outside the container is
            // unreadable to the sandbox).
            if let scopedURL, let filePath = currentFilePath,
               let bookmark = try? scopedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                store?.storeBookmark(path: filePath, bookmark: bookmark)
            }
            startPositionTimer()
            controller.play()
            applyPendingResume()
        } catch {
            releaseScopedAccess()
            state = .failed
            errorMessage = nativeErrorString(error)
        }
    }

    public func play() {
        controller.play()
    }

    public func pause() {
        controller.pause()
        saveCurrentPosition()
    }

    public func seek(to seconds: Double, exact: Bool) {
        controller.seek(to: seconds)
    }

    public func seekRelative(_ seconds: Double) {
        controller.seek(to: max(0, position + seconds))
    }

    /// Chapter skipping: seeks to the nearest chapter boundary after
    /// (direction > 0) or before (direction < 0) the current position.
    /// No-op when the file has no chapters. Plain (keyframe) seek — the
    /// chapter boundary is a keyframe for these files, so playback lands
    /// exactly there.
    public func skipChapter(_ direction: Int) {
        guard !chapters.isEmpty, direction != 0 else { return }
        let pos = position
        if direction > 0 {
            guard let next = chapters.first(where: { $0.startTime > pos + 1.0 }) else { return }
            controller.seek(to: next.startTime)
        } else {
            guard let prev = chapters.last(where: { $0.startTime < pos - 1.0 }) else { return }
            controller.seek(to: prev.startTime)
        }
    }

    public func stop() {
        saveCurrentPosition()
        controller.stop()
        releaseScopedAccess()
        positionTimer?.invalidate()
        positionTimer = nil
        fileName = nil
        currentFilePath = nil
        position = 0
        duration = 0
        isPlaying = false
        updateDisplaySleepPrevention()
        state = .idle
    }

    /// Drops the sandbox grant for the current file, if we held one.
    private func releaseScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    /// Registers the Metal view as the frame sink (called by NativeVideoView
    /// on make/update). The controller pushes decoded frames here on MainActor.
    public func registerSink(_ sink: any VideoFrameSink) {
        controller.configure(sink: sink, onStateChange: { [weak self] in
            self?.refreshFromController()
        })
    }

    public func selectAudioTrack(_ id: Int) {
        audioTrackID = id
        pendingAudioPick = nil
        if let track = audioTracks.first(where: { $0.id == id }) {
            store?.storeTrackPick(kind: "audio", lang: track.language, title: track.title, trackID: id, isOff: false)
        }
        // Native: the id IS the stream index — switch the pipeline.
        controller.selectAudioTrack(streamIndex: id)
    }

    public func selectSubtitleTrack(_ id: Int?) {
        subtitleTrackID = id
        pendingSubPick = nil
        if let id, let track = subtitleTracks.first(where: { $0.id == id }) {
            store?.storeTrackPick(kind: "sub", lang: track.language, title: track.title, trackID: id, isOff: false)
        } else {
            store?.storeTrackPick(kind: "sub", lang: nil, title: nil, trackID: 0, isOff: true)
        }
        // Native: nil = subtitles off, id = subtitle stream index.
        controller.selectSubtitleTrack(streamIndex: id)
    }

    // MARK: - Track mapping (NativeTrackInfo -> MediaTrack)

    private func mapTracks(_ tracks: [NativeTrackInfo]) {
        videoTracks = []
        audioTracks = []
        subtitleTracks = []
        for t in tracks {
            let kind: MediaTrack.Kind
            switch t.type {
            case MEDIA_TRACK_TYPE_VIDEO.rawValue: kind = .video
            case MEDIA_TRACK_TYPE_AUDIO.rawValue: kind = .audio
            case MEDIA_TRACK_TYPE_SUBTITLE.rawValue: kind = .subtitle
            default: continue
            }
            let mt = MediaTrack(id: t.id, kind: kind, codec: t.codecName,
                                language: t.language, title: t.title,
                                channelCount: t.channelCount > 0 ? t.channelCount : nil,
                                sampleRate: t.sampleRate > 0 ? t.sampleRate : nil,
                                isDefault: t.isDefault, isForced: t.isForced)
            switch kind {
            case .video: videoTracks.append(mt)
            case .audio: audioTracks.append(mt)
            case .subtitle: subtitleTracks.append(mt)
            }
        }
        // Default track selection: the container's default-flagged track
        // first, then the first audio track.
        if audioTrackID == nil, let d = audioTracks.first(where: { $0.isDefault }) {
            audioTrackID = d.id
        } else if audioTrackID == nil, let f = audioTracks.first {
            audioTrackID = f.id
        }
        applyPendingTrackPicks()
    }

    // MARK: - Resume + picks

    private func applyPendingResume() {
        guard let resume = pendingResumePosition, duration > 0 else {
            pendingResumePosition = nil
            return
        }
        pendingResumePosition = nil
        let target = min(resume, duration)
        position = target
        controller.seek(to: target)
    }

    private func applyPendingTrackPicks() {
        // Audio: the controller already plays the default stream on open; a
        // stored pick switches to the matched stream.
        if let pick = pendingAudioPick {
            if let id = matchTrack(pick, in: audioTracks) {
                audioTrackID = id
                controller.selectAudioTrack(streamIndex: id)
            }
            pendingAudioPick = nil
        }
        if let pick = pendingSubPick {
            if pick.isOff {
                subtitleTrackID = nil
                controller.selectSubtitleTrack(streamIndex: nil)
            } else if let id = matchTrack(pick, in: subtitleTracks) {
                subtitleTrackID = id
                controller.selectSubtitleTrack(streamIndex: id)
            }
            pendingSubPick = nil
        }
    }

    private func matchTrack(_ pick: PlayerTrackPick, in tracks: [MediaTrack]) -> Int? {
        if let lang = pick.lang, let title = pick.title,
           let t = tracks.first(where: { $0.language == lang && $0.title == title }) {
            return t.id
        }
        if let lang = pick.lang, let t = tracks.first(where: { $0.language == lang }) {
            return t.id
        }
        if let title = pick.title, let t = tracks.first(where: { $0.title == title }) {
            return t.id
        }
        return nil
    }

    // MARK: - Polling + persistence

    private func startPositionTimer() {
        positionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshFromController() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    /// The position clock cannot move while paused/ended, so every 5 Hz
    /// firing is pure overhead (runloop wake + Task hop to main). Kill the
    /// timer when playback stops; the controller's state-change callback
    /// (refreshFromController) restarts it on resume.
    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    /// Pulls current clock/metrics from the controller (pipeline-safe getters).
    ///
    /// Paused-CPU guard: @Published writes fire objectWillChange even when
    /// the value is identical, and each one re-renders the SwiftUI tree
    /// (TimelineBar, sliders, AttributeGraph diffing) — measured ~5-9% CPU
    /// while PAUSED because the 5 Hz timer kept publishing the same frozen
    /// position. Publish only actual changes; while paused nothing can
    /// change except isPlaying (handled by state-change callbacks).
    private func refreshFromController() {
        let nowPlaying = controller.isPlaying
        if nowPlaying != isPlaying {
            isPlaying = nowPlaying
            updateDisplaySleepPrevention()
            if nowPlaying { startPositionTimer() } else { stopPositionTimer() }
        }
        guard nowPlaying else { return }
        let clock = controller.currentClockSafe()
        if clock >= 0 {
            let newPosition = duration > 0 ? min(clock, duration) : clock
            if newPosition != position { position = newPosition }
        }
        autosavePosition()
    }

    /// Keeps the display awake (and the system from sleeping) while media is
    /// actually playing, and releases it the moment playback stops — pause,
    /// stop, EOF, error. The activity is re-acquired automatically when
    /// playback resumes (refreshFromController runs on every state change).
    private func updateDisplaySleepPrevention() {
        if isPlaying, playbackActivity == nil {
            playbackActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Playing video"
            )
            NSLog("[Native] display sleep prevention ON")
        } else if !isPlaying, let activity = playbackActivity {
            ProcessInfo.processInfo.endActivity(activity)
            playbackActivity = nil
            NSLog("[Native] display sleep prevention OFF")
        }
    }

    private func autosavePosition() {
        guard isPlaying, position > 0 else { return }
        guard Date.now.timeIntervalSince(lastAutosave) >= 5 else { return }
        lastAutosave = .now
        saveCurrentPosition()
    }

    func saveCurrentPosition() {
        guard let path = currentFilePath, position > 0 else { return }
        store?.saveCurrentPosition(path: path, position: position, duration: duration)
        // Diagnostic evidence for headless verification: under App Sandbox
        // the store lives in a container the CLI cannot read, so the app
        // reports its own saves (macos-native-playback skill recipe).
        NSLog("[Native] saved position %.3f/%.3f s", position, duration)
    }

    private func nativeErrorString(_ error: Error) -> String {
        switch error {
        case NativePlayerError.unsupportedVideoCodec(let c): return "Unsupported video codec: \(c)"
        case NativePlayerError.unsupportedAudioCodec(let c): return "Unsupported audio codec: \(c)"
        case NativePlayerError.cannotOpen: return "Could not open the file."
        case NativePlayerError.videoDecoderFailed: return "Video decoder failed to start."
        case NativePlayerError.audioDecoderFailed: return "Audio decoder failed to start."
        case NativePlayerError.outputDeviceFailed: return "Audio output device failed."
        case NativePlayerError.seekFailed: return "Seek failed."
        default: return error.localizedDescription
        }
    }

    // MARK: - Protocol surface passthroughs

    public var currentTime: Double { position }
    public var volume: Double { 100 }
    public var isMuted: Bool { false }

    nonisolated deinit {
        // A @MainActor class's deinit is nonisolated; the engine is always
        // created and torn down on the main actor (the app owns it for the
        // process lifetime), so assume isolation for the cleanup.
        MainActor.assumeIsolated {
            controller.stop()
            if let activity = playbackActivity {
                ProcessInfo.processInfo.endActivity(activity)
                playbackActivity = nil
            }
        }
    }
}