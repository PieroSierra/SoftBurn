# Quickstart: Rename Files to Sequence

**Branch**: `007-rename-to-sequence`

---

## Build & Run

```bash
# Build (Debug)
xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build

# Or open in Xcode (recommended during development)
open SoftBurn.xcodeproj
```

No new dependencies — all code uses built-in macOS frameworks (SwiftUI, Foundation, FileManager).

---

## Manual Testing Checklist

### Happy Path
1. Import photos from **two or more folders** with files in non-alphabetical order
2. Arrange them so files from the same folder are **interleaved** (e.g. FolderA/b, FolderB/x, FolderA/a)
3. File menu → "Rename Files to Sequence..."
4. Verify preview list:
   - Flat, in playback order (no folder headers)
   - Each row: `ParentFolder/filename → NNNN-filename`
   - FolderA files get `0001`, `0002` in encounter order
   - FolderB files get `0001`, `0002` independently
5. Click "Rename" → confirm in second alert
6. Verify files renamed on disk (Finder)
7. Verify app still plays in the same order

### Photos Library Items
1. Import a mix of filesystem files and Photos Library items
2. Open rename dialog
3. Verify:
   - Warning banner is visible at the top
   - Photos Library items appear in list with "will not be renamed" indicator (dimmed)
   - No Photos Library files are modified after confirm

### Idempotency
1. Run "Rename Files to Sequence" once → files become `0001-x.jpg`, `0002-y.jpg`
2. Reorder some items in the grid
3. Run again → files become `0001-y.jpg`, `0002-x.jpg` (no double prefix)

### Conflict
1. Manually create a file named `0001-photo.jpg` in a target folder (different from any slideshow file)
2. Run rename → verify error dialog names the conflicting file
3. Verify files renamed before the conflict retain their new names

### Cancel
1. Open dialog → click Cancel → no files renamed
2. Open dialog → click Rename → second alert appears → click Cancel → no files renamed

### Disabled State
1. Open a slideshow containing **only** Photos Library items → verify menu item is disabled
2. Open an empty slideshow → verify menu item is disabled

---

## Key Files

| File | Role |
|------|------|
| `SoftBurn/Views/Main/ContentView.swift` | File menu item + sheet trigger |
| `SoftBurn/Views/Main/RenameToSequenceView.swift` | Preview dialog (new) |
| `SoftBurn/Utilities/SequenceRenamer.swift` | Rename algorithm + `RenamePreviewItem` (new) |
| `SoftBurn/State/SlideshowState.swift` | `updateFilesystemURL(id:newURL:)` (new method) |
| `SoftBurn/Models/Models.swift` | `MediaItem.withFilesystemURL(_:)` (new helper) |
