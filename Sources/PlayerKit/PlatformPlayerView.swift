#if !canImport(VideoToolbox)
  import PlatformMedia
  import SwiftUI

  /// The library's video view where the native engine doesn't run: PlatformMedia's picture of the engine's player,
  /// with the subtitle style's sample line while the style is edited (the engine draws the subtitles themselves
  /// into the picture).
  public struct SomePlayerView: View {
    @ObservedObject public var player: SomePlayerBox
    var subtitleStyle: SubtitleStyle
    var subtitleSample: String?

    public init(player: SomePlayerBox, subtitleStyle: SubtitleStyle = SubtitleStyle(), subtitleSample: String? = nil) {
      self.player = player
      self.subtitleStyle = subtitleStyle
      self.subtitleSample = subtitleSample
    }

    public var body: some View {
      ZStack(alignment: .bottom) {
        if let engine = player.engine as? PlatformSomePlayer {
          PlatformVideoView(player: engine.player)
        } else {
          Color.black
        }
        if let subtitleSample {
          Text(subtitleSample)
            .font(.system(size: subtitleStyle.size, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(textAlignment)
            .shadow(color: .black.opacity(0.9), radius: 2)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding(.horizontal, 24)
            .padding(.bottom, 72)
        }
      }
    }

    private var textAlignment: TextAlignment {
      switch subtitleStyle.alignment {
      case .leading: .leading
      case .center: .center
      case .trailing: .trailing
      }
    }

    private var frameAlignment: Alignment {
      switch subtitleStyle.alignment {
      case .leading: .leading
      case .center: .center
      case .trailing: .trailing
      }
    }
  }
#endif
