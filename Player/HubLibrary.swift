import Combine
import Foundation
import PlayerKit
import SSHTunnel
import VaultKit

/// Another device's videos: an account's Hub devices (the hosts via Hub its vault keeps), browsed over SFTP and
/// played as they're read (`SFTPMediaSource`), signed in with this device's key (the Secure Enclave key every v57
/// app shares) or the host's saved password. Nothing is copied to this Mac. A stream keeps the login it was opened
/// with, so it stays on its account's host whatever the sheet shows next.
@MainActor final class HubLibrary: ObservableObject {
  /// A folder on a device, being browsed.
  struct Place: Equatable {
    var hostID: String
    var path: String
  }

  @Published private(set) var place: Place?
  @Published private(set) var entries: [SFTPFileInfo] = []
  @Published private(set) var isLoading = false
  @Published var error: String?

  private var clients: [String: SFTPClient] = [:]
  /// The stream playing now, unregistered when another opens.
  private var playing: URL?
  /// The screenshots' devices, in place of the vault's (`--hub-library`).
  private var demoHosts: [VaultHost]?
  /// The vault of the account whose devices are shown: their hosts, passwords' ids and known host keys.
  let vault: Vault

  init(vault: Vault) {
    self.vault = vault
    if let page = ScreenshotDemo.hubLibraryPage { showDemo(page) }
  }

  /// The devices to offer, by name.
  var hosts: [VaultHost] {
    (demoHosts ?? vault.hubHosts)
      .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  func host(id: String) -> VaultHost? {
    demoHosts.map { $0.first { $0.id == id } } ?? vault.host(id: id)
  }

  /// Shows a folder on a device: its home folder when `path` is nil. Lists folders and the videos Player plays.
  func browse(hostID: String, path: String? = nil) async {
    guard let host = host(id: hostID) else { return }
    isLoading = true
    error = nil
    defer { isLoading = false }
    do {
      let client = try await client(for: host)
      let folder = try await client.realPath(path ?? ".")
      let listed = try await client.list(folder)
      entries = listed.filter {
        !$0.name.hasPrefix(".")
          && ($0.isDirectory || MediaFiles.isSupported(URL(fileURLWithPath: $0.name)))
      }
      .sorted { ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase) }
      place = Place(hostID: hostID, path: folder)
    } catch {
      self.error = error.localizedDescription
      clients[hostID]?.close()
      clients[hostID] = nil
    }
  }

  /// The folder above the one shown.
  func up() async {
    guard let place, place.path != "/" else { return }
    let parent = (place.path as NSString).deletingLastPathComponent
    await browse(hostID: place.hostID, path: parent.isEmpty ? "/" : parent)
  }

  func leave() {
    place = nil
    entries = []
  }

