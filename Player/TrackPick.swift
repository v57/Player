import Foundation
import SwiftData

/// A manual audio/subtitle track selection, remembered so the same choice
/// auto-applies when a different video opens. Picks are global — never tied
/// to a file — and the newest pick per kind wins. Tracks are matched by
/// language/title because track ids are per-file.
@Model
final class TrackPick {
    /// "audio" or "sub".
    var kind: String
    /// Track language code (e.g. "eng", "jpn"); nil for an "off" pick.
    var lang: String?
    /// Track title; nil when the track had none (or the pick is "off").
    var title: String?
    /// Raw track id at pick time — informational only (ids are per-file).
    var trackID: Int
    /// True when the user explicitly turned this kind off (subtitles off).
    var isOff: Bool
    /// When the pick was made; the newest pick per kind is applied on open.
    var pickedAt: Date

    init(kind: String, lang: String?, title: String?, trackID: Int,
         isOff: Bool, pickedAt: Date = .now) {
        self.kind = kind
        self.lang = lang
        self.title = title
        self.trackID = trackID
        self.isOff = isOff
        self.pickedAt = pickedAt
    }
}
