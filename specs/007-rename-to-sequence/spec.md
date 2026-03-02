# Feature Specification: Rename Files to Sequence

**Feature Branch**: `007-rename-to-sequence`
**Created**: 2026-03-01
**Status**: Draft

## Clarifications

### Session 2026-03-01

- Q: How should Photos Library items appear in the preview list? → A: They appear inline at their slideshow position with their current filename and a "will not be renamed" indicator instead of a new filename. They are not omitted from the list.
- Q: Should the rename operation be idempotent — i.e. safe to run multiple times without accumulating prefixes? → A: Yes. Before applying a new prefix, the algorithm MUST detect and strip any existing leading `\d{4}-` pattern so a file like `0003-photo.jpg` becomes `0001-photo.jpg`, never `0001-0003-photo.jpg`.
- Q: Should the `\d{4}-` strip apply unconditionally, or only to prefixes previously applied by SoftBurn? → A: Unconditionally. Files that naturally start with a 4-digit prefix (e.g. `2024-vacation.jpg`) are de minimis; the file will still receive the correct new prefix and be in the right order — only part of the original name is altered, which is acceptable. Documented as a known limitation.
- Q: How is the preview list organised — flat playback order or grouped by folder? → A: Flat, in playback order. Each row shows `ParentFolder\filename -> NNNN-filename`. Per-folder sequence counters still increment as that folder's files are encountered in playback order (e.g. if FolderA's files appear at positions 1 and 3 globally, they get 0001 and 0002). Photos Library items appear at their playback position showing `Photos Library\id.ext -> will not be renamed`. No folder section headers.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Rename All Files to Match View Order (Priority: P1)

A user has imported photos from several folders, arranged them in their desired playback order in SoftBurn, and now wants the filesystem to reflect that order. They choose "Rename Files to Sequence" from the File menu. A dialog explains the operation, shows a preview list of all planned renames grouped by folder, and prompts them to confirm. After confirmation, each file is renamed in place with a zero-padded sequence prefix so that the filesystem sort order within each folder matches the SoftBurn view order.

**Why this priority**: This is the entire feature — the ability to commit the SoftBurn ordering to the filesystem. Everything else (warnings, preview, error handling) serves this core action.

**Independent Test**: Can be fully tested with a slideshow containing files from at least two folders in different orders; confirms files are renamed correctly and the app continues to play them in the same sequence.

**Acceptance Scenarios**:

1. **Given** a slideshow with files `folder1/imageB.jpg` (position 1) and `folder1/imageA.jpg` (position 2), **When** the user invokes "Rename Files to Sequence" and confirms, **Then** files are renamed to `folder1/0001-imageB.jpg` and `folder1/0002-imageA.jpg` respectively.
2. **Given** files interleaved across two folders in playback order `[folder1/a, folder2/x, folder1/b, folder1/c, folder2/y]`, **When** the operation runs, **Then** folder1 files receive `0001-a`, `0002-b`, `0003-c` and folder2 files receive `0001-x`, `0002-y` — each folder's counter increments independently as its files are encountered in playback order.
3. **Given** the rename completes successfully, **When** the user plays the slideshow, **Then** playback order is identical to before the rename.

---

### User Story 2 - Preview Before Committing (Priority: P2)

Before any files are touched, the user sees a scrollable preview list in the confirmation dialog. The list is flat and in playback order — every item in the slideshow is shown as a numbered row: `ParentFolder\filename.ext → NNNN-filename.ext`. Photos Library items appear at their playback position as `Photos Library\id.ext → will not be renamed`. The per-folder sequence counter increments each time a file from a given folder is encountered in playback order, so files from the same folder that are non-contiguous still receive correct consecutive numbers within that folder.

**Why this priority**: This feature is destructive (renames files permanently). A clear preview is essential for user confidence and safety. It is independently useful — the preview can be implemented and shown even before the rename logic is wired up.

**Independent Test**: Can be tested by opening the dialog and verifying the preview list matches the example pattern (flat, playback order, per-folder counters correct) without actually performing any rename.

**Acceptance Scenarios**:

