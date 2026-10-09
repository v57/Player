// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Vendored FFmpeg dylibs, resolved from the package root so the package
// builds from any checkout location (it used to hardcode /Users/v57/...).
let ffmpegLibDir = Context.packageDirectory + "/Sources/FFmpeg/lib"

let package = Package(
  name: "SomePlayer", platforms: [.macOS(.v27)],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(name: "SomePlayer", targets: ["SomePlayer"])
  ],
  targets: [
    // C bridge over FFmpeg (libavformat/libavcodec/libavutil). SwiftPM
    // requires C and Swift to live in separate targets; this one owns the
    // MediaDemuxer shim and links the vendored FFmpeg dylibs (headers +
    // libs under Sources/FFmpeg, package-relative).
    .target(
      name: "SomePlayerCDemux", publicHeadersPath: ".",
      cSettings: [.headerSearchPath("../FFmpeg/include")],
      linkerSettings: [
        .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
        .unsafeFlags(["-L" + ffmpegLibDir]),
      ], ),
    // The media engine: demux wrapper, decode, playback, persistence
    // seam, and the SomePlayerView SwiftUI surface.
    .target(
      name: "SomePlayer", dependencies: ["SomePlayerCDemux"],
      swiftSettings: [.enableUpcomingFeature("ApproachableConcurrency")], ),
    .testTarget(
      name: "SomePlayerTests", dependencies: ["SomePlayer"], path: "Tests/SomePlayerTests",
      linkerSettings: [
        // The library's FFmpeg dylibs carry @rpath install names; the
        // test bundle must resolve that rpath to the vendored lib dir
        // to dlopen the library at test runtime.
        .unsafeFlags([
          "-Xlinker", "-rpath", "-Xlinker", ffmpegLibDir,
        ])
      ], ),
  ], cLanguageStandard: .gnu17)
