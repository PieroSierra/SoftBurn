//
//  PatinaShaders.metal
//  SoftBurn
//
//  Metal shaders for patina post-processing effects.
//  These effects simulate film and analog media characteristics.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shader Constants

constant float PI = 3.14159265359;

// Patina effect modes
constant int PATINA_NONE = 0;
constant int PATINA_35MM = 1;
constant int PATINA_AGED_FILM = 2;
constant int PATINA_VHS = 3;

// MARK: - Patina Tunables (Uniform-driven)
//
// Populated from Swift (`PatinaTuning.swift`) so a DEBUG window can tune them live.
// Keep layouts in sync with Swift-side structs.
//

struct PatinaParams35mm {
    float grainFineness;
    float grainIntensity;
    float blurRadiusTexels;
    float4 toneMultiplyRGBA; // use xyz
    float blackLift;
    float contrast;
    float rolloffThreshold;
    float rolloffSoftness;
    float vignetteStrength;
    float vignetteRadius;
    float2 _pad0;
};

struct PatinaParamsAgedFilm {
    float grainFineness;
    float grainIntensity;
    float blurRadiusTexels;
    float jitterAmplitudeTexels;
    float driftSpeed;
    float driftIntensity;
    float dimPulseSpeed;
    float dimPulseThreshold;
    float dimPulseIntensity;
    float highlightSoftThreshold;
    float highlightSoftAmount;
    float shadowLiftThreshold;
    float shadowLiftAmount;
    float vignetteStrength;
    float vignetteRadius;
    float dustRate;
    float dustIntensity;
    float dustSize;
    float2 _pad0;
};

struct PatinaParamsVHS {
    float blurTap1;
    float blurTap2;
    float blurW0;
    float blurW1;
    float blurW2;
    float chromaOffsetTexels;
    float chromaMix;
    float scanlineBase;
    float scanlineAmp;
    float scanlinePow;
    float lineFrequencyScale;
    float desat;
    float4 tintMultiplyRGBA; // use xyz
    float trackingThreshold;
    float trackingIntensity;
    float staticIntensity;
    float tearEnabled;
    float tearGateRate;
    float tearGateThreshold;
    float tearSpeed;
    float tearBandHeight;
    float tearOffsetTexels;
    float edgeSoftStrength;
    float scanlineBandWidth;  // Ratio of bright band (0.5-0.8)
    float blackLift;          // Minimum black level (0-0.20)
};

// MARK: - Uniform Buffer

struct PatinaUniforms {
    int mode;           // Patina effect mode
    float time;         // Time in seconds for animated effects
    float2 resolution;  // Output resolution
    float seed;         // Random seed for grain variation
    int currentRotation; // Current media rotation: 0, 90, 180, 270
    PatinaParams35mm p35;
    PatinaParamsAgedFilm aged;
    PatinaParamsVHS vhs;
};

// MARK: - Vertex Shader

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut patinaVertexShader(uint vertexID [[vertex_id]]) {
    // Fullscreen triangle (covers entire screen with single triangle)
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    
    float2 texCoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Noise Functions

// High-quality hash for grain generation
float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Value noise for smooth variations
float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    
    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));
    
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Film grain with controllable fineness
float filmGrain(float2 uv, float time, float fineness, float seed) {
    float2 grainUV = uv * fineness;
    grainUV += float2(seed, time * 24.0); // 24fps grain refresh
    return hash12(grainUV) * 2.0 - 1.0;
}

// MARK: - Sampling / Tonemapping Helpers

static inline float3 sampleRGB(texture2d<float> tex, sampler s, float2 uv) {
    return tex.sample(s, saturate(uv)).rgb;
}

static inline float3 softBlur5(texture2d<float> tex, sampler s, float2 uv, float2 texel, float radius) {
    // Very small 5-tap blur (cross). Lightweight “softness/imperfection”.
    float2 dx = float2(texel.x * radius, 0.0);
    float2 dy = float2(0.0, texel.y * radius);
    float3 c0 = sampleRGB(tex, s, uv);
    float3 c1 = sampleRGB(tex, s, uv + dx);
    float3 c2 = sampleRGB(tex, s, uv - dx);
    float3 c3 = sampleRGB(tex, s, uv + dy);
    float3 c4 = sampleRGB(tex, s, uv - dy);
    return c0 * 0.52 + (c1 + c2) * 0.14 + (c3 + c4) * 0.10;
}

