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
