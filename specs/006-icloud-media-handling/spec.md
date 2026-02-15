# Feature Specification: Improve iCloud Media Handling

**Feature Branch**: `006-icloud-media-handling`
**Created**: 2026-02-11
**Status**: Draft
**Input**: User description: "Improve iCloud handling for Photos Library media items — download state visibility, graceful degradation, face detection retry, and preview panel placeholder."

## Clarifications

### Session 2026-02-11

- Q: Should download state tracking apply to Photos Library items only, or also filesystem items on iCloud Drive? → A: Photos Library items only — filesystem items rely on macOS iCloud Drive transparent sync.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Download State Visibility in Grid (Priority: P1)

When a user imports Photos Library items that are stored in iCloud (not downloaded locally), the grid should clearly indicate each item's download state. Currently, thumbnails appear instantly (from low-res iCloud thumbnails) with no indication that the full-resolution original is still downloading. When offline, items silently resolve to a generic photo placeholder with no error indication. The thumbnail never auto-refreshes when the download eventually completes.

The user needs to know at a glance: is this item ready, downloading, or unavailable?

**Why this priority**: This is the first thing users see after importing iCloud content. Without download visibility, every downstream feature (preview, playback, export) fails silently and the user has no idea why.

**Independent Test**: Import 3+ iCloud-only photos/videos from the Photos picker. The grid should show a download progress indicator on each item while downloading. After download completes, the indicator disappears and the full thumbnail renders. With Wi-Fi off, items should show an "unavailable" state (distinct from the downloading state).

**Acceptance Scenarios**:

1. **Given** a user imports an iCloud-only photo via the Photos picker, **When** the photo is downloading, **Then** the grid thumbnail displays a progress indicator overlay (e.g., spinner or progress ring) until the download completes.
2. **Given** an iCloud item finishes downloading, **When** the download completes, **Then** the grid thumbnail automatically refreshes to show the full-resolution thumbnail and the progress indicator disappears.
3. **Given** Wi-Fi is disabled before importing an iCloud-only item, **When** the item cannot be downloaded, **Then** the grid shows a distinct "unavailable" state (e.g., cloud icon with slash, or dimmed thumbnail with icon) — not a generic photo placeholder.
4. **Given** an iCloud item failed to download due to no network, **When** the network becomes available again, **Then** the download retries automatically and the grid updates when the item becomes available.

---

### User Story 2 — Graceful Playback with Unavailable Media (Priority: P2)

During slideshow playback, if an iCloud item hasn't finished downloading, the slide currently shows nothing (blank/black) for the entire slide duration. The user sees a gap in their slideshow with no explanation. The playback should degrade gracefully: show a recognizable placeholder for unavailable items and continue the slideshow without interruption.

**Why this priority**: Blank slides during playback are the most jarring user-visible symptom. Even if the grid shows download state correctly (US1), playback needs its own handling because downloads may not have completed before the user hits Play.

