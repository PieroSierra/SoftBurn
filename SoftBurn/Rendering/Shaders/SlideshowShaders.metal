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
    float2 uv;         // rotated UV for texture sampling
    float2 viewUV;     // original UV for face box checking (view position)
};

struct LayerUniforms {
    float2 scale;           // scales unit quad (-1..1) to fitted size in NDC
    float2 translate;       // translation in NDC
    float  opacity;         // 0..1
    int    effectMode;      // 0 none, 1 monochrome, 2 silvertone, 3 sepia
    int    rotationDegrees; // 0, 90, 180, 270 (counterclockwise)
    int    debugShowFaces;  // 1 to show face boxes, 0 otherwise
    int    faceBoxCount;    // number of valid face boxes (0-8)
    int    isVideoTexture;  // 1 for video (bottom-left origin), 0 for photo (top-left origin)
    float4 faceBoxes[8];    // each is (minX, minY, width, height) in Vision space (origin bottom-left)
};

// MARK: - Helpers (Effects)

static inline float luminance(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}

// MARK: - Wes Palette Helpers

/// Convert RGB to Hue (0-1 range, where 1.0 = 360°)
static inline float rgbToHue(float3 rgb) {
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    if (delta < 0.001) return 0.0;

    float hue;
    if (maxC == rgb.r) hue = (rgb.g - rgb.b) / delta;
    else if (maxC == rgb.g) hue = 2.0 + (rgb.b - rgb.r) / delta;
    else hue = 4.0 + (rgb.r - rgb.g) / delta;

    return fract(hue / 6.0);  // Normalize to 0-1
}

/// Detect skin tones and return protection factor (0-1, higher = more protection)
/// Skin tones fall in hue range ~15°-45° (orange-yellow) with moderate saturation
static inline float skinToneProtection(float3 rgb) {
    float hue = rgbToHue(rgb) * 360.0;  // Convert to degrees

    // Skin tones: ~15° to ~45° with smooth falloff
    float skinMask = smoothstep(10.0, 20.0, hue) * (1.0 - smoothstep(40.0, 50.0, hue));

    // Require minimum saturation - very desaturated pixels aren't skin
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float sat = (maxC > 0.001) ? (maxC - minC) / maxC : 0.0;
    float satMask = smoothstep(0.15, 0.3, sat);

    return skinMask * satMask;
}

/// Adjust contrast around midpoint (negative = softer, positive = punchier)
static inline float3 adjustContrast(float3 rgb, float amount) {
    float3 mid = float3(0.5);
    return saturate(mid + (rgb - mid) * (1.0 + amount));
}

/// Adjust saturation (0 = grayscale, 1 = original, >1 = oversaturated)
static inline float3 adjustSaturation(float3 rgb, float amount) {
    float y = luminance(rgb);
    return saturate(mix(float3(y), rgb, amount));
}

// MARK: - Wes Color Palettes

/// Budapest Rose: warm pastel, rose-tinted midtones, purple shadows
static inline float3 applyBudapestRose(float3 rgb) {
    // Palette colors (normalized RGB)
    float3 dominant = float3(1.000, 0.847, 0.925);   // Rose #FFD8EC
    float3 shadow = float3(0.471, 0.259, 0.514);     // Purple #784283
    float3 highlight = float3(0.867, 0.839, 0.565);  // Cream #DDD690
    float3 accentRed = float3(0.898, 0.000, 0.047);  // Accent #E5000C

    float y = luminance(rgb);
    float protection = skinToneProtection(rgb);
    float strength = mix(0.75, 0.225, protection);  // 75% base strength, 22.5% on skin

    // Zone weights with soft transitions (reduced 25%)
    float shadowW = (1.0 - smoothstep(0.0, 0.4, y)) * 0.3;
    float midW = smoothstep(0.2, 0.4, y) * (1.0 - smoothstep(0.6, 0.8, y)) * 0.375;
    float highW = smoothstep(0.6, 0.9, y) * 0.225;

    // Bias reds toward accent red
    float redBias = smoothstep(0.3, 0.6, rgb.r) * (1.0 - smoothstep(0.2, 0.5, rgb.g));

    float3 graded = rgb;
    graded = mix(graded, shadow * (y + 0.3), shadowW * strength);
    graded = mix(graded, dominant, midW * strength);
    graded = mix(graded, highlight, highW * strength);
    graded = mix(graded, accentRed * (rgb.r + 0.2), redBias * strength * 0.225);

    // Reduce saturation to ~81% (was 75%, now 25% less reduction)
    graded = adjustSaturation(graded, 0.8125);
    graded = adjustContrast(graded, -0.075);

    return saturate(graded);
}

