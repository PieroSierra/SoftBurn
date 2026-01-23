# Implementation Plan: Thumbnail Grid Zoom

**Branch**: `002-thumbnail-zoom` | **Date**: 2026-01-23 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/002-thumbnail-zoom/spec.md`

## Summary

Add zoom in/out functionality to the thumbnail grid view with discrete zoom levels (100pt to 680pt), toolbar button controls (+/-), trackpad pinch gesture support, animated transitions, and persistent zoom preference storage.

## Technical Context

**Language/Version**: Swift 5.9+ with strict concurrency (Swift 6 compatible)
**Primary Dependencies**: SwiftUI, AppKit, Foundation (all built-in macOS frameworks)
**Storage**: UserDefaults via @AppStorage
**Testing**: Manual testing (no XCTest infrastructure in current project)
**Target Platform**: macOS 14+ (Sonoma), with macOS 26 (Tahoe) LiquidGlass enhancements
**Project Type**: Native macOS desktop application
**Performance Goals**: 60fps scrolling at all zoom levels with 1000+ items
**Constraints**: Zoom transitions ≤300ms, thumbnail loading ≤500ms
**Scale/Scope**: Single feature addition affecting 4-5 source files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution file contains template placeholders only (no project-specific principles defined). No gates to evaluate. Proceeding with implementation planning.

## Project Structure

### Documentation (this feature)

```text
specs/002-thumbnail-zoom/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: Technical research findings
├── data-model.md        # Phase 1: Entity definitions
├── quickstart.md        # Phase 1: Implementation guide
├── contracts/           # Phase 1: API contracts
│   └── api.md           # Swift protocol definitions
├── checklists/          # Validation checklists
│   └── requirements.md  # Spec quality validation
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
SoftBurn/
├── State/
│   └── SlideshowSettings.swift    # Extend with GridZoomState
├── Views/
│   ├── Main/
│   │   └── ContentView.swift      # Add toolbar zoom buttons
│   └── Grid/
│       └── MediaGridCollectionView.swift  # Add zoom animation + gesture
├── Caching/
│   └── ThumbnailCache.swift       # Optional: extend for 680pt support
└── Models/
    └── ZoomLevel.swift            # New: ZoomLevel type definition
```

**Structure Decision**: Single project structure. Feature adds new model type (ZoomLevel) and extends existing files. No new directories needed.

## Complexity Tracking

> No constitution violations requiring justification.

## Phase 0: Research Summary

Research completed and documented in [research.md](research.md). Key decisions:

| Topic | Decision | Rationale |
|-------|----------|-----------|
| Animation | NSAnimationContext.runAnimationGroup | Existing pattern in codebase |
| Gesture | Override magnify(with:) in NSCollectionView | Native AppKit integration |
| Persistence | @AppStorage("gridZoomLevelIndex") | Consistent with existing settings |
| Cache | Extend key with optional size parameter | Supports 680pt without cache explosion |
| Scroll | Capture/restore visible item position | Maintains user context |

## Phase 1: Design Summary

### Data Model

Defined in [data-model.md](data-model.md):

- **ZoomLevel**: Static enumeration of 6 discrete sizes (100, 140, 220, 320, 420, 680 points)
- **GridZoomState**: Observable state with currentLevelIndex, canZoomIn/Out, zoomIn/Out methods
- **ThumbnailCacheKey** (extended): Adds optional requestedSize for multi-size caching

### API Contracts

Defined in [contracts/api.md](contracts/api.md):

- GridZoomStateProtocol: Observable zoom state interface
- MediaGridCollectionView extensions: updateZoomLevel, handleMagnification
- ThumbnailCache extension: thumbnail(for:rotationDegrees:requestedSize:)
- Toolbar contract: Button placement and behavior requirements

### Quickstart

Implementation guide in [quickstart.md](quickstart.md) with code snippets for each component.

## Implementation Phases

### Phase A: Foundation (P1 - Toolbar Buttons)
1. Create ZoomLevel type definition
2. Add GridZoomState with persistence
3. Add +/- toolbar buttons to ContentView
4. Wire buttons to state (no animation yet)

### Phase B: Grid Animation (P1 - Toolbar Buttons)
5. Add updateZoomLevel method to MediaGridCollectionView
6. Implement animated layout invalidation
7. Add scroll position preservation
8. Connect GridZoomState changes to grid updates

### Phase C: Pinch Gesture (P2)
9. Override magnify(with:) in MediaCollectionView
10. Add debounced accumulation in container
11. Implement snapToNearestZoomLevel logic
12. Test gesture interaction with scroll

### Phase D: Large Thumbnails (P3 - Optional)
13. Extend ThumbnailCache for 680pt support
14. Add size parameter to cache key
15. Update cache generation logic
16. Test memory usage at large sizes

## Files to Modify

| File | Changes | Priority |
|------|---------|----------|
| `Models/ZoomLevel.swift` | New file: ZoomLevel struct | P1 |
| `State/SlideshowSettings.swift` | Add GridZoomState class | P1 |
| `Views/Main/ContentView.swift` | Add zoom toolbar buttons (both macOS versions) | P1 |
| `Views/Grid/MediaGridCollectionView.swift` | Add zoom animation, gesture handler | P1/P2 |
| `Caching/ThumbnailCache.swift` | Optional: extend for 680pt | P3 |

## Success Verification

Per spec Success Criteria:

- [ ] SC-001: Navigate all 6 zoom levels via buttons
- [ ] SC-002: Transitions ≤300ms with smooth animation
- [ ] SC-003: Pinch gestures respond within 200ms
- [ ] SC-004: Zoom persists across app restart
- [ ] SC-005: 60fps scrolling with 1000+ items
- [ ] SC-006: Selection preserved through zoom
- [ ] SC-007: Drag-and-drop works at all levels
- [ ] SC-008: Thumbnails appear within 500ms of zoom
