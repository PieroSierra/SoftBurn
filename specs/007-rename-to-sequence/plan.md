# Implementation Plan: Rename Files to Sequence

**Branch**: `007-rename-to-sequence` | **Date**: 2026-03-01 | **Spec**: [spec.md](spec.md)

---

## Summary

Add a "Rename Files to Sequence..." menu item to the SoftBurn File menu. When invoked, the app computes new sequential filenames for all filesystem-sourced items in current playback order (per-parent-folder numbering, independent counters), presents a preview dialog with a flat playback-order list (Photos Library items shown with a skip indicator), requires two-step confirmation, then executes renames via `FileManager.moveItem` and updates in-memory state after each success. The operation is intentionally non-atomic: partial renames on failure are kept, view state is updated, and an error dialog identifies the failing file.

---

## Technical Context

**Language/Version**: Swift 5.9+ (Swift 6 compatible, strict concurrency)
**Primary Dependencies**: SwiftUI, AppKit, Foundation (`FileManager`) — all built-in macOS frameworks
**Storage**: In-memory `[MediaItem]` array in `SlideshowState`; filesystem files via `FileManager.moveItem`; security-scoped bookmarks (existing mechanism) for sandboxed access
**Testing**: XCTest (existing project test target)
**Target Platform**: macOS (macOS 26+ LiquidGlass toolbar; existing fallback paths untouched)
**Project Type**: Single macOS native app
**Performance Goals**: Preview generation instantaneous for ≤ 9999 items; rename of 100 files completes within 30 seconds (SC-001); error dialog surfaces within 2 seconds of failure (SC-004)
**Constraints**: App sandbox — must use security-scoped bookmarks; no external dependencies; `@MainActor` for all `SlideshowState` mutations; `FileManager.moveItem` runs synchronously on main thread (acceptable at this scale — see research.md §10)
**Scale/Scope**: Up to 9999 files per folder (4-digit prefix sufficient); typical slideshows 10–500 items

---

## Constitution Check

No project-specific constitution found — `constitution.md` contains only the unfilled template. No architectural gates to evaluate. Proceeding on the basis of CLAUDE.md conventions and established codebase patterns.

---

## Project Structure

### Documentation (this feature)

```text
specs/007-rename-to-sequence/
├── plan.md              ← This file
├── spec.md              ← Feature specification
├── research.md          ← Phase 0 research findings
├── data-model.md        ← Phase 1 data types
├── quickstart.md        ← Build + manual test guide
├── checklists/
│   └── requirements.md
└── tasks.md             ← Phase 2 output (/speckit.tasks)
```

### Source Code (within existing app)

```text
SoftBurn/
├── Views/
│   └── Main/
│       ├── ContentView.swift              ← Modified: menu item + sheet state
│       └── RenameToSequenceView.swift     ← New: preview dialog
├── Utilities/
│   └── SequenceRenamer.swift              ← New: algorithm + RenamePreviewItem type
├── State/
│   └── SlideshowState.swift               ← Modified: updateFilesystemURL(id:newURL:)
└── Models/
    └── Models.swift                       ← Modified: MediaItem.withFilesystemURL(_:)
```

**Structure Decision**: Single-project native macOS app. No new targets, no new packages. Feature is self-contained within 2 new files and minor additions to 3 existing files.

---

## Implementation Steps

### Step 1 — `RenamePreviewItem` and `SequenceRenamer` (new file: `Utilities/SequenceRenamer.swift`)

Create a new Swift file containing:

**`RenamePreviewItem`** — a `Sendable` value type with:
- `id: UUID` (mirrors `MediaItem.id`)
- `playbackIndex: Int` (1-based, display only)
- `parentFolderDisplayName: String` (last path component of parent, or `"Photos Library"`)
- `currentFilename: String` (last path component of current URL)
- `newFilename: String?` (`nil` for Photos Library items)
- `currentURL: URL` (needed for `FileManager.moveItem`)
- `newURL: URL?` (`nil` for Photos Library items)
- `isPhotosLibrary: Bool`

**`SequenceRenamer`** — namespace (caseless enum or struct with only static members):

```
static func buildPreview(for items: [MediaItem]) -> [RenamePreviewItem]
```

Algorithm (see data-model.md for full detail):
1. Maintain `[URL: Int]` folder counter, keyed by parent folder URL.
2. For each item: if Photos Library → skip indicator row. If filesystem → strip `\d{4}-` prefix from base name, increment folder counter, format `"%04d-\(baseName).\(ext)"`, produce row.
3. Return full array parallel to input.

**Prefix strip logic**:
- Get `baseName = url.deletingPathExtension().lastPathComponent`
- If `baseName.count > 5` and first 4 chars are ASCII digits and char at index 4 is `-`, then `baseName = String(baseName.dropFirst(5))`

---

### Step 2 — `MediaItem.withFilesystemURL(_:)` (modify: `Models/Models.swift`)

Add a non-mutating helper to `MediaItem`:

```
func withFilesystemURL(_ url: URL) -> MediaItem
```

Returns a new `MediaItem` with `source = .filesystem(url)` and all other fields copied from `self` (`id`, `kind`, `rotationAngle`, `faceDetectionRects`, etc.).

This is the only change to `Models.swift`.

---

### Step 3 — `SlideshowState.updateFilesystemURL(id:newURL:)` (modify: `State/SlideshowState.swift`)

Add one `@MainActor` method:

```
func updateFilesystemURL(id: UUID, newURL: URL)
```

