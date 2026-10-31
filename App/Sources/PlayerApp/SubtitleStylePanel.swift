import ComponentKit
import PlayerKit
import SwiftUI

/// Edit Style (Subtitles menu): the subtitles' size, width and alignment, in a panel at the window's right side over
/// the video, which keeps playing. Every change shows on the video at once (a sample line while no cue is on
/// screen); Apply keeps the style and closes the panel.
struct SubtitleStylePanel: View {
  @EnvironmentObject private var uiState: PlayerUIState

  /// Shown on the video while the panel is open and no cue is: long enough to wrap at the narrow width.
  static let sample = "This is how subtitles look. A longer line like this one shows where they wrap."

  var body: some View {
    KitSheet(
      title: "Subtitle Style", meta: "Changes show on the video as you make them.", systemImage: "captions.bubble",
      hue: .indigo, width: 320
    ) {
      FormCard {
        FormRow("Size", value: "\(Int(uiState.subtitleStyle.size)) pt") {
          KitSlider(
            "Size", value: $uiState.subtitleStyle.size, in: SubtitleStyle.sizes, step: 1,
            format: { "\(Int($0)) pt" })
        }
        FormRow("Width") {
          KitSegmented(
            selection: $uiState.subtitleStyle.width,
            options: SubtitleStyle.Width.allCases.map { ($0.title, $0) }
          )
          .kitSegmentedStyle(.wide)
        }
        FormRow("Alignment") {
          KitSegmented(
            selection: $uiState.subtitleStyle.alignment,
            segments: SubtitleStyle.Alignment.allCases.map {
              KitSegment($0.title, value: $0, systemImage: $0.systemImage)
            }
          )
          .kitSegmentedStyle(.wide)
        }
      }
    } footer: {
      Button("Apply") {
        SubtitleStylePreferences.style = uiState.subtitleStyle
        uiState.showSubtitleStyle = false
      }
      .buttonStyle(.kitPrimary)
    }
    // The kit overlays' card, without the dim: the video keeps playing beside it.
    .kitOverlayCard()
  }
}
