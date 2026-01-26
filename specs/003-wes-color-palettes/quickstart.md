# Quickstart: Wes Color Palettes Implementation

**Feature**: 003-wes-color-palettes
**Date**: 2026-01-26

## Overview

This guide provides step-by-step implementation instructions for adding three Wes Anderson-inspired color palettes to SoftBurn. The implementation modifies 4 existing files with no new files required.

---

## Prerequisites

- Xcode with Metal shader support
- Familiarity with SoftBurn's existing color effect system
- Understanding of Metal shader language basics

---

## Implementation Steps

### Step 1: Extend PostProcessingEffect Enum

**File**: `SoftBurn/Models/SlideshowDocument.swift`

Add three new cases to the `PostProcessingEffect` enum and update the `displayName` computed property.

```swift
enum PostProcessingEffect: String, Codable, CaseIterable {
    case none
    case monochrome
    case silvertone
    case sepia
    case budapestRose       // ADD
    case fantasticMrYellow  // ADD
    case darjeelingMint     // ADD

    var displayName: String {
        switch self {
        case .none: return "None"
        case .monochrome: return "Monochrome"
        case .silvertone: return "Silvertone"
        case .sepia: return "Sepia"
        case .budapestRose: return "Budapest Rose"           // ADD
        case .fantasticMrYellow: return "Fantastic Mr Yellow" // ADD
        case .darjeelingMint: return "Darjeeling Mint"       // ADD
        }
    }
}
```

**Verification**: Build should succeed. UI color menu will now show 7 options (3 new ones do nothing yet).

---

### Step 2: Map Effect Modes in Renderer

**File**: `SoftBurn/Rendering/MetalSlideshowRenderer.swift`

Find the `effectMode` calculation (around line 829) and add cases for the new palettes.

```swift
let effectMode: Int32 = {
    switch settings.effect {
    case .none: return 0
    case .monochrome: return 1
    case .silvertone: return 2
    case .sepia: return 3
    case .budapestRose: return 4       // ADD
    case .fantasticMrYellow: return 5  // ADD
    case .darjeelingMint: return 6     // ADD
    }
}()
```

**Verification**: Build should succeed. Selecting new palettes passes mode 4/5/6 to shader (falls through to default, no visual change yet).

---

### Step 3: Implement Shader Palette Functions

**File**: `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`

Add the following code after the existing `applyEffect` function (around line 63).

#### 3a. Add Helper Functions

```metal
// RGB to Hue conversion (0-1 range)
static inline float rgbToHue(float3 rgb) {
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float delta = maxC - minC;
    if (delta < 0.001) return 0.0;

    float hue;
    if (maxC == rgb.r) hue = (rgb.g - rgb.b) / delta;
    else if (maxC == rgb.g) hue = 2.0 + (rgb.b - rgb.r) / delta;
    else hue = 4.0 + (rgb.r - rgb.g) / delta;

    return fract(hue / 6.0);
}

// Skin tone protection (returns 0-1, higher = more protection)
static inline float skinToneProtection(float3 rgb) {
    float hue = rgbToHue(rgb) * 360.0;

    // Skin tones: ~15° to ~45°
    float skinMask = smoothstep(10.0, 20.0, hue) * (1.0 - smoothstep(40.0, 50.0, hue));

    // Require minimum saturation
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    float minC = min(rgb.r, min(rgb.g, rgb.b));
    float sat = (maxC > 0.001) ? (maxC - minC) / maxC : 0.0;
    float satMask = smoothstep(0.15, 0.3, sat);

    return skinMask * satMask;
}

// Contrast adjustment
static inline float3 adjustContrast(float3 rgb, float amount) {
    float3 mid = float3(0.5);
    return saturate(mid + (rgb - mid) * (1.0 + amount));
}

// Saturation adjustment
static inline float3 adjustSaturation(float3 rgb, float amount) {
    float y = luminance(rgb);
    return saturate(mix(float3(y), rgb, amount));
}
```

#### 3b. Add Budapest Rose Palette Function

