import AppKit
import CoreGraphics
import CoreVideo
import Metal
import SwiftUI

/// The library's main SwiftUI view: hosts the native Metal video surface and
/// registers it as the engine's VideoFrameSink. Presents CVPixelBuffers via
/// CAMetalLayer + the YUV->RGB shader (KANBAN: player pushes, view consumes).
///
/// The app passes its boxed player (the same object it injects as
/// @EnvironmentObject); the view conditional-casts to the native engine to
/// register the sink — mirroring the old app-side NativeVideoView.
public struct SomePlayerView: NSViewRepresentable {
  @ObservedObject public var player: SomePlayerBox
  var subtitleStyle: SubtitleStyle
  var subtitleSample: String?

  /// `subtitleSample` shows while no cue is on screen (a style being edited, on a video without subtitles).
  public init(player: SomePlayerBox, subtitleStyle: SubtitleStyle = SubtitleStyle(), subtitleSample: String? = nil) {
    self.player = player
    self.subtitleStyle = subtitleStyle
    self.subtitleSample = subtitleSample
  }

  public func makeNSView(context: Context) -> MediaMetalView {
    let view = MediaMetalView(frame: .zero)
    view.player = player
    view.subtitleStyle = subtitleStyle
    view.subtitleSample = subtitleSample
    if let engine = player.engine as? NativeSomePlayer { engine.registerSink(view) }
    return view
  }

  public func updateNSView(_ nsView: MediaMetalView, context: Context) {
    nsView.player = player
    nsView.subtitleStyle = subtitleStyle
    nsView.subtitleSample = subtitleSample
    if let engine = player.engine as? NativeSomePlayer { engine.registerSink(nsView) }
  }

  public static func dismantleNSView(_ nsView: MediaMetalView, coordinator: ()) {
    nsView.tearDown()
  }
}

/// AppKit view backed by CAMetalLayer that renders decoded YUV frames.
public final class MediaMetalView: NSView, VideoFrameSink {
  private let metalLayer = CAMetalLayer()
  private var renderer: MediaMetalRenderer?
  private var currentFrame: NativeVideoFrame?
  /// Subtitle overlay (SRT Phase A): white text above the video, no box. The text layer's shadow is a tight dark
  /// edge and the halo's a soft spread around it, so the cue reads on any frame (as the timeline's times do).
  private let subtitleLayer = CATextLayer()
  private let subtitleHalo = CALayer()
  /// The cue on screen, without markup; nil while none is.
  private var subtitleCue: String?
  /// What the subtitle layer shows: the cue, else the sample; nil while neither is.
  private var subtitleText: String?
  var subtitleStyle = SubtitleStyle() {
    didSet { if subtitleStyle != oldValue { layoutSubtitleLayer() } }
  }
  var subtitleSample: String? {
    didSet { if subtitleSample != oldValue { refreshSubtitle() } }
  }
  /// The boxed player (set by the SwiftUI wrapper) for key/click transport.
  weak var player: SomePlayerBox?
  /// One-shot warnings: a frame arrived but nothing could render it.
  private var warnedRendererNil = false
  /// The window whose key notifications we observe (exactly one at a time).
  private weak var observedWindow: NSWindow?

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    metalLayer.device = MTLCreateSystemDefaultDevice()
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    layer = metalLayer
    if let device = metalLayer.device {
      renderer = try? MediaMetalRenderer(device: device, pixelFormat: metalLayer.pixelFormat)
    }
    if renderer == nil { NSLog("[Native] VIEW init: Metal renderer unavailable") }
    setupSubtitleLayer()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  public override var isOpaque: Bool { true }
  public override var acceptsFirstResponder: Bool { true }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Observe only the current window: the observer used to be added on
    // every move and removed only for the last window.
    if let observedWindow {
      NotificationCenter.default.removeObserver(
        self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
    }
    observedWindow = window
    guard let window else { return }
    // Take first responder when attached to a window, so transport keys
    // (Space/arrows/Return) work without clicking the video first. Also
    // re-grab when the window comes back key (e.g. after a sheet or
    // another app steals focus).
    DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
    NotificationCenter.default.addObserver(
      self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification,
      object: window)
  }

