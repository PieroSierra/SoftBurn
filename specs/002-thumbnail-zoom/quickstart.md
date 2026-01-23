# Quickstart: Thumbnail Grid Zoom

**Feature**: 002-thumbnail-zoom
**Created**: 2026-01-23

## Overview

This feature adds zoom in/out controls to the thumbnail grid, allowing users to adjust thumbnail sizes through discrete zoom levels (100pt to 680pt). Zoom can be controlled via toolbar buttons (+/-) or trackpad pinch gestures.

## Key Components

### 1. ZoomLevel Enum/Struct
Location: New file or extend existing settings

```swift
struct ZoomLevel: Identifiable, Equatable {
    let id: Int
    let pointSize: CGFloat
    let displayName: String

    static let all: [ZoomLevel] = [
        ZoomLevel(id: 0, pointSize: 100, displayName: "Dense"),
        ZoomLevel(id: 1, pointSize: 140, displayName: "Comfortable"),
        ZoomLevel(id: 2, pointSize: 220, displayName: "Medium"),       // Default
        ZoomLevel(id: 3, pointSize: 320, displayName: "Large"),
        ZoomLevel(id: 4, pointSize: 420, displayName: "Very Large"),
        ZoomLevel(id: 5, pointSize: 680, displayName: "Preview")
    ]

    static let defaultIndex = 2
}
```

### 2. Grid Zoom State
Location: SlideshowSettings.swift or new GridSettings.swift

```swift
@MainActor
final class GridZoomState: ObservableObject {
    @AppStorage("gridZoomLevelIndex") var currentLevelIndex: Int = ZoomLevel.defaultIndex

    var currentPointSize: CGFloat { ZoomLevel.all[currentLevelIndex].pointSize }
    var canZoomIn: Bool { currentLevelIndex < ZoomLevel.all.count - 1 }
    var canZoomOut: Bool { currentLevelIndex > 0 }

    func zoomIn() { if canZoomIn { currentLevelIndex += 1 } }
    func zoomOut() { if canZoomOut { currentLevelIndex -= 1 } }
}
```

### 3. Toolbar Buttons
Location: ContentView.swift, within `.primaryAction` ToolbarItemGroup

```swift
// Add before rotate button
Button(action: { gridZoomState.zoomOut() }) {
    Image(systemName: "minus")
}
.help("Zoom out")
.disabled(!gridZoomState.canZoomOut || slideshowState.isEmpty)

Button(action: { gridZoomState.zoomIn() }) {
    Image(systemName: "plus")
}
.help("Zoom in")
.disabled(!gridZoomState.canZoomIn || slideshowState.isEmpty)
```

### 4. Animated Layout Updates
Location: MediaGridCollectionView.swift

```swift
func updateZoomLevel(to pointSize: CGFloat, animated: Bool = true) {
    let newSize = NSSize(width: pointSize, height: pointSize)
    guard flowLayout.itemSize != newSize else { return }

    if animated {
        let savedScrollPosition = captureScrollPosition()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            flowLayout.itemSize = newSize
            flowLayout.invalidateLayout()
        } completionHandler: { [weak self] in
            self?.restoreScrollPosition(savedScrollPosition)
        }
    } else {
        flowLayout.itemSize = newSize
        flowLayout.invalidateLayout()
    }
}
```

### 5. Pinch Gesture Handler
Location: MediaCollectionView (NSCollectionView subclass)

```swift
override func magnify(with event: NSEvent) {
    parent?.handleMagnification(event.magnification)
}
```

Location: MediaGridContainerView

```swift
private var magnificationAccumulator: CGFloat = 0
private var debounceWorkItem: DispatchWorkItem?

func handleMagnification(_ delta: CGFloat) {
    magnificationAccumulator += delta
    debounceWorkItem?.cancel()
    debounceWorkItem = DispatchWorkItem { [weak self] in
        self?.snapToNearestZoomLevel()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: debounceWorkItem!)
}

private func snapToNearestZoomLevel() {
    let currentSize = flowLayout.itemSize.width
    let proposedSize = currentSize * (1 + magnificationAccumulator)
    magnificationAccumulator = 0

    let nearest = ZoomLevel.all.min { abs($0.pointSize - proposedSize) < abs($1.pointSize - proposedSize) }
    if let level = nearest {
        gridZoomState.currentLevelIndex = level.id
    }
}
```

## Testing Checklist

- [ ] Click + button increases zoom by one level
- [ ] Click - button decreases zoom by one level
- [ ] Buttons disabled at min/max zoom levels
- [ ] Pinch-out increases zoom level
- [ ] Pinch-in decreases zoom level
- [ ] Zoom persists across app restart
- [ ] Selection state preserved during zoom
- [ ] Scroll position maintained during zoom
- [ ] Drag-and-drop works at all zoom levels
- [ ] No performance degradation with 1000+ items

## Files to Modify

1. **New/Extend**: `ZoomLevel` type definition
2. **Modify**: `SlideshowSettings.swift` or new `GridSettings.swift` - Add GridZoomState
3. **Modify**: `ContentView.swift` - Add toolbar buttons (both macOS 26+ and older)
4. **Modify**: `MediaGridCollectionView.swift` - Add zoom animation, magnify handler
5. **Modify**: `ThumbnailCache.swift` - Optional: extend for 680pt support
6. **Modify**: `MediaThumbnailCellView` - Ensure selection strokes don't scale

## Performance Considerations

- Thumbnail generation remains async via existing ThumbnailCache
- Only visible cells are animated during zoom transitions
- Layout invalidation uses existing NSCollectionViewFlowLayout optimization
- For 680pt zoom, may need to extend ThumbnailCache max size from 350pt to 700pt
