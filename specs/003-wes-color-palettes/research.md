# Research: Wes Color Palettes

**Feature**: 003-wes-color-palettes
**Date**: 2026-01-26

## Research Questions

### 1. Color Grading Approach for GPU-Based Palette Effects

**Question**: How should palette-based color grading be implemented in Metal shaders to achieve the specified visual characteristics while maintaining 60fps performance?

**Decision**: Luminance-based split-toning with selective color biasing

**Rationale**:
- The existing effects (Monochrome, Silvertone, Sepia) use luminance extraction as their foundation
- Split-toning (different colors for highlights/midtones/shadows) is a well-established film grading technique
- GPU-efficient: requires only luminance calculation, conditional blending, and color multiplication
- Avoids expensive operations like full RGB-to-LAB conversions

**Alternatives Considered**:
- **LUT-based grading**: Rejected - would require pre-baked 3D lookup tables, adds texture memory overhead, less flexible for per-palette adjustments
- **Full colorspace conversion (LAB/OKLCH)**: Rejected - computationally expensive for real-time 60fps rendering
- **Object segmentation + recoloring**: Rejected - explicitly out of scope per spec (FR-028)

**Implementation Approach**:
```metal
// Core grading logic per pixel
float y = luminance(rgb);  // Reuse existing function

// Determine luminance zone weights (soft transitions)
float shadowWeight = smoothstep(0.0, 0.3, y) * (1.0 - smoothstep(0.2, 0.5, y));
float midtoneWeight = smoothstep(0.2, 0.4, y) * (1.0 - smoothstep(0.6, 0.8, y));
float highlightWeight = smoothstep(0.5, 0.7, y);

// Blend original toward palette colors based on zone
float3 graded = rgb;
graded = mix(graded, shadowColor * y * 3.0, shadowWeight * strength);
graded = mix(graded, dominantColor, midtoneWeight * strength * 0.5);
graded = mix(graded, highlightColor * (0.5 + y * 0.5), highlightWeight * strength * 0.3);
```

---

### 2. Skin Tone Preservation Algorithm

**Question**: How should skin tones be detected and protected from palette color shifts?

**Decision**: Hue-range exclusion with saturation threshold

**Rationale**:
- Human skin tones (across all ethnicities) fall within a narrow hue range: approximately 15°-45° in HSL/HSV
- Simple to compute in shader: RGB → HSL conversion for hue only
- Allows graduated protection (partial effect at boundaries) via smoothstep
- Well-documented technique used in professional color grading software

**Alternatives Considered**:
- **Machine learning skin detection**: Rejected - requires model inference, not feasible in real-time shader
- **Fixed RGB value ranges**: Rejected - too brittle, doesn't handle varying lighting conditions
- **No skin protection**: Rejected - explicit spec requirement (FR-004)

**Implementation Approach**:
```metal
// RGB to Hue conversion (0-1 range)
float rgbToHue(float3 rgb) {
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

// Skin tone detection (returns 0-1 protection factor)
float skinToneProtection(float3 rgb) {
    float hue = rgbToHue(rgb);  // 0-1 range
    float hueAngle = hue * 360.0;

    // Skin tones: ~15° to ~45° (orange-yellow range)
    float skinMask = smoothstep(10.0, 20.0, hueAngle) * (1.0 - smoothstep(40.0, 50.0, hueAngle));

    // Also check saturation - very desaturated pixels aren't skin
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float sat = (maxC > 0.001) ? (maxC - minC) / maxC : 0.0;
    float satMask = smoothstep(0.15, 0.3, sat);

    return skinMask * satMask;
}

// In grading function:
float protection = skinToneProtection(rgb);
float effectStrength = mix(1.0, 0.3, protection);  // Reduce to 30% on skin
```

---

### 3. Per-Palette Color Constants

**Question**: How should the 5 anchor colors per palette be encoded for shader use?

**Decision**: Normalized float3 constants defined directly in shader code

**Rationale**:
- Only 3 palettes with fixed colors (not user-configurable)
- Compile-time constants enable shader compiler optimization
- Avoids uniform buffer complexity for static data
- Colors specified in spec as RGB 0-255, converted to 0.0-1.0 for shader

**Palette Color Definitions**:

