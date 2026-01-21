# SPEC: Export as Video

## Objective

Implement **Export as Video** as a deliberate, blocking operation that renders the current slideshow—using the same visual and timing semantics as **Play**—into a self-contained QuickTime video file.

The exported video must visually and temporally match what the user sees when playing the slideshow in-app.

---

## User Mental Model

- **Play** = preview / experience the slideshow
- **Save Slideshow** = persist the editable project
- **Export as Video** = produce a final, shareable artifact

Export is **not** playback and **not** a background task.

---

## Entry Point

**Toolbar**

Let's create a File menu, move Save and Open into it, and create a new "Export as Video" entrypoint:

`(icon:folder) File →`

`├ (icon:square.and.arrow.down) Save Slideshow…`

`├ (icon:folder) Open Slideshow...`

`└ (icon:film.stack) Export as Video ▸`



---

## Export Presets (v1)

On selecting **Export as Video**, present a submenu with fixed presets:

`Export as Video → `

`├ (icon:square.and.arrow.down) QuickTime (1080p)…`

`├ (icon:square.and.arrow.down) QuickTime (720p)… `

`└ (icon:square.and.arrow.down) QuickTime (480p)…`

### Notes

- QuickTime `.mov` only (v1)
- No codec, bitrate, or frame-rate controls exposed in v1
- Presets exist to keep scope limited and UX simple
- Default / recommended preset: **1080p**

---

## Save Location

After preset selection:

- Present standard macOS **Save Panel**

- Default filename:
  
    `<Slideshow Name> – 720p.mov`

- Default directory:
  
  - Last export location, or
  - Movies folder

- File extension fixed by preset

Canceling the save panel aborts export with no side effects.

---

## Export Execution Model

### App State

Once the user confirms the save location:

- App enters **Export Mode**
- All editing and playback interactions are disabled
- The slideshow canvas and controls are visually dimmed or hidden
- The app presents a **full-app modal overlay**

Export is **blocking** by design.

---

## Export Modal UI

### Contents

- Title: **Exporting Video**

- Subtitle:
  
    `<Slideshow Name> – 720p`

- Progress indicator:
  
  - Determinate if feasible
  - Indeterminate otherwise

- Optional detail text (best effort):
  
  - Frame counts, elapsed time, or phase (“Rendering…”, “Encoding…”)

### Controls

- **Cancel** (always available)

### Behaviour

- Cancel:
  - Stops rendering immediately
  - Cleans up any partial output file
  - Returns the app to normal editable state
- Completion:
  - Modal dismisses automatically
  - Optional confirmation:
    - “Export Complete”
    - Button: **Reveal in Finder**

---

## Rendering Requirements

### Visuals

- Exported output must match **Play** behaviour exactly:
  - Same ordering
  - Same durations
  - Same transitions
  - Same effects
- Rendering is frame-based (offline), not screen capture
- Reuse the existing **Metal rendering pipeline** where possible
- Target resolution:
  - 720p or 480p depending on preset
- Frame rate:
  - Use the app’s existing playback frame rate, or
  - A fixed rate if already defined elsewhere

---

### Audio

> **⚠️ AUDIO CURRENTLY DISABLED (January 2026)**
>
> Exported videos are **silent**. Background music and video audio are not included.
> See "Known Issues & Limitations" section for technical details and future fix plan.

The spec below describes the *intended* behavior when audio is re-enabled:

- Audio is rendered **offline**, not in real time
- Export includes:
  - Background music (if enabled)
  - Audio tracks from video clips (if enabled)
- Audio is mixed into a **single stereo track**
- Audio timing must remain in sync with rendered frames

⚠️ Do not rely on system audio capture.

All audio must come from sources already managed by the app.

---

## Technical Assumptions (Non-Binding)

- The Metal pipeline currently renders frames to screen during Play
- Export may “hijack” or re-route this pipeline to render into:
  - An off-screen render target
  - Then encode frames into a QuickTime movie
- Audio may need to be:
  - Buffered and mixed separately
  - Or rendered in parallel with frame generation

The Agent is expected to:

- Inspect the existing pipeline
- Propose a viable rendering + encoding strategy
- Identify gaps or constraints
- Ask clarifying questions before implementation if needed

---

## Error Handling

### Possible failures

- Disk write failure
- Insufficient disk space
- Rendering pipeline error
- Audio encoding error

### Behaviour

- Abort export
- Present a human-readable error alert
- Ensure partial files are cleaned up
- Return app to editable state

---

## Explicit Non-Goals (v1)

- Background exporting while editing
- Custom resolutions
- Codec selection
- Bitrate or quality sliders
- Sharing destinations
- Batch export

These may be revisited in future iterations.

---

## Agent Instructions

You are expected to:

1. Review the existing rendering and playback architecture
2. Determine how best to reuse or adapt the Metal pipeline for offline export
3. Propose an implementation plan that:
   - Preserves visual parity with Play
   - Correctly synchronizes audio
4. Identify any technical unknowns or constraints
5. Ask targeted questions **before** implementing if assumptions are invalid

---

## Implementation Notes (January 2026)

### Architecture Overview

The export feature is implemented across these files:

