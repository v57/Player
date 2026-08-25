import Foundation

/// User-selectable audio enhancement modes. Pure value type: the raw string
/// is the mode's stable identity (survives user-defaults round trips), and
/// each mode maps to one pinned `AudioEnhancementPreset`.
public enum AudioEnhancementMode: String, CaseIterable, Sendable, Identifiable {
  case original, balanced, dialogue

  public var id: String { rawValue }

  /// User-facing menu label (no compressor jargon).
  public var displayName: String {
    switch self {
    case .original: return "Original"
    case .balanced: return "Balanced"
    case .dialogue: return "Enhance Dialogue"
    }
  }
}
