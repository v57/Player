// MetalVideoRenderer.swift — Metal YUV->RGB renderer PoC (Wave-2, KANBAN backlog).
//
// Renders a biplanar 4:2:0 CVPixelBuffer (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
// into an offscreen MTLTexture with aspect-fit letterboxing computed from the
// source display aspect (CVPixelBufferGetWidth/Height * sar) vs the view aspect.
// Headless: no NSWindow, no MTKView — offscreen render target + readback.
//
// The shader source (embedded below) is identical to YUVToRGB.metal.

import Foundation
import Metal
import CoreVideo
import CoreGraphics

/// Normalized destination rectangle in [0,1]^2 view space (origin bottom-left, y up).
/// This is the aspect-fit (letterboxed) rect the vertex shader expands into a quad.
public struct DestRect {
    public var origin: SIMD2<Float>
    public var size: SIMD2<Float>

    public init(origin: SIMD2<Float>, size: SIMD2<Float>) {
        self.origin = origin
        self.size = size
    }

    public var x: Float { origin.x }
    public var y: Float { origin.y }
    public var width: Float { size.x }
    public var height: Float { size.y }
}

public enum MetalRenderError: Error {
    case noDevice
    case textureCacheCreateFailed(CVReturn)
    case libraryCreateFailed(String)
    case pipelineCreateFailed(String)
    case textureCreateFailed(CVReturn)
    case commandBufferFailed
    case encoderFailed
    case pixelFormatMismatch
}

public final class MetalVideoRenderer {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let pipelineState: MTLRenderPipelineState

    // MARK: - Shader source (keep in sync with YUVToRGB.metal)

    public static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Rect {
        float2 origin;
        float2 size;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut quadVertex(uint vid [[vertex_id]],
                                constant Rect &rect [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
        float2 pos = rect.origin + corner * rect.size;
        float2 ndc = pos * 2.0 - 1.0;
        float2 texCoord = float2(corner.x, 1.0 - corner.y);

        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.texCoord = texCoord;
        return out;
    }

    fragment float4 yuvFragment(VertexOut in [[stage_in]],
                                texture2d<float, access::sample> yTex  [[texture(0)]],
                                texture2d<float, access::sample> uvTex [[texture(1)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

        float y8  = yTex.sample(s, in.texCoord).r;
        float2 uv = uvTex.sample(s, in.texCoord).rg;

        float yp  = (y8 * 255.0 - 16.0) / 219.0;
        float cb  = (uv.r * 255.0 - 128.0) / 224.0;
        float cr  = (uv.g * 255.0 - 128.0) / 224.0;

        float r = 1.1644 * yp + 1.5960 * cr;
        float g = 1.1644 * yp - 0.3918 * cb - 0.8130 * cr;
        float b = 1.1644 * yp + 2.0172 * cb;

        return float4(r, g, b, 1.0);
    }
    """

    // MARK: - Init

    /// - Parameter pixelFormat: pixel format of the render targets this renderer
    ///   will be asked to draw into (the pipeline is built for it).
    public init(pixelFormat: MTLPixelFormat = .rgba8Unorm) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.noDevice
        }
        self.device = device
        self.pixelFormat = pixelFormat

        guard let queue = device.makeCommandQueue() else {
            throw MetalRenderError.commandBufferFailed
        }
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache = cache else {
            throw MetalRenderError.textureCacheCreateFailed(cacheStatus)
        }
        self.textureCache = cache

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalRenderError.libraryCreateFailed("\(error)")
        }
        guard let vertexFn = library.makeFunction(name: "quadVertex"),
              let fragmentFn = library.makeFunction(name: "yuvFragment") else {
            throw MetalRenderError.libraryCreateFailed("missing quadVertex/yuvFragment functions")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw MetalRenderError.pipelineCreateFailed("\(error)")
        }
    }

    // MARK: - Render

    /// Renders `pixelBuffer` (biplanar Y/CbCr 8-bit) into `target` with aspect-fit
    /// letterboxing.
    ///
    /// - Parameters:
    ///   - pixelBuffer: source, e.g. kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange.
    ///   - target: offscreen render target (pixelFormat must match init's).
    ///   - viewAspect: target width / target height (e.g. 16/9 for a 1920x1080 view).
    ///   - sar: sample (storage) aspect ratio of the source. Display aspect =
    ///     CVPixelBufferGetWidth/Height * sar. video.mkv is 1920x816 with sar 1:1
    ///     -> DAR 40:17.
    /// - Returns: the computed normalized dest rect (letterboxed), for verification.
    /// - Note: synchronous — commits and waits for GPU completion, so the caller
    ///   can read back immediately.
    @discardableResult
    public func render(pixelBuffer: CVPixelBuffer,
                       into target: MTLTexture,
                       viewAspect: Float,
                       sar: Float = 1.0) throws -> DestRect {
        guard target.pixelFormat == pixelFormat else {
            throw MetalRenderError.pixelFormatMismatch
        }

        // --- Aspect-fit letterbox math (normalized [0,1]^2, y-up) ---
        let srcW = Float(CVPixelBufferGetWidth(pixelBuffer))
        let srcH = Float(CVPixelBufferGetHeight(pixelBuffer))
        let displayAspect = (srcW * sar) / srcH

        let rect: DestRect
        if displayAspect > viewAspect {
            // Source wider than view: fit width, letterbox top/bottom.
            let scale = viewAspect / displayAspect
            rect = DestRect(origin: SIMD2(0, (1 - scale) / 2), size: SIMD2(1, scale))
        } else {
            // Source taller than view: fit height, letterbox left/right.
            let scale = displayAspect / viewAspect
            rect = DestRect(origin: SIMD2((1 - scale) / 2, 0), size: SIMD2(scale, 1))
        }

        // --- Wrap Y (plane 0) and CbCr (plane 1) into Metal textures ---
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yTex = makeTexture(plane: 0, pixelFormat: .r8Unorm, of: pixelBuffer),
              let uvTex = makeTexture(plane: 1, pixelFormat: .rg8Unorm, of: pixelBuffer) else {
            throw MetalRenderError.textureCreateFailed(kCVReturnError)
        }

        // --- Draw the quad ---
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRenderError.commandBufferFailed
        }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            throw MetalRenderError.encoderFailed
        }
        encoder.setRenderPipelineState(pipelineState)
        let rectFloats: [Float] = [rect.origin.x, rect.origin.y, rect.size.x, rect.size.y]
        rectFloats.withUnsafeBytes { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return rect
    }

    // MARK: - Helpers

    private func makeTexture(plane: Int,
                             pixelFormat: MTLPixelFormat,
                             of pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, pixelFormat, w, h, plane, &cvTex)
        guard status == kCVReturnSuccess, let cvTex = cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }
}
