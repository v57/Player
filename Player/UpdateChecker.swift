import AppKit
import Foundation

/// Checks GitHub Releases for a newer Player and offers the download.
///
/// Chosen over Sparkle on size: Sparkle.framework (plus its XPC helpers) would
/// roughly double this ~2.6 MB app. Player is a direct download with no
/// sandbox, so the check is one HTTPS request to the GitHub API for the latest
/// release; installing stays manual (the alert opens the release download,
/// built by Tests/Scripts/release-macos.sh). Release tags are "v" + the
/// CFBundleShortVersionString.
@MainActor final class UpdateChecker {
  static let shared = UpdateChecker()

  private static let latestReleaseAPI = URL(
    string: "https://api.github.com/repos/v57/Player/releases/latest")!
  private static let downloadURL = URL(
    string: "https://github.com/v57/Player/releases/latest/download/Player.zip")!
  private static let checkInterval: TimeInterval = 24 * 60 * 60

  private enum Key {
    static let automatic = "updateCheckAutomatically"
    static let lastCheck = "updateCheckLastDate"
    static let skipped = "updateCheckSkippedVersion"
  }

  private var isChecking = false

  /// Daily background check at launch. On by default (the Player menu toggles
  /// it); PLAYER_NO_UPDATE_CHECK=1 disables it for automated runs.
  var checksAutomatically: Bool {
    get { UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: Key.automatic) }
  }

  func checkOnLaunchIfDue() {
    guard checksAutomatically,
      ProcessInfo.processInfo.environment["PLAYER_NO_UPDATE_CHECK"] != "1"
    else { return }
    let last = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date ?? .distantPast
    guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
    Task { await check(userInitiated: false) }
  }

  /// "Check for Updates…": like the background check, but also reports
  /// "up to date" and failures, and ignores a skipped version.
  func check(userInitiated: Bool) async {
    guard !isChecking else { return }
    isChecking = true
    defer { isChecking = false }
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    do {
      let release = try await fetchLatestRelease()
      UserDefaults.standard.set(Date(), forKey: Key.lastCheck)
      guard let release, let current,
        case let latest = Self.version(fromTag: release.tagName),
        Self.isVersion(latest, newerThan: current)
      else {
        if userInitiated { showUpToDate(current ?? "") }
        return
      }
      if !userInitiated, UserDefaults.standard.string(forKey: Key.skipped) == latest { return }
      showUpdateAvailable(version: latest, current: current, releasePage: release.htmlURL)
    } catch {
      NSLog("[Update] check failed: %@", error.localizedDescription)
      if userInitiated { showFailure(error) }
    }
  }

  // MARK: - GitHub

  private struct Release: Decodable {
    let tagName: String
    let htmlURL: URL
    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
    }
  }

  /// The latest published release; nil when the repository has none yet
  /// (GitHub answers 404).
  private func fetchLatestRelease() async throws -> Release? {
    var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if http.statusCode == 404 { return nil }
    guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try JSONDecoder().decode(Release.self, from: data)
  }

  // MARK: - Versions

  /// "v1.2" -> "1.2".
  nonisolated static func version(fromTag tag: String) -> String {
    tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
  }

  /// Numeric dotted comparison ("1.10" > "1.9", "1.0" == "1"); a non-numeric
  /// component compares as 0.
  nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
    let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
    let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(lhs.count, rhs.count) {
      let l = i < lhs.count ? lhs[i] : 0
      let r = i < rhs.count ? rhs[i] : 0
      if l != r { return l > r }
    }
    return false
  }

  // MARK: - Alerts

  private func showUpdateAvailable(version: String, current: String, releasePage: URL) {
    let alert = NSAlert()
    alert.messageText = "Player \(version) is available"
    alert.informativeText =
      "You have version \(current). Download the new version, then replace Player in your "
      + "Applications folder."
    alert.addButton(withTitle: "Download")
    alert.addButton(withTitle: "Release Notes")
    alert.addButton(withTitle: "Skip This Version")
    NSApp.activate()
    switch alert.runModal() {
    case .alertFirstButtonReturn: NSWorkspace.shared.open(Self.downloadURL)
    case .alertSecondButtonReturn: NSWorkspace.shared.open(releasePage)
    case .alertThirdButtonReturn: UserDefaults.standard.set(version, forKey: Key.skipped)
    default: break
    }
  }

  private func showUpToDate(_ current: String) {
    let alert = NSAlert()
    alert.messageText = "Player is up to date"
    alert.informativeText = "Version \(current) is the latest version."
    alert.runModal()
  }

  private func showFailure(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Couldn't check for updates"
    alert.informativeText = error.localizedDescription
    alert.runModal()
  }
}
