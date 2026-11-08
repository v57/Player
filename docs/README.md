# Player user guide

Player is a video player for the Mac. It plays MKV, MP4, M4V and MOV files with hardware decoding, has audio modes that
make dialogue clearer or loud scenes quieter, shows text subtitles, and remembers where you stopped. It can play a video
while it's still downloading, and stream one from another of your devices with **Open from Device…**.

## Platforms

- **Mac:** macOS 14 or later, on Apple silicon.
- **iPhone and iPad:** no app. Player runs on the Mac only.
- **Linux:** Player builds for Linux on v57's own SwiftUI and plays through GStreamer, but this build isn't released
  yet. It lacks the audio modes and Even Out Loudness, chapters, **Open from Device…**, waiting for a download and the
  subtitle style.
- **Windows:** no build.

## Supported formats

| | Supported |
|---|---|
| Files | MKV, MP4, M4V, MOV |
| Video | H.264, HEVC |
| Audio | AAC (including HE-AAC), DTS, Dolby Digital (AC-3), Dolby Digital Plus (E-AC-3) |
| Subtitles | SRT, ASS/SSA, WebVTT. Image subtitles, such as PGS, aren't shown. |

## Pages

- [Getting Started](Getting-Started.md): open a video, the welcome screen and the window.
- [Playback](Playback.md): the timeline, chapters, full screen, resume, media keys and videos still downloading.
- [Audio and Subtitles](Audio-and-Subtitles.md): tracks, audio modes, loudness and subtitle style.
- [Open from Device](Open-from-Device.md): play a video that's on another of your devices.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md)
- [Privacy and Security](Privacy-and-Security.md): what Player sends over the network, keys and iCloud.

## Works with other v57 apps

- [Get](https://github.com/v57/Get/blob/main/docs/README.md) downloads videos in order, so Player can start one before
  it's complete. When Get moves the finished file into Downloads, Player's recent list follows it and keeps your place.
- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) keeps the list of your devices. **Open from Device…**
  lists the devices your vault knows: your Hub devices and the Macs that let your devices in. Player signs in to them
  with its own key, which you allow per Mac in **Vault ▸ Settings ▸ Remote**.
- [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md) devices, such as a home server, can hold the videos you
  open with **Open from Device…**.

## Network

Player plays files. It contacts another device only when you use **Open from Device…**, GitHub only when you check for
updates, and iCloud while iCloud is on. See [Privacy and Security](Privacy-and-Security.md).
