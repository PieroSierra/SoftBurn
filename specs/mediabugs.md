# Media Hangling Bugs

## Media Importing Issues

| MEDIA PLAYBACK | Filesystem                                                                   | Photos Library                                                                                                                                                                                     |
| -------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Photo, present | works, shows up immediately                                                  | works, shows up immediately                                                                                                                                                                        |
| Photo, iCloud  | triggers download; spinner shown while iCloud downloads, then refreshes view | photo downloads, eventually works.  But I can't see the spinner.  We should be triggering the download but adding a spinner in the UI                                                              |
| Video, Present | works, shows up immediately                                                  | works, shows up immediately                                                                                                                                                                        |
| Video, iCloud  | triggers download; spinner shown while iCloud downloads, then refreshes view | video downloads, eventually works.  But I can't see the spinner.  Preview (before video downloaded) show a spinner if invoked. We should be triggering the download but adding a spinner in the UI |

## Media Playback Known Issues

1. ~~Single-frame Stutter after 2s of playback~~ **FIXED** (11 Feb 2026) — Two-part fix:
   
   - **Timer fix**: Replaced two-timer model (slideTimer + animationTimer) with single animation timer. Slot promotion is now synchronous via `promoteNextToCurrent()` when `animationProgress >= 1.0`. No async race window. This fixed photo→photo stutter.
   - **Video source swap fix**: When a video moves from next→current slot, the renderer now swaps `VideoTextureSource` references instead of calling `item.remove(output)` + `item.add(output)`. Those synchronous AVPlayerItemVideoOutput operations were blocking the main thread and causing audio buffer underruns across all streams (including background music). The swap is zero-cost — the promoted video's output continues uninterrupted. This fixed photo→video, video→video stutter and audio glitches.

2. ~~Play in Full video playback does not work  - videos only play for the n seconds of the regular slideshow setting~~ **FIXED** (11 Feb 2026)

3. ~~**Playback frame drop after incoming transition** — During live playback, when a video transitions from "next" to "current" (after the 2s crossfade completes), there is a brief visible glitch/frame drop.~~ **FIXED** (11 Feb 2026) — Same root cause as #1. Synchronous slot promotion + video source swap eliminates both the async race window and the AVPlayerItem output rebinding stall.

4. ~~**Export: video audio cuts off after ~5s** — During video export, audio from video clips starts correctly but cuts out after exactly 5 seconds (the default slideDuration).~~ **FIXED** (11 Feb 2026) — `AudioComposer.addVideoAudio()` was using raw `exportSettings.slideDuration` (5s) for audio duration instead of the actual visible time. Fixed to use `incomingTransition + entry.holdDuration + entry.transitionDuration`, matching the full time the video is on screen.

## Export Issues

| VIDEO EXPORT                      | Filesystem | Photos Library                     |
| --------------------------------- | ---------- | ---------------------------------- |
| Photo, present                    | works      | works                              |
| Photo, iCloud                     | N/A        | not tested (iCloud review pending) |
| Video, present (play in full OFF) | works      | works                              |
| Video, iCloud (play in full OFF)  | N/A        | not tested (iCloud review pending) |
| Video, present (play in full ON)  | works      | works                              |
| Video, iCloud (play in full ON)   | N/A        | not tested (iCloud review pending) |

Export works correctly for all present (non-iCloud) media with mixed sources. iCloud content deferred until iCloud codepaths are reviewed.

---

# Code Audit: Media Handling & Playback (February 2026)

Deep code review of the media pipeline — import, playback, transitions, and export — with attention to interactions between filesystem/Photos Library sources, photo/video types, iCloud state, and settings combinations.

## How the Playback Pipeline Works

Understanding the timer model and texture lifecycle is necessary context for the bugs below.

### Two-Phase Slide Cycle (Single-Timer Model)

Each slide goes through two phases driven by a single animation timer (60fps):

```
Phase 1 (Hold):       0 ≤ animationProgress < transitionStart
Phase 2 (Transition): transitionStart ≤ animationProgress < 1.0
→ When animationProgress >= 1.0: synchronous promoteNextToCurrent(), overshoot carried to next cycle
```

- **Animation timer** — fires at 60fps, increments `animationProgress` from 0.0 toward 1.0. When it reaches or exceeds 1.0, `promoteNextToCurrent()` runs synchronously on the same frame. No async gap.

`totalSlideDuration = currentHoldDuration + transitionDuration` (2.0s for non-plain styles, 0 for plain).

Example with 5s hold + 2s transition = 7s total:

- Hold: 0.0 → 0.71 (5s)
- Transition: 0.71 → 1.0 (2s, crossfade/zoom)
- At 1.0: synchronous `promoteNextToCurrent(overshoot)` promotes next→current, resets progress. `loadNextMediaInBackground()` fires async.

### Slot Model

