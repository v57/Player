// metal-render-test.swift — headless self-test for MetalVideoRenderer (Wave-2 PoC).
//
// Builds a synthetic 1920x816 biplanar CVPixelBuffer with known YUV values,
// renders it offscreen into MTLTextures via MetalVideoRenderer, reads the pixels
// back with MTLTexture.getBytes and asserts:
//   1. YUV->RGB conversion matches the BT.709 video-range matrix within ±3/255.
//   2. Letterbox math: 40:17 source (1920x816, sar 1:1) into a 16:9 view
//      (1920x1080) -> dest height 816, centered vertically; bars black.
// Exit code 0 only if all assertions pass. No GUI.

import CoreGraphics
import CoreVideo
import Foundation
import Metal

@main struct MetalRenderTest {

  static var failures = 0
  static let tolerance = 3  // ±3/255

  static func check(_ cond: Bool, _ label: String) {
    if cond {
      print("PASS  \(label)")
    } else {
      print("FAIL  \(label)")
      failures += 1
    }
  }

  /// Expected BT.709 video-range conversion, mirrored from the shader
  /// (R/G/B clamped to [0,1], matching unorm texture write behavior).
  static func expectedRGB(y: Int, cb: Int, cr: Int) -> (r: Float, g: Float, b: Float) {
    let yp = (Float(y) - 16.0) / 219.0
    let cbp = (Float(cb) - 128.0) / 224.0
    let crp = (Float(cr) - 128.0) / 224.0
    let r = min(max(1.1644 * yp + 1.5960 * crp, 0), 1)
    let g = min(max(1.1644 * yp - 0.3918 * cbp - 0.8130 * crp, 0), 1)
    let b = min(max(1.1644 * yp + 2.0172 * cbp, 0), 1)
    return (r, g, b)
  }

  /// Synthetic biplanar 4:2:0 buffer:
  ///   Y plane:    mid-gray 126 everywhere; red-ish block rows 96...103,
  ///               cols 196...203 = 81 (8x8 luma block, so linear sampling
  ///               at the read-back pixel is fully inside it).
  ///   CbCr plane: 128,128 everywhere; block rows 48...51, cols 98...101 =
  ///               90,240 (4x4 chroma block; covers the 2x2 chroma texel
  ///               neighborhood the shader bilinearly samples there).
  /// Read-back pixel for red: (200, 100) — luma 1:1, chroma 4:2:0 sited.
  static func makeSyntheticBuffer(width: Int, height: Int) -> CVPixelBuffer {
    let attrs: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      attrs as CFDictionary, &pb)
    guard status == kCVReturnSuccess, let pb = pb else {
      fatalError("CVPixelBufferCreate failed: \(status)")
    }

    CVPixelBufferLockBaseAddress(pb, [])
    let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    memset(yBase, 126, yRowBytes * height)
    for row in 96...103 { for col in 196...203 { yBase[row * yRowBytes + col] = 81 } }

    let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    let uvH = height / 2
    memset(uvBase, 128, uvRowBytes * uvH)
    for row in 48...51 {
      for col in 98...101 {
        uvBase[row * uvRowBytes + col * 2] = 90
        uvBase[row * uvRowBytes + col * 2 + 1] = 240
      }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
  }

