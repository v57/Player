import ComponentKit
import PlayerKit
import SSHTunnel
import SwiftUI
import VaultKit
import VaultUI

/// Open from Device: the Hub devices of one account (picked in the Devices header), then a device's folders and
/// videos; picking a video plays it from there.
struct HubLibrarySheet: View {
  /// The account whose devices the sheet shows, kept per window; Personal until another is picked.
  @SceneStorage("openFromDevice.account") private var accountID = VaultAccount.personal.id

  var body: some View {
    // A library per account: switching it leaves the device being browsed.
    VaultAccountScope(selection: $accountID) { vault in HubLibraryBrowser(vault: vault) }
  }
}

/// The sheet for one account's devices.
private struct HubLibraryBrowser: View {
  @EnvironmentObject private var player: SomePlayerBox
  @StateObject private var library: HubLibrary
  @Environment(\.kitDismiss) private var dismiss

  init(vault: Vault) {
    _library = StateObject(wrappedValue: HubLibrary(vault: vault))
  }

  var body: some View {
    KitSheet(
      title: "Open from Device", meta: "Videos on your other devices, played as they're read, through your Hub.",
      systemImage: "point.3.connected.trianglepath.dotted", hue: .indigo, width: 560
    ) {
      if let place = library.place {
        folder(place)
      } else {
        devices
      }
      if let error = library.error {
        Banner("Couldn’t reach the device.", message: error, systemImage: "exclamationmark.triangle", hue: .red)
      }
    } footer: {
      if library.place != nil {
        Button("Devices") { library.leave() }
        Button("Up", systemImage: "arrow.up") { Task { await library.up() } }.disabled(library.place?.path == "/")
      }
      Spacer()
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
    }
  }

  @ViewBuilder private var devices: some View {
    let hosts = library.hosts
    KitSection("Devices", meta: hosts.isEmpty ? "none yet" : "\(hosts.count) on your Hub", systemImage: "point.3.connected.trianglepath.dotted", hue: .indigo) {
      if hosts.isEmpty {
        Text("Add your Hub in the Vault app: its devices that offer SSH show up here.").kitFont(.caption).padding(8)
      }
      ForEach(hosts) { host in
        SidebarRow(host.displayName, subtitle: host.hostname, systemImage: "desktopcomputer", hue: .indigo)
          .action { Task { await library.browse(hostID: host.id) } }
      }
    } accessory: {
      VaultAccountPicker(style: .compact)
    }
  }

  @ViewBuilder private func folder(_ place: HubLibrary.Place) -> some View {
    KitSection(
      (place.path as NSString).lastPathComponent.isEmpty ? "/" : (place.path as NSString).lastPathComponent,
      meta: [library.host(id: place.hostID)?.displayName ?? "", place.path],
      systemImage: "folder", hue: .indigo, status: library.isLoading ? .working(progress: nil) : .idle
    ) {
      if library.entries.isEmpty, !library.isLoading {
        Text("No folders or videos here.").kitFont(.caption).padding(8)
      }
      ScrollView {
        VStack(spacing: 0) {
          ForEach(library.entries, id: \.path) { entry in
            SidebarRow(
              entry.name, subtitle: entry.isDirectory ? "Folder" : entry.size.formatted(.byteCount(style: .file)),
              systemImage: entry.isDirectory ? "folder" : "film", hue: entry.isDirectory ? .gray : .indigo
            ).action { open(entry, in: place) }
          }
        }
      }
      .frame(maxHeight: 360)
    }
  }

  private func open(_ entry: SFTPFileInfo, in place: HubLibrary.Place) {
    Task {
      if entry.isDirectory {
        await library.browse(hostID: place.hostID, path: entry.path)
      } else if let url = await library.stream(entry) {
        dismiss()
        try? await player.open(url)
      }
    }
  }
}