1. **Given** a slideshow `[FolderA/fileB, PhotosLib/x.HEIC, FolderA/fileC, FolderB/fileD]`, **When** the user opens "Rename Files to Sequence", **Then** the preview shows exactly: `(1) FolderA\fileB.jpg → 0001-fileB.jpg`, `(2) Photos Library\x.HEIC → will not be renamed`, `(3) FolderA\fileC.jpg → 0002-fileC.jpg`, `(4) FolderB\fileD.jpg → 0001-fileD.jpg`.
2. **Given** the preview list is displayed, **When** the user dismisses the dialog without clicking OK, **Then** no files are renamed.
3. **Given** a file already has a sequence prefix (e.g. `0003-photo.jpg`), **When** the preview is shown, **Then** the new name strips the prior prefix and applies the updated one (e.g. `0001-photo.jpg`).

---

### User Story 3 - Photos Library Items Shown as Skipped in Preview (Priority: P3)

When the current slideshow includes items sourced from the macOS Photos Library (which cannot be renamed), those items appear in the preview list in their slideshow position alongside other files. Instead of showing a new filename, they display a "will not be renamed" indicator. The dialog also shows a prominent warning at the top when any Photos Library items are present.

**Why this priority**: Showing Photos Library items inline (rather than omitting them) preserves the user's mental model of the full slideshow order and makes the scope of the operation immediately legible. The targeted warning reinforces this when relevant.

**Independent Test**: Can be fully tested by loading a slideshow that mixes filesystem files and Photos Library items, then opening the rename dialog and confirming: (a) Photos Library items appear in the list with a skip indicator, (b) the warning is present, and (c) the items are untouched after confirming the operation.

**Acceptance Scenarios**:

1. **Given** a slideshow contains only filesystem files, **When** the dialog opens, **Then** no Photos Library warning is shown and all items display old → new filename pairs.
2. **Given** a slideshow contains at least one Photos Library item, **When** the dialog opens, **Then** a visible warning states that Photos Library items cannot be renamed and will be skipped, AND each Photos Library item appears in the preview list with its current filename and a "will not be renamed" indicator in place of the new filename.
3. **Given** the dialog shows Photos Library items with skip indicators and the user confirms, **Then** Photos Library items are left untouched and all filesystem files are renamed normally.

---

### User Story 4 - Partial Failure Handling (Priority: P4)

If any individual rename fails mid-operation (e.g. permissions error, file locked), the operation halts immediately, presents an error dialog identifying the failing file, and leaves all previously renamed files in their new state. The app's internal view is updated to reflect whichever renames succeeded.

**Why this priority**: Graceful failure with clear feedback is important for a destructive operation, but it is a secondary concern behind the happy path.

**Independent Test**: Can be tested by making a file read-only before running the operation and confirming the error dialog appears with the correct filename and that successfully renamed files are reflected in the view.

**Acceptance Scenarios**:

1. **Given** 5 files are queued and the 3rd rename fails, **When** the error occurs, **Then** files 1 and 2 retain their new names, files 3–5 remain unchanged, and an error dialog names the failing file.
2. **Given** a rename fails, **When** the error dialog is dismissed, **Then** the app view correctly shows the updated names for the successfully renamed files.
3. **Given** a rename fails, **Then** no attempt is made to undo the successful renames (non-atomic behavior is expected and acceptable).

---

### Edge Cases