```metal
static inline float3 applyBudapestRose(float3 rgb) {
    // Palette colors (normalized)
    constant float3 dominant = float3(1.000, 0.847, 0.925);   // Rose
    constant float3 shadow = float3(0.471, 0.259, 0.514);     // Purple
    constant float3 highlight = float3(0.867, 0.839, 0.565);  // Cream
    constant float3 accentRed = float3(0.898, 0.000, 0.047);  // Accent

    float y = luminance(rgb);
    float protection = skinToneProtection(rgb);
    float strength = mix(1.0, 0.3, protection);

    // Zone weights
    float shadowW = (1.0 - smoothstep(0.0, 0.4, y)) * 0.4;
    float midW = smoothstep(0.2, 0.4, y) * (1.0 - smoothstep(0.6, 0.8, y)) * 0.5;
    float highW = smoothstep(0.6, 0.9, y) * 0.3;

    // Bias reds toward accent red
    float redBias = smoothstep(0.3, 0.6, rgb.r) * (1.0 - smoothstep(0.2, 0.5, rgb.g));

    float3 graded = rgb;
    graded = mix(graded, shadow * (y + 0.3), shadowW * strength);
    graded = mix(graded, dominant, midW * strength);
    graded = mix(graded, highlight, highW * strength);
    graded = mix(graded, accentRed * (rgb.r + 0.2), redBias * strength * 0.3);

    // Reduce saturation to 75%, soften contrast by 10%
    graded = adjustSaturation(graded, 0.75);
    graded = adjustContrast(graded, -0.10);

    return saturate(graded);
}
```

#### 3c. Add Fantastic Mr Yellow Palette Function

```metal
static inline float3 applyFantasticMrYellow(float3 rgb) {
    // Palette colors
    constant float3 dominant = float3(1.000, 0.788, 0.027);   // Yellow
    constant float3 foxRed = float3(0.776, 0.125, 0.153);     // Fox Red
    constant float3 shadow = float3(0.765, 0.439, 0.129);     // Autumn Brown
    constant float3 highlight = float3(0.949, 0.875, 0.816);  // Paper Cream

    float y = luminance(rgb);
    float protection = skinToneProtection(rgb);
    float strength = mix(1.0, 0.3, protection);

    // Zone weights
    float shadowW = (1.0 - smoothstep(0.0, 0.4, y)) * 0.35;
    float midW = smoothstep(0.2, 0.4, y) * (1.0 - smoothstep(0.6, 0.8, y)) * 0.5;
    float highW = smoothstep(0.6, 0.9, y) * 0.25;

    // Bias yellows toward dominant, reds toward fox red
    float yellowBias = smoothstep(0.4, 0.7, rgb.r) * smoothstep(0.3, 0.6, rgb.g) * (1.0 - smoothstep(0.2, 0.4, rgb.b));
    float redBias = smoothstep(0.4, 0.7, rgb.r) * (1.0 - smoothstep(0.2, 0.4, rgb.g));

    // De-emphasize greens
    float greenSuppress = smoothstep(0.3, 0.6, rgb.g) * (1.0 - smoothstep(0.2, 0.5, rgb.r));

    float3 graded = rgb;
    graded = mix(graded, shadow * (y + 0.4), shadowW * strength);
    graded = mix(graded, dominant, midW * strength);
    graded = mix(graded, highlight, highW * strength);
    graded = mix(graded, dominant, yellowBias * strength * 0.4);
    graded = mix(graded, foxRed * (rgb.r + 0.3), redBias * strength * 0.35);

    // Suppress neon greens
    graded.g = mix(graded.g, graded.g * 0.85, greenSuppress * strength);

    return saturate(graded);
}
```

#### 3d. Add Darjeeling Mint Palette Function

```metal
static inline float3 applyDarjeelingMint(float3 rgb) {
    // Palette colors
    constant float3 dominant = float3(0.286, 0.600, 0.486);   // Mint
    constant float3 railwayBlue = float3(0.008, 0.478, 0.690);// Blue
    constant float3 shadow = float3(0.682, 0.224, 0.094);     // Spice Red (warm)
    constant float3 highlight = float3(0.820, 0.612, 0.184);  // Dusty Gold

    float y = luminance(rgb);
    float protection = skinToneProtection(rgb);
    float strength = mix(1.0, 0.3, protection);

    // Zone weights - cool highlights, warm shadows
    float shadowW = (1.0 - smoothstep(0.0, 0.4, y)) * 0.3;
    float midW = smoothstep(0.2, 0.4, y) * (1.0 - smoothstep(0.6, 0.8, y)) * 0.45;
    float highW = smoothstep(0.6, 0.9, y) * 0.25;

    // Bias greens/cyans toward mint, blues toward railway blue
    float greenCyanBias = smoothstep(0.3, 0.6, rgb.g) * (1.0 - smoothstep(0.3, 0.6, rgb.r));
    float blueBias = smoothstep(0.3, 0.6, rgb.b) * (1.0 - smoothstep(0.3, 0.5, rgb.r));

    float3 graded = rgb;
    graded = mix(graded, shadow * (y + 0.5), shadowW * strength);  // Warm shadows
    graded = mix(graded, dominant, midW * strength);
    graded = mix(graded, highlight * 0.9 + float3(0.0, 0.05, 0.1), highW * strength);  // Cool highlights
    graded = mix(graded, dominant, greenCyanBias * strength * 0.4);
    graded = mix(graded, railwayBlue * (rgb.b + 0.3), blueBias * strength * 0.25);

    // Mild S-curve contrast
    graded = smoothstep(-0.05, 1.05, graded);

    return saturate(graded);
}
```

