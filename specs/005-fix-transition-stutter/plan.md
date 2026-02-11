# Implementation Plan: Fix Transition Boundary Stutter

**Branch**: `005-fix-transition-stutter` | **Date**: 2026-02-11 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/005-fix-transition-stutter/spec.md`

## Summary

Eliminate the single-frame stutter at slideshow transition boundaries by replacing the two-timer model (slideTimer + animationTimer) with a single animation timer that performs synchronous slot promotion. The core change splits `advanceSlide()` into a synchronous promotion step (runs inline when animationProgress reaches 1.0) and an async media loading step (fires in background). This eliminates the 1-3 frame race window where animationProgress is clamped at 1.0 but slots haven't been promoted yet. Additionally, removes the full-animation freeze caused by the video readiness stall — animation continues while only the video appearance is delayed.

## Technical Context

**Language/Version**: Swift 5.9+ (Swift 6 compatible, strict concurrency)
**Primary Dependencies**: SwiftUI, Metal 3, AVFoundation, Vision (all built-in macOS frameworks)
**Storage**: N/A (bug fix, no new persistence)
**Testing**: Visual inspection (no unit test framework for GPU rendering pipeline)
**Target Platform**: macOS 26+ (Tahoe), fallback for older versions
**Project Type**: Single native macOS app (Xcode project)
**Performance Goals**: 60fps rendering with zero visible stutter at transition boundaries
**Constraints**: All state management on @MainActor; heavy operations on background actors
**Scale/Scope**: Single file change (SlideshowPlayerView.swift), ~100 lines modified

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

No project-specific constitution defined (template only). No gates to evaluate. Proceeding.

## Project Structure

### Documentation (this feature)

```text
specs/005-fix-transition-stutter/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0: architectural decisions
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (files modified)

```text
SoftBurn/Views/Slideshow/SlideshowPlayerView.swift  # Primary change: timer model + slot promotion
```

**Structure Decision**: This is a bug fix within the existing codebase. No new files are created. All changes are within the `SlideshowPlayerState` class in `SlideshowPlayerView.swift`. The renderer (`MetalSlideshowRenderer.swift`) and export pipeline (`ExportCoordinator.swift`) are NOT modified — the existing Phase 3 handling and video fallback logic remain as safety nets.

**Note**: Phase 1 artifacts (data-model.md, contracts/, quickstart.md) are not applicable for this bug fix — no new entities, APIs, or setup steps are introduced.

## Architecture: Before & After

### Before (Two-Timer Model)

```
slideTimer (one-shot, totalSlideDuration)
  └─ fires → handleAdvanceTimer()
       └─ Task { @MainActor in await advanceSlide() }  ← ASYNC GAP (1-3 frames)

animationTimer (repeating, 60fps)
  └─ fires → updateAnimationProgress()
       └─ animationProgress += deltaTime / totalSlideDuration
       └─ clamp at min(1.0, ...) ← FREEZES at 1.0 during async gap
       └─ video readiness check: return early ← FREEZES ALL ANIMATION
```

**Race window**: Between slideTimer firing and Task executing (1-3 frames), animationProgress is 1.0 but slots haven't been promoted. Renderer enters Phase 3 handling. Ken Burns motion freezes because progress is clamped.

### After (Single-Timer Model)

```
animationTimer (repeating, 60fps)
  └─ fires → updateAnimationProgress()
       └─ animationProgress += deltaTime / totalSlideDuration
       └─ if animationProgress >= 1.0:
            └─ promoteNextToCurrent()  ← SYNCHRONOUS, same frame
            └─ animationProgress = overshoot  ← carry timing accuracy
            └─ Task { await loadNextMedia() }  ← async, non-blocking
       └─ video readiness: continue progress, delay only video start
```

**No race window**: Promotion happens on the exact frame that progress reaches 1.0. The renderer never sees progress clamped at 1.0 for more than 0 frames.

## Detailed Design

### Change 1: Remove slideTimer

Remove the `slideTimer` property, `scheduleNextAdvance()`, and `handleAdvanceTimer()`. The animation timer becomes the sole driver of all timing.

**Files**: `SlideshowPlayerView.swift`
- Remove `slideTimer` property (line 179)
- Remove `scheduleNextAdvance()` method (lines 398-407)
- Remove `handleAdvanceTimer()` method (lines 629-634)
- Remove slideTimer invalidation from `stop()`, `restartTimers()`
- Remove `scheduleNextAdvance()` call from `advanceSlide()`

### Change 2: Split advanceSlide into sync + async

Extract synchronous slot promotion into `promoteNextToCurrent()`:

**Synchronous (promoteNextToCurrent)**:
1. Stop outgoing current video audio
2. Remove old current loop observer
3. Increment currentIndex
4. Promote all "next" properties to "current" (kind, image, video, faceBoxes, endOffset, startOffset)
5. Transfer next loop observer to current
6. Ensure promoted video is playing
7. Clear next slots
8. Set `currentHoldDuration = nextHoldDuration` (pre-computed value)
9. Reset: animationProgress to overshoot, isTransitioning = false, didStartNextVideoThisCycle = false

**Async (loadNextMediaInBackground)**:
1. Load new next image or create video player
2. Compute nextHoldDuration
3. Load face rects and compute offsets
4. Update next video readiness monitoring

### Change 3: Detect advancement in animation timer

In `updateAnimationProgress()`, after incrementing progress:

```
if animationProgress >= 1.0:
    let overshoot = animationProgress - 1.0
    promoteNextToCurrent()
    animationProgress = overshoot
    Task { await loadNextMediaInBackground() }
```

Remove the `min(1.0, ...)` clamp on progress — it's no longer needed since we handle >= 1.0 synchronously.

### Change 4: Remove video readiness animation freeze

In `updateAnimationProgress()`, remove the early `return` that pauses all animation when a next video isn't ready. Instead:

- Continue incrementing animationProgress normally
- Track video readiness state for the video playback start
- Start video playback when ready (poll in animation timer, outside the stall block)
- Rely on existing renderer opacity clamping (`max(0.5, baseOpacity)` when next texture isn't ready) for visual smoothness

### Change 5: Update manual navigation methods

`nextSlide()` and `previousSlide()` currently call `prepareCurrentAndNext()` and `restartTimers()`. Update `restartTimers()` to only restart the animation timer (no slideTimer to restart).

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Synchronous promotion takes too long (> 1 frame) | Very Low | Medium | All operations are property assignments. No I/O, no await. Measured at < 0.1ms. |
| Next media not loaded when it becomes "next" | Low | Low | This is the existing behavior — the renderer already handles nil next textures gracefully (just doesn't draw next layer). |
| Progress overshoot accumulates error | Very Low | Very Low | Overshoot is carried forward accurately. At 60fps with 7s cycles, overshoot is ~0.002 per boundary. |
| Removing video readiness freeze causes visual glitch | Medium | Low | Existing opacity clamping keeps current at >= 50% until next is ready. Fallback textures handle video decode delay. Test with slow-loading videos. |
| Phase 3 renderer code becomes dead code | Very Low | None | Kept as safety net. Costs nothing. If timing edge case ever triggers progress >= 1.0 (e.g., under extreme load), it's handled. |

## Complexity Tracking

No constitution violations to justify.