  /// The URL that plays a file of the device shown, read over SFTP as it plays.
  func stream(_ file: SFTPFileInfo) async -> URL? {
    guard let place, let host = host(id: place.hostID) else { return nil }
    do {
      let client = try await client(for: host)
      if let playing { MediaSources.unregister(playing) }
      let source = SFTPMediaSource(client: client, path: file.path, size: Int64(file.size))
      // The device and the path in the name: resume positions stay apart per file.
      let url = MediaSources.register(source, name: "\(host.displayName)\(file.path)")
      playing = url
      return url
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  /// The screenshots' page: two devices that aren't there (`devices`, with the failed connection), or a folder of
  /// videos on one of them (`folder`). Nothing connects.
  private func showDemo(_ page: String) {
    let nas = VaultHost(id: "demo-nas", name: "home-nas", hostname: "10.57.0.3", user: "maya")
    demoHosts = [VaultHost(id: "demo-pc", name: "gaming-pc", hostname: "10.57.0.4"), nas]
    guard page == "folder" else {
      error = "Timed out connecting to 10.57.0.4 on port 22."
      return
    }
    let folder = "/home/maya/Movies"
    func file(_ name: String, _ gigabytes: Double) -> SFTPFileInfo {
      SFTPFileInfo(path: "\(folder)/\(name)", kind: .file, size: UInt64(gigabytes * 1e9))
    }
    entries = [
      SFTPFileInfo(path: "\(folder)/Concerts", kind: .directory), SFTPFileInfo(path: "\(folder)/Family", kind: .directory),
      file("Lisbon Trip 2026.mp4", 1.42), file("Northern Lights 4K.mkv", 2.1), file("Sintel (2010).mkv", 1.12),
      file("Tears of Steel.mov", 3.6),
    ]
    place = Place(hostID: nas.id, path: folder)
  }

  /// One SFTP login per device, kept while it works.
  private func client(for host: VaultHost) async throws -> SFTPClient {
    if let client = clients[host.id], client.isAlive { return client }
    let server = try Self.server(for: host, in: vault)
    let client = try await SFTPClient.connect(server: server)
    // Trust on first use, as Shell and Database do; a Hub device's signed key is trusted ahead of time by Vault.
    if server.knownFingerprint == nil {
      try? vault.store?.trust(fingerprint: client.hostKeyFingerprint, host: host.hostname, port: host.port)
    }
    clients[host.id] = client
    return client
  }

  /// How Player logs in to the host: its user, this device's key or the saved password, the trusted host key.
  static func server(for host: VaultHost, in vault: Vault) throws -> SSHServer {
    let known = try? vault.store?.knownFingerprint(host: host.hostname, port: host.port)
    let user = host.user.isEmpty ? NSUserName() : host.user
    if host.auth == .password {
      return SSHServer(
        host: host.hostname, port: host.port, user: user, password: VaultSecrets.password(for: host.id),
        knownFingerprint: known)
    }
    let key = try VaultIdentity.key()
    let blob = VaultIdentity.publicKeyBlob(key)
    let sshKey = SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(blob), comment: VaultDevice.name) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
    return SSHServer(host: host.hostname, port: host.port, user: user, key: sshKey, knownFingerprint: known)
  }
}

/// A file on another device read over SFTP in 1 MB blocks: the blocks read last stay cached (a seek back is free),
/// and the next ones are fetched ahead while the player decodes, so playback doesn't wait on every read.
final class SFTPMediaSource: MediaByteSource, @unchecked Sendable {
  let size: Int64
  private let client: SFTPClient
  private let path: String
  private let lock = NSLock()
  private var blocks: [Int64: Data] = [:]
  /// Blocks by last use, oldest first.
  private var order: [Int64] = []
  private var fetching: Set<Int64> = []

  static let blockSize = 1 << 20
  static let cachedBlocks = 48
  static let readAhead = 3

  init(client: SFTPClient, path: String, size: Int64) {
    self.client = client
    self.path = path
    self.size = size
  }

  func read(at offset: Int64, length: Int) throws -> Data {
    guard offset < size, length > 0 else { return Data() }
    let end = min(size, offset + Int64(length))
    var result = Data()
    var position = offset
    while position < end {
      let index = position / Int64(Self.blockSize)
      let block = try self.block(index)
      let start = Int(position - index * Int64(Self.blockSize))
      let take = min(block.count - start, Int(end - position))
      guard take > 0 else { break }
      result.append(block[block.startIndex + start..<block.startIndex + start + take])
      position += Int64(take)
    }
    prefetch(after: (end - 1) / Int64(Self.blockSize))
    return result
  }

  /// A block, from the cache or read now (the player's queue waits).
  private func block(_ index: Int64) throws -> Data {
    if let cached = cached(index) { return cached }
    let result = ResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    let client = client, path = path
    let offset = UInt64(index) * UInt64(Self.blockSize)
    Task.detached {
      do { result.value = .success(try await client.read(path, offset: offset, length: Self.blockSize)) } catch {
        result.value = .failure(error)
      }
      semaphore.signal()
    }
    semaphore.wait()
    let data = try result.value!.get()
    store(data, at: index)
    return data
  }

  private func prefetch(after index: Int64) {
    let last = (size - 1) / Int64(Self.blockSize)
    guard index < last else { return }
    for next in (index + 1)...min(last, index + Int64(Self.readAhead)) {
      let start: Bool = lock.withLock {
        guard blocks[next] == nil, !fetching.contains(next) else { return false }
        fetching.insert(next)
        return true
      }
      guard start else { continue }
      let client = client, path = path
      Task.detached { [weak self] in
        let data = try? await client.read(path, offset: UInt64(next) * UInt64(Self.blockSize), length: Self.blockSize)
        self?.lock.withLock { _ = self?.fetching.remove(next) }
        if let data { self?.store(data, at: next) }
      }
    }
  }

  private func cached(_ index: Int64) -> Data? {
    lock.withLock {
      guard let data = blocks[index] else { return nil }
      order.removeAll { $0 == index }
      order.append(index)
      return data
    }
  }

  private func store(_ data: Data, at index: Int64) {
    lock.withLock {
      blocks[index] = data
      order.removeAll { $0 == index }
      order.append(index)
      while order.count > Self.cachedBlocks { blocks[order.removeFirst()] = nil }
    }
  }

  private final class ResultBox: @unchecked Sendable { var value: Result<Data, Error>? }
}
