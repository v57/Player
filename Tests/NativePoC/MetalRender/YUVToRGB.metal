// YUVToRGB.metal — Metal renderer PoC shader (Wave-2, KANBAN backlog).
//
// Biplanar 4:2:0 video-range BT.709 YUV -> RGB:
//   Y'  = (Y - 16) / 219
//   Cb' = (Cb - 128) / 224
//   Cr' = (Cr - 128) / 224
//   R = 1.1644*Y' + 1.5960*Cr'
//   G = 1.1644*Y' - 0.3918*Cb' - 0.8130*Cr'
//   B = 1.1644*Y' + 2.0172*Cb'
//
// NOTE: MetalVideoRenderer.swift embeds an identical copy of this source as a
// Swift string (device.makeDefaultLibrary(source:)) so the test binary is
// self-contained. Keep the two copies in sync.

#include <metal_stdlib>
using namespace metal;

// Normalized destination rect in [0,1]^2 view space, origin bottom-left (y up).
// This is the aspect-fit (letterboxed) rect computed host-side from the source
// display aspect (CVPixelBufferGetWidth/Height * sar) vs the view aspect.
struct Rect {
    float2 origin; // normalized x, y (y-up)
    float2 size;   // normalized w, h
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Expands the 4 corners of the normalized dest rect into a quad (triangle
// strip: 0=(0,0) 1=(1,0) 2=(0,1) 3=(1,1)). NDC is y-up; Metal's default
// viewport maps NDC +y to render-target row 0 (top), so texCoord v=0 is the
// image top row and the image renders upright.
vertex VertexOut quadVertex(uint vid [[vertex_id]],
                            constant Rect &rect [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1u), float((vid >> 1u) & 1u));
    float2 pos = rect.origin + corner * rect.size;   // [0,1]^2, y-up
    float2 ndc = pos * 2.0 - 1.0;                    // -> NDC
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

    float y8  = yTex.sample(s, in.texCoord).r;   // luma 0..1   (R8Unorm, plane 0)
    float2 uv = uvTex.sample(s, in.texCoord).rg; // Cb, Cr 0..1 (RG8Unorm, plane 1)

    float yp  = (y8 * 255.0 - 16.0) / 219.0;
    float cb  = (uv.r * 255.0 - 128.0) / 224.0;
    float cr  = (uv.g * 255.0 - 128.0) / 224.0;

    float r = 1.1644 * yp + 1.5960 * cr;
    float g = 1.1644 * yp - 0.3918 * cb - 0.8130 * cr;
    float b = 1.1644 * yp + 2.0172 * cb;

    return float4(r, g, b, 1.0);
}
