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

- Audio is rendered **offline**, not in real time
- Export includes:
  - Background music (if enabled) - uses **musicVolume** setting with fade in/out
  - Audio tracks from video clips (if enabled) - always at **100% volume**
- Audio is mixed into a **single stereo track**
- Two-phase export: video rendered first, then muxed with audio

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

The export feature uses a **two-phase architecture** to avoid AVAssetWriter interleaved writing issues:

**Phase 1 - Render Video**: Metal pipeline renders frames to a temp video-only MOV file
**Phase 2 - Mux Audio**: AVMutableComposition + AVAssetExportSession combines video + audio

| File | Purpose |
|------|---------|
| `ExportCoordinator.swift` | Main orchestrator - builds timeline, coordinates phases, manages temp files |
| `OfflineSlideshowRenderer.swift` | Metal renderer for export - reuses shader pipelines from `MetalSlideshowRenderer` |
| `AudioComposer.swift` | Composes background music + video audio into temp M4A file with volume control |
| `VideoFrameReader.swift` | Extracts frames from video clips at specific timestamps |
| `ExportPreset.swift` | Defines 1080p/720p/480p presets with codec settings |
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

The audio pipeline uses a **two-phase export** approach to avoid AVAssetWriter interleaved writing issues:

1. **Composition**: `AudioComposer` creates `AVMutableComposition` with:
   - Background music track (looped to fill duration)
   - Video audio tracks (inserted at slide start times)

2. **Volume Control**: `AVMutableAudioMix` applies per-track volume:
   - **Music**: Uses `musicVolume` setting (0-100%) with 1.5s fade in, 0.75s fade out
   - **Video audio**: Always 100% volume (no fades)

3. **Pre-export**: `AVAssetReaderAudioMixOutput` mixes tracks → `AVAssetWriter` encodes to temp M4A (AAC stereo, 128kbps)

4. **Video Rendering**: `ExportCoordinator.renderVideoOnly()` renders frames to temp video-only MOV (H.264)

5. **Muxing**: `AVMutableComposition` + `AVAssetExportSession` (HighestQuality preset) combines:
   - Video track from temp MOV
   - Audio track from temp M4A
   - Output: Final MOV with both tracks

6. **Cleanup**: Temp files deleted after export completes

This approach separates video rendering from audio handling, leveraging AVFoundation's composition APIs which handle track muxing internally without timing issues.

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

### Photos Library Video Audio (Resolved History)

Previous issue (January 2026): Photos Library video audio extraction caused AudioQueue errors. This was resolved by pre-exporting Photos Library videos to temp files before audio composition.

---

## Testing Checklist

- [x] Export with filesystem photos only
- [x] Export with Photos Library photos only
- [x] Export with filesystem videos (video plays)
- [x] Export with Photos Library videos (video plays)
- [x] Export with background music only
- [ ] Export with video audio only (playVideosWithSound enabled)
- [ ] Export with background music + video audio
- [ ] Export without audio (no music, sound disabled) - should work as video-only
- [ ] Verify music volume setting is respected
- [ ] Export with various transition styles (plain, crossfade, zoom)
- [ ] Export with patina effects (35mm, aged film, VHS)
- [ ] Export with color effects (monochrome, silvertone, sepia)
- [x] Cancel during export (stops immediately, cleans up temp files)
- [ ] Export very long slideshow (memory stability)
- [ ] Verify audio sync matches playback

**Implementation**: Two-phase export (video render + audio mux) completed January 2026.

