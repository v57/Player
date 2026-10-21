import Foundation
import XCTest

@testable import PlayerKit

/// Media opened through a byte source (`MediaSources`, as a file on another device opens) demuxes exactly like the
/// same file opened by path, seeking included, and reads only ranges of it.
final class MediaByteSourceTests: XCTestCase {
  /// A file read in ranges, counting what it was asked for.
  private final class FileSource: MediaByteSource, @unchecked Sendable {
    let handle: FileHandle
    let size: Int64
    private let lock = NSLock()
    private(set) var bytesRead: Int64 = 0

    init(_ url: URL) throws {
      handle = try FileHandle(forReadingFrom: url)
      size = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
    }

    func read(at offset: Int64, length: Int) throws -> Data {
      try lock.withLock {
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: length) ?? Data()
        bytesRead += Int64(data.count)
        return data
      }
    }
  }

  private func corpus(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Corpus/\(name)")
    guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name) missing") }
    return url
  }

  private func packets(_ demuxer: FFmpegDemuxer, limit: Int) throws -> [String] {
    var out: [String] = []
    while out.count < limit, let packet = try demuxer.readPacket() {
      out.append("\(packet.streamID):\(packet.pts):\(packet.data.count):\(packet.data.hashValue)")
    }
    return out
  }

  func testSourceDemuxesLikeTheFile() throws {
    let url = try corpus("h264-long.mkv")
    let byPath = FFmpegDemuxer()
    try byPath.open(url)
    let source = try FileSource(url)
    let streamURL = MediaSources.register(source, name: url.lastPathComponent)
    defer { MediaSources.unregister(streamURL) }
    XCTAssertEqual(streamURL.lastPathComponent, "h264-long.mkv")
    let bySource = FFmpegDemuxer()
    try bySource.open(streamURL)

    XCTAssertEqual(bySource.trackCount, byPath.trackCount)
    XCTAssertEqual(bySource.duration, byPath.duration)
    XCTAssertEqual(
      (0..<bySource.trackCount).map { bySource.track(at: $0)?.codecName },
      (0..<byPath.trackCount).map { byPath.track(at: $0)?.codecName })
    XCTAssertEqual(try packets(bySource, limit: 200), try packets(byPath, limit: 200))

    let middle = (byPath.duration ?? 10) / 2
    try byPath.seek(to: middle)
    try bySource.seek(to: middle)
    XCTAssertEqual(try packets(bySource, limit: 50), try packets(byPath, limit: 50))
    // Probing and a seek read part of the file, not all of it.
    XCTAssertLessThan(source.bytesRead, source.size)
  }

  func testUnregisteredOrFailingSourcesDontOpen() throws {
    let demuxer = FFmpegDemuxer()
    XCTAssertThrowsError(try demuxer.open(URL(string: "player-stream://missing/a.mkv")!))
  }
}