#### 3e. Update applyEffect Switch Statement

Modify the existing `applyEffect` function to include the new cases:

```metal
static inline float3 applyEffect(float3 rgb, int mode) {
    switch (mode) {
        case 1: { // monochrome
            float y = luminance(rgb);
            return float3(y);
        }
        case 2: { // silvertone
            float y = luminance(rgb);
            float3 g = float3(y);
            float3 tinted = g * float3(0.94, 0.96, 1.0);
            return saturate(tinted + 0.02);
        }
        case 3: { // sepia
            float y = luminance(rgb);
            float3 g = float3(y);
            return saturate(g * float3(1.0, 0.92, 0.78));
        }
        case 4: return applyBudapestRose(rgb);      // ADD
        case 5: return applyFantasticMrYellow(rgb); // ADD
        case 6: return applyDarjeelingMint(rgb);    // ADD
        default:
            return rgb;
    }
}
```

**Verification**: Build and run. Selecting each palette should show distinct color grading. Test with photos containing people to verify skin tone preservation.

---

### Step 4: Add Background Color Presets

**File**: `SoftBurn/Views/Settings/SettingsPopoverView.swift`

Find the `presetColors` array (around line 369) and add three new entries:

```swift
private let presetColors: [(String, Color)] = [
    ("Dark Gray", Color(white: 0.15)),
    ("Black", .black),
    ("Gray", .gray),
    ("White", .white),
    ("Navy", Color(red: 0.1, green: 0.1, blue: 0.3)),
    ("Dark Brown", Color(red: 0.2, green: 0.15, blue: 0.1)),
    // Wes palette backgrounds
    ("Warm Cream", Color(red: 221/255, green: 214/255, blue: 144/255)),   // ADD
    ("Paper Cream", Color(red: 242/255, green: 223/255, blue: 208/255)),  // ADD
    ("Dusty Gold", Color(red: 209/255, green: 156/255, blue: 47/255)),    // ADD
]
```

**Verification**: Open background color picker. Should show 9 preset swatches (3 new ones at end).

---

## Testing Checklist

- [ ] All 7 color effects appear in Color menu (in correct order)
- [ ] Budapest Rose produces warm, pastel, rose-tinted images
- [ ] Fantastic Mr Yellow produces warm, autumnal, yellow-dominant images
- [ ] Darjeeling Mint produces cool, mint-green tinted images
- [ ] Skin tones remain natural across all three palettes
- [ ] Switching between palettes is instantaneous (no artifacts)
- [ ] Palettes work correctly with photos
- [ ] Palettes work correctly with videos
- [ ] Palettes stack correctly with patina effects (35mm, Aged Film, VHS)
- [ ] All 9 background presets appear in picker
- [ ] Warm Cream background is #DDD690
- [ ] Paper Cream background is #F2DFD0
- [ ] Dusty Gold background is #D19C2F
- [ ] Settings persist after app restart
- [ ] Saved .softburn files store new palette values correctly
- [ ] Opening files with new palettes works in current build

---

## Troubleshooting

### Shader Compilation Errors

- Ensure all helper functions are declared `static inline`
- Check for missing semicolons or braces
- Verify `constant` keyword used for palette color declarations inside functions

### Colors Look Wrong

- Verify RGB values are normalized (divided by 255)
- Check that saturation/contrast adjustments use correct polarity
- Ensure `saturate()` is called on final output

### Skin Tones Affected Too Much

- Verify hue range in `skinToneProtection` (should be ~15°-45°)
- Check saturation threshold (0.15-0.3 smoothstep)
- Ensure `strength` is reduced to 0.3 when protection is active

### Background Colors Don't Match

- Verify Color initializer uses `red:green:blue:` with values divided by 255
- Check hex conversions match specification
