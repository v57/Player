import PlayerKit
import SwiftUI

/// "Audio" and "Subtitles" menus in the app menu bar, listing the current
/// file's tracks with a checkmark on the active one.
struct PlayerCommands: Commands {
  @ObservedObject var player: SomePlayerBox
  @ObservedObject var uiState: PlayerUIState

  var body: some Commands {
    // About panel with the MIT and FFmpeg LGPL credits.
    #if os(macOS)
      CommandGroup(replacing: .appInfo) { Button("About Player") { AboutPanel.show() } }
    #endif
    CommandGroup(before: .newItem) {
      Button("Open…") { uiState.showFileImporter = true }.keyboardShortcut("o", modifiers: .command)
      Button("Open from Device…") { uiState.showHubLibrary = true }.keyboardShortcut("o", modifiers: [.command, .shift])
    }
    CommandMenu("Playback") {
      // No keyboard shortcut on Play/Pause: a bare-Space menu key
      // equivalent is unreliable on macOS (and steals Space from other
      // controls). Space is handled by the video view's keyDown and the
      // window event monitor fallback (PlayerUIState), which are
      // reliable regardless of first responder.
      Button("Play/Pause") { togglePlayPause() }
      Divider()
      Button("Previous Chapter") { player.skipChapter(-1) }.keyboardShortcut(
        .leftArrow, modifiers: .command
      ).disabled(player.chapters.isEmpty)
      Button("Next Chapter") { player.skipChapter(1) }.keyboardShortcut(
        .rightArrow, modifiers: .command
      ).disabled(player.chapters.isEmpty)
    }
    // Reserve F7/F8 for the media keys (play/pause is Space).
    CommandGroup(after: .sidebar) { EmptyView() }
    CommandMenu("Audio") {
      // Dialogue-enhancement mode: plain-language rows, persisted across
      // launches; no compressor jargon in the player UI (spec).
      Divider()
      if player.audioTracks.isEmpty {
        Text("No audio tracks").disabled(true)
      } else {
        ForEach(player.audioTracks) { track in
          Toggle(
            track.displayName,
            isOn: Binding(
              get: { player.audioTrackID == track.id },
              set: { on in if on { player.selectAudioTrack(track.id) } })
          ).disabled(!track.isPlayable)
        }
      }
      Divider()
      Section("Mode") {
        ForEach(AudioEnhancementMode.allCases) { mode in
          Toggle(
            mode.displayName,
            isOn: Binding(
              get: { player.enhancementMode == mode },
              set: { on in
                guard on else { return }
                player.enhancementMode = mode
                AudioEnhancementPreferences.save(mode)
              }))
        }
      }
      Toggle(
        "Even Out Loudness",
        isOn: Binding(
          get: { player.normalizesLoudness },
          set: { on in
            player.normalizesLoudness = on
            AudioEnhancementPreferences.normalizesLoudness = on
          }))
    }
    CommandMenu("Subtitles") {
      Toggle(
        "Off",
        isOn: Binding(
          get: { player.subtitleTrackID == nil },
          set: { on in if on { player.selectSubtitleTrack(nil) } }))
      if !player.subtitleTracks.isEmpty {
        Divider()
        ForEach(player.subtitleTracks) { track in
          Toggle(
            track.displayName,
            isOn: Binding(
              get: { player.subtitleTrackID == track.id },
              set: { on in if on { player.selectSubtitleTrack(track.id) } })
          ).disabled(!track.isPlayable)
        }
      } else {
        Text("No subtitle tracks").disabled(true)
      }
      Divider()
      Button("Edit Style…") { uiState.showSubtitleStyle = true }.disabled(player.fileName == nil)
    }
  }

  /// Play/pause through the box (Playback menu command).
  private func togglePlayPause() { if player.isPlaying { player.pause() } else { player.play() } }
}
