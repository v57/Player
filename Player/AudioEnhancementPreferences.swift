import Foundation
import MediaPlayer

/// Persists the user's dialogue-enhancement mode.
///
/// The app's persistence is SwiftData playback history (PlaybackStore); a UI
/// preference does not belong in that schema, so the mode lives in
/// UserDefaults (documented decision in the dialogue-enhancement plan, Task 9).
enum AudioEnhancementPreferences {
  private static let key = "audioEnhancementMode"

  static var current: AudioEnhancementMode {
    AudioEnhancementMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .original
  }

  static func save(_ mode: AudioEnhancementMode) {
    UserDefaults.standard.set(mode.rawValue, forKey: key)
  }
}
