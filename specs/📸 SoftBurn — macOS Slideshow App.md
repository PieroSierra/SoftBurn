# 🎬 SoftBurn — macOS Slideshow App

## 1. Product vision (read this first)

You are building a **macOS-native slideshow application** called **SoftBurn**.

SoftBurn is intentionally:

- Simple

- Folder-first

- Classy

- Safe (never deletes original photos)

- Reversible (undo everywhere)

- Designed for emotionally sensitive contexts (e.g. celebrations, farewells)

This is **not** a timeline editor, video editor, or pro photo tool.

There are no captions, no per-photo settings, no music (for now), no filters.

The mental model is:

> “Point the app at folders full of photos, tweak a few global settings, press Play.”

Mac conventions matter. Finder-like behavior is preferred over novelty.

---

## 2. Platform & tech constraints

- Platform: **macOS**

- UI: **SwiftUI**

- App type: **Document-based app**

- File type: custom single-file slideshow document (e.g. `.softburn`)

- Target: modern macOS (Apple Silicon assumed)

- Performance: must scale to **hundreds or thousands of photos**

Do **not** assume SwiftUI automatically handles image performance.

You must explicitly manage image loading.

---

## 3. High-level UI (reference the provided images)

The app has:

- A top toolbar

- A large central canvas showing a grid of photo thumbnails

### Toolbar buttons (with tooltips)

Left side:

- ➕ Add photos (files or folders)

- 💾 Save slideshow

- 📂 Open slideshow

Right side:

- 🗑 Remove from slideshow (removes selection only, never deletes files)

- ⚙︎ Slideshow settings

- ▶︎ Play

All buttons have tooltips.

---

## 4. App states

### Empty state

- Central canvas shows instructional text

- Canvas is a drag target

- Users can drag:

- Individual photos

- Folders of photos

### Imported state

- Grid of thumbnails

- Photo count visible in toolbar

- Thumbnails are reasonably dense (specify a thumbnail size, see performance section)

### Selected state

- Standard macOS multi-selection behavior

- Selected thumbnails outlined in blue

- Selection count shown in toolbar

- Trash button enabled only when selection exists

---

## 5. Photo import semantics (important)

- Adding photos or folders **adds links to files**, not copies

- Photos are not embedded

- Duplicate photos are allowed and intentional

- Same photo file can appear multiple times in the slideshow

### Missing files behavior

- On **Load**: missing files are silently ignored (not imported)

- On **Play**: missing files are skipped and removed from the slideshow

- No modal alerts; behavior is silent and non-blocking

---

## 6. Slideshow behavior (full spec — not all implemented yet)

### Global settings only

There are **no per-photo settings**.

Global settings include:

- Shuffle photos

- Style: Pan & Zoom | Cross-fade | Plain

- Zoom on faces

- Background color (color picker)

### Shuffle semantics

- Shuffle occurs **once per Play**

- Playback order remains stable during a session

- ESC exits playback

- Pressing Play again reshuffles if Shuffle is ON

- Playback loops endlessly

- Arrow keys move forward/back in the current playback order

### Face detection

- If a face is detected → zoom on face

- If no face → fall back to standard pan & zoom

- No warnings or UI changes

### Playback

- Full-screen on **primary display only**

- ESC exits

- Arrow keys interrupt timer and navigate manually

---

## 7. Performance requirements (very important)

SwiftUI lazy containers (e.g. `LazyVGrid`) **only manage view creation**, not image memory or decoding.

You must explicitly manage image performance.

### Grid thumbnails

- Use `LazyVGrid`

- Thumbnails must be:

- Generated asynchronously

- Approximately **300–400 px** on the longest edge

- Cached (memory cache is sufficient)

- Never decode full-resolution images for the grid

### Playback images

- Load **one full-resolution image at a time**

- Optionally preload the next image

- Release previous images immediately

- Thumbnail cache must not be reused for playback

---

## 8. File format (not implemented in Phase 1, but design for it)

- Single file slideshow document

- Stores:

- Ordered list of file URLs

- Global settings

- Metadata (title, creation date)

- Missing files handled gracefully as described above

---

## 9. Undo / safety

- CMD+Z undoes:

- Photo removal

- Reordering

- Removing a photo **never deletes the original file**

- Trash tooltip must make this clear

---

## 10. What NOT to build yet

Do **not** implement:

- Slideshow playback

- Settings UI

- Save / Open

- Face detection

- Shuffle logic

- Audio

- Timeline view

- Per-photo settings

Architect in a way that does not block these features later, but **do not implement them now**.

---

## 11. ✅ Phase 1 task (this is the only thing to build now)

### Goal

Get a **working macOS SwiftUI app** that can:

1. Launch successfully

2. Show the empty state UI

3. Allow users to:
- Click ➕ and select a **folder**

- Recursively discover photos in that folder
1. Display those photos as thumbnails in a grid

2. Support:
- Drag-and-drop folders or photos into the canvas

- Multi-selection

- Visual selection state
1. Load thumbnails asynchronously and efficiently

2. Remain responsive with large folders (hundreds of photos)

### Out of scope for Phase 1

- No save/open

- No playback

- No settings

- No undo (yet)

- No face detection

- No shuffle

---

## 12. Expectations

- Prefer clarity over cleverness

- Follow macOS conventions

- Comment non-obvious decisions

- Avoid premature abstraction

- Keep the architecture extensible

---

**End of prompt.**
