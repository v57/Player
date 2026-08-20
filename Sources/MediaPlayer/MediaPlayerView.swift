import SwiftUI
import AppKit
import Metal
import CoreVideo
import CoreGraphics

/// The library's main SwiftUI view: hosts the native Metal video surface and
/// registers it as the engine's VideoFrameSink. Presents CVPixelBuffers via
/// CAMetalLayer + the YUV->RGB shader (KANBAN: player pushes, view consumes).
///
/// The app passes its boxed player (the same object it injects as
/// @EnvironmentObject); the view conditional-casts to the native engine to
/// register the sink — mirroring the old app-side NativeVideoView.
public struct MediaPlayerView: NSViewRepresentable {
    @ObservedObject public var player: MediaPlayerBox
    public var onIdleHideChanged: ((Bool) -> Void)?

    public init(player: MediaPlayerBox, onIdleHideChanged: ((Bool) -> Void)? = nil) {
        self.player = player
        self.onIdleHideChanged = onIdleHideChanged
    }

    public func makeNSView(context: Context) -> MediaMetalView {
        let view = MediaMetalView(frame: .zero)
        view.onIdleHideChanged = onIdleHideChanged
        view.player = player
        if let engine = player.engine as? NativeMediaPlayer {
            engine.registerSink(view)
        }
        return view
    }

