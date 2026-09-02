import SomePlayer
import SwiftUI

/// "Audio" and "Subtitles" menus in the app menu bar, listing the current
/// file's tracks with a checkmark on the active one.
struct PlayerCommands: Commands {
  @ObservedObject var player: SomePlayerBox
  @ObservedObject var uiState: PlayerUIState

  var body: some Commands {
    CommandGroup(before: .newItem) {
      Button("Open…") { uiState.showFileImporter = true }.keyboardShortcut("o", modifiers: .command)
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
              set: { on in if on { player.selectAudioTrack(track.id) } }))
        }
      }
      Divider()
      Section("Mode") {
        ForEach(AudioEnhancementMode.allCases) { mode in
          Button(mode.displayName) {
            player.enhancementMode = mode
            AudioEnhancementPreferences.save(mode)
          }
        }
      }
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
              set: { on in if on { player.selectSubtitleTrack(track.id) } }))
        }
      } else {
        Text("No subtitle tracks").disabled(true)
      }
    }
  }

  /// Play/pause through the box (Playback menu command).
  private func togglePlayPause() { if player.isPlaying { player.pause() } else { player.play() } }
}
