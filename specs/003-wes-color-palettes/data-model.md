# Data Model: Wes Color Palettes

**Feature**: 003-wes-color-palettes
**Date**: 2026-01-26

## Overview

This feature extends existing data structures without creating new entities. The primary changes are enum case additions and shader constant definitions.

---

## Entity: PostProcessingEffect (Extended)

**Location**: `SoftBurn/Models/SlideshowDocument.swift`

### Current State

```swift
enum PostProcessingEffect: String, Codable, CaseIterable {
    case none
    case monochrome
    case silvertone
    case sepia
}
```

### Extended State

```swift
enum PostProcessingEffect: String, Codable, CaseIterable {
    case none
    case monochrome
    case silvertone
    case sepia
    case budapestRose       // NEW: Warm pastel, rose-tinted
    case fantasticMrYellow  // NEW: Autumnal, yellow-dominant
    case darjeelingMint     // NEW: Cool, mint-green pulls
}
```

### Attributes

| Case | Raw Value | Display Name | Shader Mode |
|------|-----------|--------------|-------------|
| `none` | `"none"` | "None" | 0 |
| `monochrome` | `"monochrome"` | "Monochrome" | 1 |
| `silvertone` | `"silvertone"` | "Silvertone" | 2 |
| `sepia` | `"sepia"` | "Sepia" | 3 |
| `budapestRose` | `"budapestRose"` | "Budapest Rose" | 4 |
| `fantasticMrYellow` | `"fantasticMrYellow"` | "Fantastic Mr Yellow" | 5 |
| `darjeelingMint` | `"darjeelingMint"` | "Darjeeling Mint" | 6 |

### Validation Rules

- Raw values must be unique (enforced by Swift enum)
- Raw values are used for JSON serialization in `.softburn` files
- Unknown raw values during decoding should fall back to `.none` for backward compatibility

### Backward Compatibility

Files saved with new palettes will contain the new raw value strings. When opened in older versions of SoftBurn:
- `Codable` decoding will fail for unknown cases
- Recommendation: Add `init(from decoder:)` with fallback to `.none` for graceful degradation

---

## Entity: ColorPalette (Shader Constants)

**Location**: `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`

This is not a Swift type but a conceptual entity represented as shader constants.

### Structure (per palette)

| Field | Type | Description |
|-------|------|-------------|
| `dominant` | `float3` | Primary color for midtone bias |
| `secondary` | `float3` | Supporting color (unused in MVP) |
| `accent` | `float3` | Color for biasing specific hue ranges |
| `shadow` | `float3` | Color for shadow-range tinting |
| `highlight` | `float3` | Color for highlight-range tinting |
| `saturation` | `float` | Multiplier for output saturation (0.0-1.0) |
| `contrast` | `float` | Contrast adjustment (-1.0 to +1.0) |

### Budapest Rose Palette

| Field | Value (RGB normalized) | Hex | Role |
|-------|------------------------|-----|------|
| `dominant` | `(1.000, 0.847, 0.925)` | #FFD8EC | Dominant Rose |
| `secondary` | `(1.000, 0.659, 0.796)` | #FFA8CB | Soft Pink |
| `accent` | `(0.898, 0.000, 0.047)` | #E5000C | Accent Red |
| `shadow` | `(0.471, 0.259, 0.514)` | #784283 | Royal Purple |
| `highlight` | `(0.867, 0.839, 0.565)` | #DDD690 | Warm Cream |
| `saturation` | `0.75` | — | 75% of original |
| `contrast` | `-0.10` | — | Softened 10% |

### Fantastic Mr Yellow Palette

| Field | Value (RGB normalized) | Hex | Role |
|-------|------------------------|-----|------|
| `dominant` | `(1.000, 0.788, 0.027)` | #FFC907 | Dominant Yellow |
| `secondary` | `(0.776, 0.125, 0.153)` | #C62027 | Fox Red |
| `accent` | `(0.910, 0.592, 0.255)` | #E89741 | Warm Orange |
| `shadow` | `(0.765, 0.439, 0.129)` | #C37021 | Autumn Brown |
| `highlight` | `(0.949, 0.875, 0.816)` | #F2DFD0 | Paper Cream |
| `saturation` | `1.0` | — | No change |
| `contrast` | `0.0` | — | No change |

### Darjeeling Mint Palette

