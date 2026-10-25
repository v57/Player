import Foundation
import PlayerKit

/// Persists the subtitle style the user applied in Edit Style (UserDefaults, like AudioEnhancementPreferences).
enum SubtitleStylePreferences {
  private static let sizeKey = "subtitleSize"
  private static let widthKey = "subtitleWidth"
  private static let alignmentKey = "subtitleAlignment"

  static var style: SubtitleStyle {
    get {
      let defaults = UserDefaults.standard
      var style = SubtitleStyle()
      if defaults.object(forKey: sizeKey) != nil {
        style.size = min(max(defaults.double(forKey: sizeKey), SubtitleStyle.sizes.lowerBound), SubtitleStyle.sizes.upperBound)
      }
      if let width = defaults.string(forKey: widthKey).flatMap(SubtitleStyle.Width.init) { style.width = width }
      if let alignment = defaults.string(forKey: alignmentKey).flatMap(SubtitleStyle.Alignment.init) {
        style.alignment = alignment
      }
      return style
    }
    set {
      let defaults = UserDefaults.standard
      defaults.set(newValue.size, forKey: sizeKey)
      defaults.set(newValue.width.rawValue, forKey: widthKey)
      defaults.set(newValue.alignment.rawValue, forKey: alignmentKey)
    }
  }
}