```metal
// Budapest Rose Palette
constant float3 budapestDominant = float3(1.000, 0.847, 0.925);   // #FFD8EC - Dominant Rose
constant float3 budapestSecondary = float3(1.000, 0.659, 0.796);  // #FFA8CB - Soft Pink
constant float3 budapestAccent = float3(0.898, 0.000, 0.047);     // #E5000C - Accent Red
constant float3 budapestShadow = float3(0.471, 0.259, 0.514);     // #784283 - Royal Purple
constant float3 budapestHighlight = float3(0.867, 0.839, 0.565);  // #DDD690 - Warm Cream
constant float budapestSaturation = 0.75;  // Reduce to 75%
constant float budapestContrast = -0.10;   // Soften by 10%

// Fantastic Mr Yellow Palette
constant float3 yellowDominant = float3(1.000, 0.788, 0.027);     // #FFC907 - Dominant Yellow
constant float3 yellowSecondary = float3(0.776, 0.125, 0.153);    // #C62027 - Fox Red
constant float3 yellowAccent = float3(0.910, 0.592, 0.255);       // #E89741 - Warm Orange
constant float3 yellowShadow = float3(0.765, 0.439, 0.129);       // #C37021 - Autumn Brown
constant float3 yellowHighlight = float3(0.949, 0.875, 0.816);    // #F2DFD0 - Paper Cream
constant float yellowSaturation = 1.0;     // No reduction
constant float yellowContrast = 0.0;       // Moderate (unchanged)

// Darjeeling Mint Palette
constant float3 mintDominant = float3(0.286, 0.600, 0.486);       // #49997C - Dominant Mint
constant float3 mintSecondary = float3(0.118, 0.745, 0.804);      // #1EBECD - Soft Cyan
constant float3 mintAccent = float3(0.008, 0.478, 0.690);         // #027AB0 - Railway Blue
constant float3 mintShadow = float3(0.682, 0.224, 0.094);         // #AE3918 - Spice Red (warm shadows)
constant float3 mintHighlight = float3(0.820, 0.612, 0.184);      // #D19C2F - Dusty Gold
constant float mintSaturation = 1.0;       // No reduction
constant float mintContrast = 0.05;        // Mild S-curve (+5%)
```

---

### 4. Contrast Adjustment Implementation

**Question**: How should per-palette contrast adjustments (e.g., -10% for Budapest Rose, S-curve for Darjeeling Mint) be implemented?

**Decision**: Simple linear contrast + optional S-curve via smoothstep

**Rationale**:
- Linear contrast adjustment is computationally trivial
- S-curve can be approximated with smoothstep for Darjeeling Mint
- Matches spec requirements without overcomplicating

**Implementation Approach**:
```metal
// Linear contrast adjustment around midpoint
float3 adjustContrast(float3 rgb, float amount) {
    // amount: negative = softer, positive = punchier
    float3 midpoint = float3(0.5);
    return midpoint + (rgb - midpoint) * (1.0 + amount);
}

// S-curve contrast (for Darjeeling Mint)
float3 sCurveContrast(float3 rgb, float strength) {
    // Gentle S-curve via smoothstep
    return smoothstep(0.0 - strength, 1.0 + strength, rgb);
}
```

---

### 5. Integration with Existing Effect System

**Question**: How should the new palettes integrate with the existing PostProcessingEffect enum and shader dispatch?

**Decision**: Extend existing enum and switch statement pattern

**Rationale**:
- Existing pattern is clean and well-tested
- CaseIterable automatically includes new cases in UI menu
- Switch-based dispatch in shader is efficient (compiler optimizes)
- Maintains backward compatibility with saved .softburn files (new raw values don't conflict)

**Implementation**:

Swift enum extension:
```swift
enum PostProcessingEffect: String, Codable, CaseIterable {
    case none
    case monochrome
    case silvertone
    case sepia
    case budapestRose      // NEW
    case fantasticMrYellow // NEW
    case darjeelingMint    // NEW

    var displayName: String {
        switch self {
        // ... existing cases ...
        case .budapestRose: return "Budapest Rose"
        case .fantasticMrYellow: return "Fantastic Mr Yellow"
        case .darjeelingMint: return "Darjeeling Mint"
        }
    }
}
```

Swift mode mapping:
```swift
let effectMode: Int32 = {
    switch settings.effect {
    // ... existing cases 0-3 ...
    case .budapestRose: return 4
    case .fantasticMrYellow: return 5
    case .darjeelingMint: return 6
    }
}()
```

Metal shader dispatch:
```metal
static inline float3 applyEffect(float3 rgb, int mode) {
    switch (mode) {
        // ... existing cases 1-3 ...
        case 4: return applyBudapestRose(rgb);
        case 5: return applyFantasticMrYellow(rgb);
        case 6: return applyDarjeelingMint(rgb);
        default: return rgb;
    }
}
```

---

## Summary

All technical questions have been resolved. The implementation will:

1. Extend `PostProcessingEffect` enum with 3 new cases
2. Add luminance-based split-toning shader functions with skin tone protection
3. Use compile-time color constants for each palette
4. Apply per-palette saturation and contrast adjustments
5. Add 3 new background color presets to the existing preset array

No external dependencies required. All changes are additive to existing infrastructure.
