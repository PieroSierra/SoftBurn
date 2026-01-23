# API Contracts: Thumbnail Grid Zoom

**Feature**: 002-thumbnail-zoom
**Created**: 2026-01-23

This feature is a native macOS desktop application with no external APIs. The contracts below define internal Swift interfaces.

---

## GridZoomState Interface

```swift
/// Observable state for grid zoom level
@MainActor
protocol GridZoomStateProtocol: ObservableObject {
    /// Current zoom level index (0-5), persisted to UserDefaults
    var currentLevelIndex: Int { get set }

    /// Current zoom level point size (computed)
    var currentPointSize: CGFloat { get }

    /// Whether zoom in is available
    var canZoomIn: Bool { get }

    /// Whether zoom out is available
    var canZoomOut: Bool { get }

    /// Increase zoom by one level (animated)
    func zoomIn()

    /// Decrease zoom by one level (animated)
    func zoomOut()

    /// Snap to nearest zoom level given a proposed size
    func snapToNearest(proposedSize: CGFloat)
}
```

---

## MediaGridCollectionView Extensions

```swift
extension MediaGridCollectionView {
    /// Update grid item size with optional animation
    /// - Parameters:
    ///   - pointSize: Target thumbnail size in points
    ///   - animated: Whether to animate the transition (default: true)
    func updateZoomLevel(to pointSize: CGFloat, animated: Bool)

    /// Handle trackpad magnification gesture
    /// - Parameter delta: Magnification delta from NSEvent.magnification
    func handleMagnification(_ delta: CGFloat)
}
```

---

## ThumbnailCache Extensions

```swift
extension ThumbnailCache {
    /// Request a thumbnail at a specific size
    /// - Parameters:
    ///   - url: Source file URL
    ///   - rotationDegrees: Applied rotation (0, 90, 180, 270)
    ///   - requestedSize: Optional target size (nil uses default 350pt)
    /// - Returns: Cached or generated thumbnail, or nil if unavailable
    func thumbnail(
        for url: URL,
        rotationDegrees: Int,
        requestedSize: CGFloat?
    ) async -> NSImage?
}
```

---

## ContentView Toolbar Contract

```swift
/// Toolbar zoom controls must provide:
/// - Zoom out button (SF Symbol: "minus")
/// - Zoom in button (SF Symbol: "plus")
/// - Buttons positioned between item counter and rotate/remove group
/// - Disabled state when at min/max zoom or when slideshow is empty
/// - Help text for accessibility
```

---

## Event Flow Contract

```
┌─────────────────┐      ┌──────────────────┐      ┌───────────────────────┐
│  User Action    │      │  GridZoomState   │      │ MediaGridCollectionView│
│  (button/pinch) │─────▶│  (state update)  │─────▶│  (layout animation)   │
└─────────────────┘      └──────────────────┘      └───────────────────────┘
                                 │
                                 ▼
                         ┌──────────────┐
                         │  UserDefaults │
                         │  (persist)    │
                         └──────────────┘
```

---

## Persistence Contract

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `gridZoomLevelIndex` | Int | 2 | Index into ZoomLevel.all array |

**Invariants**:
- Value must be in range 0...5
- Invalid values reset to default (2)
- Persisted immediately on change
- Restored before grid view appears
