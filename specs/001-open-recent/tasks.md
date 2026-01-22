# Tasks: Open Recent

**Input**: Design documents from `/specs/001-open-recent/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

**Tests**: Not requested in feature specification.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **macOS app**: `SoftBurn/` at repository root
- All paths are relative to repository root

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create core model and state management that all user stories depend on

- [X] T001 [P] Create RecentSlideshow model in SoftBurn/Models/RecentSlideshow.swift
- [X] T002 [P] Create RecentSlideshowsManager singleton in SoftBurn/State/RecentSlideshowsManager.swift
- [X] T003 Add notification extensions (.openRecentSlideshow, .clearRecentList) in SoftBurn/App/SoftBurnApp.swift

**Checkpoint**: Core data model and state management ready - user story implementation can begin

---

## Phase 2: User Story 1 - Quick Access to Recent Slideshow (Priority: P1) 🎯 MVP

**Goal**: User can access recently opened slideshows via File menu and open them with a single click

**Independent Test**: Open several slideshows, quit app, relaunch, verify recent items appear in File menu and work correctly

### Implementation for User Story 1

- [X] T004 [US1] Add "Open Recent" submenu to File menu CommandGroup in SoftBurn/App/SoftBurnApp.swift
- [X] T005 [US1] Add @ObservedObject recentsManager property to ContentView in SoftBurn/Views/Main/ContentView.swift
- [X] T006 [US1] Add notification handler for .openRecentSlideshow in SoftBurn/Views/Main/ContentView.swift
- [X] T007 [US1] Add notification handler for .clearRecentList in SoftBurn/Views/Main/ContentView.swift
- [X] T008 [US1] Create openRecentSlideshow(url:) helper function in SoftBurn/Views/Main/ContentView.swift
- [X] T009 [US1] Update loadSlideshow(from:) to call RecentSlideshowsManager.shared.addOrUpdate(url:) in SoftBurn/Views/Main/ContentView.swift
- [X] T010 [US1] Add missing file alert handling to openRecentSlideshow(url:) in SoftBurn/Views/Main/ContentView.swift

**Checkpoint**: File menu "Open Recent" fully functional - can open recent slideshows, list persists across restarts

---

## Phase 3: User Story 2 - Access from Toolbar (Priority: P2)

**Goal**: User can access recent slideshows from both legacy and LiquidGlass toolbar variants

**Independent Test**: Verify "Open Recent" button appears in both toolbar variants and displays same submenu as File menu

### Implementation for User Story 2

- [X] T011 [P] [US2] Add "Open Recent" submenu to legacy toolbar File menu in SoftBurn/Views/Main/ContentView.swift (lines 587-633 area)
- [X] T012 [P] [US2] Add "Open Recent" submenu to LiquidGlass toolbar navigation placement in SoftBurn/Views/Main/ContentView.swift (lines 150-194 area)

**Checkpoint**: All three access points (File menu, legacy toolbar, LiquidGlass toolbar) display identical recent lists

---

## Phase 4: User Story 3 - Clear Recent History (Priority: P3)

**Goal**: User can clear their recent slideshow history for privacy or organization

**Independent Test**: Populate recent list, click "Clear List", verify list is empty and "Clear List" is disabled

### Implementation for User Story 3

- [X] T013 [US3] Verify "Clear List" button works correctly in File menu (already added in T004)
- [X] T014 [US3] Verify "Clear List" button works correctly in legacy toolbar submenu (already added in T011)
- [X] T015 [US3] Verify "Clear List" button works correctly in LiquidGlass toolbar submenu (already added in T012)
- [X] T016 [US3] Verify "Clear List" is disabled when list is empty in all three menus

**Checkpoint**: Clear List functionality works across all access points

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and edge case handling

- [X] T017 Build project with Debug configuration to verify no compile errors
- [ ] T018 Verify persistence works across app restart (open 3 slideshows, quit, relaunch)
- [ ] T019 Verify deduplication works (open same slideshow twice, verify it moves to top without duplicates)
- [ ] T020 Verify max 5 items enforced (open 6 slideshows, verify only 5 most recent shown)
- [ ] T021 Verify missing file handling (move a .softburn file, verify menu item disabled)
- [ ] T022 Run quickstart.md testing checklist validation

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **User Story 1 (Phase 2)**: Depends on Setup (T001-T003)
- **User Story 2 (Phase 3)**: Depends on Setup (T001-T003), can run parallel to US1
- **User Story 3 (Phase 4)**: Depends on US1 and US2 completion (verifies their "Clear List" buttons)
- **Polish (Phase 5)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Setup - No dependencies on other stories
- **User Story 2 (P2)**: Can start after Setup - No dependencies on US1 (uses same manager singleton)
- **User Story 3 (P3)**: Depends on US1 and US2 - Verifies functionality added in those stories

### Within Each User Story

- T001-T003 must complete before any user story implementation
- US1: T004 → T005 → T006/T007 (parallel) → T008 → T009 → T010
- US2: T011 and T012 can run in parallel (different toolbar sections)
- US3: T013-T016 are verification tasks, can run after US1/US2 complete

### Parallel Opportunities

**Setup Phase (can run in parallel):**
- T001 (model) and T002 (manager) touch different files

**User Story 2 (can run in parallel):**
- T011 (legacy toolbar) and T012 (LiquidGlass toolbar) modify different sections of ContentView.swift but are independent enough to merge

---

## Parallel Example: Setup Phase

```bash
# Launch model and manager creation in parallel:
Task: "Create RecentSlideshow model in SoftBurn/Models/RecentSlideshow.swift"
Task: "Create RecentSlideshowsManager singleton in SoftBurn/State/RecentSlideshowsManager.swift"
```

## Parallel Example: User Story 2

```bash
# Launch both toolbar implementations in parallel:
Task: "Add Open Recent submenu to legacy toolbar in SoftBurn/Views/Main/ContentView.swift"
Task: "Add Open Recent submenu to LiquidGlass toolbar in SoftBurn/Views/Main/ContentView.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T003)
2. Complete Phase 2: User Story 1 (T004-T010)
3. **STOP and VALIDATE**: Test File menu "Open Recent" independently
4. If satisfactory, this is a shippable MVP

### Incremental Delivery

1. Complete Setup → Core infrastructure ready
2. Add User Story 1 → File menu works → MVP!
3. Add User Story 2 → Toolbar access works → Enhanced UX
4. Add User Story 3 → Clear List verified → Full feature
5. Polish → All edge cases validated

### Suggested MVP Scope

**User Story 1 only** provides full core value:
- Recent slideshows accessible via File menu
- List persists across restarts
- Files can be opened with a click
- Missing files handled gracefully

User Stories 2-3 are enhancements that can ship in follow-up releases.

---

## Summary

| Phase | Story | Task Count | Parallel Opportunities |
|-------|-------|------------|----------------------|
| Setup | - | 3 | T001, T002 |
| US1 | P1 (MVP) | 7 | T006, T007 |
| US2 | P2 | 2 | T011, T012 |
| US3 | P3 | 4 | T013-T016 |
| Polish | - | 6 | - |
| **Total** | | **22** | |

---

## Notes

- [P] tasks = different files, no dependencies
- [Story] label maps task to specific user story for traceability
- Each user story can be independently completed and tested
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Build frequently to catch compile errors early