/// Fantastic Mr Yellow: warm autumnal, yellow-dominant, fox-red accents
static inline float3 applyFantasticMrYellow(float3 rgb) {
    // Palette colors
    float3 dominant = float3(1.000, 0.788, 0.027);   // Yellow #FFC907
    float3 foxRed = float3(0.776, 0.125, 0.153);     // Fox Red #C62027
    float3 shadow = float3(0.765, 0.439, 0.129);     // Autumn Brown #C37021
    float3 highlight = float3(0.949, 0.875, 0.816);  // Paper Cream #F2DFD0

    float y = luminance(rgb);
    float protection = skinToneProtection(rgb);
    float strength = mix(0.75, 0.225, protection);  // 75% base strength

    // Zone weights (reduced 25%)
    float shadowW = (1.0 - smoothstep(0.0, 0.4, y)) * 0.2625;
    float midW = smoothstep(0.2, 0.4, y) * (1.0 - smoothstep(0.6, 0.8, y)) * 0.375;
    float highW = smoothstep(0.6, 0.9, y) * 0.1875;

    // Bias yellows toward dominant, reds toward fox red
    float yellowBias = smoothstep(0.4, 0.7, rgb.r) * smoothstep(0.3, 0.6, rgb.g) * (1.0 - smoothstep(0.2, 0.4, rgb.b));
    float redBias = smoothstep(0.4, 0.7, rgb.r) * (1.0 - smoothstep(0.2, 0.4, rgb.g));

    // De-emphasize greens (avoid neon look)
    float greenSuppress = smoothstep(0.3, 0.6, rgb.g) * (1.0 - smoothstep(0.2, 0.5, rgb.r));

    float3 graded = rgb;
    graded = mix(graded, shadow * (y + 0.4), shadowW * strength);
    graded = mix(graded, dominant, midW * strength);
    graded = mix(graded, highlight, highW * strength);
    graded = mix(graded, dominant, yellowBias * strength * 0.3);
    graded = mix(graded, foxRed * (rgb.r + 0.3), redBias * strength * 0.2625);

    // Suppress neon greens (reduced effect)
    graded.g = mix(graded.g, graded.g * 0.8875, greenSuppress * strength);

    return saturate(graded);
}

