# Tasks: Rename Files to Sequence

**Input**: Design documents from `/specs/007-rename-to-sequence/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, quickstart.md ✓

**Tests**: No test tasks — not requested in spec (manual validation via quickstart.md).

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no shared dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

---

## Phase 1: Setup

**Purpose**: Confirm baseline compiles before any changes.

- [x] T001 Verify project builds successfully on branch `007-rename-to-sequence` — run `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build` and confirm zero errors

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Data types, algorithm, and model extensions that ALL user stories depend on. No UI is added in this phase.

**⚠️ CRITICAL**: User story phases cannot begin until T004 and T005 are complete.

- [x] T002 [P] Create `SoftBurn/Utilities/SequenceRenamer.swift` with the `RenamePreviewItem` struct: fields `id: UUID`, `playbackIndex: Int`, `parentFolderDisplayName: String`, `currentFilename: String`, `newFilename: String?`, `currentURL: URL`, `newURL: URL?`, `isPhotosLibrary: Bool`, and computed property `isRenameable: Bool`

- [x] T003 [P] Add `func withFilesystemURL(_ url: URL) -> MediaItem` to `MediaItem` in `SoftBurn/Models/Models.swift` — returns a copy of `self` with `source` replaced by `.filesystem(url)`, preserving all other fields (`id`, `kind`, `rotationAngle`, `faceDetectionRects`, etc.)

- [x] T004 Implement `static func buildPreview(for items: [MediaItem]) -> [RenamePreviewItem]` in `SoftBurn/Utilities/SequenceRenamer.swift` (depends on T002): traverse items in order, maintain `[URL: Int]` folder counter; for `.photosLibrary` items produce skip rows; for `.filesystem` items strip leading `\d{4}-` (if first 4 chars are ASCII digits and char 5 is `-`, drop first 5 chars), increment folder counter, format `"%04d-\(baseName).\(ext)"`, compute `newURL = parentFolder.appendingPathComponent(newFilename)`

- [x] T005 Add `@MainActor func updateFilesystemURL(id: UUID, newURL: URL)` to `SlideshowState` in `SoftBurn/State/SlideshowState.swift` (depends on T003): find item by `id`, guard `source` is `.filesystem`, replace with `item.withFilesystemURL(newURL)`, call `AppSessionState.shared.markDirty()`

**Checkpoint**: Build must compile with zero errors. `SequenceRenamer.buildPreview` is fully unit-testable at this point.

---

## Phase 3: User Story 1 — Rename All Files to Match View Order (Priority: P1) 🎯 MVP

**Goal**: Users can invoke "Rename Files to Sequence...", confirm via a simple alert, and have all filesystem files renamed correctly on disk with updated view state.

**Independent Test**: Import files from two folders in non-alphabetical interleaved order. Use File menu → "Rename Files to Sequence..." → confirm. Verify in Finder that files have correct `NNNN-` prefixes (per-folder counters, playback order). Verify app still plays in same sequence. See quickstart.md "Happy Path".

- [x] T006 Add state variables `@State private var showingRenamePreview = false` and `@State private var renamePreviewItems: [RenamePreviewItem] = []` to `ContentView` in `SoftBurn/Views/Main/ContentView.swift`

- [x] T007 [US1] Add "Rename Files to Sequence..." `Button` to the File `Menu` in `SoftBurn/Views/Main/ContentView.swift`, positioned after the "Save Slideshow..." button: `action` sets `renamePreviewItems = SequenceRenamer.buildPreview(for: slideshowState.photos)` then `showingRenamePreview = true`; `.disabled` when `slideshowState.photos.filter { !$0.isFromPhotosLibrary }.isEmpty` (depends on T006)

- [x] T008 [US1] Implement `private func executeRename(candidates: [RenamePreviewItem])` in `SoftBurn/Views/Main/ContentView.swift`: iterate `candidates` where `isRenameable`, for each call `currentURL.startAccessingSecurityScopedResource()`, attempt `FileManager.default.moveItem(at: currentURL, to: newURL)`, on success call `slideshowState.updateFilesystemURL(id: item.id, newURL: newURL)` and `currentURL.stopAccessingSecurityScopedResource()`, on failure stop iteration (depends on T005)

- [x] T009 [US1] Wire a minimal confirmation `.confirmationDialog` or `.alert` to `showingRenamePreview` in `SoftBurn/Views/Main/ContentView.swift`: title "Rename files?", message "Rename \(renamePreviewItems.filter(\.isRenameable).count) files to match playback order?", "Rename" (destructive) calls `executeRename(candidates: renamePreviewItems)`, "Cancel" dismisses — this is a temporary placeholder that will be replaced by the full preview sheet in Phase 4 (depends on T008)

**Checkpoint**: US1 fully functional. Menu item appears in File menu, confirmation dialog shows correct count, files are renamed on disk, view state updated, app plays in same order.

---

## Phase 4: User Story 2 — Preview Before Committing (Priority: P2)

**Goal**: Replace the minimal alert with a full preview dialog showing the flat playback-order list of all planned renames before any files are touched.

**Independent Test**: Open dialog, verify list is flat in playback order with rows `ParentFolder/filename → NNNN-filename`, verify the correct acceptance scenario from spec (FolderA/fileB→0001, Photos/x→skip, FolderA/fileC→0002, FolderB/fileD→0001). Dismiss without confirming — verify zero files renamed.

- [x] T010 [P] [US2] Create `SoftBurn/Views/Main/RenameToSequenceView.swift` as a SwiftUI `View` accepting `items: [RenamePreviewItem]`, `onConfirm: () -> Void`, `onDismiss: () -> Void` — scaffold only: title "Rename Files to Sequence", Cancel button calling `onDismiss`, placeholder Rename button, no list yet

- [x] T011 [US2] Implement the scrollable preview `List` in `SoftBurn/Views/Main/RenameToSequenceView.swift`: one row per `RenamePreviewItem` in order; each row shows `"\(item.parentFolderDisplayName)/\(item.currentFilename)"` on the left and `"→ \(item.newFilename ?? "will not be renamed")"` on the right; Photos Library rows rendered with `.foregroundStyle(.secondary)` (depends on T010)

- [x] T012 [US2] Replace placeholder Rename button in `SoftBurn/Views/Main/RenameToSequenceView.swift` with a button labelled `"Rename \(renameableCount) file(s)…"` (where `renameableCount = items.filter(\.isRenameable).count`) that triggers a `.confirmationDialog`: title "Rename \(renameableCount) files?", message "This will permanently rename files on disk. This cannot be undone.", destructive "Rename" button calls `onConfirm()`, "Cancel" dismisses (depends on T011)

- [x] T013 [US2] Replace the temporary confirmation alert from T009 with a `.sheet(isPresented: $showingRenamePreview)` presenting `RenameToSequenceView(items: renamePreviewItems, onConfirm: { showingRenamePreview = false; executeRename(candidates: renamePreviewItems) }, onDismiss: { showingRenamePreview = false })` in `SoftBurn/Views/Main/ContentView.swift` (depends on T012)

**Checkpoint**: Full preview dialog shown with flat list. Cancel dismisses with no changes. Rename button shows correct count and requires second confirmation.

---

## Phase 5: User Story 3 — Photos Library Items Shown as Skipped (Priority: P3)

**Goal**: When the slideshow contains Photos Library items, a warning banner appears at the top of the dialog, and those items are visually distinguished in the list with a skip indicator.

**Independent Test**: Load a mixed slideshow (filesystem + Photos Library items). Open dialog. Verify warning banner is present. Verify Photos Library rows appear at their playback position with "will not be renamed" in dimmed style. Confirm — verify Photos Library items are untouched. See quickstart.md "Photos Library Items".

- [x] T014 [P] [US3] Add conditional warning banner to the top of `RenameToSequenceView` in `SoftBurn/Views/Main/RenameToSequenceView.swift`: shown only when `items.contains(where: \.isPhotosLibrary)` is `true`; text: "Items from your Photos Library cannot be renamed and will be skipped."; styled as a yellow/orange callout or `.systemYellow` background label

- [x] T015 [US3] Enhance Photos Library row rendering in `SoftBurn/Views/Main/RenameToSequenceView.swift`: skip-indicator text ("will not be renamed") shown in italic or `.tertiary` style; entire row rendered with `.foregroundStyle(.secondary)` to visually distinguish it from renameable rows (depends on T014 for verification, but can be implemented in parallel if careful)

**Checkpoint**: Warning banner shown only when Photos Library items present. Rows visually distinguishable. No library items modified after confirm.

---

## Phase 6: User Story 4 — Partial Failure Handling (Priority: P4)

**Goal**: If any individual rename fails, the operation halts immediately, an error dialog names the failing file, and all previously renamed files keep their new names with the view updated accordingly.

**Independent Test**: Make one target file read-only in Finder. Run "Rename Files to Sequence" and confirm. Verify error alert names the correct file. Verify files renamed before the failure retain their new names. Verify view state reflects the partial rename. See quickstart.md "Conflict".

- [x] T016 [US4] Add `@State private var renameError: String? = nil` to `ContentView` in `SoftBurn/Views/Main/ContentView.swift` and attach an `.alert("Rename Failed", isPresented: ...)` that displays `renameError` with an OK button to dismiss

- [x] T017 [US4] Update `executeRename(candidates:)` in `SoftBurn/Views/Main/ContentView.swift` to set `renameError = "Could not rename \"\(item.currentFilename)\": \(error.localizedDescription)"` on failure and `break` out of the loop, so all successfully renamed files keep their new state and the error alert is triggered (depends on T016)

**Checkpoint**: Error alert displayed with file name on first failure. Partial renames retained. View state accurate.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Edge case validation and final manual verification.

- [ ] T018 [P] Verify disabled state of the menu item in `SoftBurn/Views/Main/ContentView.swift`: confirm item is disabled when (a) slideshow is empty and (b) slideshow contains only Photos Library items; confirm item is enabled when at least one filesystem file is present

- [ ] T019 [P] Manual idempotency test per quickstart.md: run "Rename Files to Sequence" once, then reorder items, run again — confirm filenames show new correct prefix without accumulation (e.g. `0001-photo.jpg` not `0001-0001-photo.jpg`)

- [ ] T020 Run full quickstart.md manual test checklist: Happy Path, Photos Library Items, Idempotency, Conflict, Cancel (both steps), Disabled State

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — **BLOCKS all user story phases**
- **US1 (Phase 3)**: Depends on Phase 2 completion — no dependency on US2/US3/US4
- **US2 (Phase 4)**: Depends on US1 (Phase 3) — replaces the temporary confirmation
- **US3 (Phase 5)**: Depends on US2 (Phase 4) — adds to the preview dialog
- **US4 (Phase 6)**: Depends on US1 (Phase 3) — updates `executeRename` and adds error state
- **Polish (Phase 7)**: Depends on US1–US4 completion

### Within Phase 2 (Foundational)

```
T002 [P] ──► T004 (same file, sequential)
T003 [P] ──► T005 (different file, sequential)
T002 and T003 can start in parallel (different files)
```

### Within Phase 3 (US1)

```
T006 ──► T007 ──► T008 ──► T009
(all ContentView.swift — sequential)
```

### Within Phase 4 (US2)

```
T010 ──► T011 ──► T012 ──► T013
(T010 new file, T013 back to ContentView — sequential within story)
```

### Within Phase 5 (US3)

```
T014 [P] and T015 [P] — both in RenameToSequenceView.swift
Can be done in parallel by two developers; single developer: T014 → T015
```

### Phase 6 (US4) note

US4 can be started in parallel with US2/US3 if desired — `executeRename` and ContentView error state are independent of `RenameToSequenceView`. Single developer should complete in order.

---

## Parallel Example: Phase 2 (Foundational)

```
Parallel launch:
  Task T002: "Create RenamePreviewItem in SoftBurn/Utilities/SequenceRenamer.swift"
  Task T003: "Add withFilesystemURL to MediaItem in SoftBurn/Models/Models.swift"