| Field | Value (RGB normalized) | Hex | Role |
|-------|------------------------|-----|------|
| `dominant` | `(0.286, 0.600, 0.486)` | #49997C | Dominant Mint |
| `secondary` | `(0.118, 0.745, 0.804)` | #1EBECD | Soft Cyan |
| `accent` | `(0.008, 0.478, 0.690)` | #027AB0 | Railway Blue |
| `shadow` | `(0.682, 0.224, 0.094)` | #AE3918 | Spice Red |
| `highlight` | `(0.820, 0.612, 0.184)` | #D19C2F | Dusty Gold |
| `saturation` | `1.0` | — | No change |
| `contrast` | `0.05` | — | Mild S-curve |

---

## Entity: Background Color Presets (Extended)

**Location**: `SoftBurn/Views/Settings/SettingsPopoverView.swift`

### Current State

```swift
private let presetColors: [(String, Color)] = [
    ("Dark Gray", Color(white: 0.15)),
    ("Black", .black),
    ("Gray", .gray),
    ("White", .white),
    ("Navy", Color(red: 0.1, green: 0.1, blue: 0.3)),
    ("Dark Brown", Color(red: 0.2, green: 0.15, blue: 0.1)),
]
```

### Extended State

```swift
private let presetColors: [(String, Color)] = [
    // Existing presets
    ("Dark Gray", Color(white: 0.15)),
    ("Black", .black),
    ("Gray", .gray),
    ("White", .white),
    ("Navy", Color(red: 0.1, green: 0.1, blue: 0.3)),
    ("Dark Brown", Color(red: 0.2, green: 0.15, blue: 0.1)),
    // NEW: Wes palette matching backgrounds
    ("Warm Cream", Color(red: 221/255, green: 214/255, blue: 144/255)),
    ("Paper Cream", Color(red: 242/255, green: 223/255, blue: 208/255)),
    ("Dusty Gold", Color(red: 209/255, green: 156/255, blue: 47/255)),
]
```

### New Preset Attributes

| Label | RGB | Hex | Matching Palette |
|-------|-----|-----|------------------|
| "Warm Cream" | (221, 214, 144) | #DDD690 | Budapest Rose |
| "Paper Cream" | (242, 223, 208) | #F2DFD0 | Fantastic Mr Yellow |
| "Dusty Gold" | (209, 156, 47) | #D19C2F | Darjeeling Mint |

---

## State Transitions

### Effect Selection Flow

```
User selects palette from Color menu
    ↓
SlideshowSettings.effect updated (Published property)
    ↓
MetalSlideshowRenderer observes change
    ↓
Next frame: effectMode uniform set to new value (4, 5, or 6)
    ↓
Shader applyEffect() receives mode, dispatches to palette function
    ↓
Graded pixels rendered to scene texture
```

### Background Color Selection Flow

```
User selects preset from Background color picker
    ↓
SlideshowSettings.backgroundColor updated
    ↓
Hex string persisted to UserDefaults via @AppStorage
    ↓
MetalSlideshowRenderer reads settings.backgroundColor
    ↓
Scene render pass clearColor set to selected color
```

---

## Relationships

```
┌─────────────────────────┐
│   SlideshowSettings     │
│   (Observable Object)   │
├─────────────────────────┤
│ effect: PostProcessing  │──────┐
│         Effect          │      │
│ backgroundColor: Color  │──┐   │
└─────────────────────────┘  │   │
                             │   │
        ┌────────────────────┘   │
        │                        │
        ▼                        ▼
┌───────────────────┐   ┌─────────────────────┐
│ Background Presets│   │ PostProcessingEffect│
│ (View Constants)  │   │      (Enum)         │
├───────────────────┤   ├─────────────────────┤
│ Warm Cream        │   │ .budapestRose    →4 │
│ Paper Cream       │   │ .fantasticMrYellow→5│
│ Dusty Gold        │   │ .darjeelingMint  →6 │
└───────────────────┘   └─────────────────────┘
                                  │
                                  ▼
                        ┌─────────────────────┐
                        │   Metal Shader      │
                        │   (applyEffect)     │
                        ├─────────────────────┤
                        │ mode 4 → Budapest   │
                        │ mode 5 → Yellow     │
                        │ mode 6 → Mint       │
                        └─────────────────────┘
```

---

## Persistence Format

### .softburn File (JSON excerpt)

```json
{
  "version": 5,
  "settings": {
    "effect": "budapestRose",
    "backgroundColor": "#DDD690",
    "patina": "none",
    ...
  },
  "photos": [...]
}
```

No schema changes required - existing fields accommodate new enum values.