- `guard let idx = photos.firstIndex(where: { $0.id == id }) else { return }`
- `guard case .filesystem = photos[idx].source else { return }`
- `photos[idx] = photos[idx].withFilesystemURL(newURL)`
- `AppSessionState.shared.markDirty()`

This follows the exact same pattern as `rotatePhotoCounterclockwise(withID:)`.

---

### Step 4 — `RenameToSequenceView` (new file: `Views/Main/RenameToSequenceView.swift`)

A SwiftUI `View` presented as a sheet from `ContentView`.

**Props**: `items: [RenamePreviewItem]`, `onConfirm: () -> Void`, `onDismiss: () -> Void`

**Layout**:
```
┌────────────────────────────────────────────┐
│  Rename Files to Sequence                  │
│                                            │
│  ⚠️  [Warning banner — Photos Library]     │  ← Shown only if hasPhotosLibraryItems
│      "N items from your Photos Library     │
│       will not be renamed."                │
│                                            │
│  ┌──────────────────────────────────────┐  │
│  │ 1  FolderA/fileB.jpg                 │  │
│  │    → 0001-fileB.jpg                  │  │
│  │──────────────────────────────────────│  │
│  │ 2  Photos Library/34903403.HEIC      │  │  ← Dimmed
│  │    → will not be renamed             │  │
│  │──────────────────────────────────────│  │
│  │ 3  FolderA/fileC.jpg                 │  │
│  │    → 0002-fileC.jpg                  │  │
│  └──────────────────────────────────────┘  │
│                                            │
│         [Cancel]  [Rename N files…]        │
└────────────────────────────────────────────┘
```

**Rename button**:
- Label: `"Rename \(renameableCount) file\(renameableCount == 1 ? "" : "s")…"`
- Triggers a SwiftUI `.confirmationDialog` or `.alert`:
  - Title: `"Rename \(renameableCount) files?"`
  - Message: `"This will permanently rename files on disk. This cannot be undone."`
  - Buttons: "Rename" (destructive role) + "Cancel"
  - On "Rename": call `onConfirm()`

**Photos Library rows**: rendered with `.foregroundStyle(.secondary)` and the skip text styled as a label (e.g. italic or subdued).

---

### Step 5 — Rename Execution (in `ContentView.swift`)

Add a `func executeRename(candidates: [RenamePreviewItem])` method on `ContentView` (or extract to a helper). Called from `RenameToSequenceView.onConfirm`.

```
for item in candidates where item.isRenameable {
    guard let newURL = item.newURL else { continue }
    let oldURL = item.currentURL
    oldURL.startAccessingSecurityScopedResource()
    defer { oldURL.stopAccessingSecurityScopedResource() }
    do {
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        slideshowState.updateFilesystemURL(id: item.id, newURL: newURL)
    } catch {
        // Show error alert: "Could not rename \(item.currentFilename): \(error.localizedDescription)"
        // Break — do not continue processing remaining files
        break
    }
}
```

Error presentation: a `@State var renameError: String?` driving an `.alert` in the view.

---

### Step 6 — Menu Item (modify: `ContentView.swift`)

**Sheet state**: `@State private var showingRenamePreview = false`
**Preview items**: `@State private var renamePreviewItems: [RenamePreviewItem] = []`

**Menu item** (added after "Save Slideshow..." button):

```swift
Button(action: {
    renamePreviewItems = SequenceRenamer.buildPreview(for: slideshowState.photos)
    showingRenamePreview = true
}) {
    Label("Rename Files to Sequence...", systemImage: "arrow.triangle.2.circlepath")
}
.disabled(slideshowState.photos.allSatisfy { $0.isFromPhotosLibrary } || slideshowState.isEmpty)
```

**Sheet attachment** (on the root view or the toolbar container):

```swift
.sheet(isPresented: $showingRenamePreview) {
    RenameToSequenceView(
        items: renamePreviewItems,
        onConfirm: {
            showingRenamePreview = false
            executeRename(candidates: renamePreviewItems)
        },
        onDismiss: {
            showingRenamePreview = false
        }
    )
}
```

---

## Complexity Tracking

No constitution violations. All complexity is required by the feature specification.

| Design Choice | Why Needed | Simpler Alternative Rejected Because |
|---------------|------------|-------------------------------------|
| `RenamePreviewItem` as separate type | Preview data is computed from MediaItem but has different shape (display names, new URL). Separating concerns keeps algorithm pure. | Reusing `MediaItem` directly would couple display logic to the domain model. |
| Non-atomic failure behavior | Specified in FR-014. Simpler than atomic/rollback. | Atomic rename across multiple folders would require a full undo log, far exceeding the feature scope. |
| Synchronous rename on main thread | Renames are fast (< 1ms per file on local SSD). Avoids @MainActor crossing complexity. | Async background execution adds concurrency complexity with no measurable user benefit at this scale. |

---

## Out of Scope

- Undo (CMD+Z) for rename operations — deferred (Assumptions)
- Auto-save after rename — not implemented; existing dirty-state mechanism handles this
- Updating `ThumbnailCache` / `FaceDetectionCache` keys after rename — not needed; thumbnails regenerate lazily, face rects survive via `MediaItem.faceDetectionRects`
- Progress indicator for large batches — out of scope; renames are fast at expected scale
- iCloud stub detection in preview — iCloud stubs appear as regular rename candidates and fail at execution time (standard partial-failure flow per Assumptions)
