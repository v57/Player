# PlayerKit

Player's media engine: open a video, play it, pick its tracks, and show it in a SwiftUI view. Part of
[Player](README.md).

<!-- platforms: macos linux=partial -->

## Purpose

`PlayerKit` plays MKV, MP4, M4V and MOV files. On macOS FFmpeg demuxes (the `PlayerCDemux` C bridge over the
vendored libavformat, libavcodec and libavutil), VideoToolbox decodes H.264 and HEVC, Metal draws the picture and
AVAudioEngine plays the sound, with the audio modes, loudness levelling and downmix described in
[Audio and Subtitles](Audio-and-Subtitles.md). It also plays files that are still being downloaded, and byte sources
that aren't local files (a file on another device), through `MediaSources`.

On Linux the same API plays through [PlatformMedia](../../Platform/docs/PlatformMedia.md) (GStreamer) instead,
with the same persistence but without the audio modes, loudness levelling, chapters, waiting for a growing file or
`MediaSources`.

It is not a general media framework: it doesn't encode, record or edit, and it shows text subtitles only (SRT,
ASS/SSA, WebVTT), not image subtitles such as PGS. It keeps no history itself: the app supplies a
`PlayerPersistence` store.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Player.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "PlayerKit", package: "Player")]),
]
```

The package declares macOS 14. It links the FFmpeg dylibs in `Sources/FFmpeg/lib` (LGPL; see the repository's
[README](../README.md#ffmpeg)), which an app must ship next to it, as Player's Xcode project does in its Bundle
FFmpeg phase. It depends on [Platform](https://github.com/v57/Platform)'s `PlatformMedia` from GitHub's `main`; with
`V57_LOCAL=1` it builds against a `../Platform` checkout.

```swift
import PlayerKit
import SwiftUI

struct VideoView: View {
  let url: URL
  @State private var player = SomePlayerBox.makeDefault(store: nil)

  var body: some View {
    SomePlayerView(player: player)
      .task {
        do { try await player.open(url); player.play() }
        catch { print(player.errorMessage ?? "\(error)") }
      }
  }
}
```

## Main API

### The player

`SomePlayerBox.makeDefault(store:)` returns the engine for this platform (the native one on macOS, PlatformMedia's
elsewhere) inside a `SomePlayerBox`, an `@Observable` main-actor class that forwards the `SomePlayer` protocol. Put
the box in the environment for views: an `any SomePlayer` can't be observed directly. Each property is tracked on
its own, so read `position` (updated about five times a second while playing) only in the view that shows it.

- Opening: `open(_:) async throws`, `stop()`. `MediaFiles.supportedExtensions` and `MediaFiles.isSupported(_:)`
  say which files to offer.
- Transport: `play()`, `pause()`, `seek(to:exact:)` (keyframe seeks while scrubbing, `exact: true` for the final
  position), `seekRelative(_:)`, `skipChapter(_:)` (-1 or 1), `nextTrack()` and `previousTrack()` (the next or
  previous video in the same folder, by name, wrapping around).
- State: `state` (`PlaybackState`: `.idle`, `.opening`, `.buffering`, `.ready`, `.playing`, `.paused`, `.seeking`,
  `.ended`, `.failed`), `isPlaying`, `fileName`, `position` and `duration` in seconds, `errorMessage`,
  `isWaitingForFileUpdate` (paused at the end of a file that's still growing; it retries when the file changes),
  `chapters`, `volume` and `isMuted` (read only).
- Tracks: `videoTracks`, `audioTracks`, `subtitleTracks` (`MediaTrack`: `id`, `kind`, `codec`, `language`, `title`,
  `channelCount`, `sampleRate`, `isDefault`, `isForced`, `isPlayable`, `displayName`), `audioTrackID`,
  `subtitleTrackID`, `selectAudioTrack(_:)`, `selectSubtitleTrack(_:)` (nil turns subtitles off).
- Sound: `enhancementMode` (`AudioEnhancementMode`: `.original`, `.balanced`, `.dialogue`, `.night`, each with a
  `displayName`) and `normalizesLoudness` (EBU R128, -23 LUFS), both settable while playing.

### The view

`SomePlayerView(player:subtitleStyle:subtitleSample:)` shows the video and its subtitles. `SubtitleStyle` has a
`size` (`SubtitleStyle.sizes`, 14 to 48), a `width` (`.narrow`, `.medium`, `.wide`: where lines wrap) and an
`alignment` (`.left`, `.center`, `.right`). `subtitleSample` is a line shown while no subtitle is on screen, for a
style editor. On macOS it's a Metal view; on Linux PlatformMedia's video view, where the style applies only to the
sample line.

### Remembering positions and tracks

The engine asks a `PlayerPersistence` store, which the app implements and passes to `makeDefault(store:)` (the
engine holds it weakly, so keep it alive): `resumePosition(for:)` (a path), `saveCurrentPosition(path:position:duration:)`,
`latestTrackPick(kind:)` and `storeTrackPick(kind:lang:title:trackID:isOff:)` (a `PlayerTrackPick`), and
`storeBookmark(path:bookmark:)` (a security-scoped bookmark, for a recent list in a sandboxed app). With a store, a
video opens where it was left and with the audio and subtitle tracks matching the last ones picked.

### Other sources

A file that isn't on disk (Player reads one from another device over SFTP) plays through a `MediaByteSource`:
`size` and `read(at:length:)`, called from the player's pipeline and allowed to block. `MediaSources.register(_:name:)`
returns a `player-stream://` URL to pass to `open(_:)`; `MediaSources.unregister(_:)` drops the source when done.
The source does its own caching and read-ahead.

### FFmpeg

`FFmpegLibrary.version`, `license`, `configuration` and `sourceURL`: what an About window must show for the LGPL.

## Testing

```bash
swift test
```

Check Release builds as well as Debug: some decoder bugs show up only in Release.

## Related

- [PlatformMedia](../../Platform/docs/PlatformMedia.md): the engine on Linux.
- [Open from Device](Open-from-Device.md): Player's `MediaByteSource` over SFTP.
