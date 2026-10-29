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
        VStack(alignment: .leading, spacing: 14) {
          field("Size", value: "\(Int(uiState.subtitleStyle.size)) pt") {
            KitSlider(
              "Size", value: $uiState.subtitleStyle.size, in: SubtitleStyle.sizes, step: 1,
              format: { "\(Int($0)) pt" })
          }
          field("Width") {
            KitSegmented(
              selection: $uiState.subtitleStyle.width,
              options: SubtitleStyle.Width.allCases.map { ($0.title, $0) }
            )
            .kitSegmentedStyle(.wide)
          }
          field("Alignment") {
            KitSegmented(
              selection: $uiState.subtitleStyle.alignment,
              segments: SubtitleStyle.Alignment.allCases.map {
                KitSegment($0.title, value: $0, systemImage: $0.systemImage)
              }
            )
            .kitSegmentedStyle(.wide)
          }
        }
        .padding(12)
      }
    } footer: {
      Button("Apply") {
        SubtitleStylePreferences.style = uiState.subtitleStyle
        uiState.showSubtitleStyle = false
      }
      .buttonStyle(.kitPrimary)
    }
    // The kit overlays' card (the panel ground, 20pt corners, a hairline and the float shadow), without the dim.
    .clipShape(.rect(cornerRadius: KitMetrics.radiusOverlay, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: KitMetrics.radiusOverlay, style: .continuous).strokeBorder(.kitBorder, lineWidth: 0.5)
    }
    .kitSurface(.floating, cornerRadius: KitMetrics.radiusOverlay)
  }

  /// A labelled control: the label (and its value at the end) over the control, full width.
  private func field<Control: View>(_ title: String, value: String? = nil, @ViewBuilder control: () -> Control)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).kitFont(.headline)
        Spacer()
        if let value { Text(value).kitFont(.callout).monospacedDigit().foregroundStyle(.kitSecondary) }
      }
      control()
    }
  }
}
