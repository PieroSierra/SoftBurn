# Feature Specification: Photos Library Drag and Drop

**Feature Branch**: `004-photos-library-drag-drop`
**Created**: 2026-02-04
**Status**: Draft
**Input**: User description: "Add support for dragging photos/videos from the Photos Library into the main app, adding them as if they had been selected from the Photos Library Media picker."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Drag Photos from Photos.app (Priority: P1)

A user has the SoftBurn app open alongside the Photos.app. They want to quickly add specific photos to their slideshow by dragging them directly from Photos.app into SoftBurn's main grid or empty state area.

**Why this priority**: This is the core functionality - enabling drag-and-drop from Photos Library is the entire feature request. Without this, there is no feature.

**Independent Test**: Can be fully tested by opening Photos.app side-by-side with SoftBurn and dragging one or more photos into SoftBurn's window. Delivers the value of quick, intuitive media addition without needing the picker dialog.

**Acceptance Scenarios**:

1. **Given** SoftBurn is open with an empty slideshow and Photos.app is visible, **When** user drags a single photo from Photos.app onto SoftBurn's empty state area, **Then** the photo is added to the slideshow and appears in the grid.

2. **Given** SoftBurn has existing photos in the slideshow, **When** user drags multiple photos from Photos.app onto the grid, **Then** all dragged photos are added to the slideshow and appear in the grid.

3. **Given** SoftBurn is open and user drags photos from Photos.app, **When** the drop completes, **Then** the added photos are sourced from Photos Library (not copied to filesystem) and behave identically to photos added via the "From Photos Library..." menu.

---

### User Story 2 - Drag Videos from Photos.app (Priority: P2)

A user wants to include videos from their Photos Library in the slideshow by dragging them from Photos.app into SoftBurn.

**Why this priority**: Videos are a supported media type in SoftBurn and should work the same as photos for drag-and-drop, but photos are more commonly used.

**Independent Test**: Can be tested by dragging a video file from Photos.app into SoftBurn and verifying it appears with a duration badge and plays during slideshow.

**Acceptance Scenarios**:

1. **Given** SoftBurn is open, **When** user drags a video from Photos.app onto SoftBurn, **Then** the video is added to the slideshow, shows a duration badge in the grid, and can be played in the slideshow.

2. **Given** SoftBurn is open, **When** user drags a mix of photos and videos from Photos.app, **Then** both photos and videos are added correctly to the slideshow.

---

### User Story 3 - Authorization Handling (Priority: P3)

When a user attempts to drag from Photos.app but SoftBurn does not yet have Photos Library authorization, the system should handle this gracefully.

**Why this priority**: Authorization is essential for functionality but is a supporting concern - most users will have already granted access via the menu-based picker.

**Independent Test**: Can be tested by resetting Photos authorization for SoftBurn in System Settings, then attempting to drag from Photos.app.

**Acceptance Scenarios**:

1. **Given** SoftBurn has not been granted Photos Library access, **When** user drags photos from Photos.app onto SoftBurn, **Then** the system prompts for authorization (or shows a clear message explaining why access is needed).

2. **Given** user has denied Photos Library access, **When** they attempt to drag from Photos.app, **Then** they see an informative message explaining how to grant access in System Settings.

---

### Edge Cases

- What happens when the user drags unsupported file types from Photos.app (e.g., Live Photos, screenshots with screen recordings)?
  - Only the photo/video portion should be imported; unsupported formats are silently skipped.

- What happens when the user drags a very large number of photos (e.g., 500+)?
  - All photos should be added without UI freezing; thumbnails load progressively as with other import methods.

- What happens when an iCloud-only photo is dragged (not downloaded locally)?
  - The photo should be accepted; iCloud download happens on-demand when displaying the thumbnail or playing the slideshow.

- What happens if the drag data from Photos.app does not contain the expected pasteboard types?
  - The drop should be gracefully rejected with no crash or error message.

- What happens if the user cancels the drag mid-operation?
  - No partial import should occur; the slideshow state remains unchanged.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST accept drag operations from the Photos.app containing photo assets.
- **FR-002**: System MUST accept drag operations from the Photos.app containing video assets.
- **FR-003**: Dropped Photos Library items MUST be added as Photos Library-sourced MediaItems (using localIdentifier), not as filesystem copies.
- **FR-004**: Dropped items MUST appear in the slideshow grid immediately after the drop completes.
- **FR-005**: System MUST handle drops on both the empty state view and the populated photo grid.
- **FR-006**: System MUST mark the session as dirty (unsaved changes) after a successful drop.
- **FR-007**: System MUST trigger face detection prefetch for dropped items (same as menu-based import).
- **FR-008**: System MUST request Photos Library authorization if not already granted when a drop is attempted.
- **FR-009**: System MUST display an informative message when authorization is denied and a drop is attempted.
- **FR-010**: Dropped Photos Library items MUST behave identically to items added via "From Photos Library..." menu option (same rendering, saving, playback behavior).
- **FR-011**: System MUST support dropping multiple items in a single drag operation.
- **FR-012**: System MUST silently skip any dragged items that cannot be resolved to valid PHAssets.

### Key Entities

- **Dropped Photos Library Asset**: A photo or video dragged from Photos.app, represented by its local identifier and media type (photo or video).
- **Pasteboard Data**: The data format used by Photos.app to represent dragged items, containing asset identifiers or promises.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can add photos from Photos.app via drag-and-drop in under 3 seconds (comparable to filesystem drag-and-drop).
- **SC-002**: 100% of photos/videos dragged from Photos.app are successfully added to the slideshow when authorization is granted.
- **SC-003**: Dropped items display thumbnails within 2 seconds of drop completion (on local/cached assets).
- **SC-004**: The drop operation does not block the main UI thread for more than 100ms.
- **SC-005**: Users can complete the drag-and-drop workflow on first attempt without needing instructions.

## Assumptions

- Photos.app provides pasteboard data that includes photo/video asset identifiers in a standard format.
- The existing PhotosLibraryManager and MediaItem infrastructure for Photos Library items can be reused without modification.
- Authorization request prompts are handled by the system (macOS) and not custom UI.
- Face detection prefetch for Photos Library items is already implemented and functional.
