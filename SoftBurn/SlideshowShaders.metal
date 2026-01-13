//
//  SlideshowShaders.metal
//  SoftBurn
//
//  Base scene renderer: draw textured quads for current/next media with transforms,
//  optional "Effects" color mapping, and alpha blending over a solid background.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Types

struct VertexIn {
    float2 position; // NDC position (unit quad: -1..1)
    float2 uv;       // texture coordinates
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct LayerUniforms {
    float2 scale;           // scales unit quad (-1..1) to fitted size in NDC
    float2 translate;       // translation in NDC
    float  opacity;         // 0..1
    int    effectMode;      // 0 none, 1 monochrome, 2 silvertone, 3 sepia
    int    rotationDegrees; // 0, 90, 180, 270 (counterclockwise)
    int    _pad0;           // padding for alignment
};

// MARK: - Helpers (Effects)

static inline float luminance(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}

static inline float3 applyEffect(float3 rgb, int mode) {
    switch (mode) {
        case 1: { // monochrome
            float y = luminance(rgb);
            return float3(y);
        }
        case 2: { // silvertone (cool tint + slight brightness)
            float y = luminance(rgb);
            float3 g = float3(y);
            float3 tinted = g * float3(0.94, 0.96, 1.0);
            return saturate(tinted + 0.02);
        }
        case 3: { // sepia (warm tint)
            float y = luminance(rgb);
            float3 g = float3(y);
            return saturate(g * float3(1.0, 0.92, 0.78));
        }
        default:
            return rgb;
    }
}

// MARK: - UV Rotation

/// Rotate UV coordinates counterclockwise by 90-degree multiples.
/// Uses swizzling/inversion for efficient rotation without trigonometry.
static inline float2 rotateUV(float2 uv, int degrees) {
    switch (degrees) {
        case 90:
            // Counterclockwise 90°: (u,v) -> (1-v, u)
            return float2(1.0 - uv.y, uv.x);
        case 180:
            // 180°: (u,v) -> (1-u, 1-v)
            return float2(1.0 - uv.x, 1.0 - uv.y);
        case 270:
            // Counterclockwise 270° (= clockwise 90°): (u,v) -> (v, 1-u)
            return float2(uv.y, 1.0 - uv.x);
        default:
            // 0° or invalid: no rotation
            return uv;
    }
}

// MARK: - Shaders

vertex VertexOut slideshowVertexShader(
    const device VertexIn* vertices [[buffer(0)]],
    constant LayerUniforms& u [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    float2 p = vertices[vid].position;
    p = p * u.scale + u.translate;
    out.position = float4(p, 0.0, 1.0);

    // Apply rotation to UV coordinates (before fragment shader sampling)
    out.uv = rotateUV(vertices[vid].uv, u.rotationDegrees);

    return out;
}

fragment float4 slideshowFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant LayerUniforms& u [[buffer(1)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);
    float3 rgb = applyEffect(c.rgb, u.effectMode);
    return float4(rgb, c.a * u.opacity);
}

