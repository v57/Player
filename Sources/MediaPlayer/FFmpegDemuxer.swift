import Foundation
import MediaPlayerCDemux

/// Errors surfaced by the native demux path. The UI never sees FFmpeg error
/// integers — translated at this boundary (plan section 31).
enum DemuxError: Error {
  case cannotOpen
  case noVideoTrack
  case noAudioTrack
  case readFailed
  case unsupported
}

/// One decoded-frame-agnostic packet from the container. `data` is a copy
/// owned by Swift (the C bridge hands out malloc'd buffers; we copy into Data
/// and let the bridge free its own).
struct DemuxPacket {
  let streamID: Int
  let pts: Int64  // stream timebase units; Int64.min = unknown
  let dts: Int64
  let duration: Int64
  let keyframe: Bool
  let data: Data

  /// Seconds, converted only at the boundary (plan section 7/25).
  var ptsSeconds: Double? { pts == Int64.min ? nil : Double(pts) / 1000.0 }
}

/// Rational time base, as carried by the container.
struct Rational: Equatable, Sendable {
  let num: Int32
  let den: Int32
}

/// App-owned track metadata mirror of the C MediaTrack (no AV* types).
struct NativeTrackInfo {
  let id: Int
  /// Raw MediaTrackType value (C enum imports as Int32 in struct fields).
  let type: Int32
  let codecID: Int
  let codecName: String
  let language: String?
  let title: String?
  let channelCount: Int
  let sampleRate: Int
  let timeBase: Rational
  let isDefault: Bool
  let isForced: Bool
  /// Channel layout mask (native order) + describe string for audio.
  var layoutMask: UInt64
  var layoutName: String?

  init(
    id: Int, type: Int32, codecID: Int, codecName: String, language: String?, title: String?,
    channelCount: Int, sampleRate: Int, timeBase: Rational, isDefault: Bool, isForced: Bool,
    layoutMask: UInt64 = 0, layoutName: String? = nil
  ) {
    self.id = id
    self.type = type
    self.codecID = codecID
    self.codecName = codecName
    self.language = language
    self.title = title
    self.channelCount = channelCount
    self.sampleRate = sampleRate
    self.timeBase = timeBase
    self.isDefault = isDefault
    self.isForced = isForced
    self.layoutMask = layoutMask
    self.layoutName = layoutName
  }
}

/// Swift wrapper over the MediaDemuxer C bridge (libavformat/matroska).
/// Owns one opaque demuxer handle; not thread-safe — the PlaybackController
/// serializes all access on its pipeline queue.
final class FFmpegDemuxer {
  /// The raw C handle. Internal so the PlaybackController (same module) can
  /// reach the extradata/decoder bridge calls; no other caller touches it.
  var handle: UnsafeMutablePointer<MediaDemuxer>?

  init() {}

  deinit { close() }

  /// Opens and probes the file. Throws DemuxError.cannotOpen on failure.
  func open(_ url: URL) throws {
    close()
    guard let h = url.path.withCString({ media_open($0) }) else { throw DemuxError.cannotOpen }
    handle = h
  }

  func close() {
    if let h = handle {
      media_close(h)
      handle = nil
    }
  }

  var isOpen: Bool { handle != nil }

  /// Container duration in seconds, or nil when unknown.
  var duration: Double? {
    guard let h = handle else { return nil }
    let ms = media_get_duration(h)
    return ms >= 0 ? Double(ms) / 1000.0 : nil
  }

  var trackCount: Int {
    guard let h = handle else { return 0 }
    return Int(media_get_track_count(h))
  }

  /// Track metadata for a stream index.
  func track(at index: Int) -> NativeTrackInfo? {
    guard let h = handle else { return nil }
    var t = media_track_make()
    guard media_get_track(h, Int32(index), &t) == MEDIA_RESULT_OK else { return nil }

    var info = NativeTrackInfo(
      id: Int(t.id), type: t.type, codecID: Int(t.codec_id),
      codecName: String(cString: media_track_codec_name(&t)),
      language: String(cString: media_track_language(&t)),
      title: String(cString: media_track_title(&t)), channelCount: Int(t.channel_count),
      sampleRate: Int(t.sample_rate),
      timeBase: Rational(num: t.time_base_num, den: t.time_base_den), isDefault: t.is_default != 0,
      isForced: t.is_forced != 0)
    if t.type == Int32(MEDIA_TRACK_TYPE_AUDIO.rawValue) {
      var mask: UInt64 = 0
      var name = [CChar](repeating: 0, count: 64)
      if media_get_track_channel_layout(h, Int32(index), &mask, &name, name.count)
        == MEDIA_RESULT_OK
      {
        info.layoutMask = mask
        let s = String(cString: name)
        info.layoutName = s.isEmpty ? nil : s
      }
    }
    return info
  }

  /// Reads the next packet. Returns nil at EOF; throws on error.
  func readPacket() throws -> DemuxPacket? {
    guard let h = handle else { throw DemuxError.readFailed }
    var pkt = media_packet_make()
    let r = media_read_packet(h, &pkt)
    if r == MEDIA_RESULT_EOF { return nil }
    guard r == MEDIA_RESULT_OK else { throw DemuxError.readFailed }
    defer { media_packet_free(&pkt) }

    let data = Data(bytes: pkt.data, count: Int(pkt.size))
    return DemuxPacket(
      streamID: Int(pkt.stream_id), pts: pkt.pts, dts: pkt.dts, duration: pkt.duration,
      keyframe: pkt.keyframe != 0, data: data)
  }

  /// Keyframe seek to `seconds` (backward). Throws on failure.
  func seek(to seconds: Double) throws {
    guard let h = handle else { throw DemuxError.readFailed }
    guard media_seek(h, seconds) == MEDIA_RESULT_OK else { throw DemuxError.readFailed }
  }

  // MARK: - Chapters

  /// Matroska chapters as app-owned structs (plan section 22).
  var chapters: [NativeChapter] {
    guard let h = handle else { return [] }
    let count = Int(media_get_chapter_count(h))
    guard count > 0 else { return [] }
    var out: [NativeChapter] = []
    for i in 0..<count {
      var startMs: Int64 = 0
      var titleBuf = [CChar](repeating: 0, count: 256)
      guard media_get_chapter(h, Int32(i), &startMs, &titleBuf, titleBuf.count) == MEDIA_RESULT_OK
      else { continue }
      let title = String(cString: titleBuf)
      out.append(
        NativeChapter(title: title.isEmpty ? nil : title, startTime: Double(startMs) / 1000.0))
    }
    return out
  }
}

/// One Matroska chapter (app-owned; plan section 22).
struct NativeChapter {
  let title: String?
  let startTime: Double  // seconds
}
