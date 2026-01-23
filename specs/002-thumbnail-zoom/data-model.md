# Data Model: Thumbnail Grid Zoom

**Feature**: 002-thumbnail-zoom
**Created**: 2026-01-23

## Entities

### ZoomLevel

Represents a discrete thumbnail size stop in the grid.

| Field | Type | Description |
|-------|------|-------------|
| index | Int | Position in zoom level array (0-5) |
| pointSize | CGFloat | Thumbnail edge size in points (100, 140, 220, 320, 420, 680) |
| displayName | String | Human-readable label (e.g., "Dense", "Comfortable", "Medium", etc.) |
| isDefault | Bool | Whether this is the default zoom level (index 2 / 220pt) |

**Validation Rules**:
- index must be in range 0...5
- pointSize must match predefined values: [100, 140, 220, 320, 420, 680]
- Exactly one level has isDefault = true (index 2)

**Static Definition**:
```
ZoomLevel.all = [
  ZoomLevel(index: 0, pointSize: 100, displayName: "Dense", isDefault: false),
  ZoomLevel(index: 1, pointSize: 140, displayName: "Comfortable", isDefault: false),
  ZoomLevel(index: 2, pointSize: 220, displayName: "Medium", isDefault: true),
  ZoomLevel(index: 3, pointSize: 320, displayName: "Large", isDefault: false),
  ZoomLevel(index: 4, pointSize: 420, displayName: "Very Large", isDefault: false),
  ZoomLevel(index: 5, pointSize: 680, displayName: "Preview", isDefault: false)
]
```

---

### GridZoomState

Observable state object for current zoom level in the grid view.

| Field | Type | Description |
|-------|------|-------------|
| currentLevelIndex | Int | Index of currently active zoom level (persisted to UserDefaults) |
| isAnimating | Bool | Whether a zoom transition is in progress |

**Computed Properties**:
- `currentLevel: ZoomLevel` - Returns ZoomLevel.all[currentLevelIndex]
- `currentPointSize: CGFloat` - Returns currentLevel.pointSize
- `canZoomIn: Bool` - Returns currentLevelIndex < ZoomLevel.all.count - 1
- `canZoomOut: Bool` - Returns currentLevelIndex > 0

**State Transitions**:
```
zoomIn():
  precondition: canZoomIn == true
  action: currentLevelIndex += 1
  postcondition: isAnimating = true until animation completes

zoomOut():
  precondition: canZoomOut == true
  action: currentLevelIndex -= 1
  postcondition: isAnimating = true until animation completes

snapToNearest(proposedSize: CGFloat):
  action: Find ZoomLevel with nearest pointSize, set currentLevelIndex
```

**Persistence**:
- `currentLevelIndex` persisted via @AppStorage("gridZoomLevelIndex")
- Default value: 2 (Medium / 220pt)
- Restored on app launch before grid is displayed

---

### ThumbnailCacheKey (Extended)

Extended cache key to support multiple sizes per image.

| Field | Type | Description |
|-------|------|-------------|
| source | URL or String | File URL or Photos Library localIdentifier |
| rotationDegrees | Int | Applied rotation (0, 90, 180, 270) |
| requestedSize | CGFloat? | Optional target size for cache lookup |

**Cache Behavior**:
- If requestedSize is nil or ≤ 350, use existing 350pt cache
- If requestedSize > 350, generate and cache at requested size
- Cache lookup: exact match on (source, rotation, requestedSize bucket)

**Size Buckets** (to limit cache explosion):
- Bucket A: requestedSize ≤ 350 → cache at 350pt
- Bucket B: requestedSize > 350 → cache at 700pt (supports up to 680pt display + Retina)

---

## Relationships

```
GridZoomState --uses--> ZoomLevel.all (static array)
GridZoomState --persisted-to--> UserDefaults
ThumbnailCache --uses--> ThumbnailCacheKey (extended with size)
MediaGridCollectionView --observes--> GridZoomState.currentPointSize
```

---

## State Flow Diagram

```
User Action              State Change                     UI Effect
-----------              ------------                     ---------
Click +                  GridZoomState.zoomIn()          Animated grid resize
Click -                  GridZoomState.zoomOut()         Animated grid resize
Pinch gesture            GridZoomState.snapToNearest()   Animated grid resize
App launch               Load from UserDefaults          Grid at saved zoom
Scroll during zoom       No state change                 Scroll preserved
```

---

## Notes

- ZoomLevel is a value type (struct), not persisted independently
- GridZoomState is an @Observable/@ObservableObject for SwiftUI binding
- ThumbnailCache remains a background actor; size parameter is passed per-request
- No per-document storage; zoom level is global application preference
