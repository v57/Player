import Foundation
import MediaPlayer
import SQLite3
import SwiftData

/// All SwiftData persistence for the app: playback resume positions
/// (PlaybackRecord) and remembered audio/subtitle picks (TrackPick).
///
/// Owns the app's ONE shared ModelContainer — exactly one, ever (a container
/// built inside an instance init traps on first insert; a second container
/// traps on first fetch). Engines hold this weakly and never touch SwiftData
/// themselves.
@MainActor
final class PlaybackStore {
    /// Process-lifetime singleton; engines hold it weakly.
    static let shared = PlaybackStore()

    /// The app's ONE shared SwiftData container, created lazily in a static
    /// closure. Local-only store: no CloudKit, no iCloud entitlement in this
    /// app.
    private static let modelContainer: ModelContainer = {
        let schema = Schema([PlaybackRecord.self, TrackPick.self])
        // Explicit per-app store: a SwiftData app that omits a URL lands on
        // default.store in whatever Application Support resolves to — for an
        // UNSANDBOXED build that is the SHARED ~/Library/Application Support/
        // default.store, where other unsandboxed SwiftData apps (Database)
        // collide ("The file default.store couldn't be opened", dropped
        // tables, lost data). Pinning a per-app URL keeps sandboxed and
        // unsandboxed builds isolated from each other and from other apps.
        let appSupport = URL.applicationSupportDirectory
            .appendingPathComponent("dev.v57.player", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            NSLog("[PlaybackStore] cannot create %@: %@", appSupport.path, error as NSError)
        }
        let storeURL = appSupport.appendingPathComponent("Player.store")
        migrateLegacyDefaultStoreIfNeeded(to: storeURL)
        let disk = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: schema, configurations: [disk]) {
            return container
        }
        // Unwritable/corrupt store: fall back to in-memory so playback works.
        // Log the failure — a silently missing disk store loses resume data.
        do {
            return try ModelContainer(for: schema, configurations: [disk])
        } catch {
            NSLog("[PlaybackStore] disk container failed, falling back to memory: %@",
                  error as NSError)
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }()

    /// One-time relocation: builds before the pin stored at the SwiftData
    /// default (<Application Support>/default.store). Copies it in place only
    /// when the target is absent AND the source is genuinely ours (has a
    /// ZPLAYBACKRECORD table — a foreign app's store must NOT be absorbed).
    /// VACUUM INTO produces a consistent checkpointed snapshot even when the
    /// legacy store runs WAL mode with a live writer.
    private static func migrateLegacyDefaultStoreIfNeeded(to storeURL: URL) {
        guard !FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let legacy = URL.applicationSupportDirectory.appendingPathComponent("default.store")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }

        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(legacy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let handle
        else { return }
        sqlite3_exec(handle, "PRAGMA busy_timeout = 5000", nil, nil, nil)
        guard hasPlaybackTable(handle) else { return }
        let target = storeURL.path.replacingOccurrences(of: "'", with: "''")
        if sqlite3_exec(handle, "VACUUM INTO '\(target)'", nil, nil, nil) == SQLITE_OK {
            NSLog("[PlaybackStore] migrated legacy store to %@", storeURL.path)
        }
    }

    private static func hasPlaybackTable(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='ZPLAYBACKRECORD'"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
            sqlite3_step(stmt) == SQLITE_ROW
        else { return false }
        return sqlite3_column_int64(stmt, 0) > 0
    }

    private let modelContext: ModelContext

    private init() {
        modelContext = ModelContext(Self.modelContainer)
    }

    // MARK: - Resume positions

    /// Upserts one `PlaybackRecord` per file, keyed by absolute path.
    /// No-op when path is nil or the position is still 0.
    func saveCurrentPosition(path: String?, position: Double, duration: Double) {
        guard let path, position > 0 else { return }
        let record: PlaybackRecord
        if let existing = fetchRecord(path: path) {
            record = existing
        } else {
            // A freshly created @Model is NOT registered with the context;
            // save() would silently persist nothing without insert().
            let created = PlaybackRecord(filePath: path, position: 0, duration: 0)
            modelContext.insert(created)
            record = created
        }
        record.position = position
        record.duration = duration
        record.lastPlayedAt = .now
        try? modelContext.save()
    }

    /// Saved position to resume from, or nil when the record says the file
    /// was barely started or was already watched to the end.
    func resumePosition(for path: String) -> Double? {
        guard let record = fetchRecord(path: path) else { return nil }
        let pos = record.position
        // Opening-second noise: don't resume a file that was barely started.
        guard pos >= 5 else { return nil }
        if record.duration > 0 {
            // Within 30 s (or 5 %) of the end counts as finished — start over.
            guard pos <= max(record.duration - 30, record.duration * 0.95) else { return nil }
        }
        return pos
    }

    func fetchRecord(path: String) -> PlaybackRecord? {
        let descriptor = FetchDescriptor<PlaybackRecord>(
            predicate: #Predicate { $0.filePath == path }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// The `limit` most recently played files, newest first — used for the
    /// empty-state "Recent" list. Only records the user has really watched
    /// (position > 0) are shown.
    func recentVideos(limit: Int = 5) -> [PlaybackRecord] {
        var descriptor = FetchDescriptor<PlaybackRecord>(
            predicate: #Predicate { $0.position > 0 }
        )
        descriptor.sortBy = [SortDescriptor(\PlaybackRecord.lastPlayedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Persists (updates) the security-scoped bookmark for a file so it can be
    /// reopened from the Recent list. Never clears an existing bookmark.
    func storeBookmark(path: String, bookmark: Data) {
        let record: PlaybackRecord
        if let existing = fetchRecord(path: path) {
            record = existing
        } else {
            let created = PlaybackRecord(filePath: path, position: 0, duration: 0)
            modelContext.insert(created)
            record = created
        }
        record.bookmarkData = bookmark
        record.lastPlayedAt = .now
        try? modelContext.save()
    }

    // MARK: - Track picks

    /// Saves a manual pick so the same choice carries to the next video.
    /// Picks are global (not per-file); the newest pick per kind wins.
    func storeTrackPick(kind: String, lang: String?, title: String?,
                        trackID: Int, isOff: Bool) {
        let pick = TrackPick(kind: kind, lang: lang, title: title,
                             trackID: trackID, isOff: isOff)
        modelContext.insert(pick)
        try? modelContext.save()
    }

    /// Newest manual pick of a kind, or nil when the user never picked one.
    /// Named `latestTrackPickRecord` (not `latestTrackPick`) because the
    /// PlayerPersistence conformance needs `latestTrackPick(kind:) ->
    /// PlayerTrackPick?` — two methods differing only in return type can't
    /// coexist.
    func latestTrackPickRecord(kind: String) -> TrackPick? {
        var descriptor = FetchDescriptor<TrackPick>(
            predicate: #Predicate { $0.kind == kind }
        )
        descriptor.sortBy = [SortDescriptor(\.pickedAt, order: .reverse)]
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

// MARK: - PlayerPersistence (library seam)

extension PlaybackStore: PlayerPersistence {
    func latestTrackPick(kind: String) -> PlayerTrackPick? {
        latestTrackPickRecord(kind: kind).map {
            PlayerTrackPick(kind: $0.kind, lang: $0.lang, title: $0.title,
                            trackID: $0.trackID, isOff: $0.isOff, pickedAt: $0.pickedAt)
        }
    }
}
