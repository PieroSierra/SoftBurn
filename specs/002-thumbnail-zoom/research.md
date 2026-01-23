# Research: Thumbnail Grid Zoom

**Feature**: 002-thumbnail-zoom
**Created**: 2026-01-23

## Research Questions & Findings

### 1. NSCollectionView Animation Patterns

**Decision**: Use NSAnimationContext.runAnimationGroup with layout invalidation

**Rationale**:
- SoftBurn already uses this pattern for drop placeholder animations (lines 472-476 in MediaGridCollectionView.swift)
- Native AppKit approach, works well with NSCollectionViewFlowLayout
- Allows capturing scroll position before animation and restoring after

**Implementation Pattern**:
```swift
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.25
    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    flowLayout.itemSize = newSize
    flowLayout.invalidateLayout()
} completionHandler: {
    self.restoreScrollPosition(savedOffset)
}
```

**Duration Recommendations**:
- Item size changes: 0.25 seconds (responsive without being rushed)
- Cross-fade transitions: 0.15 seconds (subtle background operation)

**Alternatives Considered**:
- CATransaction alone: Not sufficient for coordinated layout changes
- performBatchUpdates: Not available in NSCollectionView (UIKit only)

---

### 2. ThumbnailCache Size Handling

**Decision**: Extend ThumbnailCache to support multiple sizes per image with size-aware cache keys

**Rationale**:
- Current cache is hardcoded to 350pt maximum (ThumbnailCache.swift line 46)
- Cache key currently includes (source, rotation) but NOT size
- 680pt zoom level requires larger thumbnails than current 350pt max

**Implementation Approach**:
1. Extend cache key to include requested size: `(source, rotation, size)`
2. Add optional `requestedSize` parameter to `thumbnail(for:rotationDegrees:)` API
3. Generate thumbnails at requested size (not always 350pt)
4. For memory management: cache only requested sizes (no preemptive generation)

**Size Strategy**:
- Small sizes (100-220pt): Single cached size at 350pt, downscaled by display layer (current behavior)
- Medium sizes (320-420pt): Can reuse 350pt cache, slight upscaling acceptable
- Large size (680pt): Generate new thumbnail at 680pt (requires Retina support: 1360px actual)

**Alternatives Considered**:
- Always generate at 680pt: Wasteful for small zoom levels
- LRU eviction for multiple sizes: Added complexity, defer until memory issues observed

---

### 3. Pinch-to-Zoom Gesture Implementation

**Decision**: Override `magnify(with:)` in MediaCollectionView with debounced snapping

**Rationale**:
- Native macOS trackpad integration (no manual gesture recognizer setup)
- Called automatically by AppKit for pinch events
- Works inside NSScrollView without special configuration
- Similar pattern already used in PhotoViewerSheet.swift for SwiftUI MagnificationGesture

**Implementation Pattern**:
```swift
// In MediaCollectionView
override func magnify(with event: NSEvent) {
    parent?.handleMagnification(event.magnification)
}

// In MediaGridContainerView
private var magnificationAccumulator: CGFloat = 0
private var magnificationDebounceTimer: Timer?

func handleMagnification(_ delta: CGFloat) {
    magnificationAccumulator += delta
    magnificationDebounceTimer?.invalidate()
    magnificationDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
        self.snapToNearestZoomLevel()
    }
}
```

**Snapping Logic**:
- Accumulate magnification deltas over 50ms window
- Ignore tiny movements (threshold: 0.05)
- Snap to nearest discrete zoom level from [100, 140, 220, 320, 420, 680]
- Animate transition with 0.25s duration

**Alternatives Considered**:
- NSMagnificationGestureRecognizer: Requires manual setup, less integrated
- scrollWheel override: Works for scroll zooming but not pinch-to-zoom

---

### 4. Toolbar Button Integration

**Decision**: Add +/- buttons to existing `.primaryAction` ToolbarItemGroup before rotate button

**Rationale**:
- Maintains consistency with existing toolbar patterns
- SF Symbols "plus" and "minus" match other icon-only buttons
- No ControlGroup needed (project doesn't use it currently)
- Same placement strategy for both macOS 26+ and older macOS toolbars

**Exact Insertion Points**:
- **macOS 26+**: ContentView.swift lines 268-308 (`.primaryAction` placement)
- **Older macOS**: ContentView.swift lines 733-776 (HStack with buttons)

**Button Pattern**:
```swift
Button(action: { zoomOut() }) {
    Image(systemName: "minus")
}
.help("Zoom out")
.disabled(slideshowState.isEmpty || isShowingViewer || isAtMinZoom)

Button(action: { zoomIn() }) {
    Image(systemName: "plus")
}
.help("Zoom in")
.disabled(slideshowState.isEmpty || isShowingViewer || isAtMaxZoom)
```

**Alternatives Considered**:
- ControlGroup for visual grouping: Not used elsewhere in project, would break consistency
- Segmented control: Too different from existing button style

---

### 5. Zoom Level Persistence

**Decision**: Use UserDefaults via @AppStorage in SlideshowSettings

**Rationale**:
- SlideshowSettings already manages persistent app preferences (line references in CLAUDE.md)
- @AppStorage pattern used throughout the app for settings
- Global setting (not per-document) as specified in requirements

**Implementation**:
```swift
// In SlideshowSettings or new GridSettings
@AppStorage("gridZoomLevelIndex") var gridZoomLevelIndex: Int = 2  // Default: 220pt (index 2)
```

**Zoom Level Array**:
```swift
static let zoomLevels: [CGFloat] = [100, 140, 220, 320, 420, 680]
```

---

### 6. Selection State Preservation

**Decision**: Selection is UUID-based and independent of cell size—no changes needed

**Rationale**:
- SlideshowState tracks selection as `Set<UUID>` (per CLAUDE.md)
- Selection layers use fixed stroke widths (3pt outer, 2pt inner) not scaled with cell
- NSCollectionView maintains selection state across layout invalidations

**Verification Needed**:
- Confirm marquee selection during zoom changes cancels gracefully
- Test that drag-and-drop state is preserved if zoom occurs mid-drag

---

### 7. Scroll Position Preservation

**Decision**: Capture visible item index before zoom, restore proportional position after animation

**Rationale**:
- NSCollectionView doesn't automatically preserve scroll position on layout invalidation
- Must manually track and restore to maintain user context

**Implementation**:
```swift
// Before zoom
let visibleItems = collectionView.visibleItems()
let topItem = visibleItems.first
let topIndexPath = collectionView.indexPath(for: topItem)
let distanceFromTop = scrollView.contentView.bounds.origin.y - topItem.view.frame.origin.y

// After zoom animation
let newTopItemFrame = collectionView.item(at: topIndexPath).view.frame
let newScrollY = newTopItemFrame.origin.y + distanceFromTop
scrollView.contentView.bounds.origin.y = newScrollY
```

---

## Dependencies Identified

1. **ThumbnailCache.swift** - Extend for multi-size support
2. **MediaGridCollectionView.swift** - Add magnify(with:) override, animation wrapper
3. **ContentView.swift** - Add toolbar buttons (both macOS versions)
4. **SlideshowSettings.swift** (or new GridSettings) - Persist zoom level

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| Memory pressure with large thumbnails | Generate at requested size only, not preemptively |
| Animation jank on old hardware | Use 0.25s duration, leverage existing CATransaction patterns |
| Selection loss during zoom | UUID-based selection is size-independent |
| Scroll position jump | Capture and restore visible item position |