**Independent Test**: Import 2 locally-present photos and 1 iCloud-only photo (with Wi-Fi off so it can't download). Play the slideshow. The iCloud item should show a recognizable placeholder (not blank) for its duration, and transitions to/from adjacent slides should be smooth.

**Acceptance Scenarios**:

1. **Given** a slideshow contains an iCloud item that has not yet downloaded, **When** the slideshow reaches that item, **Then** a placeholder image is displayed (e.g., a subtle cloud icon centered on a neutral background) instead of a blank/black screen.
2. **Given** a slideshow is playing and an iCloud item finishes downloading mid-playback, **When** the download completes, **Then** the item renders normally on its next appearance in the loop (not mid-slide — avoid jarring swap).
3. **Given** a slideshow contains only iCloud items and the network is unavailable, **When** the user presses Play, **Then** the slideshow plays with placeholders for all items (no hang, no crash, no blank screens). Transitions still animate between placeholders.
4. **Given** an iCloud video has not downloaded, **When** the slideshow reaches that video's slide, **Then** a placeholder is shown (not a frozen frame or blank). Audio from background music continues uninterrupted.

---

### User Story 3 — Face Detection Retry After Late Download (Priority: P3)

Face detection runs during import as a prefetch step. If an iCloud photo hasn't downloaded by the time face detection runs, it silently fails — the photo never gets face-aware zoom, even after the download eventually completes. The system should retry face detection for items that were unavailable during the initial prefetch.

**Why this priority**: Face-aware zoom is a quality-of-life feature, not a blocker. The slideshow still plays correctly without it — the photo just uses random Ken Burns offsets instead of face-centered zoom. But for portrait-heavy slideshows, missing face detection is a noticeable quality loss.

**Independent Test**: Import an iCloud-only photo (with Wi-Fi off), wait for face detection prefetch to complete (it will fail for the iCloud item). Turn Wi-Fi on, wait for download to complete. Play the slideshow — the photo should have face-aware zoom (face rects should be populated).

**Acceptance Scenarios**:

1. **Given** an iCloud photo was unavailable during the initial face detection prefetch, **When** the photo's full-resolution version finishes downloading, **Then** face detection is automatically re-run for that photo.
2. **Given** face detection has been retried and completed for a late-downloaded photo, **When** the slideshow plays, **Then** the photo uses face-aware Ken Burns zoom (not random offsets).
3. **Given** multiple iCloud photos download at different times, **When** face detection retries are queued, **Then** they respect the existing concurrency limit (no more than 3 simultaneous detections) and do not degrade UI responsiveness.

---

### User Story 4 — Preview Panel Placeholder (Priority: P4)

When previewing an iCloud item that is still downloading, the preview panel shows a spinner but with no background frame or placeholder. The other UI controls (that would normally overlay the image) float unanchored in empty space, creating a broken-looking layout.

**Why this priority**: This is a cosmetic polish issue. The spinner works functionally — the user knows something is loading. But the unanchored controls look like a bug.

**Independent Test**: Import an iCloud-only item, select it in the grid, open the preview panel. The preview should show a properly-framed placeholder (same dimensions as a normal preview) with a centered spinner, and all controls should be positioned correctly relative to the placeholder frame.

**Acceptance Scenarios**:

1. **Given** an iCloud item is selected for preview and is still downloading, **When** the preview panel opens, **Then** a properly-sized placeholder frame is displayed (matching the expected aspect ratio or a default size) with a centered spinner.
2. **Given** the preview placeholder is displayed, **When** the user views the preview panel, **Then** all overlay controls (close, rotation, etc.) are positioned correctly relative to the placeholder frame — not floating in empty space.
3. **Given** the iCloud item finishes downloading while the preview is open, **When** the download completes, **Then** the placeholder is replaced with the actual image/video without requiring the user to close and reopen preview.

---

### Edge Cases

- What happens when the same iCloud item is imported twice (once before download, once after)? The system should deduplicate or handle both instances gracefully.
- What happens if the iCloud download succeeds but the file is corrupted or zero-length? The system should treat it as unavailable (placeholder state).
- What happens during export when iCloud items haven't downloaded? Export should either wait for downloads or skip unavailable items with a warning (deferred to export iCloud testing).
- What happens if the user's iCloud account is signed out or the Photos Library authorization is revoked? Items should show as unavailable with an appropriate error state.
- What happens with iCloud items in a saved .softburn file that are later offloaded back to iCloud? On reopen, the system should trigger downloads and show download state.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The grid MUST display a visible download-in-progress indicator on each iCloud item that is currently downloading.
- **FR-002**: The grid MUST display a distinct "unavailable" indicator on iCloud items that cannot be downloaded (no network, download failure).
- **FR-003**: Grid thumbnails MUST automatically refresh when an iCloud item's download completes — no manual action required.
- **FR-004**: The grid MUST automatically retry downloads for failed iCloud items when network connectivity is restored.
- **FR-005**: Slideshow playback MUST display a recognizable placeholder for iCloud items that are not yet downloaded — never a blank/black screen.
- **FR-006**: Slideshow transitions MUST animate normally to and from placeholder slides (crossfade, zoom, etc.).
- **FR-007**: Slideshow playback MUST NOT hang, freeze, or crash when all items are iCloud-only and the network is unavailable.
- **FR-008**: Background music MUST continue playing uninterrupted during placeholder slides.
- **FR-009**: Face detection MUST be automatically retried for iCloud photos that were unavailable during the initial prefetch, once their download completes.
- **FR-010**: Face detection retries MUST respect the existing concurrency limit and not degrade UI responsiveness.
- **FR-011**: The preview panel MUST display a properly-framed placeholder with centered spinner when an iCloud item is loading, with all controls correctly positioned.
- **FR-012**: The preview panel MUST auto-update to show the actual content when an iCloud item finishes downloading (no close/reopen required).

### Key Entities

- **Download State**: Each Photos Library media item has a download state: `ready` (original available locally), `downloading` (in progress), `unavailable` (failed or no network). This state applies only to Photos Library items — filesystem items (including those on iCloud Drive) rely on macOS transparent sync and are treated as always `ready` or simply missing. Valid transitions: `downloading → ready`, `downloading → unavailable`, `unavailable → downloading` (on network restore).
- **Placeholder**: A visual representation used in the grid, preview, and playback when an item's original is not yet available. Distinct appearances for "downloading" (spinner) vs "unavailable" (error icon).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of iCloud items in the grid show a visible download state indicator (spinner or unavailable icon) within 1 second of import when the original is not locally available.
- **SC-002**: 100% of grid thumbnails auto-refresh within 2 seconds of an iCloud download completing — no manual refresh needed.
- **SC-003**: 0% of slideshow slides display blank/black screens for unavailable iCloud items — all show a recognizable placeholder.
- **SC-004**: Slideshow playback completes a full loop of a mixed local + iCloud slideshow (with some items unavailable) without any hangs, crashes, or frozen transitions.
- **SC-005**: 100% of iCloud photos that download after the initial face detection prefetch have face detection re-run automatically, and use face-aware zoom on their next playback appearance.
- **SC-006**: Preview panel shows properly-framed placeholder (no floating/unanchored controls) for 100% of loading iCloud items.

## Assumptions

- The existing Photos Library integration provides sufficient information to determine whether an item needs downloading. The low-res thumbnail is already available for iCloud items (confirmed by testing — thumbnails appear instantly).
- Network connectivity changes can be detected or polled at a reasonable frequency to trigger download retries.
- The placeholder image/icon is a simple built-in asset — no complex design work required. A neutral background with a cloud icon (downloading) or cloud-with-slash icon (unavailable) is sufficient.
- Export with iCloud items is out of scope for this feature — it will be addressed after iCloud handling is solid for import/grid/playback/preview.
