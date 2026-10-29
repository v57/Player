// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this repository with `V57_LOCAL=1` (in
/// Xcode, open Player-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's kits, the package at "..": SwiftPM names a path dependency after its folder, which is Player in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Player")

// The Player app, all of it but the bundle: Player.xcodeproj (at the repository's root) builds
// Sources/Player/PlayerMain.swift into Player.app with Resources (the icon, Info.plist and entitlements) and the
// FFmpeg dylibs, and links PlayerApp; on Linux the Player target below does.
let package = Package(
  name: "PlayerApp", platforms: [.macOS(.v14)],
  products: [
    .library(name: "PlayerApp", targets: ["PlayerApp"])
  ],
  dependencies: [
    // This repository's engine (PlayerKit).
    .package(path: ".."),
    // The shared design, in-app updates, screenshot scenes, the user's Hub devices and SFTP to them, and Now Playing.
    v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Vault"), v57("Database"), v57("Platform"),
  ],
  targets: [
    .target(
      name: "PlayerApp",
      dependencies: [
        .product(name: "PlayerKit", package: kits), .product(name: "ComponentKit", package: "Component"),
        .product(name: "UpdateKit", package: "UpdateKit"), .product(name: "DevScreenshots", package: "Dev"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
        .product(name: "SSHTunnel", package: "Database"), .product(name: "PlatformMedia", package: "Platform"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
        .enableUpcomingFeature("MemberImportVisibility"),
      ])
  ])

#if os(Linux)
// The app on v57/SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Player; SwiftUI's
// Linux/scripts/build-app stages it). The frameworks the app imports (SwiftData, SQLite3, Combine) are v57/SwiftUI's
// stand-ins. Only here: on Apple platforms v57/SwiftUI (with its swift-syntax) stays out of the package graph Xcode
// resolves.
package.dependencies += [v57("SwiftUI")]
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
  // On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published) and URLSession along.
  .unsafeFlags(
    ["Combine", "FoundationNetworking", "SwiftUIPortability"].flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }),
]
for target in package.targets where target.name == "PlayerApp" {
  target.dependencies += [
    .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftData", package: "SwiftUI"),
    .product(name: "SQLite3", package: "SwiftUI"),
  ]
  target.swiftSettings = appSettings
}
// The entry point, Sources/Player/PlayerMain.swift, which the Xcode project builds on macOS.
package.targets.append(
  .executableTarget(
    name: "Player", dependencies: ["PlayerApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: appSettings))
package.products.append(.executable(name: "Player", targets: ["Player"]))
#endif
