# Feature Specification: Fix Transition Boundary Stutter

**Feature Branch**: `005-fix-transition-stutter`
**Created**: 2026-02-11
**Status**: Draft
**Input**: User description: "Fix the single-frame playback stutter at transition boundaries. The stutter is caused by an async race between timer-driven slot promotion (advanceSlide) and frame-accurate rendering."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Smooth Photo-to-Photo Transitions (Priority: P1)

A user plays a slideshow of photos with crossfade or pan-and-zoom transitions. As one photo fades out and the next fades in, the animation is perfectly smooth with no visible hitch, freeze, or snap at the transition boundary. The Ken Burns pan/zoom motion flows continuously from one slide to the next.

**Why this priority**: This is the core stutter bug. Photo-to-photo transitions are the most common use case and the motion freeze-then-snap is most visible during Ken Burns pan/zoom, where the camera appears to "stick" for 1-3 frames then jump.

**Independent Test**: Play a slideshow of 5+ photos with Pan & Zoom transition style. Observe each transition boundary. The pan/zoom motion should be continuous with no visible pause or snap at handoff.

**Acceptance Scenarios**:

1. **Given** a slideshow with 5+ photos and Pan & Zoom transitions, **When** the current slide's cycle completes and the next slide is promoted, **Then** the pan/zoom motion continues smoothly through the boundary with no freeze or snap.
2. **Given** a slideshow with Crossfade transitions, **When** the crossfade completes and the next slide becomes current, **Then** there is no single-frame flash, hitch, or opacity discontinuity.
3. **Given** a slideshow playing for multiple complete loops, **When** each transition boundary is reached, **Then** every transition is equally smooth with no accumulated drift or increasing stutter.

---

### User Story 2 - Smooth Transitions Involving Videos (Priority: P2)

A user plays a slideshow containing a mix of photos and videos. When transitioning from a photo to a video (or vice versa), the crossfade and motion remain smooth. If the incoming video takes time to decode its first frame, only the incoming video's appearance is delayed -- the outgoing slide's animation continues uninterrupted.

**Why this priority**: Mixed media slideshows are a key use case. The current video readiness stall pauses ALL animation (not just the incoming video), creating a visible full-screen freeze that can last up to 3 seconds.

**Independent Test**: Play a slideshow with alternating photos and videos. Observe transitions for freezes or animation pauses. The outgoing slide should always animate smoothly.

**Acceptance Scenarios**:

1. **Given** a photo transitioning to a video, **When** the transition phase begins, **Then** the outgoing photo's Ken Burns motion and opacity fade continue smoothly regardless of whether the video has decoded its first frame.
2. **Given** a next video that takes up to 3 seconds to decode, **When** the transition phase begins, **Then** the current slide's animation does not freeze -- only the incoming video's appearance in the crossfade is delayed until it is ready.
3. **Given** a video transitioning to a photo, **When** the transition completes, **Then** there is no audio cutoff glitch or motion discontinuity.

---

### User Story 3 - Video-to-Video Transitions (Priority: P3)

A user plays a slideshow with consecutive videos. When one video transitions to the next, both the outgoing and incoming videos play smoothly through the crossfade with no frame drops or audio glitches.

**Why this priority**: Less common than mixed media, but still affected by the same async race condition.

**Independent Test**: Play a slideshow with 3+ consecutive videos using crossfade transitions. Observe for frame drops at boundaries.

**Acceptance Scenarios**:

1. **Given** two consecutive videos with crossfade transition, **When** the transition boundary is reached, **Then** both videos play smoothly through the crossfade with no visible frame drop.
2. **Given** a video-to-video transition, **When** the outgoing video completes, **Then** its audio stops cleanly without a pop or glitch.

---

### Edge Cases

- What happens when the slideshow has only 1 item? (Should loop with Ken Burns motion; for non-plain transitions, self-crossfade should be smooth.)
- What happens when a video is shorter than the transition duration (< 2 seconds)? (Should fall back to slide duration and loop normally, as already implemented.)
- What happens during rapid manual navigation (left/right arrow keys)? (Should reset cleanly without stutter accumulation.)
- What happens when the system is under heavy load and render frames are dropped? (Should recover gracefully without accumulating timing errors.)
- What happens at the very first slide (no incoming transition)? (Should start cleanly with no stutter.)

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Slot promotion (moving "next" to "current") MUST happen synchronously within the same execution context that resets animation progress, not as a deferred async task that executes frames later.
- **FR-002**: The animation system MUST NOT freeze or pause the current slide's motion while waiting for a next video to decode. Only the next slot's visibility should be delayed.
- **FR-003**: Ken Burns pan/zoom motion MUST be continuous across transition boundaries with no visible snap or freeze at the handoff point.
- **FR-004**: Animation progress MUST NOT stall at 1.0 for multiple frames while waiting for deferred slot promotion. The transition from one slide to the next MUST be frame-accurate.
- **FR-005**: The existing video fallback texture system (for videos that haven't decoded yet), opacity clamping, and post-transition race window protection MUST continue to function correctly.
- **FR-006**: Manual navigation (left/right arrow keys) MUST continue to work and produce clean, stutter-free transitions.
- **FR-007**: All transition styles (plain, crossfade, pan & zoom, zoom) MUST benefit from the stutter fix.
- **FR-008**: The export pipeline MUST NOT be affected by playback timing changes (export has its own independent frame-accurate timing system).

### Key Entities

- **Animation Progress**: A normalized value (0.0 to 1.0) representing the current position within a slide's hold+transition cycle. Drives opacity crossfade and Ken Burns motion calculations.
- **Slot Promotion**: The act of moving the "next" media item into the "current" slot, resetting animation progress, and loading a new "next" item. Currently triggered asynchronously; must become synchronous at the promotion step.
- **Slide Timer**: A one-shot timer that fires after `totalSlideDuration` to trigger advancement. Currently wraps advanceSlide() in an async Task, creating the race window.
- **Animation Timer**: A repeating 60fps timer that increments animation progress and drives the render loop.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero visible frame stutters or motion discontinuities at transition boundaries during a 20-slide playback loop, verified by visual inspection across all transition styles.
- **SC-002**: Ken Burns pan/zoom motion appears continuous across all transition boundaries -- no freeze or snap visible to a human observer.
- **SC-003**: When the next media is a video that takes time to decode, the current slide's animation continues smoothly without any full-screen freeze.
- **SC-004**: No regression in existing playback features: video fallback textures, opacity handling, post-transition protection, face detection zoom, and per-slot duration zoom all continue to function correctly.
- **SC-005**: Manual navigation (arrow keys) produces clean transitions without stutter, with no behavioral change from the user's perspective.