static inline float vignetteMask(float2 uv, float strength, float radius) {
    // radius ~ 0.75..0.95; strength ~ 0..1
    float2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float v = smoothstep(radius, 1.05, r);
    return 1.0 - v * strength;
}

static inline float3 liftBlacksAndReduceContrast(float3 c, float blackLift, float contrast) {
    // blackLift: 0..0.08, contrast: 0.85..1.0 (lower = flatter/matte)
    c = c * contrast + (1.0 - contrast) * 0.5;
    c = c + blackLift;
    return saturate(c);
}

static inline float3 highlightRolloff(float3 c, float threshold, float softness) {
    // Compress highlights above threshold with a soft knee.
    float y = dot(c, float3(0.299, 0.587, 0.114));
    if (y <= threshold) return c;
    float t = (y - threshold) / max(1e-5, (1.0 - threshold));
    // Soft knee: t' = 1 - exp(-t * softness)
    float t2 = 1.0 - exp(-t * softness);
    float y2 = threshold + t2 * (1.0 - threshold);
    float scale = y > 1e-5 ? (y2 / y) : 1.0;
    return saturate(c * scale);
}

// MARK: - Effect: 35mm Film

// Very fine, uniform grain - professionally projected look
float3 apply35mm(texture2d<float> tex, sampler s, float2 uv, float time, float2 resolution, float seed, constant PatinaParams35mm& p) {
    float2 texel = 1.0 / resolution;

    // Softness & imperfection: mild blur to reduce “clinical” sharpness.
    float3 base = softBlur5(tex, s, uv, texel, p.blurRadiusTexels);

    // Film grain: fine and fairly uniform.
    float grain = filmGrain(uv, time, p.grainFineness, seed);
    float3 result = base + grain * p.grainIntensity;

    // Color & tone: gentle film-stock feel (slightly warmer, reduced contrast, matte blacks).
    result *= p.toneMultiplyRGBA.xyz;
    result = liftBlacksAndReduceContrast(result, p.blackLift, p.contrast);

    // Highlight roll-off: soft knee into whites.
    result = highlightRolloff(result, p.rolloffThreshold, p.rolloffSoftness);

    // Vignette: subtle.
    result *= vignetteMask(uv, p.vignetteStrength, p.vignetteRadius);

    return saturate(result);
}

// MARK: - Effect: Aged Film

