# Feature Specification: Thumbnail Grid Zoom

**Feature Branch**: `002-thumbnail-zoom`
**Created**: 2026-01-23
**Status**: Draft
**Input**: User description: "Zoom in/out feature for the main thumbnail view with toolbar buttons (- and +) positioned between item counter and rotate/remove/settings/play group. Fixed size stops: 100 (dense), 140 (comfortable), 220-240 (medium), 320-360 (large), 420 (very large), 680 (near-preview). Pinch-to-zoom gesture support. Smooth animated transitions. Local app setting persistence. Must preserve performance, existing thumbnail shape, gripper overlays, multi-select, drag-and-drop, and selection state styling."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Zoom Using Toolbar Buttons (Priority: P1)

A user working with a large media library wants to quickly adjust the thumbnail size to either see more items at once (zoomed out) or examine individual photos more closely (zoomed in). They use the minus and plus buttons in the toolbar to step through predefined zoom levels.

**Why this priority**: This is the primary interaction method and most discoverable. Toolbar buttons provide clear affordance for the feature and work reliably across all input devices.

**Independent Test**: Can be fully tested by clicking the +/- buttons and observing thumbnails resize smoothly through each zoom level. Delivers immediate value by enabling users to customize their viewing density.

**Acceptance Scenarios**:

1. **Given** the grid is displaying at default zoom level (220pt), **When** the user clicks the plus (+) button, **Then** thumbnails animate smoothly to the next larger size (320pt)
2. **Given** the grid is at the smallest zoom level (100pt), **When** the user clicks the minus (-) button, **Then** nothing happens (button appears disabled or no action occurs)
3. **Given** the grid is at the largest zoom level (680pt), **When** the user clicks the plus (+) button, **Then** nothing happens (button appears disabled or no action occurs)
4. **Given** the user has changed zoom level during the session, **When** they quit and relaunch the app, **Then** the grid displays at their previously selected zoom level

---

### User Story 2 - Zoom Using Pinch Gesture (Priority: P2)

A user with a trackpad wants to zoom the thumbnail grid using the familiar pinch-to-zoom gesture. Pinching in decreases thumbnail size; pinching out increases it. The gesture snaps to the nearest predefined zoom level.

**Why this priority**: Provides a natural, gesture-based alternative to toolbar buttons that trackpad users expect. Secondary because it requires trackpad hardware and is less discoverable than buttons.

**Independent Test**: Can be tested by performing pinch gestures on a trackpad and confirming the grid responds by stepping through zoom levels smoothly.

**Acceptance Scenarios**:

1. **Given** the grid is at medium zoom (220pt), **When** the user performs a pinch-out gesture, **Then** thumbnails animate to the next larger size (320pt)
2. **Given** the grid is at medium zoom (220pt), **When** the user performs a pinch-in gesture, **Then** thumbnails animate to the next smaller size (140pt)
3. **Given** the user pinches out past the largest zoom level, **When** the gesture ends, **Then** the grid remains at the maximum zoom level (680pt) without over-scrolling
4. **Given** the user performs a rapid large pinch gesture, **When** the gesture ends, **Then** the grid steps through multiple zoom levels smoothly (not jumping abruptly)

---

### User Story 3 - Maintain Context During Zoom (Priority: P2)

A user has selected several photos and wants to zoom in to see them more clearly while maintaining their selection. The zoom operation should keep selected items visible and preserve selection state visually.

**Why this priority**: Critical for usability—losing selection or scroll position during zoom would be frustrating and require users to redo their work.

**Independent Test**: Can be tested by selecting items, zooming in/out, and confirming all selected items remain selected with proper visual indication.

**Acceptance Scenarios**:

1. **Given** 5 photos are selected in the grid, **When** the user changes zoom level, **Then** all 5 photos remain selected with blue/white selection borders visible
2. **Given** the user is viewing items in the middle of a long list, **When** they zoom in, **Then** the same general region remains visible (scroll position adjusts proportionally)
3. **Given** the user has a marquee drag selection in progress, **When** zoom changes, **Then** the selection operation completes or cancels gracefully without errors

---

### User Story 4 - Large Library Performance (Priority: P3)

A user with thousands of photos in their slideshow zooms in to the largest size (680pt). The grid should remain responsive and scroll smoothly, loading larger thumbnails progressively without blocking the interface.

**Why this priority**: Performance is essential for professional use, but most users won't have extremely large libraries. Core functionality takes precedence.

**Independent Test**: Can be tested by loading 1000+ items and zooming through all levels while monitoring scrolling smoothness and memory usage.

**Acceptance Scenarios**:

