import ComponentKit
import PlayerKit
import SwiftUI

/// The timeline on the video's bottom edge: elapsed time, the scrubber, total time. No scrim and no outline: the times
/// and the slider each cast one soft shadow, so they read on any frame without darkening the picture. Always dark.
struct TimelineBar: View {
  @ObservedObject var player: SomePlayerBox

  /// Value shown while the user is dragging; the slider only follows
  /// `player.position` when not scrubbing, so the poll timer can't fight
  /// the user's thumb.
  @State private var scrubValue: Double = 0
  @State private var isScrubbing = false

  var body: some View {
    HStack(spacing: 10) {
      time(player.position).frame(width: 50, alignment: .trailing)

      KitSlider(
        "Timeline",
        value: Binding(
          get: { isScrubbing ? scrubValue : player.position },
          set: { newValue in
            scrubValue = newValue
            // Live preview while dragging; plain (keyframe) seeks
            // are cheap enough for every tick.
            if isScrubbing { player.seek(to: newValue) }
          }), in: 0...max(player.duration, 0.001), format: { MediaTime(seconds: $0).displayString }
      ) { editing in
        if editing {
          isScrubbing = true
          scrubValue = player.position
        } else {
          // Land exactly on the released value.
          player.seek(to: scrubValue, exact: true)
          isScrubbing = false
        }
      }
      .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
      .disabled(player.duration <= 0)

      time(player.duration).frame(width: 50, alignment: .leading)
    }
    .environment(\.colorScheme, .dark)
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }

  /// A time in bold white with one soft shadow (bold, so the halo has enough ink around it to read on white).
  private func time(_ seconds: Double) -> some View {
    Text(MediaTime(seconds: seconds).displayString)
      .kitFont(.callout)
      .fontWeight(.bold)
      .monospacedDigit()
      .foregroundStyle(Color.white)
      .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
  }
}