    public func updateNSView(_ nsView: MediaMetalView, context: Context) {
        nsView.player = player
        if let engine = player.engine as? NativeMediaPlayer {
            engine.registerSink(nsView)
        }
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
    /// Subtitle overlay (SRT Phase A): CATextLayer above the video.
    private let subtitleLayer = CATextLayer()
    /// The boxed player (set by the SwiftUI wrapper) for key/click transport.
    weak var player: MediaPlayerBox?
    var onIdleHideChanged: ((Bool) -> Void)?
    // TEMP DIAGNOSTICS
    private var diagFirstPresent = false
    private var diagRendererNil = 0
    private var diagBackingZero = 0

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
        NSLog("[Native] VIEW init device=%@ renderer=%@", metalLayer.device != nil ? "ok" : "nil", renderer != nil ? "ok" : "nil")
        setupSubtitleLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Take first responder when attached to a window, so transport keys
        // (Space/arrows/Return) work without clicking the video first. Also
        // re-grab when the window comes back key (e.g. after a sheet or
        // another app steals focus).
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window
        )
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        // Re-take first responder whenever the window becomes key again, so
        // Space keeps working after the focus moved elsewhere (timeline
        // slider, menu, other app) and returns.
        if window != nil, let window, window.isKeyWindow {
            window.makeFirstResponder(self)
        }
    }

    private func setupSubtitleLayer() {
        subtitleLayer.string = nil
        subtitleLayer.alignmentMode = .center
        subtitleLayer.foregroundColor = NSColor.white.cgColor
        subtitleLayer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        subtitleLayer.cornerRadius = 6
        subtitleLayer.isHidden = true
        subtitleLayer.contentsScale = 2.0
        subtitleLayer.fontSize = 18
        // Add above the video layer.
        metalLayer.addSublayer(subtitleLayer)
    }

    /// VideoFrameSink — MainActor, called by the controller.
    public func present(frame: NativeVideoFrame) {
        if !diagFirstPresent {
            diagFirstPresent = true
            let backing = convertToBacking(bounds)
            NSLog("[Native] VIEW first present pts=%.3f renderer=%@ layerIsViewLayer=%d win=%@ bounds=%.0fx%.0f backing=%.0fx%.0f",
                  frame.pts, renderer != nil ? "ok" : "nil", layer === metalLayer ? 1 : 0,
                  window != nil ? "yes" : "no", bounds.width, bounds.height, backing.width, backing.height)
        }
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
        subtitleLayer.string = nil
        subtitleLayer.isHidden = true
    }

    /// Reads the active subtitle cue from the native engine and updates the
    /// overlay. Called on every presented frame (MainActor).
    private func updateSubtitleOverlay() {
        guard let cue = (player?.engine as? NativeMediaPlayer)?.activeSubtitleCue, !cue.isEmpty else {
            if !subtitleLayer.isHidden {
                subtitleLayer.string = nil
                subtitleLayer.isHidden = true
            }
            return
        }
        // SRT markup: strip <i>, <b>, <font> tags for Phase A plain rendering.
        let plain = cue.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        subtitleLayer.string = plain
        subtitleLayer.isHidden = false
        // Re-position: bottom-centered, sized to the layer.
        layoutSubtitleLayer()
    }

    private func layoutSubtitleLayer() {
        let w = max(bounds.width * 0.8, 200)
        let h: CGFloat = 40
        subtitleLayer.frame = CGRect(x: (bounds.width - w) / 2,
                                     y: bounds.height - 90,
                                     width: w, height: h)
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
            diagRendererNil += 1
            if diagRendererNil == 1 {
                NSLog("[Native] VIEW renderFrame: renderer NIL (frame present, nothing renders)")
            }
            return
        }
        let backing = convertToBacking(bounds)
        guard backing.width >= 1, backing.height >= 1 else {
            diagBackingZero += 1
            if diagBackingZero == 1 {
                NSLog("[Native] VIEW renderFrame: backing ZERO (%.1fx%.1f)", backing.width, backing.height)
            }
            return
        }
        // Aspect-fit with the source's display aspect (DAR = SAR * w/h).
        let srcW = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
        let srcH = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer))
        let displayAspect = srcW / srcH   // SAR 1:1 for the target file
        renderer.render(pixelBuffer: frame.pixelBuffer,
                        into: metalLayer,
                        size: CGSize(width: backing.width, height: backing.height),
                        displayAspect: displayAspect)
    }

    func tearDown() {
        currentFrame = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        // (do NOT touch metalLayer.contents — see clear(); undefined on CAMetalLayer)
    }

    // MARK: - Interaction (space/return/arrows/chapters/click)

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            // Single click toggles play/pause (deferred for double-click).
            singleClickTimer?.invalidate()
            singleClickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.togglePlayPause()
            }
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
        case 123: // kVK_LeftArrow
            if hasCmd {
                player?.skipChapter(-1)
                return
            }
        case 124: // kVK_RightArrow
            if hasCmd {
                player?.skipChapter(1)
                return
            }
        case 96: // kVK_F5
            if !hasCmd, !hasCtrl, !hasOpt {
                player?.skipChapter(-1)
                return
            }
        case 97: // kVK_F6
            if !hasCmd, !hasCtrl, !hasOpt {
                player?.skipChapter(1)
                return
            }
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case " ":
            togglePlayPause()
        case "\r": // Return/Enter
            togglePlayPause()
        case "\u{1B}":
            if let window, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                super.keyDown(with: event)
            }
        default:
            switch event.keyCode {
            case 123: player?.seekRelative(-5)   // kVK_LeftArrow
            case 124: player?.seekRelative(5)    // kVK_RightArrow
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
    // TEMP DIAGNOSTIC
    private var diagNilDrawables = 0

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
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw MetalSetupError.noCache }
        textureCache = cache
    }

    enum MetalSetupError: Error {
        case noQueue, noCache
    }

    func render(pixelBuffer: CVPixelBuffer, into layer: CAMetalLayer,
                size: CGSize, displayAspect: CGFloat) {
        guard let drawable = layer.nextDrawable() else {
            if diagNilDrawables == 0 {
                NSLog("[Native] VIEW renderer: nextDrawable NIL (layer not connected?)")
            }
            diagNilDrawables += 1
            return
        }
        diagNilDrawables = 0
        guard let cache = textureCache else { return }

        // Two-plane textures (Y + CbCr) from the pixel buffer.
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var yTexRef: CVMetalTexture?
        var uvTexRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
                                                        .r8Unorm, w, h, 0, &yTexRef) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
                                                        .rg8Unorm, w / 2, h / 2, 1, &uvTexRef) == kCVReturnSuccess,
              let yTex = yTexRef.flatMap(CVMetalTextureGetTexture),
              let uvTex = uvTexRef.flatMap(CVMetalTextureGetTexture) else { return }

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
              let enc = cmd.makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor().withColorAttachment(drawable.texture, clear: true)) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(uvTex, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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
    fragment float4 yuvFragment(VertexOut in [[stage_in]],
                                texture2d<float, access::sample> yTex [[texture(0)]],
                                texture2d<float, access::sample> uvTex [[texture(1)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float y8 = yTex.sample(s, in.texCoord).r;
        float2 uv = uvTex.sample(s, in.texCoord).rg;
        float yp = (y8 * 255.0 - 16.0) / 219.0;
        float cb = (uv.r * 255.0 - 128.0) / 224.0;
        float cr = (uv.g * 255.0 - 128.0) / 224.0;
        float r = 1.1644 * yp + 1.5960 * cr;
        float g = 1.1644 * yp - 0.3918 * cb - 0.8130 * cr;
        float b = 1.1644 * yp + 2.0172 * cb;
        return float4(r, g, b, 1.0);
    }
    """
}

private extension MTLRenderPassDescriptor {
    func withColorAttachment(_ texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = texture
        d.colorAttachments[0].loadAction = clear ? .clear : .load
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return d
    }
}
