# Research: Rename Files to Sequence

**Branch**: `007-rename-to-sequence` | **Date**: 2026-03-01

---

## 1. How filesystem vs. Photos Library items are distinguished

**Decision**: Use `MediaItem.source` enum — no new flag needed.

`MediaItem.source` is already a discriminated enum:
```swift
enum Source: Codable, Sendable, Hashable {
    case filesystem(URL)
    case photosLibrary(localIdentifier: String, cloudIdentifier: String?)
}
```

A computed property `isFromPhotosLibrary` exists and returns `true` for `.photosLibrary` items.

**Rationale**: The distinction is already in the model. No new tracking variable is needed in `SlideshowSettings`.

**Alternatives considered**: A `hasPhotoLibraryItems` flag on `SlideshowSettings` — rejected because it would duplicate information already derivable from `SlideshowState.photos`.

---

## 2. How to update a MediaItem's URL after a rename

**Decision**: Add `func updateFilesystemURL(id: UUID, newURL: URL)` to `SlideshowState`. The implementation creates a replacement `MediaItem` (preserving `id`, `kind`, `rotation`, `faceDetectionRects`) and swaps it into the `photos` array.

**Rationale**: `MediaItem.source` is a `let` constant (immutable by design, Sendable). The cleanest approach is to add a `withFilesystemURL(_ url: URL) -> MediaItem` helper on `MediaItem` that copies all other fields, then use it from `SlideshowState`.

**Alternatives considered**:
- Making `source` a `var` — rejected because it weakens the Sendable guarantee and breaks the immutable-value design used throughout the codebase.
- Replacing the entire `photos` array — rejected because it clears `selectedPhotoIDs` and is semantically too coarse.

---

## 3. Tracking Photos Library presence (for dialog warning)

**Decision**: Compute on-demand from `SlideshowState.photos` at the point of building the preview. No persistent flag.

```swift
let hasPhotosLibraryItems = slideshowState.photos.contains { $0.isFromPhotosLibrary }
```

**Rationale**: This is a one-time computation when opening the dialog. No reason to maintain a cached flag.

---

## 4. File menu structure — where to add the new item

**Decision**: Add "Rename Files to Sequence..." button to the existing SwiftUI `Menu { }` block inside the `ToolbarItemGroup(placement: .navigation)` in `ContentView.swift`, after the "Save Slideshow..." button and before the `Divider()` that precedes "Export as Video".

**File**: `SoftBurn/Views/Main/ContentView.swift`

The File menu is a SwiftUI `Menu` label button within the LiquidGlass toolbar. The new item follows the same `Button(action:) { Label(...) }` pattern.

**Rationale**: Consistent with existing menu structure, positioned near "Save Slideshow" as specified (FR-001).

---

## 5. Security-scoped bookmark handling during rename

**Decision**: Call `startAccessingSecurityScopedResource()` on the old URL before `FileManager.moveItem`, call `stopAccessingSecurityScopedResource()` after (success or failure). After a successful rename, the in-session access via the renamed URL is valid without requiring a new bookmark — security-scoped access follows the open file descriptor, not the path. The `SlideshowDocument` bookmark cache (keyed by path string) will be regenerated correctly the next time the user saves.

**Rationale**: `FileManager.moveItem(at:to:)` is the correct macOS API for in-place renames on the same volume (no data copy). The sandbox entitlement allows writes to files already accessed via security-scoped bookmarks.

**Alternatives considered**: Re-creating bookmarks immediately after each rename — rejected as unnecessary for the current session; the next Save already handles this.

---

## 6. Rename API

**Decision**: `FileManager.default.moveItem(at: oldURL, to: newURL)` wrapped in a `do/try/catch`.

**Rationale**: Standard macOS file rename. Atomic on the same volume. `FileManager.moveItem` is not yet used in the codebase for renaming, but `.removeItem(at:)` and `.createDirectory` are already used, confirming `FileManager` is the established approach.

---

## 7. Cache invalidation after rename

**ThumbnailCache**: Keyed by URL. After rename, the old-URL entry becomes an orphan. It will be naturally evicted or ignored since the new URL will generate a fresh thumbnail on next scroll. **No explicit cache invalidation needed** — the renamed item is in the same position in the grid and its thumbnail will regenerate transparently.

**FaceDetectionCache**: Face detection rects are stored in the `.softburn` document and ingested back into `FaceDetectionCache` on load. Internally the cache is keyed by URL. After rename, the old key becomes stale. However, face rects are preserved on the `MediaItem` struct itself (via `faceDetectionRects`), so the data survives the rename. The cache will be re-populated correctly on next save/load cycle. **No explicit invalidation needed for correctness during the current session**.

---

## 8. `markDirty()` semantics

**Decision**: Call `AppSessionState.shared.markDirty()` once after the entire rename operation completes (or after each individual successful rename, following the per-mutation pattern already used in `SlideshowState`).

**Rationale**: Every mutation in `SlideshowState` calls `markDirty()`. The rename operation changes file paths (which are part of the `.softburn` document), so the document is dirtied.

---

## 9. Idempotent prefix stripping regex

**Decision**: Strip any prefix matching `/^\d{4}-/` from the filename (excluding extension) before applying the new prefix. Use `String` operations (no regex framework needed): check if the name component starts with 4 ASCII digits followed by `-`, then take the suffix from index 5 onward.

**Rationale**: Simple, deterministic, no regex overhead. Edge case (natural `\d{4}-` prefix in original filename) is a known, accepted limitation documented in FR-007.

---

## 10. Swift concurrency considerations

**Decision**: Rename execution runs on `@MainActor` (same as `SlideshowState`). `FileManager.moveItem` is synchronous and fast for in-place renames on the same volume. For large numbers of files, this could block the main thread briefly, but given the scale assumption (< 9999 files, rename is instantaneous per file), this is acceptable. A `Task { }` wrapper with `await MainActor.run {}` for state updates is an option if profiling reveals a problem — but not needed upfront.

**Alternatives considered**: Background actor for file operations — rejected for initial implementation (adds complexity, renames are fast, YAGNI).