- What if a target filename already exists in the folder (e.g. `0001-photo.jpg` already exists as a different file)? The rename for that slot must fail with an error identifying the conflict.
- What if all files in the slideshow are from the Photos Library? The menu item is disabled (FR-002 — no renameable files), so the dialog cannot be opened in this state.
- What if a file's name already starts with an existing sequence prefix like `0003-`? The old prefix is stripped and replaced with the new correct one — the operation is safe to run multiple times.
- What if a file's name naturally starts with a 4-digit number followed by a dash (e.g. `2024-vacation.jpg`)? The `\d{4}-` is stripped unconditionally. The file will be correctly sequenced; only that leading portion of the original name is lost. This is a known, accepted limitation documented in FR-007.
- What if two files in different folders share the same base name? Each is renamed independently — no conflict arises because they are in separate directories.
- What if the slideshow is empty? The menu item is disabled or the dialog states there is nothing to rename.
- What if a file has been moved or deleted since it was imported? The rename for that file fails with a "file not found" error, following the same partial-failure behavior.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST expose a "Rename Files to Sequence" menu item in the File menu, positioned below "Save Slideshow."
- **FR-002**: The menu item MUST be disabled when the slideshow contains no renameable filesystem files (empty slideshow or all items are Photos Library items).
- **FR-003**: Invoking the menu item MUST open a non-modal preview dialog before any files are touched.
- **FR-004**: The preview dialog MUST display a scrollable, flat list of every item in the slideshow in playback order. Each row shows `ParentFolder\filename.ext → NNNN-filename.ext` for filesystem files, or `Photos Library\id.ext → will not be renamed` for Photos Library items. There are no folder section headers — the list is purely sequential. Per-folder sequence numbers are assigned by counting how many times each folder has been encountered as the list is traversed top-to-bottom (e.g. the 2nd FolderA file encountered gets `0002` regardless of its global position).
- **FR-005**: The preview dialog MUST show a warning message at the top if and only if the slideshow contains one or more Photos Library items.
- **FR-006**: The new filename MUST follow the format `NNNN-original_filename.ext`, where NNNN is a zero-padded 4-digit integer representing the file's rank within its parent folder according to SoftBurn's current view order.
- **FR-007**: The rename algorithm MUST be idempotent. Before applying a new sequence prefix, it MUST check for a leading `\d{4}-` pattern in the filename and strip it if found, so that running the operation multiple times never accumulates prefixes (e.g. `0003-photo.jpg` → `0001-photo.jpg`, never `0001-0003-photo.jpg`). This stripping applies unconditionally — files that happen to start with a natural 4-digit prefix (e.g. `2024-vacation.jpg` → `0007-vacation.jpg`) will lose that prefix. This is a known, accepted limitation.
- **FR-008**: Sequence numbers MUST be assigned per parent folder, independent of other folders. Numbers are assigned by traversing the slideshow in playback order and incrementing each folder's counter when one of its files is encountered. The first file from a given folder encountered in playback order receives `0001`, the second `0002`, and so on — regardless of whether files from other folders appear between them.
- **FR-009**: After the user reviews the preview, the dialog MUST require a second explicit confirmation (OK/Cancel) before executing any rename, clearly labeled to convey the action is permanent.
- **FR-010**: Upon confirmation, the app MUST rename each filesystem file in playback order, updating its internal view state after each successful rename.
- **FR-011**: Photos Library items MUST NOT be renamed under any circumstances. They are shown in the preview list with a skip indicator but are silently excluded from the rename operation when the user confirms.
- **FR-012**: If a rename fails for any reason, the app MUST immediately halt the operation and display an error dialog identifying the file that could not be renamed.
- **FR-013**: After a partial failure, the app view MUST accurately reflect the names of all files that were successfully renamed, and the original names of all files that were not yet processed.
- **FR-014**: The operation MUST NOT attempt to roll back or undo any successful renames after a failure.
- **FR-015**: The app's internal references (used for playback, saving, and thumbnail display) MUST be updated to the new file paths for all successfully renamed files.

### Key Entities

- **RenameCandidate**: A filesystem-sourced media item queued for renaming. Attributes: current file URL, proposed new filename, parent folder URL, rank within parent folder.
- **FolderGroup**: A collection of RenameCandidate items sharing the same immediate parent folder, with folder-scoped sequence numbering.
- **RenameResult**: The outcome of a single rename attempt — success (with new URL) or failure (with error description and original URL).

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can open the rename dialog, review the preview, and confirm the operation in under 30 seconds for a slideshow of 100 files.
- **SC-002**: After a successful rename operation, the app's playback order is identical to the view order prior to the rename — verifiable by playing the slideshow end to end.
- **SC-003**: After a successful rename, the filesystem sort order within each parent folder matches the SoftBurn view order for files in that folder — verifiable by listing folder contents alphabetically.
- **SC-004**: A rename failure surfaces an error message within 2 seconds of the failure occurring, identifying the specific file by name.
- **SC-005**: Zero Photos Library files are modified by the operation under any circumstances.
- **SC-006**: The preview list in the dialog is 100% accurate — every rename shown occurs, and no rename occurs that was not shown.

---

## Assumptions

- The number of files per folder will not exceed 9999 in practice; 4-digit zero-padded prefixes are sufficient.
- "Parent folder" means the immediate containing directory of the file, not any ancestor folder. Nested folder structures are handled by assigning sequence numbers only within the direct parent.
- Files sourced via iCloud Drive that have been fully downloaded to local storage are treated as regular filesystem files and are eligible for renaming.
- iCloud Drive files that are not yet downloaded locally (cloud-only stubs) will fail to rename; this is handled by the standard partial-failure error flow.
- The operation does not require an internet connection; it acts only on locally accessible file paths.
- The user's existing `.softburn` document is not automatically saved after renaming; if the user closes without saving, the updated paths are lost. This is consistent with existing app behavior for other state changes.
- Undo (CMD+Z) is out of scope for this feature. The second confirmation step is the safety mechanism.
