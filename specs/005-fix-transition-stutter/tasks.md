# Tasks: Fix Transition Boundary Stutter

**Input**: Design documents from `/specs/005-fix-transition-stutter/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: Visual inspection only (GPU rendering pipeline, no unit test framework). Build verification at checkpoints.

**Organization**: Tasks are grouped by user story. All changes are within `SlideshowPlayerView.swift` in the `SlideshowPlayerState` class.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single macOS app**: `SoftBurn/` at repository root (Xcode project structure)

---

## Phase 1: Foundational (Extract New Methods)

**Purpose**: Create the two new methods that replace the monolithic `advanceSlide()`. These are prerequisites for the timer model change.

- [x] T001 Extract `promoteNextToCurrent()` method from `advanceSlide()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift`. This synchronous method must: (1) stop outgoing current video and remove its loop observer, (2) increment `currentIndex`, (3) promote all next properties to current (`currentKind = nextKind`, `currentImage = nextImage`, `currentVideo = nextVideo`, `currentFaceBoxes = nextFaceBoxes`, `currentEndOffset = nextEndOffset`, `currentStartOffset = nextStartOffset`), (4) invalidate old current video if different from next, (5) transfer next loop observer to current, (6) ensure promoted video is playing, (7) clear all next slots (`nextImage = nil`, `nextVideo = nil`, `nextFaceBoxes = []`, `nextEndOffset = .zero`, `nextStartOffset = .zero`, `nextKind = .photo`), (8) set `currentHoldDuration = nextHoldDuration`, (9) reset `isTransitioning = false` and `didStartNextVideoThisCycle = false`. The method takes an `overshoot: Double` parameter and sets `animationProgress = overshoot`. It must NOT be async — no `await` calls.

- [x] T002 Extract `loadNextMediaInBackground()` async method from `advanceSlide()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift`. This method must: (1) compute `currentHoldDuration` via `await holdDuration(for: currentItem)` (refine the pre-computed value from promote), (2) determine next item (`(currentIndex + 1) % photos.count`), (3) set `nextKind`, `nextStartOffset`, (4) load next media (photo: load image, face rects, compute offset; video: create player), (5) compute `nextHoldDuration` via `await holdDuration(for: nextItem)`, (6) call `updateNextVideoReadiness()`. Must check `guard !isStopped` at entry and after each await point.

**Checkpoint**: Two new methods exist alongside original `advanceSlide()`. Code compiles but new methods are not yet called.

---

## Phase 2: User Story 1 - Smooth Photo-to-Photo Transitions (Priority: P1) MVP

**Goal**: Eliminate the async race window by removing slideTimer and driving slot promotion from the animation timer. This fixes the 1-3 frame Ken Burns freeze at every transition boundary.

**Independent Test**: Play a slideshow of 5+ photos with Pan & Zoom transitions. Observe each transition boundary — pan/zoom motion should be continuous with no freeze or snap.

### Implementation for User Story 1

- [x] T003 [US1] Remove `slideTimer` property declaration, `scheduleNextAdvance()` method, and `handleAdvanceTimer()` method from `SlideshowPlayerState` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift`. Remove `slideTimer?.invalidate()` from `stop()` and `restartTimers()`. Remove `scheduleNextAdvance()` calls from `startTimers()` and `advanceSlide()`.

- [x] T004 [US1] Modify `updateAnimationProgress()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift` to detect `animationProgress >= 1.0` and perform synchronous slot promotion. After the existing progress increment line, replace the `min(1.0, ...)` clamp with: (1) compute unclamped progress: `animationProgress += progressIncrement`, (2) if `animationProgress >= 1.0`, compute `let overshoot = animationProgress - 1.0`, call `promoteNextToCurrent(overshoot: overshoot)`, then fire `Task { @MainActor [weak self] in await self?.loadNextMediaInBackground() }`. The progress must NOT be clamped to 1.0 anymore — the >= 1.0 check handles it synchronously.

- [x] T005 [US1] Update `startTimers()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift` to only start the animation timer (remove the `scheduleNextAdvance()` call). Update `restartTimers()` to only invalidate and restart the animation timer.

- [x] T006 [US1] Remove or refactor the original `advanceSlide()` method in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift`. It is no longer called by handleAdvanceTimer (which was removed). If `nextSlide()`/`previousSlide()` still reference it, keep a wrapper that calls `promoteNextToCurrent(overshoot: 0)` + `Task { loadNextMediaInBackground() }`, or refactor those methods directly.

- [x] T007 [US1] Build the project: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Fix any compilation errors from the timer model restructuring. Ensure zero warnings related to the changed code.

**Checkpoint**: Photo-to-photo transitions should be stutter-free. Build, run, play a slideshow with 5+ photos and Pan & Zoom. Verify no freeze or snap at transition boundaries. Verify crossfade transitions are also smooth. Verify looping for 2+ complete cycles shows no drift.

---

## Phase 3: User Story 2 - Smooth Transitions Involving Videos (Priority: P2)

**Goal**: Eliminate the full-animation freeze when the next media is a video that hasn't decoded yet. The current slide's motion continues smoothly; only the video's appearance is delayed.

**Independent Test**: Play a slideshow with alternating photos and videos. The outgoing slide's Ken Burns motion should never freeze, even if the incoming video takes time to decode.

### Implementation for User Story 2

- [x] T008 [US2] Remove the video readiness early return in `updateAnimationProgress()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift`. Currently lines 743-754 return early (pausing all animation) when `nextKind == .video && !nextVideoReady && waited < maxWaitForVideoSeconds`. Remove this early return so animation progress always increments. Keep the video readiness polling and the video playback start logic, but restructure so they don't block progress: (1) still check `nextVideoReady` and update it from `nextVideo?.status`, (2) still start video playback when ready (`videoPlayer.play()` + `installLoopObserver`), (3) remove the `waitingForVideoStartTime` timeout mechanism (no longer needed since progress isn't paused), (4) keep the `didStartNextVideoThisCycle` guard to prevent double-start. The renderer's existing opacity clamping (`max(0.5, baseOpacity)` when next texture isn't ready) handles the visual transition.

- [x] T009 [US2] Clean up the `waitingForVideoStartTime` property and `maxWaitForVideoSeconds` constant in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift` if they are no longer referenced after T008. Remove from property declarations and from `stop()` cleanup. Remove from `nextSlide()`/`previousSlide()` if referenced there.

