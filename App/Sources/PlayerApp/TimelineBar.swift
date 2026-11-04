import ComponentKit
import PlayerKit
import SwiftUI

/// The timeline on the video's bottom edge: elapsed time, the scrubber, total time. No scrim: the times wear a tight
/// dark edge and a soft halo, and the slider is the kit's on-video style, so they read on any frame without darkening
/// the picture. Always dark.
///
/// `player.position` moves ~5 Hz while playing: only `ElapsedTime` and `TimelineScrubber` read it, so only they redraw.
struct TimelineBar: View {
  let player: SomePlayerBox

  var body: some View {
    HStack(spacing: 10) {
      ElapsedTime(player: player).frame(width: 50, alignment: .trailing)

      TimelineScrubber(player: player)
        // Clears the knob, which overhangs the track's ends, from the times at the start and the end.
        .padding(.horizontal, 6)

      TimelineTime(seconds: player.duration).frame(width: 50, alignment: .leading)
    }
    .environment(\.colorScheme, .dark)
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
  }
}

private struct ElapsedTime: View {
  let player: SomePlayerBox

  var body: some View { TimelineTime(seconds: player.position) }
}

private struct TimelineScrubber: View {
  let player: SomePlayerBox

  /// Value shown while the user is dragging; the slider only follows
  /// `player.position` when not scrubbing, so the poll timer can't fight
  /// the user's thumb.
  @State private var scrubValue: Double = 0
  @State private var isScrubbing = false

  var body: some View {
    let shown = isScrubbing ? scrubValue : player.position
    KitSlider(
      "Timeline",
      value: Binding(
        get: { shown },
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
    .kitSliderStyle(.overlay)
    .disabled(player.duration <= 0)
  }
}

/// A time in semibold white (wide enough glyphs to hold an edge) with a tight dark edge, three 1pt blurs stacked to
/// darken it, then a soft spread: on a white frame the edge is what reads.
private struct TimelineTime: View {
  let seconds: Double

  var body: some View {
    Text(MediaTime(seconds: seconds).displayString)
      .kitFont(.callout)
      .fontWeight(.semibold)
      .monospacedDigit()
      .foregroundStyle(Color.white)
      .shadow(color: .black, radius: 0.5)
      .shadow(color: .black, radius: 0.5)
      .shadow(color: .black, radius: 0.5)
      .shadow(color: .black.opacity(0.7), radius: 1)
      .shadow(color: .black.opacity(0.45), radius: 2)
      .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
  }
}
