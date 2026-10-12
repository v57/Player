import AppKit
import PlayerKit

/// The standard About panel with credits: Player's MIT license and the FFmpeg
/// LGPL notice (FFmpeg's legal checklist asks for it in the about box). The
/// FFmpeg version and license are read from the loaded dylibs, so the notice
/// always matches what ships; the license texts are bundled by the "Bundle
/// FFmpeg" build phase.
enum AboutPanel {
  static func show() {
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    NSApp.activate()
  }

  static func credits() -> NSAttributedString {
    let resources = Bundle.main.resourceURL
    let license = FFmpegLibrary.license ?? "LGPL version 2.1 or later"
    let text = NSMutableAttributedString()
    func add(_ string: String, link: URL? = nil, bold: Bool = false) {
      var attributes: [NSAttributedString.Key: Any] = [
        .font: bold
          ? NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
          : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.labelColor,
      ]
      if let link { attributes[.link] = link }
      text.append(NSAttributedString(string: string, attributes: attributes))
    }

    add("© 2026 Dmitry Kozlov. Free software under the ")
    add("MIT License", link: URL(string: "https://github.com/v57/Player/blob/main/LICENSE"))
    add(". Source: ")
    add("github.com/v57/Player", link: URL(string: "https://github.com/v57/Player"))
    add(".\n\n")

    add("FFmpeg\n", bold: true)
    add(
      "This app uses libraries from the FFmpeg project (libavformat, libavcodec, libavutil "
        + "\(FFmpegLibrary.version)) under the GNU Lesser General Public License, \(license). "
        + "They are unmodified and dynamically linked (Contents/Frameworks). Source code: ")
    add("FFmpeg \(FFmpegLibrary.version)", link: FFmpegLibrary.sourceURL)
    add(", built with ")
    add(
      "build-ffmpeg-macos.sh",
      link: URL(
        string: "https://github.com/v57/Player/blob/main/Tests/Scripts/build-ffmpeg-macos.sh"))
    add(". License: ")
    add(
      "LGPL v2.1",
      link: resources?.appendingPathComponent("COPYING.LGPLv2.1.txt")
        ?? URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html"))
    add(" (")
    add("FFmpeg license notes", link: resources?.appendingPathComponent("LICENSE.FFmpeg.txt"))
    add("). FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.")

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    text.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    return text
  }
}
