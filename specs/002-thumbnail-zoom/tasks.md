# Tasks: Thumbnail Grid Zoom

**Input**: Design documents from `/specs/002-thumbnail-zoom/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Manual testing only (no XCTest infrastructure in this project)

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3, US4)
- Include exact file paths in descriptions

## Path Conventions

- **Project root**: `SoftBurn/` (native macOS app)
- Paths use the existing project structure from CLAUDE.md

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create foundational types needed by all user stories

- [x] T001 [P] Create ZoomLevel struct with static array of 6 zoom levels (100, 140, 220, 320, 420, 680) in SoftBurn/Models/ZoomLevel.swift
- [x] T002 [P] Add GridZoomState class with @AppStorage persistence and computed properties (canZoomIn, canZoomOut, currentPointSize) in SoftBurn/State/SlideshowSettings.swift

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core state integration that MUST be complete before ANY user story can be implemented

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T003 Add @StateObject gridZoomState property to ContentView and inject into environment in SoftBurn/Views/Main/ContentView.swift
- [x] T004 Wire GridZoomState.currentPointSize to MediaGridCollectionView as a binding or observed property in SoftBurn/Views/Grid/MediaGridCollectionView.swift

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Zoom Using Toolbar Buttons (Priority: P1) 🎯 MVP

**Goal**: Users can zoom in/out using toolbar buttons with animated transitions

**Independent Test**: Click +/- buttons and verify thumbnails resize smoothly through all 6 zoom levels, with persistence across app restart

### Implementation for User Story 1

- [x] T005 [P] [US1] Add zoom out (-) button with SF Symbol "minus" to LiquidGlass toolbar (macOS 26+) in SoftBurn/Views/Main/ContentView.swift, positioned between item counter and rotate button
- [x] T006 [P] [US1] Add Divider() between zoom out and zoom in buttons in LiquidGlass toolbar in SoftBurn/Views/Main/ContentView.swift
- [x] T007 [P] [US1] Add zoom in (+) button with SF Symbol "plus" to LiquidGlass toolbar (macOS 26+) in SoftBurn/Views/Main/ContentView.swift
- [x] T008 [P] [US1] Add zoom out (-) button to legacy toolbar (pre-macOS 26) in SoftBurn/Views/Main/ContentView.swift, same positioning as LiquidGlass
- [x] T009 [P] [US1] Add Divider() between zoom out and zoom in buttons in legacy toolbar in SoftBurn/Views/Main/ContentView.swift
- [x] T010 [P] [US1] Add zoom in (+) button to legacy toolbar (pre-macOS 26) in SoftBurn/Views/Main/ContentView.swift
- [x] T011 [US1] Wire toolbar buttons to GridZoomState.zoomIn() and zoomOut() methods with .disabled() modifiers for min/max bounds in SoftBurn/Views/Main/ContentView.swift
- [x] T012 [US1] Add updateZoomLevel(to:animated:) method to MediaGridContainerView that updates flowLayout.itemSize in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T013 [US1] Implement NSAnimationContext.runAnimationGroup animation wrapper (0.25s duration, easeInEaseOut) in updateZoomLevel in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T014 [US1] Add observer for GridZoomState.currentPointSize changes that calls updateZoomLevel in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T015 [US1] Add .help() accessibility text to zoom buttons ("Zoom in", "Zoom out") in SoftBurn/Views/Main/ContentView.swift

**Checkpoint**: User Story 1 complete - toolbar zoom buttons work with animation and persistence

---

## Phase 4: User Story 2 - Zoom Using Pinch Gesture (Priority: P2)

**Goal**: Users can zoom in/out using trackpad pinch gestures that snap to discrete levels

**Independent Test**: Perform pinch gestures on trackpad and verify grid steps through zoom levels smoothly

### Implementation for User Story 2

- [x] T016 [US2] Override magnify(with:) in MediaCollectionView to forward magnification delta to parent container in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T017 [US2] Add magnificationAccumulator property and debounceWorkItem to MediaGridContainerView in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T018 [US2] Implement handleMagnification(_ delta:) method that accumulates deltas and schedules debounced snap in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T019 [US2] Implement snapToNearestZoomLevel() method that finds nearest ZoomLevel and updates GridZoomState.currentLevelIndex in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T020 [US2] Add threshold check (0.05) to ignore tiny magnification movements in handleMagnification in SoftBurn/Views/Grid/MediaGridCollectionView.swift

**Checkpoint**: User Story 2 complete - pinch gestures snap to discrete zoom levels

---

## Phase 5: User Story 3 - Maintain Context During Zoom (Priority: P2)

**Goal**: Selection state and scroll position are preserved during zoom operations

**Independent Test**: Select items, zoom in/out, verify selection remains visible and scroll position is maintained

### Implementation for User Story 3

- [x] T021 [US3] Add captureScrollPosition() method that records visible item index and offset in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T022 [US3] Add restoreScrollPosition() method that adjusts scroll to keep same item visible after layout change in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T023 [US3] Integrate scroll capture/restore into updateZoomLevel animation completion handler in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T024 [US3] Verify selection layers (outerSelectionLayer, innerSelectionLayer) use fixed stroke widths not scaled by zoom in SoftBurn/Views/Grid/MediaGridCollectionView.swift
- [x] T025 [US3] Add guard in handleMagnification to defer zoom during active drag operations (check isDragging state) in SoftBurn/Views/Grid/MediaGridCollectionView.swift

**Checkpoint**: User Story 3 complete - context preserved during zoom operations

---

## Phase 6: User Story 4 - Large Library Performance (Priority: P3)

**Goal**: Grid remains responsive with 1000+ items at all zoom levels, with progressive thumbnail loading

**Independent Test**: Load 1000+ item slideshow, zoom to all levels, verify 60fps scrolling and <500ms thumbnail loading

### Implementation for User Story 4

- [x] T026 [US4] Extend ThumbnailCache.Key struct to include optional requestedSize parameter in SoftBurn/Caching/ThumbnailCache.swift
- [x] T027 [US4] Add size bucket logic: requestedSize ≤ 350 uses 350pt cache, requestedSize > 350 uses 700pt cache in SoftBurn/Caching/ThumbnailCache.swift
- [x] T028 [US4] Update thumbnail generation to use requestedSize when generating new thumbnails in SoftBurn/Caching/ThumbnailCache.swift
- [x] T029 [US4] Update ThumbnailView to pass current zoom pointSize to ThumbnailCache.thumbnail(for:rotationDegrees:requestedSize:) in SoftBurn/Views/Grid/ThumbnailView.swift
- [x] T030 [US4] Verify placeholder (ProgressView) displays during async thumbnail loading at large zoom levels in SoftBurn/Views/Grid/ThumbnailView.swift

**Checkpoint**: User Story 4 complete - performance optimized for large libraries

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and cleanup

- [ ] T031 [P] Run manual test checklist from quickstart.md (all 10 items)
- [ ] T032 [P] Verify zoom buttons appear correctly on both macOS 26+ and older macOS versions
- [ ] T033 [P] Test persistence: change zoom, quit app, relaunch, verify zoom restored
- [ ] T034 [P] Test edge case: zoom during file load (buttons should be disabled or deferred)
- [ ] T035 Code review for Swift 6 concurrency compatibility (@MainActor, Sendable)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Stories (Phase 3-6)**: All depend on Foundational phase completion
  - US1 (P1): Can proceed first - toolbar buttons
  - US2 (P2): Can start after US1 or in parallel if different developer
  - US3 (P2): Can start after US1 (needs updateZoomLevel method)
  - US4 (P3): Can start after US1 (independent cache work)
- **Polish (Phase 7)**: Depends on desired user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Foundation only - No dependencies on other stories
- **User Story 2 (P2)**: Foundation only - Uses same updateZoomLevel from US1
- **User Story 3 (P2)**: Depends on US1 updateZoomLevel method existing
- **User Story 4 (P3)**: Foundation only - Independent cache extension

### Within Each User Story

- Toolbar buttons (UI) can be parallel [P]
- Animation implementation after UI
- Integration after core implementation

### Parallel Opportunities

- T001, T002 can run in parallel (different files)
- T005-T010 can all run in parallel (same file but independent additions)
- T026-T029 can mostly run in parallel (related but independent functions)
- T031-T034 can all run in parallel (independent validation tests)

---

## Parallel Example: User Story 1

```bash
# Launch all toolbar button tasks together:
Task: "T005 [P] [US1] Add zoom out (-) button to LiquidGlass toolbar"
Task: "T006 [P] [US1] Add Divider() between zoom buttons in LiquidGlass toolbar"
Task: "T007 [P] [US1] Add zoom in (+) button to LiquidGlass toolbar"
Task: "T008 [P] [US1] Add zoom out (-) button to legacy toolbar"
Task: "T009 [P] [US1] Add Divider() between zoom buttons in legacy toolbar"
Task: "T010 [P] [US1] Add zoom in (+) button to legacy toolbar"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T002)
2. Complete Phase 2: Foundational (T003-T004)
3. Complete Phase 3: User Story 1 (T005-T015)
4. **STOP and VALIDATE**: Test toolbar buttons work with animation and persistence
5. Deploy/demo if ready - core zoom feature is functional

### Incremental Delivery

1. Setup + Foundational → Foundation ready (T001-T004)
2. Add User Story 1 → Test independently → Deploy (MVP with toolbar buttons)
3. Add User Story 2 → Test independently → Deploy (adds pinch gesture)
4. Add User Story 3 → Test independently → Deploy (adds context preservation)
5. Add User Story 4 → Test independently → Deploy (optimizes large libraries)

### Parallel Team Strategy

With multiple developers:

1. Team completes Setup + Foundational together
2. Once Foundational is done:
   - Developer A: User Story 1 (toolbar buttons)
   - Developer B: User Story 4 (cache extension - independent)
3. After US1 complete:
   - Developer A: User Story 2 (gestures)
   - Developer B: User Story 3 (context preservation)
4. Stories complete and validate independently

---

## Notes

- [P] tasks = different files or independent additions to same file
- [Story] label maps task to specific user story for traceability
- Manual testing only - no XCTest infrastructure
- Both toolbar variants (legacy + LiquidGlass) must be updated together
- Divider() required between - and + buttons per clarification
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
