# Implementation Plan: Wes Color Palettes

**Branch**: `003-wes-color-palettes` | **Date**: 2026-01-26 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-wes-color-palettes/spec.md`

## Summary

Add three cinematic color grading presets (Budapest Rose, Fantastic Mr Yellow, Darjeeling Mint) to the existing color effects system. Each palette uses 5 anchor colors to apply luminance-aware color grading with skin tone preservation. Implementation extends the existing `PostProcessingEffect` enum and `applyEffect()` Metal shader function, following the established pattern for Monochrome/Silvertone/Sepia effects.

## Technical Context

**Language/Version**: Swift 5.9+ with strict concurrency (Swift 6 compatible)
**Primary Dependencies**: SwiftUI, Metal 3, AppKit (all built-in macOS frameworks)
**Storage**: UserDefaults via @AppStorage (hex color strings, enum raw values)
**Testing**: Manual visual testing (no XCTest infrastructure in project)
**Target Platform**: macOS 13+ (Ventura and later)
**Project Type**: Single native macOS application
**Performance Goals**: 60fps slideshow playback maintained during color grading
**Constraints**: GPU-accelerated rendering required; no per-frame CPU color processing
**Scale/Scope**: 3 new color palettes, 3 new background swatches

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution is a template (not configured for SoftBurn). No constitutional gates apply. Proceeding with standard macOS/Metal best practices documented in CLAUDE.md.

**Pre-Design Check**: ✅ PASS (no constitution violations)

## Project Structure

### Documentation (this feature)

```text
specs/003-wes-color-palettes/
├── plan.md              # This file
├── research.md          # Phase 0 output - color grading algorithms
├── data-model.md        # Phase 1 output - palette data structures
├── quickstart.md        # Phase 1 output - implementation guide
└── checklists/          # Validation checklists
    └── requirements.md  # Spec quality checklist
```

### Source Code (files to modify)

```text
SoftBurn/
├── Models/
│   └── SlideshowDocument.swift     # PostProcessingEffect enum (add 3 cases)
├── State/
│   └── SlideshowSettings.swift     # No changes needed (existing infrastructure)
├── Rendering/
│   ├── MetalSlideshowRenderer.swift # Effect mode mapping (add cases 4,5,6)
│   └── Shaders/
│       └── SlideshowShaders.metal   # applyEffect() function (add palette grading)
└── Views/
    └── Settings/
        └── SettingsPopoverView.swift # Background color presets (add 3 colors)
```

**Structure Decision**: Single macOS app - modifications to existing files only. No new files required.

## Complexity Tracking

No constitutional violations to justify.

## Phase 0: Research Findings

See [research.md](./research.md) for detailed analysis.

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Color grading approach | Luminance-based split-toning | Matches existing effect pattern; GPU-efficient |
| Skin tone preservation | Hue-range exclusion (15°-45° hue) | Standard technique; computationally cheap |
| Palette application | Highlight/midtone/shadow targeting | Spec requirement; enables distinct looks |
| Saturation/contrast | Per-palette constants | Spec provides exact values |

## Phase 1: Design

### Files Modified

| File | Changes |
|------|---------|
| `SlideshowDocument.swift` | Add 3 enum cases with displayNames |
| `MetalSlideshowRenderer.swift` | Map effect enum to shader mode (4,5,6) |
| `SlideshowShaders.metal` | Add `applyWesPalette()` function + 3 palette modes |
| `SettingsPopoverView.swift` | Add 3 preset background colors |
| `PostProcessingEffect.swift` | Add switch cases for new palettes (pass-through to GPU) |
| `OfflineSlideshowRenderer.swift` | Map effect enum to shader mode for video export |

### Shader Algorithm (applyEffect extension)

```metal
// Palette grading algorithm (pseudocode)
1. Extract luminance (Y) from RGB
2. Calculate saturation for skin tone detection
3. Convert to HSL for hue analysis
4. If skin tone detected (hue 15°-45°, sat > 0.2): reduce effect strength to 30%
5. Apply luminance-based color mixing:
   - Shadows (Y < 0.3): blend toward shadow palette color
   - Midtones (0.3 < Y < 0.7): blend toward dominant palette color
   - Highlights (Y > 0.7): blend toward highlight palette color
6. Apply palette-specific saturation multiplier
7. Apply palette-specific contrast adjustment
8. Return graded RGB
```

### Effect Mode Mapping

| Effect | Enum Case | Shader Mode | Display Name |
|--------|-----------|-------------|--------------|
| None | `.none` | 0 | "None" |
| Monochrome | `.monochrome` | 1 | "Monochrome" |
| Silvertone | `.silvertone` | 2 | "Silvertone" |
| Sepia | `.sepia` | 3 | "Sepia" |
| Budapest Rose | `.budapestRose` | 4 | "Budapest Rose" |
| Fantastic Mr Yellow | `.fantasticMrYellow` | 5 | "Fantastic Mr Yellow" |
| Darjeeling Mint | `.darjeelingMint` | 6 | "Darjeeling Mint" |

### Background Color Presets (additions)

| Palette | Label | RGB | Hex |
|---------|-------|-----|-----|
| Budapest Rose | "Warm Cream" | (221,214,144) | #DDD690 |
| Fantastic Mr Yellow | "Paper Cream" | (242,223,208) | #F2DFD0 |
| Darjeeling Mint | "Dusty Gold" | (209,156,47) | #D19C2F |

## Post-Design Constitution Check

**Post-Design Check**: ✅ PASS

- No new dependencies added (Metal already in use)
- No new files created (extends existing infrastructure)
- Performance maintained (GPU shader-only changes)
- Follows existing patterns (enum cases + shader modes)
