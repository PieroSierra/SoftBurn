# Tasks: Wes Color Palettes

**Input**: Design documents from `/specs/003-wes-color-palettes/`
**Prerequisites**: plan.md (required), spec.md (required), research.md, data-model.md, quickstart.md

**Tests**: No automated tests - manual visual testing only (per project tech stack).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

All paths are relative to repository root. This project uses a single macOS app structure:

```text
SoftBurn/
├── Models/SlideshowDocument.swift
├── Rendering/
│   ├── MetalSlideshowRenderer.swift
│   └── Shaders/SlideshowShaders.metal
└── Views/Settings/SettingsPopoverView.swift
```

---

## Phase 1: Setup (No Changes Required)

**Purpose**: Project initialization and basic structure

This feature extends existing infrastructure. No setup tasks required - all dependencies (Metal, SwiftUI, AppKit) are already configured.

**Checkpoint**: Setup complete - proceed to Foundational phase

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure that MUST be complete before user stories can be implemented

**⚠️ CRITICAL**: Shader helper functions must exist before palette-specific grading can be implemented

- [x] T001 Add RGB-to-Hue helper function `rgbToHue()` in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`
- [x] T002 Add skin tone protection function `skinToneProtection()` in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`
- [x] T003 [P] Add contrast adjustment function `adjustContrast()` in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`
- [x] T004 [P] Add saturation adjustment function `adjustSaturation()` in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Apply Cinematic Color Palette (Priority: P1) 🎯 MVP

**Goal**: Users can select any of the three color palettes from the Color menu to transform their photos with cinematic color grading.

**Independent Test**: Select each palette from the Color menu and verify photos display with expected color characteristics. Test with photos containing people to verify skin tone preservation.

### Implementation for User Story 1

#### Enum & Mode Mapping (Sequential - both files depend on same enum)

- [x] T005 [US1] Add `.budapestRose`, `.fantasticMrYellow`, `.darjeelingMint` cases to `PostProcessingEffect` enum in `SoftBurn/Models/SlideshowDocument.swift`
- [x] T006 [US1] Add `displayName` computed property cases for new palettes in `SoftBurn/Models/SlideshowDocument.swift`
- [x] T007 [US1] Add effect mode mapping (4, 5, 6) in `effectMode` switch statement in `SoftBurn/Rendering/MetalSlideshowRenderer.swift`

#### Shader Implementation (Parallel - separate functions)

- [x] T008 [P] [US1] Implement `applyBudapestRose()` palette function with rose midtones, purple shadows, 75% saturation, -10% contrast in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`
- [x] T009 [P] [US1] Implement `applyFantasticMrYellow()` palette function with yellow dominant, fox-red bias, green de-emphasis in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`
- [x] T010 [P] [US1] Implement `applyDarjeelingMint()` palette function with mint pulls, railway blue, warm shadows, S-curve contrast in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`

#### Shader Integration

- [x] T011 [US1] Add cases 4, 5, 6 to `applyEffect()` switch statement to dispatch to palette functions in `SoftBurn/Rendering/Shaders/SlideshowShaders.metal`

**Checkpoint**: User Story 1 complete - all three palettes selectable from Color menu, render with expected characteristics, preserve skin tones

---

## Phase 4: User Story 2 - Combine Palette with Matching Background (Priority: P2)

**Goal**: Users can select matching background colors that complement each palette's aesthetic.

**Independent Test**: Select each new background swatch and verify it displays the correct color during slideshow transitions.

### Implementation for User Story 2

- [x] T012 [US2] Add "Warm Cream" preset color (RGB 221,214,144) to `presetColors` array in `SoftBurn/Views/Settings/SettingsPopoverView.swift`
- [x] T013 [P] [US2] Add "Paper Cream" preset color (RGB 242,223,208) to `presetColors` array in `SoftBurn/Views/Settings/SettingsPopoverView.swift`
- [x] T014 [P] [US2] Add "Dusty Gold" preset color (RGB 209,156,47) to `presetColors` array in `SoftBurn/Views/Settings/SettingsPopoverView.swift`

**Checkpoint**: User Story 2 complete - all three background swatches available in picker, display correct colors

---

## Phase 5: User Story 3 - Switch Between Palettes and Effects (Priority: P3)

**Goal**: Users can seamlessly switch between Wes palettes and existing color effects without visual artifacts.

**Independent Test**: Cycle through all 7 color options (None, Monochrome, Silvertone, Sepia, Budapest Rose, Fantastic Mr Yellow, Darjeeling Mint) and verify each applies cleanly without remnants from previous selection.

### Implementation for User Story 3

