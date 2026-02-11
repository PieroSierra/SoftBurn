# Media Hangling Bugs

## Media Importing Issues

| MEDIA PLAYBACK | Filesystem                                                                   | Photos Library                                                                                                                                                                                     |
| -------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Photo, present | works, shows up immediately                                                  | works, shows up immediately                                                                                                                                                                        |
| Photo, iCloud  | triggers download; spinner shown while iCloud downloads, then refreshes view | photo downloads, eventually works.  But I can't see the spinner.  We should be triggering the download but adding a spinner in the UI                                                              |
| Video, Present | works, shows up immediately                                                  | works, shows up immediately                                                                                                                                                                        |
| Video, iCloud  | triggers download; spinner shown while iCloud downloads, then refreshes view | video downloads, eventually works.  But I can't see the spinner.  Preview (before video downloaded) show a spinner if invoked. We should be triggering the download but adding a spinner in the UI |

## Media Playback Known Issues

1. Single-frame Stutter after 2s of playback
* transition from A to B 'stops' for 1 frame... minor but annoying.
* Auto stutters noticeably interrupted - major problem
* We have attempted to fix this numerous times (see other notes), and the current state is the best we've achieved.

2. ~~Play in Full video playback does not work  - videos only play for the n seconds of the regular slideshow setting~~ **FIXED** (11 Feb 2026)

3. **Playback frame drop after incoming transition** — During live playback, when a video transitions from "next" to "current" (after the 2s crossfade completes), there is a brief visible glitch/frame drop. The video and zoom continue correctly after. This is related to the async `advanceSlide()` race window described in the stutter analysis below. **Open — fix later.**

## Export Issues

| VIDEO EXPORT                      | Filesystem | Photos Library |
| --------------------------------- | ---------- | -------------- |
| Photo, present                    |            |                |
| Photo, iCloud                     |            |                |
| Video, Present (play in full OFF) |            |                |
| Video, iCloud (play in full OFF)  |            |                |
| Video, Present (play in full ON)  |            |                |
| Video, iCloud (play in full ON)   |            |                |

To be tested -- but I believe the same audio issues apply.

---

# Code Audit: Media Handling & Playback (February 2026)

Deep code review of the media pipeline — import, playback, transitions, and export — with attention to interactions between filesystem/Photos Library sources, photo/video types, iCloud state, and settings combinations.

## How the Playback Pipeline Works

Understanding the timer model and texture lifecycle is necessary context for the bugs below.

### Three-Phase Slide Cycle

Each slide goes through three phases controlled by two timers:

```
Phase 1 (Hold):       0 ≤ animationProgress < transitionStart
Phase 2 (Transition): transitionStart ≤ animationProgress < 1.0
Phase 3 (Race):       animationProgress ≥ 1.0, waiting for advanceSlide()
```

- **Slide timer** — fires once after `totalSlideDuration` (hold + 2s transition), triggers async `advanceSlide()`
- **Animation timer** — fires at 60fps, increments `animationProgress` from 0.0 to 1.0

`totalSlideDuration = currentHoldDuration + transitionDuration` (2.0s for non-plain styles, 0 for plain).

Example with 5s hold + 2s transition = 7s total:

- Hold: 0.0 → 0.71 (5s)
- Transition: 0.71 → 1.0 (2s, crossfade/zoom)
- advanceSlide() promotes next→current, loads new next, resets to 0.0

### Slot Model

The renderer maintains two slots:

- **Current** — the visible media (photo texture or video player)
- **Next** — pre-loaded for the upcoming transition

On `advanceSlide()`: next is promoted to current, old current is released, new next is loaded async.

### Metal Rendering (Two-Pass)

1. **Pass 1 — Scene Composition**: Renders current + next layers to offscreen texture with opacity/scale/offset uniforms
2. **Pass 2 — Patina**: Applies film simulation (35mm/aged/VHS) or blits directly when patina=none

Opacity during transition is calculated from `animationProgress`, NOT from the `isTransitioning` flag (which can be out of sync).

---

## Confirmed Bug: "Play in Full" Broken for Photos Library Videos

**Severity: High** — Feature completely non-functional for Photos Library videos (both playback and export).

### Root Cause

`SlideshowPlayerView.swift:510`:

```swift
if playVideosInFull, let seconds = await VideoMetadataCache.shared.durationSeconds(for: item.url) {
    return seconds
}
return slideDuration
```

`ExportCoordinator.swift:393`:

```swift
private func getVideoDuration(_ item: MediaItem) async -> Double? {
    await VideoMetadataCache.shared.durationSeconds(for: item.url)
}
```

