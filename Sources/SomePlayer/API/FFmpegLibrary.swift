import Foundation
import SomePlayerCDemux

/// The FFmpeg build linked at runtime, read from the loaded dylibs (not
/// hardcoded) so the app's license notice always matches what ships.
public enum FFmpegLibrary {
  /// The FFmpeg release, e.g. "n7.1.5" (av_version_info).
  public static var version: String { String(cString: media_ffmpeg_version()) }

  /// The libraries' license, e.g. "LGPL version 2.1 or later"; nil when
  /// libavformat, libavcodec and libavutil report different licenses.
  public static var license: String? { media_ffmpeg_license().map { String(cString: $0) } }

  /// The configure line the dylibs were built with.
  public static var configuration: String { String(cString: media_ffmpeg_configuration()) }

  /// Upstream source of this exact release (the tag is the version string).
  public static var sourceURL: URL {
    URL(string: "https://github.com/FFmpeg/FFmpeg/tree/\(version)")!
  }
}
