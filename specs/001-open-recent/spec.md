# Feature Specification: Open Recent

**Feature Branch**: `001-open-recent`
**Created**: 2026-01-21
**Status**: Draft
**Input**: User description: "Add Open Recent menu with last five slideshows to File Menu and toolbars"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Quick Access to Recent Slideshow (Priority: P1)

A user who frequently works on the same slideshows wants to quickly reopen a recently edited project without navigating through the file system.

**Why this priority**: This is the core value proposition - reducing friction when accessing recent work. Users expect this standard macOS behavior.

**Independent Test**: Can be fully tested by opening several slideshows, closing the app, reopening, and verifying recent items appear and work.

**Acceptance Scenarios**:

1. **Given** user has opened 3 slideshows in previous sessions, **When** user clicks "Open Recent" in File menu, **Then** those 3 slideshows appear in chronological order (most recent first)
2. **Given** user clicks on a recent slideshow entry, **When** the file still exists at that location, **Then** the slideshow opens immediately
3. **Given** user opens a slideshow, **When** user checks "Open Recent" menu, **Then** that slideshow appears at the top of the list

---

### User Story 2 - Access from Toolbar (Priority: P2)

A user who primarily uses the toolbar wants the same quick access to recent slideshows without navigating to the menu bar.

**Why this priority**: Extends P1 functionality to toolbar users for consistent UX across both legacy and LiquidGlass toolbar styles.

**Independent Test**: Can be tested by verifying the Open Recent button appears in both toolbar variants and displays the same submenu as File menu.

**Acceptance Scenarios**:

1. **Given** user is using legacy toolbar, **When** user clicks the Open Recent button (clock icon), **Then** submenu displays same recent slideshows as File menu
2. **Given** user is using LiquidGlass toolbar (macOS 26+), **When** user clicks the Open Recent button (clock icon), **Then** submenu displays same recent slideshows as File menu
3. **Given** user opens a slideshow via toolbar, **When** that slideshow is added to recents, **Then** both File menu and toolbar show the updated list

---

### User Story 3 - Clear Recent History (Priority: P3)

A user wants to clear their recent slideshow history for privacy or organization reasons.

**Why this priority**: Secondary feature that provides user control over stored data.

**Independent Test**: Can be tested by populating recent list, clicking "Clear List", and verifying the list is empty.

**Acceptance Scenarios**:

1. **Given** user has items in the recent list, **When** user clicks "Clear List", **Then** all recent slideshow entries are removed
2. **Given** user clears the list, **When** user checks "Open Recent" again, **Then** no slideshow entries appear (only "Clear List" remains, possibly disabled)

---

### Edge Cases

- What happens when a recent slideshow file has been moved or deleted?
  - Display the filename with visual indication it's unavailable; show error message on click attempt
- What happens when user opens more than 5 slideshows?
  - Only the 5 most recent are retained; oldest entry is removed
- What happens when the same slideshow is opened multiple times?
  - Move it to the top of the list (no duplicates)
- What happens on first launch with no history?
  - "Open Recent" submenu shows only "Clear List" (disabled state)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display "Open Recent" menu item in File menu with clock icon
- **FR-002**: System MUST display "Open Recent" button in legacy toolbar File section with clock icon
- **FR-003**: System MUST display "Open Recent" button in LiquidGlass toolbar File section with clock icon
- **FR-004**: System MUST show submenu containing up to 5 most recently opened slideshows
- **FR-005**: System MUST order recent slideshows by last opened time (most recent first)
- **FR-006**: System MUST persist recent slideshow list across app restarts
- **FR-007**: System MUST display slideshow filename as the menu item label
- **FR-008**: System MUST include a divider between slideshow entries and "Clear List"
- **FR-009**: System MUST include "Clear List" action at bottom of submenu (no icon)
- **FR-010**: System MUST remove all entries when "Clear List" is activated
- **FR-011**: System MUST update the recent list when any slideshow is opened (via any method)
- **FR-012**: System MUST prevent duplicate entries (reopening moves to top)
- **FR-013**: System MUST handle missing files gracefully with user feedback

### Key Entities

- **Recent Slideshow Entry**: File path, filename (display), last opened timestamp
- **Recent List**: Ordered collection of up to 5 Recent Slideshow Entries

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can open a recent slideshow in under 3 seconds (2 clicks maximum)
- **SC-002**: Recent list persists correctly across 100% of app restart cycles
- **SC-003**: All three access points (File menu, legacy toolbar, LiquidGlass toolbar) display identical recent lists
- **SC-004**: 100% of valid recent file selections successfully open the slideshow
- **SC-005**: Clear List action removes all entries in a single interaction

## Assumptions

- The clock icon ("clock" SF Symbol) is appropriate and available in the app's icon set
- App Storage (UserDefaults) provides sufficient persistence for this feature
- Maximum of 5 recent items is appropriate for this use case (standard macOS convention)
- Slideshow files are identified by their file path
- "Clear List" should be disabled (greyed out) when list is empty rather than hidden
