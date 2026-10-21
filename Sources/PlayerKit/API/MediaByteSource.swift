import Foundation

/// Media read in ranges from somewhere other than a local file (a file on another device over SFTP): the player
/// demuxes it as it reads, seeking where the container says, so nothing is copied here first.
///
/// Calls come from the player's pipeline queue and may block until the bytes arrive; a source caches and reads
/// ahead itself.
public protocol MediaByteSource: AnyObject, Sendable {
  /// The file's size in bytes.
  var size: Int64 { get }
  /// Up to `length` bytes from `offset`; fewer at the end, empty past it. Throws when the bytes can't be read.
  func read(at offset: Int64, length: Int) throws -> Data
}

/// Sources by URL, so a remote file opens like any other (`SomePlayer.open`): register a source, open the URL it
/// returns, unregister it when done.
public enum MediaSources {
  public static let scheme = "player-stream"

  private static let lock = NSLock()
  nonisolated(unsafe) private static var sources: [String: any MediaByteSource] = [:]

  /// The URL that opens `source`; `name` (with its extension) is what the player shows and probes by.
  public static func register(_ source: any MediaByteSource, name: String) -> URL {
    let token = UUID().uuidString.lowercased()
    lock.withLock { sources[token] = source }
    var components = URLComponents()
    components.scheme = scheme
    components.host = token
    components.path = "/" + name
    return components.url ?? URL(string: "\(scheme)://\(token)/media")!
  }

  public static func unregister(_ url: URL) {
    guard let token = url.host else { return }
    _ = lock.withLock { sources.removeValue(forKey: token) }
  }

  static func source(for url: URL) -> (any MediaByteSource)? {
    guard url.scheme == scheme, let token = url.host else { return nil }
    return lock.withLock { sources[token] }
  }
}

/// The position over a source, for the demuxer's read and seek callbacks.
final class MediaSourceReader {
  let source: any MediaByteSource
  private(set) var position: Int64 = 0

  init(source: any MediaByteSource) { self.source = source }

  func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
    guard position < source.size else { return 0 }
    guard let data = try? source.read(at: position, length: count) else { return -1 }
    data.copyBytes(to: buffer, count: min(count, data.count))
    position += Int64(data.count)
    return Int32(data.count)
  }

  func seek(to offset: Int64, whence: Int32) -> Int64 {
    let size = source.size
    let target: Int64
    switch whence {
    case 0x10000: return size  // MEDIA_IO_SIZE
    case SEEK_SET: target = offset
    case SEEK_CUR: target = position + offset
    case SEEK_END: target = size + offset
    default: return -1
    }
    guard target >= 0 else { return -1 }
    position = target
    return target
  }
}