- [x] T010 [US2] Build the project: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Fix any compilation errors.

**Checkpoint**: Mixed media transitions (photo-to-video, video-to-photo) should be smooth. The outgoing slide's Ken Burns motion should never freeze. If a video takes time to decode, the current slide fades normally and the video appears when ready. Build, run, test with alternating photos and videos.

---

## Phase 4: User Story 3 - Video-to-Video Transitions (Priority: P3)

**Goal**: Verify that consecutive video transitions are smooth. No additional code changes expected — the Phase 2 and 3 changes handle this case.

**Independent Test**: Play a slideshow with 3+ consecutive videos using crossfade transitions. Observe for frame drops at boundaries.

### Implementation for User Story 3

- [x] T011 [US3] Verify video-to-video transitions by visual inspection in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift`. No code changes expected for this story — the synchronous promotion (T001) and video readiness fix (T008) handle consecutive videos. If issues are found, investigate and fix within the existing `promoteNextToCurrent()` video handling logic (outgoing video stop, incoming video start, loop observer transfer).

**Checkpoint**: Video-to-video crossfade transitions are smooth. Audio stops cleanly on outgoing video. No frame drops at boundaries.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Manual navigation, edge cases, and final cleanup

- [x] T012 Update `nextSlide()` and `previousSlide()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift` to work correctly with the single-timer model. These methods currently call `restartTimers()` which was updated in T005. Verify they still: (1) reset `animationProgress = 0`, (2) reset `isTransitioning = false` and `didStartNextVideoThisCycle = false`, (3) call `prepareCurrentAndNext()` correctly, (4) produce clean transitions when invoked rapidly. Remove any references to slideTimer or scheduleNextAdvance.

- [x] T013 Remove dead code in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift`. Clean up: (1) the original `advanceSlide()` method if fully replaced, (2) any `slideTimer` references in comments, (3) the `nextVideoReady` property and `updateNextVideoReadiness()` if no longer used (check if renderer still reads `nextVideoReady`). Preserve the `@Published var nextVideoReady` property if it is read by other code.

- [x] T014 Final build and comprehensive testing: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Run the app and test: (1) Photo-to-photo with Pan & Zoom — no stutter, (2) Photo-to-photo with Crossfade — no stutter, (3) Photo-to-photo with Zoom — no stutter, (4) Photo-to-photo with Plain — clean instant cut, (5) Photo-to-video — smooth, no freeze, (6) Video-to-photo — smooth, clean audio cutoff, (7) Video-to-video — smooth crossfade, (8) Single photo slideshow — loops with Ken Burns, (9) Rapid arrow key navigation — clean transitions, (10) 20+ slide loop — no accumulated drift.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — can start immediately. Creates the two extracted methods.
- **User Story 1 (Phase 2)**: Depends on Phase 1 completion — wires the new methods into the timer model.
- **User Story 2 (Phase 3)**: Depends on Phase 2 completion — modifies video readiness logic within the new timer model.
- **User Story 3 (Phase 4)**: Depends on Phase 3 completion — verification only, no expected code changes.
- **Polish (Phase 5)**: Depends on Phase 3 completion — cleanup and manual navigation.

### User Story Dependencies

- **User Story 1 (P1)**: Depends on Foundational (Phase 1). This is the MVP — fixes photo-to-photo stutter.
- **User Story 2 (P2)**: Depends on US1 completion. Modifies the same `updateAnimationProgress()` function.
- **User Story 3 (P3)**: Depends on US2 completion. Verification only.

### Within Each Phase

- Phase 1: T001 and T002 can run in parallel (different methods being created)
- Phase 2: T003 → T004 → T005 → T006 → T007 (sequential — each modifies the same function/class)
- Phase 3: T008 → T009 → T010 (sequential — T009 depends on T008's changes)
- Phase 4: T011 (single verification task)
- Phase 5: T012, T013 can run in parallel → T014 (final verification depends on both)

### Parallel Opportunities

```text
# Phase 1: These two methods are independent and can be created in parallel:
T001: Create promoteNextToCurrent() method
T002: Create loadNextMediaInBackground() method

# Phase 5: These cleanup tasks touch different parts of the class:
T012: Update manual navigation methods
T013: Remove dead code
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Extract two new methods (T001-T002)
2. Complete Phase 2: Wire into timer model (T003-T007)
3. **STOP and VALIDATE**: Build, run, test photo-to-photo transitions
4. If stutter is eliminated, the core fix is validated

### Incremental Delivery

1. Phase 1 + Phase 2 → Photo stutter fixed (MVP!)
2. Add Phase 3 → Video readiness freeze fixed
3. Add Phase 4 → Video-to-video verified
4. Add Phase 5 → Manual nav updated, dead code cleaned

---

## Notes

- All tasks modify `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift` — no parallel file-level work possible
- The renderer (`MetalSlideshowRenderer.swift`) is NOT modified — existing Phase 3 safety nets remain
- The export pipeline (`ExportCoordinator.swift`) is NOT modified — has its own timing model
- Commit after each phase checkpoint for easy rollback
- The `[P]` marker is rarely used here because all tasks modify the same file
