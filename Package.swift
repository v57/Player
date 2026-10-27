// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Vendored FFmpeg dylibs, resolved from the package root so the package
// builds from any checkout location (it used to hardcode /Users/v57/...).
let ffmpegLibDir = Context.packageDirectory + "/Sources/FFmpeg/lib"

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1` (in Xcode,
/// open Player-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}

let package = Package(
  name: "Player", platforms: [.macOS(.v14)],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(name: "PlayerKit", targets: ["PlayerKit"])
  ],
  dependencies: [
    // PlatformMedia: the engine off macOS (GStreamer on Linux) and the Now Playing / media keys integration.
    v57("Platform")
  ],
  targets: [
    // C bridge over FFmpeg (libavformat/libavcodec/libavutil). SwiftPM
    // requires C and Swift to live in separate targets; this one owns the
    // MediaDemuxer shim and links the vendored FFmpeg dylibs (headers +
    // libs under Sources/FFmpeg, package-relative) and AudioToolbox (AAC).
    .target(
      name: "PlayerCDemux", publicHeadersPath: ".",
      cSettings: [.headerSearchPath("../FFmpeg/include")],
      linkerSettings: [
        .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
        .linkedFramework("AudioToolbox"),
        .unsafeFlags(["-L" + ffmpegLibDir]),
      ], ),
    // The media engine: demux wrapper, decode, playback, persistence
    // seam, and the SomePlayerView SwiftUI surface.
    .target(
      name: "PlayerKit", dependencies: ["PlayerCDemux", .product(name: "PlatformMedia", package: "Platform")],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "PlayerKitTests", dependencies: ["PlayerKit"], path: "Tests/PlayerKitTests",
      linkerSettings: [
        // The library's FFmpeg dylibs carry @rpath install names; the
        // test bundle must resolve that rpath to the vendored lib dir
        // to dlopen the library at test runtime.
        .unsafeFlags([
          "-Xlinker", "-rpath", "-Xlinker", ffmpegLibDir,
        ])
      ], ),
  ], cLanguageStandard: .gnu17)

#if os(Linux)
// Linux: PlayerKit plays through PlatformMedia (GStreamer) instead of the native engine (FFmpeg dylibs built for
// macOS, VideoToolbox, Metal, AVAudioEngine), and the app is an executable on v57/SwiftUI's GTK backend built from
// the Xcode app folder (SwiftUI's Linux/scripts/build-app stages it). The frameworks the app imports (SwiftData,
// SQLite3, Combine) are v57/SwiftUI's stand-ins.
package.dependencies += [
  v57("SwiftUI"), v57("Component"), v57("UpdateKit"), v57("Dev"), v57("Vault"), v57("Database"),
]
package.targets.removeAll { $0.name == "PlayerCDemux" || $0.name == "PlayerKitTests" }
for target in package.targets where target.name == "PlayerKit" {
  target.dependencies = [
    .product(name: "PlatformMedia", package: "Platform"), .product(name: "SwiftUI", package: "SwiftUI"),
  ]
  target.exclude = [
    "Playback/NativeSomePlayer.swift", "Playback/PlaybackController.swift", "FFmpegDemuxer.swift",
    "SomePlayerView.swift", "API/FFmpegLibrary.swift", "AudioEnhancement",
  ]
}
package.targets.append(
  .executableTarget(
    name: "PlayerApp",
    dependencies: [
      "PlayerKit", .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftData", package: "SwiftUI"),
      .product(name: "SQLite3", package: "SwiftUI"), .product(name: "ComponentKit", package: "Component"),
      .product(name: "UpdateKit", package: "UpdateKit"), .product(name: "DevScreenshots", package: "Dev"),
      .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
      .product(name: "SSHTunnel", package: "Database"), .product(name: "PlatformMedia", package: "Platform"),
    ],
    path: "Player", exclude: ["Info.plist", "Player.entitlements", "AppIcon.icon"],
    swiftSettings: [
      .swiftLanguageMode(.v5), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
      .enableUpcomingFeature("MemberImportVisibility"),
      // On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published) and URLSession along.
      .unsafeFlags(
        ["Combine", "FoundationNetworking", "SwiftUIPortability"].flatMap {
          ["-Xfrontend", "-import-module", "-Xfrontend", $0]
        }),
    ]))
package.products.append(.executable(name: "Player", targets: ["PlayerApp"]))
#endif