// Slightly coarser grain, subtle brightness drift
float3 applyAgedFilm(texture2d<float> tex, sampler s, float2 uv, float time, float2 resolution, float seed, constant PatinaParamsAgedFilm& p) {
    // Coarser grain than 35mm
    // Tiny frame instability / jitter (projector weave). Kept very small.
    float2 texel = 1.0 / resolution;
    float jx = (valueNoise(float2(time * 0.35, seed + 11.0)) - 0.5) * texel.x * p.jitterAmplitudeTexels;
    float jy = (valueNoise(float2(time * 0.28, seed + 37.0)) - 0.5) * texel.y * p.jitterAmplitudeTexels;
    uv = saturate(uv + float2(jx, jy));

    // Slight blur/softness.
    float3 base = softBlur5(tex, s, uv, texel, p.blurRadiusTexels);

    float grain = filmGrain(uv, time, p.grainFineness, seed);
    
    // Irregular grain variation
    float grainMod = valueNoise(uv * 200.0 + time * 5.0);
    grain *= 0.7 + grainMod * 0.6;
    
    // Moderate grain intensity
    float3 result = base + grain * p.grainIntensity;
    
    // Very subtle brightness drift over time (slow sine wave)
    // Gentle drift + irregular dim pulses with occasional flashes
    float brightnessDrift = sin(time * p.driftSpeed) * p.driftIntensity;

    // Irregular dimPulse: combine multiple noise frequencies for non-uniform breathing
    float slowPulse = valueNoise(float2(time * p.dimPulseSpeed * 0.3, seed));
    float mediumPulse = valueNoise(float2(time * p.dimPulseSpeed * 0.8, seed + 17.3));
    float fastPulse = valueNoise(float2(time * p.dimPulseSpeed * 2.1, seed + 42.7));

    // Combine octaves with different weights for irregular pattern
    float irregularNoise = slowPulse * 0.5 + mediumPulse * 0.3 + fastPulse * 0.2;

    // Occasional sharp flashes: use a separate high-threshold gate
    float flashGate = hash12(float2(floor(time * p.dimPulseSpeed * 1.3), seed + 88.4));
    float flashTrigger = step(0.97, flashGate); // Flash happens ~3% of the time
    float flashIntensity = hash12(float2(time * 100.0, seed + 123.0)) * 0.5 + 0.5; // 0.5 to 1.0
    float flashValue = flashTrigger * flashIntensity * abs(p.dimPulseIntensity) * 3.0; // Stronger flash

    // Base dim pulse (can be negative for dimming or positive for brightening)
    float dimPulse = smoothstep(p.dimPulseThreshold, 1.0, irregularNoise) * p.dimPulseIntensity;

    result += brightnessDrift;
    result += dimPulse;
    result += flashValue; // Add occasional bright flashes
    
    // Mild highlight softening
    float luminance = dot(result, float3(0.299, 0.587, 0.114));
    if (luminance > p.highlightSoftThreshold) {
        float softening = (luminance - p.highlightSoftThreshold) * p.highlightSoftAmount;
        result = mix(result, float3(luminance), softening);
    }
    
    // Slight shadow lift
    if (luminance < p.shadowLiftThreshold) {
        result += (p.shadowLiftThreshold - luminance) * p.shadowLiftAmount;
    }
    
    // Vignetting: noticeable but not theatrical.
    result *= vignetteMask(uv, p.vignetteStrength, p.vignetteRadius);

    // Occasional dust specks and scratches (thicker, more varied)
    // Use larger cells for bigger dust particles and add randomness to size
    float dustScale = max(1.0, p.dustSize);
    float2 dustCell = floor(uv * resolution / dustScale);
    float dustTime = floor(time * 2.0);
    float dustChance = hash12(dustCell + dustTime);
    if (dustChance > (1.0 - p.dustRate)) {
        // Random size variation within cell
        float sizeVar = hash12(dustCell * 7.3 + dustTime) * 0.8 + 0.6; // 0.6 to 1.4
        float2 dustCenter = (dustCell + 0.5) * dustScale / resolution;
        float2 toCenter = uv - dustCenter;
        float dustRadius = (dustScale * sizeVar * 0.5) / resolution.x;

        // Soft-edged dust with random shape distortion
        float shapeNoise = hash12(dustCell * 13.7);
        float aspectRatio = 0.3 + shapeNoise * 1.4; // 0.3 to 1.7 for varied shapes (scratches vs specks)
        float2 scaledDist = float2(toCenter.x, toCenter.y * aspectRatio);
        float shapedDist = length(scaledDist);

        float dustAlpha = 1.0 - smoothstep(0.0, dustRadius, shapedDist);
        float dustDarkness = hash12(dustCell * 1000.0 + dustTime) * p.dustIntensity;
        result -= dustDarkness * dustAlpha;
    }
    
    return saturate(result);
}

// MARK: - Effect: VHS

// Helper: Transform UV to logical orientation based on rotation.
// The scene texture already has the media rotated, but VHS effects need to know
// the "logical" orientation to apply directional effects correctly.
// For 90° rotated (portrait) videos, the visual "top" is on the left side of the texture.
static inline float2 transformUVForRotation(float2 uv, int rotation) {
    switch (rotation) {
        case 90:
            // Portrait video: logical top is on texture left
            return float2(uv.y, 1.0 - uv.x);
        case 180:
            return float2(1.0 - uv.x, 1.0 - uv.y);
        case 270:
            // Portrait video (rotated other way): logical top is on texture right
            return float2(1.0 - uv.y, uv.x);
        default:
            return uv;
    }
}