No additional implementation required. This functionality is inherently provided by:
- The enum-based effect selection (only one case active at a time)
- The `applyEffect()` switch statement (mutually exclusive execution paths)
- The Metal pipeline's per-frame rendering (no state persistence between frames)

**Verification only**: Confirm existing architecture handles effect switching correctly.

- [ ] T015 [US3] Verify palette-to-palette switching works without artifacts (manual test)
- [ ] T016 [US3] Verify palette-to-legacy-effect switching works without artifacts (manual test)
- [ ] T017 [US3] Verify legacy-effect-to-palette switching works without artifacts (manual test)

**Checkpoint**: User Story 3 complete - all effect switching works seamlessly

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories

- [ ] T018 Verify palettes work correctly with photos (manual test with variety of images)
- [ ] T019 Verify palettes work correctly with video frames (manual test with video slideshow)
- [ ] T020 [P] Verify palettes stack correctly with 35mm patina effect (manual test)
- [ ] T021 [P] Verify palettes stack correctly with Aged Film patina effect (manual test)
- [ ] T022 [P] Verify palettes stack correctly with VHS patina effect (manual test)
- [ ] T023 Verify settings persist after app restart (save, quit, reopen)
- [ ] T024 [P] Verify .softburn files save new palette values correctly
- [x] T025 Build release configuration and verify no shader compilation errors

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No changes needed - proceed immediately
- **Foundational (Phase 2)**: No dependencies - helper functions can be added first
- **User Story 1 (Phase 3)**: Depends on Foundational (T001-T004) - shader helpers must exist
- **User Story 2 (Phase 4)**: No dependencies on other stories - can run in parallel with US1
- **User Story 3 (Phase 5)**: Depends on US1 completion - needs palettes to exist for testing
- **Polish (Phase 6)**: Depends on US1 completion - needs palettes for cross-cutting validation

### User Story Dependencies

- **User Story 1 (P1)**: Requires Foundational phase - Core feature, must complete first for MVP
- **User Story 2 (P2)**: Independent - Can be implemented in parallel with US1 (different file)
- **User Story 3 (P3)**: Requires US1 - Needs palettes to exist for effect switching tests

### Within Each User Story

- Enum cases before mode mapping (same enum reference)
- Mode mapping before shader dispatch (shader reads mode from renderer)
- Helper functions before palette functions (palette functions call helpers)
- Palette functions before switch dispatch (dispatch calls palette functions)

### Parallel Opportunities

**Phase 2 (Foundational)**:
- T003 and T004 can run in parallel (separate helper functions)

**Phase 3 (User Story 1)**:
- T008, T009, T010 can run in parallel (separate palette functions in same file)

**Phase 4 (User Story 2)**:
- T012, T013, T014 can run in parallel (separate array entries, but same array - recommend sequential for clarity)

**Phase 6 (Polish)**:
- T020, T021, T022 can run in parallel (independent patina tests)
- T024 can run in parallel with T023 (different test scenarios)

---

## Parallel Example: User Story 1 Shader Functions

```bash
# After T007 (mode mapping) completes, launch all palette functions together:
Task: "Implement applyBudapestRose() in SlideshowShaders.metal"
Task: "Implement applyFantasticMrYellow() in SlideshowShaders.metal"
Task: "Implement applyDarjeelingMint() in SlideshowShaders.metal"

# These are separate functions in the same file - no conflicts
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational (T001-T004) - shader helpers
2. Complete Phase 3: User Story 1 (T005-T011) - palette implementation
3. **STOP and VALIDATE**: Test all three palettes with photos
4. Verify skin tone preservation
5. Deploy/demo if ready - core feature complete

### Incremental Delivery

1. Foundational → helpers ready
2. Add User Story 1 → Test palettes → **MVP Complete**
3. Add User Story 2 → Test backgrounds → Enhanced version
4. Add User Story 3 → Test switching → Full validation
5. Polish → Cross-cutting verification → Release ready

### Recommended Execution Order

For a single developer:

```
T001 → T002 → T003 → T004                    # Foundational (can parallelize T003+T004)
T005 → T006 → T007                            # Enum & mapping (sequential)
T008 → T009 → T010 → T011                    # Shader palettes (can parallelize T008+T009+T010)
T012 → T013 → T014                            # Background presets
T015 → T016 → T017                            # Effect switching verification
T018 → T019 → T020 → T021 → T022 → T023 → T024 → T025  # Polish
```

---

## Notes

- All tasks modify existing files - no new files created
- Shader changes in Metal require Xcode build to verify compilation
- Manual visual testing is the primary validation method
- Skin tone preservation is critical for US1 acceptance
- Background colors must match exact RGB values from spec
- Effect switching should be instantaneous with no artifacts