The renderer maintains two slots:

- **Current** — the visible media (photo texture or video player)
- **Next** — pre-loaded for the upcoming transition

On `promoteNextToCurrent()`: next is promoted to current synchronously (same frame), old current is released. When a video moves from next→current, the renderer swaps `VideoTextureSource` references (zero-cost) instead of rebinding AVPlayerItemVideoOutput. New next is loaded async via `loadNextMediaInBackground()`.

### Metal Rendering (Two-Pass)

1. **Pass 1 — Scene Composition**: Renders current + next layers to offscreen texture with opacity/scale/offset uniforms
2. **Pass 2 — Patina**: Applies film simulation (35mm/aged/VHS) or blits directly when patina=none

Opacity during transition is calculated from `animationProgress`. The renderer includes safety nets: opacity clamping when next texture isn't ready, and fallback textures for video decode latency.

---

## ~~Confirmed Bug: "Play in Full" Broken for Photos Library Videos~~ **FIXED** (Fix 1)

Fixed by changing both call sites to use the `MediaItem` overload of `VideoMetadataCache.durationSeconds()`. See Fix 1 below for details.

---

## Analysis: Single-Frame Stutter

The stutter manifests in two ways:

1. A brief visual hitch at the transition boundary (minor)
2. Noticeable interruption during pan/zoom animation (major)

### Primary Cause: Async Race Window

`handleAdvanceTimer()` wraps `advanceSlide()` in `Task { @MainActor in ... }` (SlideshowPlayerView.swift:623). The async task doesn't execute immediately — it's enqueued on the main actor's executor. During the 1-3 frames between enqueue and execution:

