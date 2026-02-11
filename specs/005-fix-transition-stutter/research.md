# Research: Fix Transition Boundary Stutter

**Date**: 2026-02-11
**Feature**: 005-fix-transition-stutter

## Decision 1: Single Timer vs Two Timers

**Decision**: Replace the two-timer model (slideTimer + animationTimer) with a single animation timer that detects progress >= 1.0 and performs synchronous slot promotion inline.

**Rationale**: The root cause of the stutter is the async gap between the slideTimer firing and advanceSlide() executing. The slideTimer calls `Task { @MainActor in await self.advanceSlide() }`, which enqueues on the main actor's executor. During the 1-3 frame delay before execution, the animation timer keeps firing, animationProgress is clamped at 1.0, and Ken Burns motion freezes. By removing the slideTimer entirely and detecting the advancement condition inside the animation timer callback, promotion happens synchronously on the same frame that progress reaches 1.0.

**Alternatives considered**:
- **Synchronous dispatch from slideTimer** (call advanceSlide synchronously without Task wrapper): Rejected because advanceSlide() is async (it loads media via await). The async parts need to remain async, but the synchronous promotion step can be extracted.
- **CADisplayLink instead of Timer**: Would improve frame accuracy but adds complexity. The real issue is the async gap, not timer precision. Could be a future improvement.
- **Prediction/interpolation in renderer**: Make the renderer predict when progress will reach 1.0 and pre-interpolate. Overly complex and fragile.

## Decision 2: Split advanceSlide into Sync Promotion + Async Loading

**Decision**: Extract the synchronous property assignments from advanceSlide() into a new `promoteNextToCurrent()` method that runs inline in the animation timer. The async media loading runs in a fire-and-forget Task afterward.

**Rationale**: advanceSlide() does two things:
1. **Synchronous promotion**: Property assignments (currentImage = nextImage, currentVideo = nextVideo, index increment, face box transfer, observer transfer, progress reset). None of these require `await`.
2. **Async loading**: Load new next image/video, compute hold durations, load face rects. These require `await` but can run in background without blocking the promotion.

By separating these, promotion happens on the exact frame that progress reaches 1.0, while loading happens asynchronously without any visible delay.

**Key insight**: `nextHoldDuration` is already pre-computed when the next item is loaded. During synchronous promotion, we set `currentHoldDuration = nextHoldDuration` (the pre-computed value), so `totalSlideDuration` is immediately correct for the new cycle.

## Decision 3: Progress Overshoot Carry-Over

**Decision**: When animationProgress exceeds 1.0, carry the overshoot into the next cycle instead of clamping to 0.

**Rationale**: Currently progress is clamped with `min(1.0, ...)`. When the animation timer fires at 16.67ms intervals and progress is at 0.998, the next increment would bring it to 1.000381. If we reset to 0.0 after promotion, we lose 0.000381 worth of timing, causing imperceptible but accumulating drift over many cycles. Carrying the overshoot maintains frame-accurate timing: `animationProgress = max(0, progressAfterIncrement - 1.0)`.

**Alternatives considered**:
- **Reset to 0.0**: Simpler but loses timing accuracy. The drift is ~0.27ms per cycle (at 7s cycle = 0.004%), which would be invisible. Still, carrying overshoot is trivially simple and strictly correct.

## Decision 4: Video Readiness — No Animation Freeze

**Decision**: Remove the early return in updateAnimationProgress() that pauses ALL animation when a next video isn't ready. Instead, continue progress normally and rely on existing opacity clamping.

**Rationale**: The current code (line 751) returns early when `nextKind == .video && !nextVideoReady && waited < 3s`, which stops incrementing animationProgress entirely. This freezes the current slide's Ken Burns motion, opacity transitions, everything — a visible full-screen freeze.

The existing opacity clamping (line 786-788: `max(0.5, baseOpacity)` when next isn't ready) already handles the visual concern: the current slide stays at least 50% visible until the video decodes. The video readiness wait should only delay the VIDEO PLAYBACK START, not the animation system.

**New approach**:
1. Continue incrementing animationProgress normally (no early return)
2. The transition starts on schedule
3. If next video isn't ready, opacity clamping keeps current visible
4. Poll video readiness in the animation timer; start playback when ready
5. When the video decodes its first frame, it appears at whatever opacity the transition has reached

**Alternatives considered**:
- **Delay only the transition start (not all animation)**: This preserves the current slide's hold phase but still causes a visible pause at the transition point. The opacity clamping approach is smoother because the current slide starts fading while the video loads, and the clamping prevents it from disappearing.

## Decision 5: Files Modified — Minimal Blast Radius

**Decision**: Changes are limited to SlideshowPlayerView.swift (timer model and state management). No changes to MetalSlideshowRenderer.swift, MetalSlideshowView.swift, or the export pipeline.

**Rationale**: The renderer's opacity calculation, Ken Burns motion math, and video fallback logic already handle edge cases correctly (Phase 3 detection, nextTextureReady checks, fallback textures). The bug is purely in the timer/scheduling model. By making slot promotion synchronous, the "Phase 3 race window" effectively disappears — animationProgress never stays at 1.0 for more than 0 frames, so the renderer always sees either Phase 1 or Phase 2.

The Phase 3 code in the renderer can remain as a safety net (it costs nothing and protects against future timing edge cases), but it should never trigger in normal operation after this fix.
