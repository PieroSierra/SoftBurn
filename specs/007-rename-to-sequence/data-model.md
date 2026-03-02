# Data Model: Rename Files to Sequence

**Branch**: `007-rename-to-sequence` | **Date**: 2026-03-01

---

## New Types

### `RenamePreviewItem`

A value type representing one row in the preview dialog. Computed once from `[MediaItem]` before the dialog is shown. Never mutated.

| Field | Type | Description |
|-------|------|-------------|
| `id` | `UUID` | Mirrors `MediaItem.id` — used to find the item in `SlideshowState` |
| `playbackIndex` | `Int` | 1-based position in the slideshow (display only) |
| `parentFolderDisplayName` | `String` | Last path component of the immediate parent folder, or `"Photos Library"` for library items |
| `currentFilename` | `String` | Last path component of the current URL (filename + extension) |
| `newFilename` | `String?` | Proposed new filename (e.g. `0003-photo.jpg`). `nil` for Photos Library items. |
| `currentURL` | `URL` | Full URL of the current file (used for `FileManager.moveItem`) |
| `newURL` | `URL?` | Full URL of the proposed new location. `nil` for Photos Library items. |
| `isPhotosLibrary` | `Bool` | `true` if this item cannot be renamed |

**Computed properties**:
- `isRenameable: Bool` → `!isPhotosLibrary && newFilename != nil`
- `parentFolder: URL?` → parent directory of `currentURL` (for filesystem items)

---

### `SequenceRenamer` (utility / namespace)

A stateless utility. No stored properties. One static method:

```
SequenceRenamer.buildPreview(for items: [MediaItem]) -> [RenamePreviewItem]
```

**Algorithm**:
1. Maintain `[URL: Int]` folder counter dictionary (keyed by parent folder URL).
2. For each `MediaItem` in order:
   - If `.photosLibrary`: produce `RenamePreviewItem` with `isPhotosLibrary = true`, `newFilename = nil`.
   - If `.filesystem(url)`:
     - `parentFolder` = `url.deletingLastPathComponent()`
     - Increment `folderCounters[parentFolder]` (default 0 → 1)
     - `seqNum` = current counter value (1-based)
     - `baseName` = `url.deletingPathExtension().lastPathComponent`
     - Strip leading `\d{4}-` from `baseName` if present (take suffix from index 5)
     - `ext` = `url.pathExtension`
     - `newFilename` = `String(format: "%04d-%@.%@", seqNum, baseName, ext)`
     - `newURL` = `parentFolder.appendingPathComponent(newFilename)`
     - Produce `RenamePreviewItem` with computed values.
3. Return the resulting array.

---

## Modified Types

### `MediaItem` (addition only)

Add a non-mutating helper method:

```
func withFilesystemURL(_ url: URL) -> MediaItem
```

Returns a copy of `self` with `source` replaced by `.filesystem(url)`. All other fields (`id`, `kind`, `rotationAngle`, `faceDetectionRects`) are preserved unchanged.

---

### `SlideshowState` (addition only)

Add one new method on `@MainActor`:

```
func updateFilesystemURL(id: UUID, newURL: URL)
```

- Finds the item with matching `id` in `photos`.
- Guards that the item's `source` is `.filesystem`.
- Replaces the item with `item.withFilesystemURL(newURL)`.
- Calls `AppSessionState.shared.markDirty()`.

---

## No New Persistence

The rename operation modifies files on the filesystem and updates the in-memory `[MediaItem]` array. No new fields are added to `SlideshowDocument` or `.softburn` format. The updated file paths are persisted naturally the next time the user saves via the existing bookmark regeneration mechanism.

---

## Entity Relationship

```
SlideshowState.photos: [MediaItem]
         │
         │ (read) ──── SequenceRenamer.buildPreview() ────► [RenamePreviewItem]
         │                                                          │
         │                                                          │ (displayed in)
         │                                                   RenameToSequenceView
         │                                                          │
         │ (updated via)                                            │ (on confirm)
         └──── SlideshowState.updateFilesystemURL(id:newURL:) ◄────┘
                          │
                          ▼
                FileManager.moveItem(at: oldURL, to: newURL)
```
