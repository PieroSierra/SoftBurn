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

`├ (icon:square.and.arrow.down) QuickTime (720p)… `

`└ (icon:square.and.arrow.down) QuickTime (480p)…`

### Notes

- QuickTime `.mov` only (v1)
- No codec, bitrate, or frame-rate controls exposed in v1
- Presets exist to keep scope limited and UX simple
- Default / recommended preset: **720p**

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
| `AudioComposer.swift` | Composes background music + video audio into temp M4A file |
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

### Audio Pipeline

1. **Composition**: `AudioComposer` creates `AVMutableComposition` with:
   - Background music track (looped to fill duration)
   - Video audio tracks (inserted at slide start times)

2. **Mixing**: `AVAssetReaderAudioMixOutput` mixes all tracks with volume fades

3. **Export**: `AVAssetWriter` encodes mixed PCM to AAC in temp M4A file

4. **Integration**: Main export reads temp M4A and writes samples to final MOV

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

### Photos Library Video Audio (UNRESOLVED)

**Symptom**: Export freezes when attempting to extract audio from Photos Library videos.

**Error Messages**:
```
Unable to obtain a task name port right for pid 431: (os/kern) failure (0x5)
AddInstanceForFactory: No factory registered for id <CFUUID> F8BB1C28-BAE8-11D6-9C31-00039315CD46
AudioQueueObject.cpp:3530  _Start: Error (-4) getting reporterIDs
```

**Root Cause Analysis**:
- The AudioQueue errors occur when certain AVFoundation operations trigger audio hardware initialization
- This appears to be a sandbox or entitlement issue on macOS
- The error occurs even when using `PHAssetResourceManager.writeData()` to export videos to temp files
- The video file itself is valid and can be read for video frames, but audio operations trigger the error

**Attempted Fixes**:
1. ✗ Using `PHAssetResourceManager` instead of `PHImageManager.requestAVAsset()` - still triggers error
2. ✗ Using `AVAssetWriter` instead of `AVAssetExportSession` for audio - still triggers error
3. ✗ Various audio reader settings (PCM conversion, etc.) - still triggers error

**Current Workaround**: None fully working. The code attempts to use `PHAssetResourceManager` but audio extraction from Photos Library videos still fails.

**Potential Future Solutions**:
1. Request additional entitlements (`com.apple.security.audio.capture`?)
2. Pre-export all Photos Library videos to temp files before audio processing begins
3. Use a different audio extraction API
4. Skip audio for Photos Library videos (graceful degradation)

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

- [ ] Export with filesystem photos only (should work)
- [ ] Export with Photos Library photos only (should work)
- [ ] Export with filesystem videos (should work including audio)
- [ ] Export with Photos Library videos (video frames work, audio fails)
- [ ] Export with background music (should work)
- [ ] Export with various transition styles (plain, crossfade, zoom)
- [ ] Export with patina effects (35mm, aged film, VHS)
- [ ] Export with color effects (monochrome, silvertone, sepia)
- [ ] Cancel during export
- [ ] Export very long slideshow (memory stability)