Both call `durationSeconds(for: URL)` — the **URL overload** (VideoMetadataCache.swift:49). This overload creates an `AVURLAsset` from the URL and loads its duration.

For Photos Library items, `item.url` returns a **synthetic URL**: `photos://asset/{localID}`. This is not a valid file URL. `AVURLAsset` cannot load from it, so `asset.load(.duration)` throws, `durationSeconds` returns `nil`, and `holdDuration` falls back to `slideDuration`.

`VideoMetadataCache` already has a correct overload at line 20:

```swift
func durationSeconds(for item: MediaItem) async -> Double?
```

This properly handles Photos Library videos by calling `PHAsset.duration`. But neither `SlideshowPlayerView` nor `ExportCoordinator` calls it.

### Impact

- **Playback**: Photos Library videos always play for `slideDuration` regardless of "Play in Full" setting
- **Export**: Same — exported videos truncated to `slideDuration`
- **Filesystem videos**: Work correctly (real file URL)

### Fix

Change both call sites to use the `MediaItem` overload:

- `SlideshowPlayerView.swift:510`: `durationSeconds(for: item)` instead of `durationSeconds(for: item.url)`
- `ExportCoordinator.swift:393`: `durationSeconds(for: item)` instead of `durationSeconds(for: item.url)`

### How to Test

1. Import a video from Photos Library (not filesystem)
2. Enable "Play in Full" in settings
3. Play slideshow — video should play for its intrinsic duration, not `slideDuration`
4. Export with "Play in Full" on — exported video should include full video duration

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

### High Priority (likely to expose bugs)

1. **Photos Library video + "Play in Full" ON** — Confirmed broken (see bug above). Test both playback and export.

2. **Photos Library video + iCloud (not downloaded) + Play** — Does the video eventually appear? Is there any feedback while downloading? What happens if you lose network mid-download?

3. **Mixed slideshow (photos + videos from both sources) + transitions** — Play a slideshow with alternating filesystem photos, Photos Library photos, filesystem videos, Photos Library videos. Watch for:
   
   - Stutter at video→photo transitions
   - Stutter at photo→video transitions
   - Missing frames when transitioning between sources

4. **Video→Video transitions** — Two consecutive videos with crossfade. The next video starts playing during transition (SlideshowPlayerView.swift:749-752). Watch for:
   
   - Audio overlap (both videos playing simultaneously during 2s transition)
   - Texture flash if second video hasn't decoded yet

5. **Export with Photos Library videos** — Export a slideshow containing Photos Library videos. Check:
   
   - Are video segments present in export?
   - Is video audio included?
   - With "Play in Full" ON vs OFF?

6. **All items iCloud + no network** — What happens? Does the app hang? Show errors? Skip items?

### Medium Priority

7. **Single video slideshow + "Play in Full" ON** — Does the video loop? Next index wraps to itself: `(0+1) % 1 = 0`.

8. **Single photo slideshow** — Same wrapping logic. Should display indefinitely with Ken Burns motion.

9. **Plain transition style + videos** — With `transitionStyle = .plain`, `transitionDuration = 0` and `totalSlideDuration = holdDuration` only. Verify instant cut works cleanly.

10. **Large slideshow (100+ items) + "Play in Full" ON** — Memory usage. Face detection cache and thumbnail cache are both unbounded (`[String: [CGRect]]` and similar dicts). Check for memory growth over time.

11. **Export cancel mid-way** — Does cleanup happen? Is the incomplete output file deleted? (Current code does NOT delete the output file on cancel — ExportCoordinator.cleanup() only removes temp audio/video intermediates.)

12. **File deleted during playback** — Import a filesystem photo, start playback, delete the file externally. The texture is cached so current play continues, but what happens on the next loop?

### Lower Priority

13. **Music + video audio interaction** — Background music plays via MusicPlaybackManager. Video audio plays via AVPlayer. They are independent. Verify volume levels make sense when both play simultaneously.

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

`installLoopObserver()` adds a NotificationCenter observer for `AVPlayerItem.didPlayToEndTimeNotification`. Observers are cleaned up in `advanceSlide()` and `stop()`. But if `advanceSlide()` throws or is interrupted, an observer could leak. The observer closure captures `self` weakly, so it won't prevent deallocation, but it could fire unexpectedly on a stale player.

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

Fill in results after running the app with the fixes applied.

## "Play in Full" Verification