// Restrained analog tape look
float3 applyVHS(texture2d<float> tex, sampler s, float2 uv, float time, float2 resolution, float seed, int currentRotation, constant PatinaParamsVHS& p) {
    float2 texelSize = 1.0 / resolution;

    // Transform UV to logical orientation for directional VHS effects.
    // This ensures tear lines, scanlines, and tracking run "horizontally"
    // relative to the video's logical orientation, not the screen.
    float2 logicalUV = transformUVForRotation(uv, currentRotation);

    // For rotated content, determine the logical texel size
    float2 logicalTexelSize = texelSize;
    if (currentRotation == 90 || currentRotation == 270) {
        logicalTexelSize = float2(texelSize.y, texelSize.x); // Swap for portrait
    }

    // Random scan tear line: horizontal rip that scans downward; offsets the top portion.
    // Uses logical UV so tear runs horizontally relative to video content.
    float2 workingUV = uv; // Screen-space UV for sampling
    if (p.tearEnabled > 0.5) {
        float gate = valueNoise(float2(floor(time * max(0.001, p.tearGateRate)), seed + 91.0));
        if (gate > p.tearGateThreshold) {
            float tearY = fract(time * max(0.001, p.tearSpeed) + seed * 0.13) * 1.3 - 0.15;
            float topMask = step(logicalUV.y, tearY); // Use logical Y for tear position

            // Apply tear offset in screen space, but direction depends on rotation
            float offset = p.tearOffsetTexels;
            if (currentRotation == 0 || currentRotation == 180) {
                workingUV.x = saturate(workingUV.x + offset * texelSize.x * topMask);
            } else {
                // For 90°/270° rotation, tear offset affects screen Y
                workingUV.y = saturate(workingUV.y + offset * texelSize.y * topMask);
            }
        }
    }

    // Mild horizontal softness (horizontal blur in logical space)
    // For rotated content, "horizontal" blur becomes vertical in screen space
    float2 blurDir = (currentRotation == 90 || currentRotation == 270) ?
                     float2(0.0, texelSize.y) : float2(texelSize.x, 0.0);

    float3 c0 = sampleRGB(tex, s, workingUV);
    float3 c1 = sampleRGB(tex, s, workingUV + blurDir * p.blurTap1);
    float3 c_1 = sampleRGB(tex, s, workingUV - blurDir * p.blurTap1);
    float3 c2 = sampleRGB(tex, s, workingUV + blurDir * p.blurTap2);
    float3 c_2 = sampleRGB(tex, s, workingUV - blurDir * p.blurTap2);
    float3 result = (c0 * p.blurW0) + (c1 + c_1) * p.blurW1 + (c2 + c_2) * p.blurW2;

    // Very light horizontal noise (in logical space)
    float hNoise = hash12(float2(logicalUV.y * resolution.y, floor(time * 30.0))) * 2.0 - 1.0;
    float2 offsetUV = workingUV;
    if (currentRotation == 90 || currentRotation == 270) {
        offsetUV.y += hNoise * texelSize.y * 0.5;
    } else {
        offsetUV.x += hNoise * texelSize.x * 0.5;
    }

    // Subtle chroma bleed (shift color channels in logical horizontal direction)
    float2 center = logicalUV - 0.5;
    float r = length(center) * 2.0;
    float chromaOffset = p.chromaOffsetTexels * (0.6 + r * 0.9);

    float rShift = (hash12(float2(logicalUV.y * 100.0, time)) * 2.0 - 1.0) * chromaOffset;
    float bShift = (hash12(float2(logicalUV.y * 100.0 + 50.0, time)) * 2.0 - 1.0) * chromaOffset;

    // Apply chroma shift in logical horizontal direction
    float2 rOffset, bOffset;
    if (currentRotation == 90 || currentRotation == 270) {
        rOffset = float2(0.0, rShift * texelSize.y);
        bOffset = float2(0.0, bShift * texelSize.y);
    } else {
        rOffset = float2(rShift * texelSize.x, 0.0);
        bOffset = float2(bShift * texelSize.x, 0.0);
    }

    float rSample = sampleRGB(tex, s, offsetUV + rOffset).r;
    float bSample = sampleRGB(tex, s, offsetUV - bOffset).b;
    result.r = mix(result.r, rSample, p.chromaMix);
    result.b = mix(result.b, bSample, p.chromaMix);

    // Scanlines: run in logical Y direction
    // For rotated content, scanlines appear vertical in screen space
    float logicalResY = (currentRotation == 90 || currentRotation == 270) ? resolution.x : resolution.y;

    // Scanlines: gradient bands with wide bright areas, narrow dark lines
    float freq = logicalResY * p.lineFrequencyScale * 0.5;  // Halve frequency for thicker bands
    float phase = fract(logicalUV.y * freq);

    // Asymmetric wave: bright band (e.g. 65%) with gradient edges, then dark gap
    float bandWidth = p.scanlineBandWidth;  // Controls bright portion ratio
    float scanline;
    if (phase < bandWidth) {
        // Bright band with soft gradient at edges
        float t = phase / bandWidth;
        float edgeFade = smoothstep(0.0, 0.12, t) * smoothstep(1.0, 0.88, t);
        scanline = edgeFade;
    } else {
        // Dark gap between bands - smaller and darker
        float t = (phase - bandWidth) / (1.0 - bandWidth);
        scanline = 0.25 * (1.0 - cos(t * PI * 2.0)) * 0.5;  // Subtle pulse in dark area
    }
    scanline = pow(scanline, p.scanlinePow);
    result *= p.scanlineBase + scanline * p.scanlineAmp;

    // Gentle desaturation
    float luminance = dot(result, float3(0.299, 0.587, 0.114));
    result = mix(float3(luminance), result, p.desat);

    // CRT-ish tint (very light green/blue bias).
    result *= p.tintMultiplyRGBA.xyz;

    // Visual artifacts: horizontal tracking lines in logical space
    float logicalLine = floor(logicalUV.y * (logicalResY * p.lineFrequencyScale));
    float lineNoise = hash12(float2(logicalLine, floor(time * 30.0)));
    float tracking = smoothstep(p.trackingThreshold, 1.0, lineNoise);
    result *= 1.0 - tracking * p.trackingIntensity;

    // Very light static grain (stronger than film grain).
    float staticG = (hash12(float2(uv * resolution * 0.25 + time * 18.0)) * 2.0 - 1.0) * p.staticIntensity;
    result += staticG;

    // Edge softening in logical X direction
    float edgeSoft = 1.0 - smoothstep(0.0, 0.02, logicalUV.x) * (1.0 - smoothstep(0.98, 1.0, logicalUV.x));
    result *= 0.98 + edgeSoft * p.edgeSoftStrength;

    // Lift blacks and reduce contrast for washed-out VHS look
    result = p.blackLift + result * (1.0 - p.blackLift);

    return saturate(result);
}

