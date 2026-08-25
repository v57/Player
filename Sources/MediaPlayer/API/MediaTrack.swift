import Foundation

/// One audio/video/subtitle track of the loaded media, engine-agnostic.
///
/// Track ids are opaque per-file engine ids (native stream
/// index) — matching a choice across files happens via language/title, never
/// by id.
public struct MediaTrack: Identifiable, Equatable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    case video
    case audio
    case subtitle
  }

  /// Opaque engine track id (native stream index).
  public let id: Int
  public let kind: Kind
  /// Engine codec name (e.g. "dts", "aac") for the info line.
  public let codec: String?
  /// ISO 639 language code (e.g. "eng"); "und" = untagged.
  public let language: String?
  /// Track title, when the file carries one.
  public let title: String?
  /// Audio channel count (e.g. 6 for 5.1).
  public let channelCount: Int?
  /// Audio sample rate in Hz.
  public let sampleRate: Int?
  public let isDefault: Bool
  public let isForced: Bool
}

extension MediaTrack {
  /// IINA-style menu label (iina/MPVTrack.swift `readableString`):
  /// `[Language] Title (codec, 6ch, 48kHz)`.
  ///
  /// Shared app-side formatting — engines only supply the raw fields. The
  /// bracketed language name comes FIRST, so it stays visible even when
  /// the track has a title.
  public var displayName: String {
    var languageLabel = ""
    if let languageCode = language, languageCode != "und",
      let readable = Locale.current.localizedString(forIdentifier: languageCode), !readable.isEmpty
    {
      languageLabel = "[\(readable)]"
    }
    let titlePart = title.flatMap { $0.isEmpty ? nil : $0 } ?? "No Title"

    var info = ""
    if kind == .audio {
      var components: [String] = []
      if let codec { components.append(codec) }
      if let channelCount { components.append("\(channelCount)ch") }
      if let sampleRate {
        // en_US_POSIX keeps "44.1kHz" a dot even in comma locales.
        components.append(
          String(
            format: "%gkHz", locale: Locale(identifier: "en_US_POSIX"), Double(sampleRate) / 1000))
      }
      if !components.isEmpty { info = "(\(components.joined(separator: ", ")))" }
    }
    return [languageLabel, titlePart, info].filter { !$0.isEmpty }.joined(separator: " ")
  }
}