  @objc private func windowDidBecomeKey(_ note: Notification) {
    // Re-take first responder whenever the window becomes key again, so
    // Space keeps working after the focus moved elsewhere (timeline
    // slider, menu, other app) and returns.
    if window != nil, let window, window.isKeyWindow { window.makeFirstResponder(self) }
  }

  private func setupSubtitleLayer() {
    subtitleLayer.string = nil
    subtitleLayer.isWrapped = true
    subtitleLayer.alignmentMode = .center
    subtitleLayer.contentsScale = 2.0
    subtitleLayer.shadowColor = NSColor.black.cgColor
    subtitleLayer.shadowOpacity = 1
    subtitleLayer.shadowRadius = 1
    subtitleLayer.shadowOffset = .zero
    subtitleHalo.shadowColor = NSColor.black.cgColor
    subtitleHalo.shadowOpacity = 0.6
    subtitleHalo.shadowRadius = 4
    subtitleHalo.shadowOffset = CGSize(width: 0, height: -1)
    subtitleHalo.isHidden = true
    subtitleHalo.addSublayer(subtitleLayer)
    // Add above the video layer.
    metalLayer.addSublayer(subtitleHalo)
  }

  /// VideoFrameSink — MainActor, called by the controller.
  public func present(frame: NativeVideoFrame) {
    currentFrame = frame
    renderFrame()
    updateSubtitleOverlay()
  }

  public func clear() {
    // NOTE: NEVER set metalLayer.contents here — `.contents` is
    // unsupported on CAMetalLayer ("changing 'contents' on CAMetalLayer
    // may result in undefined behavior") and corrupts the layer so
    // subsequent drawable presentation goes black until the window is
    // recreated. Dropping currentFrame stops future renders; the layer
    // keeps its last presented drawable (frozen frame) until the next
    // file presents.
    currentFrame = nil
    showSubtitle(nil)
  }