| File | Purpose |
|------|---------|
| `ExportCoordinator.swift` | Main orchestrator - builds timeline, renders frames, writes video |
| `OfflineSlideshowRenderer.swift` | Metal renderer for export - reuses shader pipelines from `MetalSlideshowRenderer` |
| `AudioComposer.swift` | Composes background music + video audio (currently unused - audio disabled) |
| `VideoFrameReader.swift` | Extracts frames from video clips at specific timestamps |
| `ExportPreset.swift` | Defines 720p/480p presets with codec settings |
| `ExportProgress.swift` | Observable progress state for UI |
| `ExportModalView.swift` | Modal UI during export |

### Rendering Pipeline

1. **Timeline Building**: `ExportCoordinator.buildTimeline()` creates `SlideEntry` array with:
   - Start time, hold duration, transition duration for each slide
   - Face detection boxes (for Ken Burns zoom targets)
   - Random start/end offsets for pan motion

2. **Frame Rendering**: For each frame at time `t`:
   - `findSlides(at: t)` returns current slide, next slide, and animation progress
   - `loadTexture()` loads photo textures or extracts video frames
   - `calculateTransform()` computes Ken Burns scale/offset based on motion progress
   - `OfflineSlideshowRenderer.renderFrame()` executes two-pass Metal pipeline:
     - Pass 1: Scene composition (media layers with transforms, opacity, color effects)
     - Pass 2: Patina post-processing (grain, scratches, vignette) or direct blit

3. **Video Writing**: `AVAssetWriter` with pixel buffer adaptor appends rendered frames

### Audio Pipeline (DISABLED)

Audio encoding is currently disabled due to AVAssetWriter hang issues with sequential writing pattern. See "Known Issues & Limitations" section for details.

When re-enabled, the pipeline will:

1. **Composition**: `AudioComposer` creates `AVMutableComposition` with:
   - Background music track (looped to fill duration)
   - Video audio tracks (inserted at slide start times)

2. **Mixing**: `AVAssetReaderAudioMixOutput` mixes all tracks with volume fades

3. **Export**: `AVAssetWriter` encodes mixed PCM to AAC in temp M4A file

4. **Integration**: Main export reads temp M4A and writes samples interleaved with video frames

### Ken Burns Motion Timing

The motion calculation ensures smooth continuity when slides transition from "next" to "current" slot:

```
motionTotal = incomingTransition + holdDuration + outgoingTransition
motionElapsed = cycleElapsed + incomingTransition  (for current slot)
motionElapsed = transitionProgress * incomingTransition  (for next slot)
```

For the last slide (no outgoing transition), `outgoingTransition = 0`, which is correctly handled.

### Photos Library Support

- **Photos**: Use `PhotosLibraryImageLoader.loadFullResolutionCGImage()` → Metal texture
- **Videos**: Use `PHAssetResourceManager.writeData()` to export to temp file, then use `VideoFrameReader`

---

## Known Issues & Limitations

### Audio Export (DISABLED - January 2026)

**Status**: Audio encoding is temporarily disabled.

**Root Cause**: The sequential audio/video writing pattern causes AVAssetWriter to hang indefinitely. The original implementation wrote all video frames first, then attempted to write audio samples after marking video input as finished. This fails because:

1. AVAssetWriter expects **interleaved writes** with overlapping time ranges
2. After `videoInput.markAsFinished()`, the writer's timeline state changes
3. `audioInput.isReadyForMoreMediaData` never becomes true
4. The infinite polling loop (`while !isReadyForMoreMediaData`) has no escape condition

The hang occurs at exactly frame 36 (1.2 seconds at 30fps), which is when the audio writing loop starts executing.

**Note**: This issue has NOTHING to do with Photos Library videos. It affects any export with sound/music enabled, even with only filesystem photos.

**Workaround**: Audio encoding has been removed from `ExportCoordinator`. Exported videos are silent.

**Future Fix**: Implement proper interleaved audio/video writing:
1. Pre-compose audio to temp file (AudioComposer already works)
2. Create a combined timeline with both video frames and audio samples sorted by presentation time
3. Write samples to appropriate input in timestamp order
4. Both inputs receive data concurrently (overlapping time ranges)
5. Mark both as finished, then `finishWriting()`

### Video Playback Timing

Videos play from the beginning of their slide's cycle. There's no support for:
- Starting video at a specific offset
- Looping short videos
- Speed adjustment

### Memory Usage

Large slideshows with many high-resolution photos may consume significant memory. Consider:
- Texture caching limits
- Releasing textures after use
- Progress-based memory cleanup

---

## Testing Checklist

- [x] Export with filesystem photos only (works, silent)
- [x] Export with Photos Library photos only (works, silent)
- [x] Export with filesystem videos (works, video plays, silent)
- [x] Export with Photos Library videos (works, video plays, silent)
- [ ] Export with various transition styles (plain, crossfade, zoom)
- [ ] Export with patina effects (35mm, aged film, VHS)
- [ ] Export with color effects (monochrome, silvertone, sepia)
- [x] Cancel during export (works - stops immediately)
- [ ] Export very long slideshow (memory stability)

**Verified January 2026**: Export completes without hanging. No audio in output (as expected with audio disabled).