1. **Given** a slideshow with 1000 photos at small zoom (100pt), **When** the user scrolls through the list, **Then** scrolling remains smooth (no visible stutter)
2. **Given** the user zooms from 100pt to 680pt, **When** new larger thumbnails are needed, **Then** placeholders display immediately while thumbnails load asynchronously
3. **Given** limited system memory, **When** the user zooms to large sizes, **Then** the app remains responsive (thumbnails may show lower resolution rather than blocking)

---

### Edge Cases

- What happens when the user zooms while a slideshow file is being opened? Grid should accept zoom changes after load completes; during load, buttons may be disabled.
- How does the system handle zoom during an active drag-and-drop reorder? The drag operation should complete at the current zoom level; zoom is deferred until drop completes.
- What happens if window becomes very narrow at large zoom levels? Grid shows as few as 1 column; horizontal scrolling is not introduced.
- How does zoom interact with "Open Recent" file switching? Zoom level persists globally, not per-document.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST provide zoom in (+) and zoom out (-) buttons in the toolbar, positioned between the item counter and the rotate/remove/settings/play button group, with a visual divider (Divider()) between the minus and plus icons
- **FR-001a**: System MUST implement zoom buttons in both toolbar variants: the legacy toolbar (pre-macOS 26) and the LiquidGlass toolbar (macOS 26 Tahoe and later)
- **FR-002**: System MUST support exactly six discrete zoom levels: 100pt (dense grid), 140pt (comfortable grid), 220pt (medium - default), 320pt (large), 420pt (very large), 680pt (near-preview tiles)
- **FR-003**: System MUST use SF Symbols "minus" icon for zoom out and "plus" icon for zoom in
- **FR-004**: System MUST disable (visually indicate) the minus button at minimum zoom (100pt) and plus button at maximum zoom (680pt)
- **FR-005**: System MUST animate transitions between zoom levels using a cross-fade effect
- **FR-006**: System MUST respond to trackpad pinch gestures by stepping through zoom levels (pinch-in decreases, pinch-out increases)
- **FR-007**: System MUST snap to the nearest discrete zoom level when a pinch gesture ends (no arbitrary intermediate sizes)
- **FR-008**: System MUST persist the current zoom level as a local application preference (not per-document)
- **FR-009**: System MUST restore the persisted zoom level when the application launches
- **FR-010**: System MUST preserve multi-select functionality (keyboard modifiers, marquee drag selection) at all zoom levels
- **FR-011**: System MUST preserve drag-and-drop reorder functionality at all zoom levels, using current-size thumbnails for drag preview
- **FR-012**: System MUST maintain selection state (blue outer rectangle with white inner rectangle) at all zoom levels with consistent stroke widths (not scaled)
- **FR-013**: System MUST preserve the square thumbnail shape with clipped corners at all zoom levels
- **FR-014**: System MUST preserve gripper overlay icons on thumbnails at all zoom levels
- **FR-015**: System MUST generate thumbnails asynchronously without blocking scrolling or UI interaction
- **FR-016**: System MUST display placeholder content while larger thumbnails are loading asynchronously
- **FR-017**: System MUST NOT degrade scrolling performance regardless of library size or zoom level

### Key Entities

- **ZoomLevel**: Enumeration of the six discrete thumbnail sizes (100, 140, 220, 320, 420, 680 points) with associated display names
- **ThumbnailGridSettings**: Application-level preferences object storing the current zoom level (persisted via UserDefaults)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can navigate through all six zoom levels using toolbar buttons with each click producing exactly one level change
- **SC-002**: Zoom level transitions complete within 300ms with visible smooth animation (no jarring jumps)
- **SC-003**: Pinch gestures are recognized and result in zoom level changes within 200ms of gesture end
- **SC-004**: Zoom preference persists across application restarts with 100% reliability
- **SC-005**: Grid maintains 60fps scrolling performance at all zoom levels with libraries of 1000+ items
- **SC-006**: Selection state remains intact through zoom operations (0% selection loss)
- **SC-007**: Drag-and-drop operations complete successfully at all zoom levels without errors
- **SC-008**: Larger thumbnails begin appearing within 500ms of zoom increase (progressive loading)

## Clarifications

### Session 2026-01-23

- Q: Should zoom buttons work in both toolbar variants (legacy and LiquidGlass)? → A: Yes, both toolbar variants must include the zoom buttons
- Q: Is there a visual separator between the - and + buttons? → A: Yes, a Divider() should appear between the minus and plus icons

## Assumptions

- The existing thumbnail cache can accommodate multiple sizes per image, or will be extended to do so
- The current 350pt maximum thumbnail size in the cache will need to increase to support 680pt zoom level
- SF Symbols "plus" and "minus" are available in the deployment target macOS version
- The NSCollectionView layout system supports animated size changes via flow layout invalidation
- Cross-fade animation can be achieved through layer opacity transitions during layout animation