  /// Reads the active subtitle cue from the native engine and updates the
  /// overlay. Called on every presented frame (MainActor).
  private func updateSubtitleOverlay() {
    guard let cue = (player?.engine as? NativeSomePlayer)?.activeSubtitleCue, !cue.isEmpty else {
      showSubtitle(nil)
      return
    }
    // SRT markup: strip <i>, <b>, <font> tags for Phase A plain rendering.
    showSubtitle(cue.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
  }

  private func showSubtitle(_ cue: String?) {
    guard cue != subtitleCue else { return }
    subtitleCue = cue
    refreshSubtitle()
  }

  private func refreshSubtitle() {
    let text = subtitleCue ?? subtitleSample
    guard text != subtitleText else { return }
    subtitleText = text
    subtitleHalo.isHidden = text == nil
    layoutSubtitleLayer()
  }

  /// At the bottom, clear of the timeline, in semibold at the style's size: wrapped at the style's width, the lines
  /// lined up at the left, in the middle or at the right (the block sits there too). The layer's origin is
  /// bottom-left.
  private func layoutSubtitleLayer() {
    guard let subtitleText else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    let text = NSAttributedString(
      string: subtitleText,
      attributes: [
        .font: NSFont.systemFont(ofSize: subtitleStyle.size, weight: .semibold),
        .foregroundColor: NSColor.white,
      ])
    let width = max(bounds.width * subtitleStyle.width.fraction, 200)
    let height = text.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height.rounded(.up) + 2
    let margin = (bounds.width - bounds.width * SubtitleStyle.Width.wide.fraction) / 2
    let x: CGFloat
    switch subtitleStyle.alignment {
    case .leading:
      subtitleLayer.alignmentMode = .left
      x = margin
    case .center:
      subtitleLayer.alignmentMode = .center
      x = (bounds.width - width) / 2
    case .trailing:
      subtitleLayer.alignmentMode = .right
      x = bounds.width - margin - width
    }
    subtitleLayer.string = text
    subtitleLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    subtitleHalo.frame = CGRect(x: x, y: 56, width: width, height: height)
    subtitleLayer.frame = subtitleHalo.bounds
  }

  public override func layout() {
    super.layout()
    metalLayer.frame = bounds
    metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
    layoutSubtitleLayer()
    renderFrame()
  }

  private func renderFrame() {
    guard let frame = currentFrame else { return }
    guard let renderer else {
      if !warnedRendererNil {
        warnedRendererNil = true
        NSLog("[Native] VIEW renderFrame: no Metal renderer — frames cannot be shown")
      }
      return
    }
    let backing = convertToBacking(bounds)
    guard backing.width >= 1, backing.height >= 1 else { return }
    // Aspect-fit with the source's display aspect (DAR = SAR * w/h).
    let srcW = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
    let srcH = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer))
    let displayAspect = srcW / srcH  // SAR 1:1 for the target file
    renderer.render(
      pixelBuffer: frame.pixelBuffer, into: metalLayer,
      size: CGSize(width: backing.width, height: backing.height), displayAspect: displayAspect)
  }

  func tearDown() {
    currentFrame = nil
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
    observedWindow = nil
    // (do NOT touch metalLayer.contents — see clear(); undefined on CAMetalLayer)
  }

  // MARK: - Interaction (space/return/arrows/chapters/click)

  public override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      // A double-click arrives as TWO mouseDowns: clickCount=1, then
      // clickCount=2. The first one already armed the single-click timer
      // below, so cancel it — otherwise the deferred play/pause fires
      // right after entering fullscreen.
      singleClickTimer?.invalidate()
      singleClickTimer = nil
      window?.toggleFullScreen(nil)
    } else if event.clickCount == 1 {
      // Single click toggles play/pause (deferred for double-click).
      singleClickTimer?.invalidate()
      singleClickTimer = Timer.scheduledTimer(
        withTimeInterval: NSEvent.doubleClickInterval, repeats: false
      ) {
        [weak self] _ in
        // Scheduled on the main run loop, so the callback runs on main.
        MainActor.assumeIsolated {
          guard let self else { return }
          self.singleClickTimer = nil
          self.togglePlayPause()
        }
      }
    } else {
      // Triple-click and beyond: swallow any stray pending single-click.
      singleClickTimer?.invalidate()
      singleClickTimer = nil
    }
  }

  private var singleClickTimer: Timer?

  public override func keyDown(with event: NSEvent) {
    if event.isARepeat { return }
    // NOTE: PlayerUIState's window key monitor (handleTransportKey) now
    // handles Space/Return/arrows/F5/F6 BEFORE this view and consumes
    // them, so this keyDown mostly runs only when the monitor is absent
    // (no window / not installed). Kept as the in-view fallback so the
    // video surface itself always answers transport keys.
    // Chapter keys first: with Command or as dedicated media keys, before
    // the arrow-key handling (Cmd+Left/Right must not fall through to the
    // plain -5/+5 arrow behavior).
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let hasCmd = mods.contains(.command)
    let hasCtrl = mods.contains(.control)
    let hasOpt = mods.contains(.option)
    switch event.keyCode {
    case 123:  // kVK_LeftArrow
      if hasCmd {
        player?.skipChapter(-1)
        return
      }
    case 124:  // kVK_RightArrow
      if hasCmd {
        player?.skipChapter(1)
        return
      }
    case 96:  // kVK_F5
      if !hasCmd, !hasCtrl, !hasOpt {
        player?.skipChapter(-1)
        return
      }
    case 97:  // kVK_F6
      if !hasCmd, !hasCtrl, !hasOpt {
        player?.skipChapter(1)
        return
      }
    default: break
    }

    switch event.charactersIgnoringModifiers {
    case " ": togglePlayPause()
    case "\r":  // Return/Enter
      togglePlayPause()
    case "\u{1B}":
      if let window, window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
      } else {
        super.keyDown(with: event)
      }
    default:
      switch event.keyCode {
      case 123: player?.seekRelative(-5)  // kVK_LeftArrow
      case 124: player?.seekRelative(5)  // kVK_RightArrow
      default: super.keyDown(with: event)
      }
    }
  }

  /// Play/pause through the box (menu command).
  private func togglePlayPause() {
    guard let player else { return }
    if player.isPlaying { player.pause() } else { player.play() }
  }
}