/// Darjeeling Mint: cool composed, mint-green pulls, warm shadows
static inline float3 applyDarjeelingMint(float3 rgb) {
    // Palette colors
    float3 dominant = float3(0.286, 0.600, 0.486);   // Mint #49997C
    float3 railwayBlue = float3(0.008, 0.478, 0.690);// Blue #027AB0
    float3 shadow = float3(0.682, 0.224, 0.094);     // Spice Red #AE3918 (warm)
    float3 highlight = float3(0.820, 0.612, 0.184);  // Dusty Gold #D19C2F

    float y = luminance(rgb);
    float protection = skinToneProtection(rgb);
    float strength = mix(0.75, 0.225, protection);  // 75% base strength

    // Zone weights - cool highlights, warm shadows (reduced 25%)
    float shadowW = (1.0 - smoothstep(0.0, 0.4, y)) * 0.225;
    float midW = smoothstep(0.2, 0.4, y) * (1.0 - smoothstep(0.6, 0.8, y)) * 0.3375;
    float highW = smoothstep(0.6, 0.9, y) * 0.1875;

    // Bias greens/cyans toward mint, blues toward railway blue
    float greenCyanBias = smoothstep(0.3, 0.6, rgb.g) * (1.0 - smoothstep(0.3, 0.6, rgb.r));
    float blueBias = smoothstep(0.3, 0.6, rgb.b) * (1.0 - smoothstep(0.3, 0.5, rgb.r));

    float3 graded = rgb;
    graded = mix(graded, shadow * (y + 0.5), shadowW * strength);  // Warm shadows
    graded = mix(graded, dominant, midW * strength);
    graded = mix(graded, highlight * 0.9 + float3(0.0, 0.05, 0.1), highW * strength);  // Cool highlights
    graded = mix(graded, dominant, greenCyanBias * strength * 0.3);
    graded = mix(graded, railwayBlue * (rgb.b + 0.3), blueBias * strength * 0.1875);

    // Mild S-curve contrast (reduced effect by blending with original)
    float3 curved = smoothstep(-0.05, 1.05, graded);
    graded = mix(graded, curved, 0.75);

    return saturate(graded);
}

// MARK: - Effect Dispatcher

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
        case 4: return applyBudapestRose(rgb);       // Budapest Rose
        case 5: return applyFantasticMrYellow(rgb);  // Fantastic Mr Yellow
        case 6: return applyDarjeelingMint(rgb);     // Darjeeling Mint
        default:
            return rgb;
    }
}

// MARK: - UV Rotation

/// Rotate UV coordinates counterclockwise by 90-degree multiples.
/// Uses swizzling/inversion for efficient rotation without trigonometry.
/// Note: Both photo textures (from MTKTextureLoader) and video textures
/// (from CVPixelBuffer via CVMetalTextureCache) use top-left origin in Metal.
static inline float2 rotateUV(float2 uv, int degrees, int isVideo) {
    // Both photos and videos use top-left origin in Metal.
    // The isVideo parameter is kept for potential future use but not used for origin adjustment.
    (void)isVideo;  // Suppress unused parameter warning

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

    // Store original UV for face box checking (view position)
    out.viewUV = vertices[vid].uv;

    // Apply rotation to UV coordinates for texture sampling
    // Pass isVideoTexture to handle video's bottom-left origin vs photo's top-left origin
    out.uv = rotateUV(vertices[vid].uv, u.rotationDegrees, u.isVideoTexture);

    return out;
}

fragment float4 slideshowFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant LayerUniforms& u [[buffer(1)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.uv);  // Use rotated UV for texture sampling
    float3 rgb = applyEffect(c.rgb, u.effectMode);

    // Debug: draw face boxes as semi-transparent red overlay
    if (u.debugShowFaces != 0 && u.faceBoxCount > 0) {
        // Use viewUV (original, unrotated UV) for face box checking
        // viewUV is in texture space (origin top-left)
        // Face boxes are in Vision space (origin bottom-left), already rotated to match view
        // Convert viewUV to Vision space: visionY = 1.0 - textureY
        float2 visionUV = float2(in.viewUV.x, 1.0 - in.viewUV.y);

        for (int i = 0; i < u.faceBoxCount && i < 8; i++) {
            float4 box = u.faceBoxes[i];
            float minX = box.x;
            float minY = box.y;
            float maxX = box.x + box.z;
            float maxY = box.y + box.w;

            if (visionUV.x >= minX && visionUV.x <= maxX &&
                visionUV.y >= minY && visionUV.y <= maxY) {
                // Inside face box - blend with red
                rgb = mix(rgb, float3(1.0, 0.0, 0.0), 0.4);
                break;
            }
        }
    }

    return float4(rgb, c.a * u.opacity);
}