// MARK: - Fragment Shader

fragment float4 patinaFragmentShader(VertexOut in [[stage_in]],
                                      texture2d<float> inputTexture [[texture(0)]],
                                      constant PatinaUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear,
                                      min_filter::linear,
                                      address::clamp_to_edge);
    
    float2 uv = in.texCoord;
    
    // Clamp UV to valid range
    uv = saturate(uv);
    
    // Sample input texture
    float4 color = inputTexture.sample(textureSampler, uv);
    
    // Apply patina effect based on mode
    float3 result;
    
    switch (uniforms.mode) {
        case PATINA_35MM:
            result = apply35mm(inputTexture, textureSampler, uv, uniforms.time, uniforms.resolution, uniforms.seed, uniforms.p35);
            break;
            
        case PATINA_AGED_FILM:
            result = applyAgedFilm(inputTexture, textureSampler, uv, uniforms.time, uniforms.resolution, uniforms.seed, uniforms.aged);
            break;
            
        case PATINA_VHS:
            result = applyVHS(inputTexture, textureSampler, uv, uniforms.time, uniforms.resolution, uniforms.seed, uniforms.currentRotation, uniforms.vhs);
            break;
            
        case PATINA_NONE:
        default:
            result = color.rgb;
            break;
    }
    
    return float4(result, color.a);
}