/// Minimal CAMetalLayer-backed renderer: draws a CVPixelBuffer into the
/// layer's next drawable using the YUV->RGB pipeline (PoC port).
final class MediaMetalRenderer {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pixelFormat: MTLPixelFormat
  private let pipeline: MTLRenderPipelineState
  private var textureCache: CVMetalTextureCache?
  private var nilDrawables = 0

  init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
    self.device = device
    self.pixelFormat = pixelFormat
    guard let queue = device.makeCommandQueue() else { throw MetalSetupError.noQueue }
    commandQueue = queue
    let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = lib.makeFunction(name: "quadVertex")
    desc.fragmentFunction = lib.makeFunction(name: "yuvFragment")
    desc.colorAttachments[0].pixelFormat = pixelFormat
    pipeline = try device.makeRenderPipelineState(descriptor: desc)
    var cache: CVMetalTextureCache?
    guard
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
      let cache
    else { throw MetalSetupError.noCache }
    textureCache = cache
  }

  enum MetalSetupError: Error { case noQueue, noCache }

  func render(
    pixelBuffer: CVPixelBuffer, into layer: CAMetalLayer, size: CGSize, displayAspect: CGFloat
  ) {
    guard let drawable = layer.nextDrawable() else {
      if nilDrawables == 0 {
        NSLog("[Native] VIEW renderer: nextDrawable NIL (layer not connected?)")
      }
      nilDrawables += 1
      return
    }
    nilDrawables = 0
    guard let cache = textureCache else { return }

    // Two-plane textures (Y + CbCr) from the pixel buffer.
    let w = CVPixelBufferGetWidth(pixelBuffer)
    let h = CVPixelBufferGetHeight(pixelBuffer)
    var yTexRef: CVMetalTexture?
    var uvTexRef: CVMetalTexture?
    guard
      CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm, w, h, 0, &yTexRef)
        == kCVReturnSuccess,
      CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm, w / 2, h / 2, 1, &uvTexRef)
        == kCVReturnSuccess, let yTex = yTexRef.flatMap(CVMetalTextureGetTexture),
      let uvTex = uvTexRef.flatMap(CVMetalTextureGetTexture)
    else { return }

    // Letterbox rect: source display aspect vs drawable aspect.
    let viewAspect = size.width / size.height
    var rect: SIMD4<Float>
    if displayAspect > viewAspect {
      let hh = Float(viewAspect / displayAspect)
      rect = SIMD4(0, (1 - hh) / 2, 1, hh)
    } else {
      let ww = Float(displayAspect / viewAspect)
      rect = SIMD4((1 - ww) / 2, 0, ww, 1)
    }

    guard let cmd = commandQueue.makeCommandBuffer(),
      let enc = cmd.makeRenderCommandEncoder(
        descriptor: MTLRenderPassDescriptor().withColorAttachment(drawable.texture, clear: true))
    else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
    var matrix = Self.ycbcrMatrix(for: pixelBuffer)
    enc.setFragmentBytes(&matrix, length: MemoryLayout<YCbCrMatrix>.stride, index: 0)
    enc.setFragmentTexture(yTex, index: 0)
    enc.setFragmentTexture(uvTex, index: 1)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
    cmd.present(drawable)
    cmd.commit()
  }

  /// Limited-range Y'CbCr -> R'G'B' coefficients, applied to normalized
  /// inputs Y' = (Y-16)/219 and Cb'/Cr' = (C-128)/224:
  ///   R = Y' + rCr*Cr';  G = Y' - gCb*Cb' - gCr*Cr';  B = Y' + bCb*Cb'
  /// (Kr/Kb from the standard: rCr = 2(1-Kr), bCb = 2(1-Kb), gCb = bCb*Kb/Kg,
  /// gCr = rCr*Kr/Kg). The old shader multiplied the already-normalized values
  /// by the 8-bit-domain constants (1.1644, 1.596, ...), scaling twice:
  /// luma ~16% hot with highlights clipping from Y≈204 and chroma ~14%
  /// oversaturated. It also used BT.601 for BT.709 (HD/4K) content.
  struct YCbCrMatrix {
    var rCr: Float
    var gCb: Float
    var gCr: Float
    var bCb: Float

    static let bt601 = YCbCrMatrix(rCr: 1.402, gCb: 0.344136, gCr: 0.714136, bCb: 1.772)
    static let bt709 = YCbCrMatrix(rCr: 1.5748, gCb: 0.187324, gCr: 0.468124, bCb: 1.8556)
    static let bt2020 = YCbCrMatrix(rCr: 1.4746, gCb: 0.164553, gCr: 0.571353, bCb: 1.8814)
  }

  /// The matrix the stream was encoded with (VideoToolbox carries the VUI
  /// colour description as a pixel-buffer attachment); without one, the usual
  /// convention: BT.601 for SD, BT.709 for HD and up.
  static func ycbcrMatrix(for pixelBuffer: CVPixelBuffer) -> YCbCrMatrix {
    if let value = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) {
      let matrix = value as? String
      if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        || matrix == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String)
      {
        return .bt601
      }
      if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
      if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { return .bt709 }
    }
    return CVPixelBufferGetHeight(pixelBuffer) < 720 ? .bt601 : .bt709
  }

  static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };
    vertex VertexOut quadVertex(uint vid [[vertex_id]],
                                constant float4 &rect [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
        float2 pos = rect.xy + corner * rect.zw;
        float2 ndc = pos * 2.0 - 1.0;
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.texCoord = float2(corner.x, 1.0 - corner.y);
        return out;
    }
    struct YCbCrMatrix { float rCr; float gCb; float gCr; float bCb; };
    fragment float4 yuvFragment(VertexOut in [[stage_in]],
                                texture2d<float, access::sample> yTex [[texture(0)]],
                                texture2d<float, access::sample> uvTex [[texture(1)]],
                                constant YCbCrMatrix &m [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float y8 = yTex.sample(s, in.texCoord).r;
        float2 uv = uvTex.sample(s, in.texCoord).rg;
        // Limited range -> normalized (16..235 -> 0..1, 16..240 -> -0.5..0.5).
        float yp = (y8 * 255.0 - 16.0) / 219.0;
        float cb = (uv.r * 255.0 - 128.0) / 224.0;
        float cr = (uv.g * 255.0 - 128.0) / 224.0;
        float r = yp + m.rCr * cr;
        float g = yp - m.gCb * cb - m.gCr * cr;
        float b = yp + m.bCb * cb;
        return float4(saturate(float3(r, g, b)), 1.0);
    }
    """
}

extension MTLRenderPassDescriptor {
  fileprivate func withColorAttachment(_ texture: MTLTexture, clear: Bool)
    -> MTLRenderPassDescriptor
  {
    let d = MTLRenderPassDescriptor()
    d.colorAttachments[0].texture = texture
    d.colorAttachments[0].loadAction = clear ? .clear : .load
    d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    return d
  }
}
