import SwiftUI
import MediaPlayer

/// Bottom timeline: elapsed / total time plus a scrubbing slider.
struct TimelineBar: View {
    @ObservedObject var player: MediaPlayerBox

    /// Value shown while the user is dragging; the slider only follows
    /// `player.position` when not scrubbing, so the poll timer can't fight
    /// the user's thumb.
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 10) {
            Text(MediaTime(seconds: player.position).displayString)
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : player.position },
                    set: { newValue in
                        scrubValue = newValue
                        // Live preview while dragging; plain (keyframe) seeks
                        // are cheap enough for every tick.
                        if isScrubbing {
                            player.seek(to: newValue)
                        }
                    }
                ),
                in: 0...max(player.duration, 0.001)
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
            .disabled(player.duration <= 0)
            .accessibilityLabel("Timeline")

            Text(MediaTime(seconds: player.duration).displayString)
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