Then sequentially:
  Task T004: "Implement SequenceRenamer.buildPreview in SoftBurn/Utilities/SequenceRenamer.swift"
  Task T005: "Add updateFilesystemURL to SlideshowState in SoftBurn/State/SlideshowState.swift"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001)
2. Complete Phase 2: Foundational (T002–T005)
3. Complete Phase 3: User Story 1 (T006–T009)
4. **STOP and VALIDATE**: Test US1 — files rename correctly, view updates, playback order preserved
5. Proceed to Phase 4 (full preview dialog) once MVP confirmed

### Incremental Delivery

1. Phase 1 + 2 → Algorithm ready, model extended
2. + Phase 3 (US1) → Working rename via simple alert → **testable MVP**
3. + Phase 4 (US2) → Full preview dialog replaces alert
4. + Phase 5 (US3) → Photos Library skip indicators in dialog
5. + Phase 6 (US4) → Graceful partial failure with error dialog
6. + Phase 7 → Polish and final validation

Each phase adds user-facing value without breaking the previous increment.

---

## Notes

- [P] tasks touch different files — safe to dispatch in parallel
- US1 (T009) intentionally uses a minimal alert as a stepping stone; T013 replaces it with the full sheet
- Security-scoped bookmark access: `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` must wrap each `FileManager.moveItem` call (see research.md §5)
- After rename, `ThumbnailCache` and `FaceDetectionCache` do NOT need explicit invalidation — thumbnails regenerate lazily, face rects survive in `MediaItem.faceDetectionRects` (see research.md §7)
- `AppSessionState.shared.markDirty()` is called inside `SlideshowState.updateFilesystemURL` — no need to call it again in `executeRename`
- Idempotent prefix strip: check `baseName.count > 5`, first 4 chars ASCII digits, char at index 4 is `-`, then `baseName = String(baseName.dropFirst(5))` (see research.md §9)
