# Player

A native Mac video player for MKV and MP4, built on VideoToolbox and Metal.

- Hardware H.264 and HEVC decoding (VideoToolbox), Metal rendering.
- AAC, DTS, Dolby Digital (AC-3) and Dolby Digital Plus (E-AC-3) audio, with multichannel downmix.
- Audio modes (Audio menu): Original, Balanced, Enhance Dialogue (centre and speech lift, quieter
  wide sound), and Reduce Loud Sounds (night mode: heavy compression, less bass). Even Out Loudness
  plays every file at the same loudness (EBU R128, -23 LUFS), measured as it plays. A limiter follows
  every stage that adds gain, so no mode can clip.
- Text subtitles (SRT, ASS/SSA, WebVTT), with the chosen audio and subtitle tracks remembered.
- Resumes where you left off; plays files that are still downloading.
- Media keys and Now Playing.

The engine is the `PlayerKit` library in this repository: FFmpeg demuxes, VideoToolbox decodes
video, AVAudioEngine plays audio.

## Supported formats

| | Supported |
|---|---|
| Container | MKV (Matroska), MP4, M4V, MOV |
| Video | H.264, HEVC |
| Audio | AAC (LC, HE-AAC), DTS, AC-3, E-AC-3 |
| Subtitles | SRT, ASS/SSA, WebVTT (image subtitles such as PGS are not shown) |

## Download

[Player.zip](https://github.com/v57/Player/releases/latest/download/Player.zip) from the latest
[GitHub release](https://github.com/v57/Player/releases), signed with Developer ID and notarized. Player
checks GitHub for a new release once a day and installs it in place when you agree (turn the check off under
Player > Check for Updates Automatically). Updates come from [UpdateKit](https://github.com/v57/UpdateKit).

## Requirements

macOS 14 or later on Apple silicon. The `PlayerKit` library supports macOS 12 or later.

## Build

```bash
swift build
swift test
xcodebuild -project Player.xcodeproj -scheme Player -destination 'platform=macOS' build
```

[UpdateKit](https://github.com/v57/UpdateKit) comes from GitHub's `main` branch. To work on both, clone it next to
this repository and open `Player-Local.xcworkspace` instead of the project.
`Tests/Scripts/release-macos.sh` builds the signed and notarized `Player.zip` for a release.

## License

Player is released under the [MIT License](LICENSE).

### FFmpeg

Player uses libraries from the [FFmpeg](https://ffmpeg.org) project (libavformat, libavcodec and
libavutil, release n7.1.5) under the [GNU Lesser General Public License v2.1 or later](Sources/FFmpeg/COPYING.LGPLv2.1).
The libraries are unmodified and dynamically linked: the app ships them as separate dylibs in
`Player.app/Contents/Frameworks`, together with their license texts in `Contents/Resources`.

- Source code: [FFmpeg n7.1.5](https://github.com/FFmpeg/FFmpeg/tree/n7.1.5)
  (commit `3a0867c2bfda4a4d4309ca1a8cbdc6175e67f587`).
- Build: [`Tests/Scripts/build-ffmpeg-macos.sh`](Tests/Scripts/build-ffmpeg-macos.sh) reproduces the
  shipped dylibs from that source. Its configure line is in [`Sources/FFmpeg/REPORT.md`](Sources/FFmpeg/REPORT.md).
  It is LGPL only, with no `--enable-gpl` or `--enable-nonfree`.
- The app's About window shows the same notice, with the version read from the loaded libraries.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