  static func makeTargetTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    guard let tex = device.makeTexture(descriptor: desc) else { fatalError("makeTexture failed") }
    return tex
  }

  static func readback(_ tex: MTLTexture, width: Int, height: Int) -> [UInt8] {
    let rowBytes = width * 4
    var bytes = [UInt8](repeating: 0, count: rowBytes * height)
    tex.getBytes(
      &bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return bytes
  }

  /// Pixel at (x, y), y counted from the TOP row (row 0 = image top).
  static func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (
    r: UInt8, g: UInt8, b: UInt8, a: UInt8
  ) {
    let i = (y * width + x) * 4
    return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
  }

  static func main() {
    print("== Metal YUV->RGB renderer self-test (headless) ==")

    let renderer: MetalVideoRenderer
    do { renderer = try MetalVideoRenderer() } catch {
      print("FATAL: cannot create MetalVideoRenderer: \(error)")
      exit(1)
    }
    print("device: \(renderer.device.name)")

    // ================= Test 1: YUV->RGB conversion, native size =================
    let srcW = 1920
    let srcH = 816
    let pb = makeSyntheticBuffer(width: srcW, height: srcH)
    let srcAspect = Float(srcW) / Float(srcH)  // 40/17, sar 1:1

    let target1 = makeTargetTexture(device: renderer.device, width: srcW, height: srcH)
    let rect1: DestRect
    do { rect1 = try renderer.render(pixelBuffer: pb, into: target1, viewAspect: srcAspect) } catch
    {
      print("FATAL: render test 1 failed: \(error)")
      exit(1)
    }
    let img1 = readback(target1, width: srcW, height: srcH)

    print("\n--- Test 1: YUV->RGB conversion at native 1920x816 (viewAspect \(srcAspect)) ---")
    print(
      String(
        format:
          "dest rect normalized: origin (%.4f, %.4f) size (%.4f, %.4f)  [full frame expected]",
        rect1.x, rect1.y, rect1.width, rect1.height))
    check(
      rect1.x == 0 && rect1.y == 0 && rect1.width == 1 && rect1.height == 1,
      "no letterbox when view aspect == source aspect")

    let (egr, egg, egb) = expectedRGB(y: 126, cb: 128, cr: 128)
    let grayExpected = (
      r: UInt8(round(egr * 255)), g: UInt8(round(egg * 255)), b: UInt8(round(egb * 255))
    )
    let grayGot = pixel(img1, width: srcW, x: 1000, y: 400)
    print(
      String(
        format:
          "gray pixel  Y=126 Cb=128 Cr=128: expected RGB = (%.4f, %.4f, %.4f) -> bytes (%d,%d,%d), got (%d,%d,%d)",
        egr, egg, egb, grayExpected.r, grayExpected.g, grayExpected.b, grayGot.r, grayGot.g,
        grayGot.b))
    check(
      abs(Int(grayGot.r) - Int(grayExpected.r)) <= tolerance
        && abs(Int(grayGot.g) - Int(grayExpected.g)) <= tolerance
        && abs(Int(grayGot.b) - Int(grayExpected.b)) <= tolerance, "mid-gray YUV->RGB conversion")
    print(
      "note: Y=126 is 50% luma (Y' = 110/219 = 0.5023); the given matrix outputs 1.1644*0.5023 = 0.585 (149/255) — not 0.5"
    )

    let (err, erg, erb) = expectedRGB(y: 81, cb: 90, cr: 240)
    let redExpected = (
      r: UInt8(round(err * 255)), g: UInt8(round(erg * 255)), b: UInt8(round(erb * 255))
    )
    let redGot = pixel(img1, width: srcW, x: 200, y: 100)
    print(
      String(
        format:
          "red pixel   Y=81 Cb=90 Cr=240: expected RGB = (%.4f, %.4f, %.4f) -> bytes (%d,%d,%d), got (%d,%d,%d)",
        err, erg, erb, redExpected.r, redExpected.g, redExpected.b, redGot.r, redGot.g, redGot.b))
    check(
      abs(Int(redGot.r) - Int(redExpected.r)) <= tolerance
        && abs(Int(redGot.g) - Int(redExpected.g)) <= tolerance
        && abs(Int(redGot.b) - Int(redExpected.b)) <= tolerance, "red-ish YUV->RGB conversion")

    // ================= Test 2: letterbox 40:17 into 16:9 =================
    let viewW = 1920
    let viewH = 1080
    let viewAspect = Float(viewW) / Float(viewH)
    let target2 = makeTargetTexture(device: renderer.device, width: viewW, height: viewH)
    let rect2: DestRect
    do {
      rect2 = try renderer.render(pixelBuffer: pb, into: target2, viewAspect: viewAspect, sar: 1.0)
    } catch {
      print("FATAL: render test 2 failed: \(error)")
      exit(1)
    }
    let img2 = readback(target2, width: viewW, height: viewH)

    print("\n--- Test 2: letterbox 40:17 source into 16:9 view (viewAspect \(viewAspect)) ---")
    let srcDisplayAspect = (Float(srcW) * 1.0) / Float(srcH)
    print(
      String(
        format: "source display aspect = %d/%d * sar(1.0) = %.5f  (40:17 = %.5f)", srcW, srcH,
        srcDisplayAspect, 40.0 / 17.0))
    print(
      String(
        format: "dest rect normalized: origin (%.4f, %.4f) size (%.4f, %.4f)", rect2.x, rect2.y,
        rect2.width, rect2.height))
    let rectPx = (
      x: rect2.x * Float(viewW), y: rect2.y * Float(viewH), w: rect2.width * Float(viewW),
      h: rect2.height * Float(viewH)
    )
    print(
      String(
        format: "dest rect pixels: x=%.1f y=%.1f w=%.1f h=%.1f", rectPx.x, rectPx.y, rectPx.w,
        rectPx.h))

    let referenceH = Float(viewH) * (17.0 / 40.0) / (9.0 / 16.0)
    print(String(format: "reference: 1080 * (17/40) / (9/16) = %.3f px", referenceH))
    check(abs(rectPx.h - referenceH) <= 1.5, "letterbox dest height ≈ 816 px")
    check(
      abs(rectPx.y - (Float(viewH) - rectPx.h) / 2) <= 1.5,
      "letterbox centered vertically (y ≈ 132 px)")
    check(rectPx.x == 0 && abs(rectPx.w - Float(viewW)) <= 0.01, "letterbox fills width")

    let barTop = pixel(img2, width: viewW, x: 960, y: 50)
    let barBottom = pixel(img2, width: viewW, x: 960, y: viewH - 50)
    print("letterbox pixel (960,50) got (\(barTop.r),\(barTop.g),\(barTop.b))")
    print("letterbox pixel (960,\(viewH - 50)) got (\(barBottom.r),\(barBottom.g),\(barBottom.b))")
    check(barTop.r == 0 && barTop.g == 0 && barTop.b == 0, "top letterbox bar is black")
    check(barBottom.r == 0 && barBottom.g == 0 && barBottom.b == 0, "bottom letterbox bar is black")

    let vGray = pixel(img2, width: viewW, x: 1000, y: 500)
    print(
      "video pixel (1000,500) got (\(vGray.r),\(vGray.g),\(vGray.b)) expected gray (\(grayExpected.r),\(grayExpected.g),\(grayExpected.b))"
    )
    check(
      abs(Int(vGray.r) - Int(grayExpected.r)) <= tolerance
        && abs(Int(vGray.g) - Int(grayExpected.g)) <= tolerance
        && abs(Int(vGray.b) - Int(grayExpected.b)) <= tolerance,
      "video content visible inside letterboxed rect (gray)")

    // Red block center is source (row 100, col 200) — map through the letterbox
    // rect: v = (r_s+0.5)/srcH, y_view = rect.y + (1 - v)*rect.height,
    // dest row = (1 - y_view)*viewH - 0.5. Source rows 96...103 -> dest ~228..236.
    let vRed = (100.5) / Float(srcH)
    let yViewRed = rect2.y + (1 - vRed) * rect2.height
    let redDestRow = Int((1 - yViewRed) * Float(viewH) - 0.5 + 0.5)  // round
    let vRedGot = pixel(img2, width: viewW, x: 200, y: redDestRow)
    print(
      "red block expected at dest row \(redDestRow) (source row 100); got (\(vRedGot.r),\(vRedGot.g),\(vRedGot.b)) expected (\(redExpected.r),\(redExpected.g),\(redExpected.b))"
    )
    check(
      abs(Int(vRedGot.r) - Int(redExpected.r)) <= tolerance
        && abs(Int(vRedGot.g) - Int(redExpected.g)) <= tolerance
        && abs(Int(vRedGot.b) - Int(redExpected.b)) <= tolerance,
      "red block renders at scaled, letterboxed position (row \(redDestRow))")

    print("\n== \(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED") ==")
    if failures > 0 { exit(1) }
  }
}
