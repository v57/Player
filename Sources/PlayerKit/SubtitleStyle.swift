import CoreGraphics
import Foundation

/// How subtitles draw: the text's size in points (the same in any window size), how wide the lines run before they
/// wrap, and where they sit across the bottom of the video.
public struct SubtitleStyle: Hashable, Sendable {
  /// How wide the subtitle lines run before they wrap, as a share of the video's width.
  public enum Width: String, CaseIterable, Sendable {
    case narrow, medium, wide

    public var title: String {
      switch self {
      case .narrow: String(localized: "Narrow")
      case .medium: String(localized: "Medium")
      case .wide: String(localized: "Wide")
      }
    }

    var fraction: CGFloat {
      switch self {
      case .narrow: 0.6
      case .medium: 0.8
      case .wide: 0.94
      }
    }
  }

  /// Where the lines sit and how they line up: at the left, in the middle, or at the right of the video.
  public enum Alignment: String, CaseIterable, Sendable {
    case leading, center, trailing

    public var title: String {
      switch self {
      case .leading: String(localized: "Left")
      case .center: String(localized: "Center")
      case .trailing: String(localized: "Right")
      }
    }

    public var systemImage: String {
      switch self {
      case .leading: "text.alignleft"
      case .center: "text.aligncenter"
      case .trailing: "text.alignright"
      }
    }
  }

  /// The sizes the text can take, in points.
  public static let sizes: ClosedRange<Double> = 14...48

  public var size: Double
  public var width: Width
  public var alignment: Alignment

  public init(size: Double = 24, width: Width = .medium, alignment: Alignment = .center) {
    self.size = size
    self.width = width
    self.alignment = alignment
  }
}
