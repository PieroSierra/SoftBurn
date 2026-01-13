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
    float3 _pad0;
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
    float _pad0;
};

// MARK: - Uniform Buffer

struct PatinaUniforms {
    int mode;           // Patina effect mode
    float time;         // Time in seconds for animated effects
    float2 resolution;  // Output resolution
    float seed;         // Random seed for grain variation
    float _pad0;
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
    // Gentle drift + very occasional dim (projector breathing), still subtle.
    float brightnessDrift = sin(time * p.driftSpeed) * p.driftIntensity;
    float dimPulse = smoothstep(p.dimPulseThreshold, 1.0, valueNoise(float2(time * p.dimPulseSpeed, seed))) * p.dimPulseIntensity;
    result += brightnessDrift;
    result += dimPulse;
    
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

    // Occasional faint dust specks (very sparse)
    float dustChance = hash12(floor(uv * resolution * 0.5) + floor(time * 2.0));
    if (dustChance > (1.0 - p.dustRate)) {
        float dustIntensity = hash12(uv * 1000.0 + time) * p.dustIntensity;
        result -= dustIntensity;
    }
    
    return saturate(result);
}

// MARK: - Effect: VHS

// Restrained analog tape look
float3 applyVHS(texture2d<float> tex, sampler s, float2 uv, float time, float2 resolution, float seed, constant PatinaParamsVHS& p) {
    float2 texelSize = 1.0 / resolution;

    // Random scan tear line: horizontal rip that scans downward; offsets the top portion.
    if (p.tearEnabled > 0.5) {
        float gate = valueNoise(float2(floor(time * max(0.001, p.tearGateRate)), seed + 91.0));
        if (gate > p.tearGateThreshold) {
            float tearY = fract(time * max(0.001, p.tearSpeed) + seed * 0.13) * 1.3 - 0.15;
            float topMask = step(uv.y, tearY); // uv.y=0 is top
            float offset = p.tearOffsetTexels * texelSize.x;
            uv.x = saturate(uv.x + offset * topMask);
            // Optional: brighten the tear band slightly (thin line)
            float band = smoothstep(tearY - p.tearBandHeight, tearY, uv.y) * (1.0 - smoothstep(tearY, tearY + p.tearBandHeight, uv.y));
            // We'll apply band later as a multiplicative notch.
        }
    }
    
    // Mild horizontal softness (horizontal blur) - real sampling, still lightweight.
    float3 c0 = sampleRGB(tex, s, uv);
    float3 c1 = sampleRGB(tex, s, uv + float2(texelSize.x * p.blurTap1, 0.0));
    float3 c_1 = sampleRGB(tex, s, uv - float2(texelSize.x * p.blurTap1, 0.0));
    float3 c2 = sampleRGB(tex, s, uv + float2(texelSize.x * p.blurTap2, 0.0));
    float3 c_2 = sampleRGB(tex, s, uv - float2(texelSize.x * p.blurTap2, 0.0));
    float3 result = (c0 * p.blurW0) + (c1 + c_1) * p.blurW1 + (c2 + c_2) * p.blurW2;
    
    // Very light horizontal noise
    float hNoise = hash12(float2(uv.y * resolution.y, floor(time * 30.0))) * 2.0 - 1.0;
    float2 offsetUV = uv;
    offsetUV.x += hNoise * texelSize.x * 0.5;
    
    // Subtle chroma bleed (shift color channels slightly)
    // Chromatic aberration: stronger toward edges.
    float2 center = uv - 0.5;
    float r = length(center) * 2.0;
    float chromaOffset = texelSize.x * p.chromaOffsetTexels * (0.6 + r * 0.9);
    float rShift = (hash12(float2(uv.y * 100.0, time)) * 2.0 - 1.0) * chromaOffset;
    float bShift = (hash12(float2(uv.y * 100.0 + 50.0, time)) * 2.0 - 1.0) * chromaOffset;
    
    // Apply subtle color channel separation with horizontal shift
    float rSample = sampleRGB(tex, s, offsetUV + float2(rShift, 0.0)).r;
    float bSample = sampleRGB(tex, s, offsetUV - float2(bShift, 0.0)).b;
    // Chroma bleed should be visible but restrained.
    result.r = mix(result.r, rSample, p.chromaMix);
    result.b = mix(result.b, bSample, p.chromaMix);
    
    // Very light scanline texture
    float scanline = sin(uv.y * (resolution.y * p.lineFrequencyScale) * PI) * 0.5 + 0.5;
    scanline = pow(scanline, p.scanlinePow);
    result *= p.scanlineBase + scanline * p.scanlineAmp;
    
    // Gentle desaturation
    float luminance = dot(result, float3(0.299, 0.587, 0.114));
    result = mix(float3(luminance), result, p.desat);

    // CRT-ish tint (very light green/blue bias).
    result *= p.tintMultiplyRGBA.xyz;

    // Visual artifacts: subtle horizontal tracking lines + occasional static bursts.
    float line = floor(uv.y * (resolution.y * p.lineFrequencyScale));
    float lineNoise = hash12(float2(line, floor(time * 30.0)));
    float tracking = smoothstep(p.trackingThreshold, 1.0, lineNoise);
    result *= 1.0 - tracking * p.trackingIntensity;

    // Very light static grain (stronger than film grain).
    float staticG = (hash12(float2(uv * resolution * 0.25 + time * 18.0)) * 2.0 - 1.0) * p.staticIntensity;
    result += staticG;
    
    // Very slight edge softening
    float edgeSoft = 1.0 - smoothstep(0.0, 0.02, uv.x) * (1.0 - smoothstep(0.98, 1.0, uv.x));
    result *= 0.98 + edgeSoft * p.edgeSoftStrength;
    
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
            result = applyVHS(inputTexture, textureSampler, uv, uniforms.time, uniforms.resolution, uniforms.seed, uniforms.vhs);
            break;
            
        case PATINA_NONE:
        default:
            result = color.rgb;
            break;
    }
    
    return float4(result, color.a);
}