- `animationProgress` has reached or exceeded 1.0
- The animation timer keeps running (it doesn't know advanceSlide() is pending)
- `isTransitioning` flips to `false` (because `animationProgress >= 1.0` fails the `< 1.0` check at line 724)
- The renderer enters "Phase 3" logic where opacity rules change

The renderer handles this Phase 3 correctly for opacity (next=100%, current=0% or kept visible if next not ready). But the **Ken Burns motion** calculation uses `animationProgress` which is clamped at 1.0, causing the pan/zoom to freeze for those 1-3 frames before snapping to the new slide's starting position.

### Secondary Cause: Video Readiness Wait

When the next media is a video, `updateAnimationProgress()` (line 732-744) stalls by returning early if the video hasn't decoded its first frame. This pauses all animation for up to 3 seconds. The hold phase effectively lengthens, but the visual result is a jarring pause.

### Existing Mitigations

The codebase already has several fixes for related symptoms:

- **Fallback texture system** (MetalSlideshowRenderer.swift:84-105) — when a video moves from next→current but hasn't decoded a frame, falls back to the last good current texture
- **Opacity clamping** (line 786-788) — current doesn't fade below 50% if next texture isn't ready
- **Phase 3 explicit handling** (line 757-763) — prevents both layers being 0% opacity

These prevent the worst symptoms (background flash, transparent frames) but don't eliminate the motion discontinuity.

### Why It's Hard to Fix

The fundamental tension is between:

- Timer-driven slot promotion (which must be async because it loads new media)
- Frame-accurate rendering (which needs synchronous state updates)

The current approach uses a fixed-interval slide timer that doesn't synchronize with render frames. The animation timer runs independently at 60fps. The gap between "timer fires" and "state actually updates" is inherent to the async design.

---

## Photos Library vs Filesystem: Inconsistencies

### iCloud Downloads — No Timeout or Progress

Photos Library items use `PHImageRequestOptions.isNetworkAccessAllowed = true` to auto-download from iCloud. This is set in:

- `PhotosLibraryImageLoader.loadCGImage()` (line 45)
- `PhotosLibraryImageLoader.loadNSImage()` (line 83)
- `PhotosLibraryImageLoader.getVideoURL()` (line 181)

There is no timeout. If the network is slow or unavailable, the PHImageManager callback may never fire (or fire very late). During playback, this means:

- Grid thumbnail generation hangs indefinitely for that item
- Face detection prefetch blocks on that item
- Playback texture loading blocks (no placeholder shown in grid while waiting)

The filesystem path handles this differently: files are either present or not. There's no download step.

**User-reported symptom**: "I can't see the spinner" — the code triggers the download but the grid UI doesn't show per-item download progress for Photos Library items.

### Video Export to Temp Files

Photos Library videos are exported to `/tmp/SoftBurnVideoExport/` via `PHAssetResourceManager.writeData()` (PhotosLibraryImageLoader.swift:154-176). Issues:

- Temp files accumulate if app crashes (cleanup only called explicitly via `cleanupVideoCache()`)
- Concurrent exports to same directory: filenames are based on `localIdentifier` hash, so conflicts are unlikely but not impossible with hash collisions
- Temp file URLs are cached in `videoURLCache` dict — if the temp file is deleted externally while cached URL exists, subsequent access will fail silently

### Silent Error Swallowing in Photos Picker

`PhotosPickerView.swift:52-55` has empty comment blocks where asset fetch errors would be handled. Failed assets are silently dropped with no logging or user feedback. If a user selects 10 items but 2 fail to resolve (e.g., corrupted assets), they get 8 items with no indication that 2 were lost.

### Rotation Handling Differences

- **Filesystem photos**: Rotation stored in `MediaItem.rotationDegrees`, applied at render time
- **Photos Library photos**: EXIF rotation handled by PhotoKit automatically, `rotationDegrees` always 0
- **Thumbnail cache key**: Includes rotation, but Photos Library thumbnails ignore the rotation parameter (ThumbnailCache.swift:137 returns early). This means if someone could rotate a Photos Library photo (currently not possible), the cache key wouldn't match
- **Videos**: Not rotatable at all (`rotateCounterclockwise90()` returns early for `.video` kind)

---

## Edge Cases to Test Manually

### Resolved (11 Feb 2026)

These were tested and confirmed working after the transition stutter + video source swap + audio fixes:

1. ~~**Photos Library video + "Play in Full" ON**~~ — Works (Fix 1 + Fix 5 + Fix 6)
2. ~~**Mixed slideshow (photos + videos from both sources) + transitions**~~ — No stutter, no missing frames
3. ~~**Video→Video transitions**~~ — Smooth crossfade, correct audio overlap during 2s transition
4. ~~**Export with Photos Library videos**~~ — Works with sound, correct rotation, correct timing
5. ~~**Single video slideshow + "Play in Full" ON**~~ — Loops correctly
6. ~~**Single photo slideshow**~~ — Loops with Ken Burns, no issues
7. ~~**Plain transition style + videos**~~ — Clean instant cut
8. ~~**Music + video audio interaction**~~ — Both audible, no glitches

### Still Open — iCloud

9. ~~**Photos Library video + iCloud (not downloaded) + Play**~~ — Partially addressed by Fix 10 (iCloud download manager, grid badges, preview placeholders). Playback still shows nothing for unavailable items during slide duration.

10. ~~**All items iCloud + no network**~~ — Grid now shows error badges. Preview shows "Not available" placeholder. Auto-retries when network returns.

10b. **Filesystem iCloud Drive items don't refresh thumbnails after download** — FS items from iCloud Drive show a spinner during download and an error icon if unavailable, but after macOS completes the iCloud Drive sync the thumbnail does not auto-refresh. Requires re-import or app restart. Out of scope for spec 006 (Photos Library focus).

### Still Open — Other

11. **Large slideshow (100+ items) + "Play in Full" ON** — Memory usage. Face detection cache and thumbnail cache are both unbounded (`[String: [CGRect]]` and similar dicts). Check for memory growth over time.

12. **Export cancel mid-way** — Does cleanup happen? Is the incomplete output file deleted? (Current code does NOT delete the output file on cancel — ExportCoordinator.cleanup() only removes temp audio/video intermediates.)

13. **File deleted during playback** — Import a filesystem photo, start playback, delete the file externally. The texture is cached so current play continues, but what happens on the next loop?

14. **Export with no audio sources** — No background music selected, all videos muted or no videos. Does export produce a valid file with silent audio or no audio track?

15. **Corrupted .softburn file** — Manually corrupt a saved file. Does load fail gracefully with an error message?

---

## Potential Issues (Lower Confidence — Need Testing)

### 1. Video Player Pool Exhaustion Under Rapid Skipping

`VideoPlayerPool` has a max of 4 players. If a user rapidly advances slides (e.g., pressing right arrow), each advance creates a new player for the next video. Players are invalidated and returned to the pool, but pool drain is async. Rapid skipping could temporarily exceed the pool limit, falling through to create new AVPlayers and hitting macOS hardware decoder limits.

### 2. Security-Scoped Bookmark Lifetime

Filesystem files get bookmarks created on save, not on import. If a user imports files from an external drive, works for a while but never saves, the security-scoped access obtained during import may expire if the app is backgrounded. When playback tries to load the image, it may fail silently.

### 3. Face Detection Cache Key Mismatch

Face detection cache keys use `"photos://{localID}"` for Photos Library items and file paths for filesystem items. The document serializes these as `faceRectsByPath`. If a filesystem item's path changes (e.g., volume remounts with different path), cached face rects won't match on reload. Detection would re-run, but only if prefetch is triggered — and it's NOT triggered on document open (only on import).

### 4. Ken Burns Start Offset Randomization

Each time a slide appears, `startOffset` is randomized (SlideshowPlayerView.swift:704-707). For a looping slideshow, the same photo gets a new random start on each pass. This means the pan direction "jumps" each loop — the end position of one pass won't match the start of the next. This is by design but may look jarring for small slideshows that loop frequently.

### 5. Export Frame Timing vs Playback Timing

Export renders at a fixed frame rate (30fps per ExportPreset). Live playback renders at display refresh (60fps via MTKView). The animation math is the same, but the coarser temporal resolution during export means transitions may look slightly different (choppier crossfades, less smooth Ken Burns).

### 6. Audio Composition for Photos Library Videos

The `AudioComposer` extracts audio tracks from video files. For Photos Library videos, these are temp files exported via `PHAssetResourceManager`. The AudioQueue sandbox bug is documented in `PhotosLibraryImageLoader` comments (lines 7-15) — PHImageManager.requestAVAsset() fails in sandbox. The workaround uses PHAssetResourceManager.writeData() instead. However, audio extraction from these temp files during export may still trigger related issues. This needs testing with Photos Library videos that have audio tracks.

### 7. Transition Duration Hard-Coded at 2.0s

`SlideshowPlayerState.transitionDuration` is a static constant (line 141). It's not configurable. With very short `slideDuration` values (e.g., 1s), the 2s transition dominates: `totalSlideDuration = 1 + 2 = 3s`, meaning the slide is only fully visible for 1s out of every 3s cycle, and is crossfading for the other 2s. This isn't a bug, but it produces surprising results at short durations.

### 8. Video Loop Observer Leak Potential

`installLoopObserver()` adds a NotificationCenter observer for `AVPlayerItem.didPlayToEndTimeNotification`. Observers are cleaned up in `promoteNextToCurrent()` and `stop()`. But if promotion is interrupted, an observer could leak. The observer closure captures `self` weakly, so it won't prevent deallocation, but it could fire unexpectedly on a stale player.

### 9. ~~Temp Export File Leak on Error~~ **FIXED** (Fix 3)

~~If export fails partway through (disk full, permission error), `ExportCoordinator.cleanup()` may not be called.~~ Fixed by adding `defer` cleanup block to `ExportCoordinator.export()`.

---

# Fixes Applied (February 2026)

## Fix 1: "Play in Full" for Photos Library Videos

Changed two call sites to use the `MediaItem` overload of `VideoMetadataCache.durationSeconds()`:

- `SlideshowPlayerView.swift:510` — `durationSeconds(for: item)` (was `item.url`)
- `ExportCoordinator.swift:393` — `durationSeconds(for: item)` (was `item.url`)

## Fix 2: Error Logging in Photos Picker

Added `os_log` error messages to `PhotosPickerView.swift` where asset fetch failures were silently swallowed.

## Fix 3: Export Cleanup Robustness

Added `defer` block to `ExportCoordinator.export()` so temp files are always cleaned up on error or cancellation. Incomplete output file is also deleted on failure.

## Fix 4: Photos Library Video Rotation in Export

Added `isFromPhotosLibrary` parameter to `VideoFrameReader.init()`. When true, applies the same rotation negation (90 deg <-> 270 deg) that the live playback path uses in `VideoPlayerManager.swift:134-141`. This fixes exported Photos Library videos appearing rotated.

- `VideoFrameReader.swift:36` — new `isFromPhotosLibrary` parameter, negation logic at line 65
- `ExportCoordinator.swift:577` — passes `item.isFromPhotosLibrary` to VideoFrameReader

## Fix 5: holdDuration Accounts for Transition Overlap

For "Play in Full" videos with non-plain transitions, `holdDuration` now returns `videoDuration - 4s` (subtracting the 2s incoming + 2s outgoing crossfade time). Videos shorter than 4s fall back to `slideDuration` and loop normally.

- `SlideshowPlayerView.swift:holdDuration()` — subtract `2 * transitionDuration`, fallback for short videos
- `ExportCoordinator.swift:buildTimeline()` — same calculation for export

## Fix 6: Ken Burns Zoom Uses Per-Slot Duration

Added `nextHoldDuration` to `SlideshowPlayerState`. The live Metal renderer now calculates `motionTotal` per slot using the slot's own hold duration, preventing the zoom speed "snap" when transitioning between items with very different durations. The export path already handled this correctly.

- `SlideshowPlayerView.swift` — new `nextHoldDuration` property, computed in `prepareCurrentAndNext()` and `advanceSlide()`
- `MetalSlideshowRenderer.swift:800` — per-slot `motionTotal`

## Fix 7: Export Video/Audio Time Offset

Videos and audio in export now account for the incoming transition: for non-first slides, playback starts at `entry.startTime - 2s`. This fixes the "static frame during transition" bug (video frames) and the "audio offset by 2s" bug (audio composition).

- `ExportCoordinator.swift:loadTexture()` — video frame time offset
- `AudioComposer.swift:addVideoAudio()` — audio insertion time offset

## Fix 8: Short Videos Loop in Plain Mode

In plain mode (no transitions), "Play in Full" videos shorter than `slideDuration` were not looping — they held for their intrinsic duration (e.g., 1s) then immediately cut. Now both playback and export fall back to `slideDuration` when the video is shorter, matching the non-plain behavior.

- `SlideshowPlayerView.swift:holdDuration()` — plain branch: return `seconds` only if `> slideDuration`
- `ExportCoordinator.swift:buildTimeline()` — plain branch: same fallback

---

## Fix 9: Centralize holdDuration Logic (MediaTimingCalculator)

Extracted the duplicated `holdDuration` calculation into a shared `MediaTimingCalculator` enum in `Utilities/MediaTimingCalculator.swift`. Both playback and export now call the same function, eliminating the class of bugs where one path gets fixed but the other doesn't. The `transitionDuration` constant (2.0s) is also defined once in `MediaTimingCalculator` and referenced by both `SlideshowPlayerState` and `ExportCoordinator`.

- `SoftBurn/Utilities/MediaTimingCalculator.swift` — new file, single source of truth
- `SlideshowPlayerView.swift:holdDuration()` — now delegates to `MediaTimingCalculator.holdDuration()`
- `SlideshowPlayerView.swift:transitionDuration` — now references `MediaTimingCalculator.transitionDuration`
- `ExportCoordinator.swift:buildTimeline()` — now calls `MediaTimingCalculator.holdDuration()`
- `ExportCoordinator.swift:transitionDuration` — now references `MediaTimingCalculator.transitionDuration`

## Fix 10: iCloud Download State Visibility (15 Feb 2026)

Centralized iCloud download tracking for Photos Library items with visible UI feedback across grid, preview, and playback.

**New file**: `SoftBurn/Caching/iCloudDownloadManager.swift`
- `DownloadStatePublisher` (@MainActor ObservableObject) — synchronous state publication for SwiftUI/AppKit observation
- `iCloudDownloadManager` (actor) — probes local availability via `PHAssetResourceManager` with `isNetworkAccessAllowed=false`, downloads full-resolution assets, retries with exponential backoff, auto-retries on network restoration via `NWPathMonitor`

**Grid** (`MediaGridCollectionView.swift`):
- Unified status badge (centered circular vibrancy frame) replaces three separate indicators (spinner, placeholder icon, iCloud badge)
- Loading state: centered spinner inside hudWindow material circle (both FS and Photos Library)
- Error state: centered `icloud.slash.fill` inside same circle (both FS and Photos Library)
- Combines subscription to `DownloadStatePublisher` for real-time badge updates
- Thumbnail auto-refreshes when download completes

**Preview** (`PhotoViewerSheet.swift`):
- Dark card background (`Color(white: 0.15)`) when no content loaded
- "Downloading from iCloud..." placeholder with spinner
- "Not available offline" persistent error placeholder
- Auto-reloads when download state transitions to ready

**ContentView.swift**:
- `DownloadStatePublisher.shared.register()` called synchronously on MainActor BEFORE `addPhotos()` at all three entry points (selection, drop, file load)
- Ensures grid cells see download state on their very first render

**FaceDetectionCache.swift**:
- `retryPendingItems(for:)` re-runs face detection when an iCloud item finishes downloading

**Known remaining issue**: Filesystem iCloud Drive items don't auto-refresh thumbnails after macOS sync completes (see item 10b above).

---

# Timing & Zoom Bugs — Analysis (**FIXED** 11 Feb 2026)

These bugs were interconnected and were fixed together. Analysis preserved below for reference.

## Bug: holdDuration Doesn't Account for Transition Overlap

### The Problem

When "Play in Full" is ON, `holdDuration()` returns the video's full intrinsic duration. But the video is also visible during the incoming and outgoing transitions (2s each). This means the video plays for `holdDuration + 4s` total, causing it to loop.

### How the Video Is Actually Visible

Timeline for Video B (middle item, non-plain transition):

```
A's outgoing transition     B's hold phase           B's outgoing transition
|<--- 2s --->|<--- holdDuration --->|<--- 2s --->|
B starts                                          B stops
playing here                                      (advanceSlide)
```

B plays for: 2s + holdDuration + 2s = holdDuration + 4s total.

With holdDuration = videoDuration (current code), B plays for videoDuration + 4s. Since B is only videoDuration long, it loops 4s before B's outgoing transition ends. This is the looping bug observed in testing.

### The Fix

```swift
private func holdDuration(for item: MediaItem) async -> Double {
    switch item.kind {
    case .photo:
        return slideDuration
    case .video:
        if playVideosInFull, let seconds = await VideoMetadataCache.shared.durationSeconds(for: item) {
            if transitionStyle != .plain {
                // Subtract 4s for the time the video plays during transitions (2s in + 2s out)
                return max(0, seconds - 2 * Self.transitionDuration)
            } else {
                return seconds  // Plain: no transitions, video holds for full duration
            }
        }
        return slideDuration
    }
}
```

### Edge Cases to Handle

- **First item in slideshow**: No incoming transition. Video starts immediately via `prepareCurrentAndNext(shouldAutoPlay: true)`. Only 2s outgoing. Total = holdDuration + 2s. With the -4s fix, first video would end 2s early. Accept this minor imperfection on first loop, or add first-item detection.
- **Videos shorter than 4s**: `max(0, ...)` clamps to 0. The video would transition immediately. Acceptable behavior.
- **Plain transition**: No crossfades, holdDuration = full videoDuration. Video plays exactly once.
- **Export must match**: Same fix needed in `ExportCoordinator.buildTimeline()` (line 353-354).

### Files to Change

- `SlideshowPlayerView.swift:505-515` — `holdDuration()`
- `ExportCoordinator.swift:352-357` — `buildTimeline()` hold duration calculation

## Bug: Ken Burns Zoom Speed Snap

### The Problem

When a video transitions from "next" to "current", the Ken Burns zoom speed changes abruptly because `motionTotal` is recalculated against different parameters.

### Live Playback (MetalSlideshowRenderer.swift:798-805)

```swift
let motionTotal = playerState.currentHoldDuration + (2.0 * SlideshowPlayerState.transitionDuration)
```

This uses `currentHoldDuration` for BOTH the current and next slots. When Video B (52s) appears as "next" during Photo A's (5s) outgoing transition:

- motionTotal = A.holdDuration + 4 = **9s** → zoom covers 0→100% in 9s (fast)

When B becomes "current":

- motionTotal = B.holdDuration + 4 = **56s** → zoom covers 0→100% in 56s (slow)

At the handoff, B's zoom progress jumps from ~22% (2/9) to ~3.8% (2/52). This is the visible "snap."

### Export (ExportCoordinator.swift:637) — Already Correct

The export path already calculates motionTotal per-slot:

```swift
motionTotal = incomingTransition + entry.holdDuration + entry.transitionDuration
```

Each slot uses its OWN entry's holdDuration. This is the correct approach.

### The Fix for Live Playback

Add `nextHoldDuration` to `SlideshowPlayerState`:

```swift
@Published var nextHoldDuration: Double = 5.0
```

Populate it in `prepareCurrentAndNext()` and `advanceSlide()` alongside existing next-item loading.

Then in `MetalSlideshowRenderer.swift`, calculate motionTotal per slot:

```swift
let motionTotal: Double
if slot == .current {
    motionTotal = playerState.currentHoldDuration + (2.0 * SlideshowPlayerState.transitionDuration)
} else {
    motionTotal = playerState.nextHoldDuration + (2.0 * SlideshowPlayerState.transitionDuration)
}
```

### Files to Change

- `SlideshowPlayerView.swift` — Add `nextHoldDuration` property, compute in `prepareCurrentAndNext()` and `advanceSlide()`
- `MetalSlideshowRenderer.swift:800` — Use per-slot motionTotal

## Bug: Export Video Time Offset

### The Problem

In `ExportCoordinator.loadTexture()` (line 585):

```swift
let videoTime = max(0, frameTime - entry.startTime)
```

This calculates video playback position from when B's cycle starts. But the video actually starts playing during A's outgoing transition (2s before B's cycle starts). The first 2s of video frames are never shown during the transition — instead, frame 0 is shown as a static frame. This is the "static frame during transition" bug observed in testing.

### The Fix

When loading a video texture during the transition (where B is "next"), account for the fact that B's video has been playing since the transition started:

```swift
// When this video is the "next" during a transition, it starts playing at the
// beginning of the previous slide's transition phase
let videoTime: Double
if frameTime < entry.startTime {
    // We're in the previous slide's transition — video just started
    videoTime = frameTime - (entry.startTime - Self.transitionDuration)
} else {
    // We're in this slide's own cycle — add the incoming transition time
    videoTime = (frameTime - entry.startTime) + Self.transitionDuration
}
```

### Files to Change

- `ExportCoordinator.swift:581-586` — `loadTexture()` video time calculation

## Summary: Recommended Fix Order

1. **holdDuration fix** — Root cause of video looping. Simple, high impact.
2. **Ken Burns zoom snap** — Requires adding `nextHoldDuration` to player state. Medium complexity.
3. **Export video time offset** — Fixes static frame during transition in export. Medium complexity.
4. All three should be done together since they interact (holdDuration change affects zoom calculation).

# Manual Testing Checklist

## Playback & Export — ALL PASSING (11 Feb 2026)

All playback and export tests pass for locally-present media (both Filesystem and Photos Library sources). The following were verified after Fixes 1-11:

- Play in Full: correct duration, zoom speed, short video looping, audio timing
- Transitions: photo-photo, photo-video, video-photo, video-video — all smooth (crossfade, zoom, pan & zoom, plain)
- Export: correct video frames, audio timing, rotation, mixed sources
- Edge cases: single photo loop, single video loop, music + video audio, rapid arrow key navigation

**Not tested**: iCloud content (see iCloud test table below).

## Transition Stress Tests — ALL PASSING (11 Feb 2026)

| Test                              | Status                                              |
| --------------------------------- | --------------------------------------------------- |
| Photo→Photo crossfade             | PASS                                                |
| Photo→Video crossfade             | PASS (was broken, fixed by VideoTextureSource swap) |
| Video→Photo crossfade             | PASS                                                |
| Video→Video crossfade             | PASS                                                |
| Any transition with panAndZoom    | PASS                                                |
| Plain (no transition) with videos | PASS                                                |

## Edge Cases — ALL PASSING (11 Feb 2026)

| Test                        | Status                                   |
| --------------------------- | ---------------------------------------- |
| Single photo slideshow      | PASS — Loops with Ken Burns              |
| Single video + Play in Full | PASS — Plays full, loops                 |
| Music + video with sound    | PASS — Both audible, no glitches         |
| iCloud content              | NOT TESTED — see iCloud test table below |

---

## iCloud Handling Test Table

**Purpose**: Identify all iCloud-related issues before improving iCloud codepaths.

**Setup**: To test, ensure some Photos Library items are in iCloud (not downloaded locally). You can check in Photos.app → select item → File → Show Referenced File in Finder. Optimized/iCloud items won't have a local file. Alternatively, enable "Optimize Mac Storage" in Photos → Settings → iCloud to force some items to iCloud-only thumbnails.

**Known code issues from audit** (see "Photos Library vs Filesystem: Inconsistencies" section above):

- `isNetworkAccessAllowed = true` with no timeout — callbacks may never fire
- No per-item download progress shown in grid UI
- Temp video files may accumulate if download/export is interrupted

### Import & Grid Display

| #    | Test                                           | Steps                                             | Expected                                                                                       | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ---- | ---------------------------------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IC-1 | Import iCloud photo (Photos Library)           | Add a photo that is iCloud-only via Photos picker | Photo appears in grid. Should show placeholder/spinner while downloading, then full thumbnail  | Dragging an offloaded picture:<br/>1. the thumbnail appears immediately (with no progress)<br/>2. If I Preview, it shows a spinner and eventually resolves.<br/>Note that if I cut Wifi, then import, the thumbnail appears, but Preview never resolves. <br/><br/>Overall photos download very quickly, so it's hard to see the bug (but it's there)                                                                                                                                                |
| IC-2 | Import iCloud video (Photos Library)           | Add a video that is iCloud-only via Photos picker | Video appears in grid. Should show placeholder/spinner while downloading, then video thumbnail | Same as Photo - thumbnails appear immediately (with correct mm:ss stamp) but no progress is shown in the view... Preview will show them downloading and eventually resolve.  But if I cut Wifi they never resolve.                                                                                                                                                                                                                                                                                   |
| IC-3 | Import mix of local + iCloud items             | Select 5+ items, some local, some iCloud-only     | Local items appear immediately. iCloud items download in background. No items silently dropped | This works -- the local ones appear immediately; the iCloud ones show as blank-frame-with-spinner.  Eventually they resolve.  Preview works the same (shows spinner and eventually shows the image).  NOTE that the Preview 'spinner' state is a bit wonky because there is no 'default' picture... so the spinner is centered but there's no frame to anchor the other controls that would normally be on top of the image.  So might be good to add a placeholder Media item (with spinner on top) |
| IC-4 | Import iCloud items with no network            | Disable Wi-Fi, then add iCloud-only items         | Should show error or spinner that doesn't resolve. App should NOT hang or crash                | No hangs or crashes.<br/><br/>With WiFi Off, adding a photo from iCloud (filesystem) shows a spinner, which quickly resolves into a 'vanilla photo item' (probably should be a photo/strikethrough or similar).  Preview also shows 'vanilla photo item'.  Playback shows nothing for playback_duration.  Turning WiFi back ON will eventually resolve the photo for Preview and Playback (but the thumbail does not auto-resolve and remains vanilla-photo)                                         |
| IC-5 | Import iCloud items, lose network mid-download | Start import with Wi-Fi on, disable mid-download  | Download should fail gracefully. Items should show error state, not hang indefinitely          | graceful failure -- behaviors consistent with the above in terms of what happens to individual items.  but no hangs.                                                                                                                                                                                                                                                                                                                                                                                 |

### Playback

| #     | Test                                            | Steps                                             | Expected                                                                                                                                | Result                                                                                                                                                                                                       |
| ----- | ----------------------------------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| IC-6  | Play slideshow with iCloud photo                | Slideshow includes an iCloud-only photo           | Photo should download and appear. If slow, should show placeholder (not black/hang). Ken Burns should work once loaded                  | The photo downloads and plays... but if it has not downloaded (e.g. cut Wifi), it simply displays NOTHING for the playback-duration... Might be good to slow a placeholder "Media Not Available" or similar. |
| IC-7  | Play slideshow with iCloud video                | Slideshow includes an iCloud-only video           | Video should download and play. Audio should work. If slow to download, transition should not freeze (renderer has opacity safety nets) | Video gets added as thumbnail (no spinner).  Hit Play -> nothing happens, it does render... then at some point it finishes downloading and starts rendering.  No freezes.                                    |
| IC-8  | Play slideshow with iCloud video + Play in Full | Same as IC-7 but with Play in Full ON             | Video should play for its full intrinsic duration after download completes                                                              | Same as IC-7                                                                                                                                                                                                 |
| IC-9  | Play slideshow — all items iCloud               | Every item is iCloud-only                         | App should eventually play after downloads. Should not hang indefinitely. Ideally shows download progress                               | Same as IC-7                                                                                                                                                                                                 |
| IC-10 | Play slideshow — iCloud + no network            | Disable Wi-Fi before playing                      | Playback should fail gracefully. Should not hang. Should show some error/feedback                                                       | Same as IC-7                                                                                                                                                                                                 |
| IC-11 | Play slideshow — iCloud + slow network          | Throttle network (e.g., Network Link Conditioner) | Items should eventually load. Transitions should not freeze while waiting for downloads. Music should keep playing                      | could not test                                                                                                                                                                                               |

### Export

| #     | Test                                        | Steps                                                      | Expected                                                                                    | Result |
| ----- | ------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ------ |
| IC-12 | Export with iCloud photo                    | Export slideshow containing an iCloud-only photo           | Photo should be downloaded before/during export and included correctly                      |        |
| IC-13 | Export with iCloud video (Play in Full OFF) | Export with an iCloud-only video, Play in Full OFF         | Video should download, export for slideDuration with audio                                  |        |
| IC-14 | Export with iCloud video (Play in Full ON)  | Export with an iCloud-only video, Play in Full ON          | Video should download, export for full intrinsic duration with audio                        |        |
| IC-15 | Export with iCloud video — no network       | Disable Wi-Fi, then export                                 | Export should fail gracefully with error message, not hang. Temp files should be cleaned up |        |
| IC-16 | Export cancel during iCloud download        | Start export, then cancel while iCloud item is downloading | Export should cancel cleanly. Temp files cleaned up. No orphaned downloads                  |        |

### Face Detection & Thumbnails

| #     | Test                           | Steps                                             | Expected                                                                              | Result                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| ----- | ------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| IC-17 | Face detection on iCloud photo | Import iCloud photo, check if face detection runs | Should download photo, then run face detection. Should not block other items in queue | Face detection works with iCloud photos if they download quickly...  so drag iCloud photo from Photos Library, it gets a thumbnail instantly (no wait), downloads, and when I hit Play I see the correct face detection squares. <br/><br/>However, I add an iCloud photo from iCloud, then cut Wifi before it downloads, the it will not Play (blank)... I then turn Wifi Back on, the photo downloads and plays but without face detection. |
| IC-18 | Thumbnail for iCloud video     | Import iCloud video, scroll grid                  | Thumbnail should appear after download. Should show placeholder while downloading     | There is no face-detection for Videos -- so this case is equivalnt to previous cases, Video comes in with thumbnail IMMEDIATELY but without a spinner.   Ideally it would eihter show 'blank + spinner' or 'thumbnail + spinner'                                                                                                                                                                                                              |

### Save/Load with iCloud Items

| #     | Test                                   | Steps                                                                                          | Expected                                                                                          | Result |
| ----- | -------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------ |
| IC-19 | Save .softburn with iCloud items       | Import iCloud items, save document                                                             | Should save successfully. Security-scoped bookmarks should be created for downloaded content      |        |
| IC-20 | Load .softburn — items moved to iCloud | Save with local items, then enable "Optimize Mac Storage" so items move to iCloud, then reopen | Items should re-download on open. Face detection cache should still be valid (stored in document) |        |

### Temp File Cleanup

| #     | Test                            | Steps                                                                      | Expected                                                                         | Result |
| ----- | ------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------ |
| IC-21 | Temp video files after playback | Play slideshow with iCloud videos, stop, check `/tmp/SoftBurnVideoExport/` | Temp files should be cleaned up after playback ends                              |        |
| IC-22 | Temp video files after crash    | Force-quit app during iCloud video playback, check temp dir                | Temp files will remain (known issue). Note size/count for cleanup prioritization |        |