| Test                                            | Expected                                             | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | After 11 Feb Fixes                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Filesystem video, Play in Full ON, playback     | Video plays for its full duration                    | Video plays full duration (good).<br/><br/>Note that this reveals a further bug: animation is broken -- when the crossfade from A to B happens, the video (B) is zooming in fast, at the speed of the regular transition (which I had set to 5s).  But, when the cross-fade is complete, the video 'snaps' to a new size and then proceeds to fade very slowly (the video was 12m long).  When playing a video, we need to calcuate the speed of the video zoom based on the total length of the video (if "Play in Full" is set) and only then start cross-fading.                                                                                              | Videos play full duration, timings all work.<br/><br/>Note that very short videos that are shorter than the transition_duration (I have one that is 1s) will play for just 1s when in Play in Full is on, but Loop when Play in Full is Off.  I would prefer these to loop for the full (2s + transition_duration + 2s) to avoid any timing issues. |
| Photos Library video, Play in Full ON, playback | Video plays for its full duration (was broken)       | Works, video plays full length with sound. But there's two bugs:<br/>1.When going from Photo A to Video B, Video B starts transitionning and playing and zooming in quickly... but then the video iself is long (52s)so after the 2s transtion, the video 'snaps' to a different size and zooms SLOWLY now (since zooom/52s), then goes back to fast zoom for the last 2s transtion... the speed of zoom needs to be based on the TOTAL playback length (including 4s of transitions).  Also when first trasntion completes, the audio stutters<br/>2. when the full video plays (52s), for the last 2s transition it loops (need to calculate length correctly) | Videos play full duration, timings all work.<br/><br/>Note that I did not test very short videos, but I assume they will also "play once in full" instead of looping.  LIke for local FS videos, I would prefer them to loop for the duration.                                                                                                      |
| Filesystem video, Play in Full ON, export       | Exported segment matches video duration              | Setup is Photo A, Video B, Photo C (all from File System).  Works, with sound.  But bugs:<br/>1. during transition, video B shows as a static frame. after which it plays correctly with audio (thus 'skipping' the audio glitch)<br/>2.When Video B starts transitionning to Photo C, it loops (I see the beginning of B for 2 seconds, silently)                                                                                                                                                                                                                                                                                                               | export works and transition timings and zoom are correct. <br/><br/> However, the sound timings are off:  the sound for a video doesn't start until AFTER the 2s entry transition and continues PAST the 2s exit transition by 2s.  So we're basically offset by 2s.                                                                                |
| Photos Library video, Play in Full ON, export   | Exported segment matches video duration (was broken) | Setup is Photo A, Video B, Photo C (all from Photos Library).  Works, with sound.  But bugs:<br/>1. during transition, video B shows as a static frame. after which it plays correctly with audio (thus 'skipping' the audio glitch)<br/>2.Video B is exported as Rotated (but it plays fine in the Playback)<br/>                                                                                                                                                                                                                                                                                                                                               | export works and transition timings and zoom are correct. <br/><br/> However, the sound timings are off:  the sound for a video doesn't start until AFTER the 2s entry transition and continues PAST the 2s exit transition by 2s.  So we're basically offset by 2s.                                                                                |
| Mixed (both sources), Play in Full ON, playback | Each video plays for its own duration                | Works, with sound, but with the same issues as above.  During transtion from video A(FS) to video B(Photo library)<br/>1. video A ends before the 2s transtion and loops<br/>2. video B transitions  as a static frame, and only starts playing after the transition is complete (with sound)<br/>3. Video B is exported as Rotated (but it plays fine in the Playback)                                                                                                                                                                                                                                                                                          | did not test                                                                                                                                                                                                                                                                                                                                        |

## Export Matrix

For each cell, note: works / broken / partial (describe):

| VIDEO EXPORT                      | Filesystem | Photos Library |
| --------------------------------- | ---------- | -------------- |
| Photo, present                    |            |                |
| Photo, iCloud                     |            |                |
| Video, present (play in full OFF) |            |                |
| Video, iCloud (play in full OFF)  |            |                |
| Video, present (play in full ON)  |            |                |
| Video, iCloud (play in full ON)   |            |                |

## Transition Stress Tests

| Test                              | Watch for                    | Result |
| --------------------------------- | ---------------------------- | ------ |
| Photo→Photo crossfade             | Stutter at boundary          |        |
| Photo→Video crossfade             | Stutter or black flash       |        |
| Video→Photo crossfade             | Audio cutoff timing          |        |
| Video→Video crossfade             | Audio overlap, texture flash |        |
| Any transition with panAndZoom    | Motion freeze at boundary    |        |
| Plain (no transition) with videos | Clean instant cut            |        |

## Edge Cases

| Test                                   | Expected                        | Result |
| -------------------------------------- | ------------------------------- | ------ |
| Single photo slideshow                 | Loops with Ken Burns            |        |
| Single video + Play in Full            | Plays full, loops               |        |
| All items from iCloud (not downloaded) | Downloads, eventually plays     |        |
| Music + video with sound               | Both audible, reasonable levels |        |
