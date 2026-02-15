# Tasks: Improve iCloud Media Handling

**Input**: Design documents from `/specs/006-icloud-media-handling/`
**Prerequisites**: plan.md (required), spec.md (required), research.md

**Tests**: Visual inspection only (GPU rendering pipeline, no unit test framework). Build verification at checkpoints.

**Organization**: Tasks are grouped by user story. All changes are within the existing Xcode project structure.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

- **Single macOS app**: `SoftBurn/` at repository root (Xcode project structure)

---

## Phase 1: Foundational (New Actor + Download State Enum)

**Purpose**: Create the iCloudDownloadManager actor and DownloadState type that all user stories depend on. This is the centralized download state tracking and network monitoring infrastructure.

- [x] T001 Create `DownloadState` enum (`.ready`, `.downloading`, `.unavailable`) and `iCloudDownloadManager` actor in `SoftBurn/Caching/iCloudDownloadManager.swift`. The actor must: (1) maintain a `[UUID: DownloadState]` dictionary mapping MediaItem IDs to download states, (2) provide `trackItem(_ item: MediaItem)` to begin tracking a Photos Library item (check if original is locally available via PHAsset resource availability, set initial state to `.downloading` or `.ready`), (3) provide `state(for itemID: UUID) -> DownloadState` to query state, (4) provide an `AsyncStream<(UUID, DownloadState)>` or `@Published` mechanism for observers to react to state changes, (5) be a singleton (`shared`) following the existing FaceDetectionCache/ThumbnailCache pattern. Only track items where `item.isFromPhotosLibrary == true` — filesystem items are always `.ready`.

- [x] T002 Add NWPathMonitor integration to `iCloudDownloadManager` in `SoftBurn/Caching/iCloudDownloadManager.swift`. The monitor must: (1) start on a background DispatchQueue at actor init, (2) track current network availability (`.satisfied` vs other), (3) when network transitions from unavailable → available, re-queue all items in `.unavailable` state for retry by transitioning them to `.downloading` and re-triggering their download, (4) expose a `isNetworkAvailable: Bool` property for other components to check, (5) cancel the monitor in a `stop()` method. Import the `Network` framework.

- [x] T003 Add download execution and timeout logic to `iCloudDownloadManager` in `SoftBurn/Caching/iCloudDownloadManager.swift`. Implement `requestDownload(for item: MediaItem)` that: (1) sets state to `.downloading`, (2) calls `PhotosLibraryImageLoader.shared.loadCGImage()` or `.getVideoURL()` (based on item.kind) to trigger the iCloud download, (3) on success transitions to `.ready` and notifies observers, (4) on failure or 30-second timeout transitions to `.unavailable`, (5) limits retry attempts to 3 per item per network session (reset count when network changes), (6) uses a `Task.sleep` + `Task` cancellation pattern for timeout.

- [x] T004 Wire `iCloudDownloadManager.trackItem()` into the import path. In the file where Photos Library items are added to `SlideshowState` (likely `ContentView.swift` or `PhotosPickerView.swift`), call `await iCloudDownloadManager.shared.trackItem(item)` for each newly-imported Photos Library item. This kicks off download state tracking immediately on import.

- [x] T005 Build the project: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Fix any compilation errors from the new actor and Network framework import.

**Checkpoint**: iCloudDownloadManager exists and tracks download states for Photos Library items. Network monitor detects connectivity changes. No UI changes yet — the state is tracked but not displayed.

---

## Phase 2: User Story 1 — Download State Visibility in Grid (Priority: P1) MVP

**Goal**: Show download progress and unavailable indicators on grid thumbnails. Auto-refresh when download completes. Auto-retry on network restore.

**Independent Test**: Import 3+ iCloud-only items from Photos Library. Grid should show cloud-arrow overlay while downloading. After download, overlay disappears and full thumbnail appears. With Wi-Fi off, items show cloud-slash overlay. Turn Wi-Fi on — items auto-retry and overlay updates.

### Implementation for User Story 1

- [x] T006 [US1] Modify `ThumbnailView` in `SoftBurn/Views/Grid/ThumbnailView.swift` to observe download state from `iCloudDownloadManager`. Add a `@State private var downloadState: DownloadState?` property. In the `.task` modifier (or a new one), subscribe to state changes for `photo.id` from the download manager. When `downloadState` is `.downloading`, overlay a small SF Symbol `cloud.arrow.down` badge (bottom-right corner, semi-transparent background). When `.unavailable`, overlay `icloud.slash` badge. When `.ready` or `nil` (filesystem item), show no overlay.

- [x] T007 [US1] Modify thumbnail refresh logic in `SoftBurn/Views/Grid/ThumbnailView.swift`. When download state transitions from `.downloading` → `.ready`, re-trigger `loadThumbnail()` by invalidating the cached thumbnail for that item (call `ThumbnailCache.shared.invalidate(for: photo)` — add this method if it doesn't exist) and setting `thumbnail = nil` + `isLoading = true` to re-fetch. This fixes the "thumbnail doesn't auto-resolve" bug from IC-4.

- [x] T008 [US1] Add `invalidate(for item: MediaItem)` method to `ThumbnailCache` in `SoftBurn/Caching/ThumbnailCache.swift` if it doesn't exist. This method removes the cached thumbnail for a specific item, forcing a re-fetch on next request.

- [x] T009 [US1] Build the project: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Fix any compilation errors.

**Checkpoint**: Grid shows download state overlays on iCloud items. Thumbnails auto-refresh when download completes. Auto-retry on network restore updates the grid. Build and test with iCloud items (online and offline).

---

## Phase 3: User Story 2 — Graceful Playback with Unavailable Media (Priority: P2)

**Goal**: Show a placeholder texture instead of blank/black when an iCloud item hasn't downloaded. Transitions animate normally to/from placeholders.

**Independent Test**: Import 2 local photos + 1 iCloud-only photo (Wi-Fi off). Play slideshow. The iCloud item shows a placeholder (cloud icon on neutral background), not blank. Transitions to/from the placeholder are smooth crossfades.

### Implementation for User Story 2

- [x] T010 [US2] Create a placeholder `MTLTexture` in `MetalSlideshowRenderer` in `SoftBurn/Rendering/MetalSlideshowRenderer.swift`. At renderer initialization (or lazily on first use), generate a texture: (1) create an `NSImage` of appropriate size (e.g., 512x512) with a neutral dark gray background and a centered SF Symbol `icloud.and.arrow.down` rendered in lighter gray, (2) convert to `MTLTexture` via the existing texture loading utility or `MTKTextureLoader`, (3) store as `private var placeholderTexture: MTLTexture?`. This texture is used when the playback state has `currentImage == nil` or `nextImage == nil` for a Photos Library item.

- [x] T011 [US2] Modify `SlideshowPlayerState.prepareCurrentAndNext()` and `loadNextMediaInBackground()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift` to detect iCloud unavailability. When `imageLoader.loadImage(for: item)` returns nil AND `item.isFromPhotosLibrary == true`, set a new flag `currentIsPlaceholder = true` (or `nextIsPlaceholder = true`) instead of leaving `currentImage = nil`. Add `@Published var currentIsPlaceholder: Bool = false` and `@Published var nextIsPlaceholder: Bool = false` properties.

- [x] T012 [US2] Modify the texture selection in `MetalSlideshowRenderer.update()` or the render method in `SoftBurn/Rendering/MetalSlideshowRenderer.swift`. When `playerState.currentImage == nil` and `playerState.currentIsPlaceholder == true`, use `placeholderTexture` as the current texture instead of nil/fallback. Same for next slot. The placeholder texture participates in normal crossfade transitions (it's just a texture). Ken Burns motion should still apply (slow zoom on placeholder looks fine).

- [x] T013 [US2] Handle `promoteNextToCurrent()` in `SoftBurn/Views/Slideshow/SlideshowPlayerView.swift` — ensure `currentIsPlaceholder` is promoted from `nextIsPlaceholder` along with other properties, and `nextIsPlaceholder` is reset to `false`.

- [x] T014 [US2] Build the project: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Fix any compilation errors.

**Checkpoint**: Playback shows placeholder for unavailable iCloud items. No blank/black slides. Transitions animate smoothly. Background music continues. Build and test with mixed local + iCloud items (Wi-Fi off).

---

## Phase 4: User Story 3 — Face Detection Retry (Priority: P3)

**Goal**: Automatically re-run face detection for Photos Library items that were unavailable during the initial prefetch, once they download.

**Independent Test**: Import an iCloud photo (Wi-Fi off). Wait for face detection prefetch to fail. Turn Wi-Fi on. After download completes, play slideshow — photo should have face-aware Ken Burns zoom.

### Implementation for User Story 3

- [x] T015 [US3] Add `pendingRetry: Set<String>` property to `FaceDetectionCache` in `SoftBurn/Caching/FaceDetectionCache.swift`. When `detectFaces(photosLibraryLocalID:)` returns `[]` because `loadFullResolutionCGImage()` returned nil, add the item's cache key to `pendingRetry` instead of storing `[]` in the cache. This distinguishes "no faces detected" from "couldn't load image".

- [x] T016 [US3] Add `retryPendingItems()` method to `FaceDetectionCache` in `SoftBurn/Caching/FaceDetectionCache.swift`. This method: (1) takes all items from `pendingRetry`, (2) re-queues them through the existing `prefetch(items:)` flow (respecting the concurrency limit of 3), (3) removes items from `pendingRetry` as they are re-queued, (4) marks `AppSessionState` dirty if any new face rects are found.

- [x] T017 [US3] Wire `iCloudDownloadManager` download completion to `FaceDetectionCache.retryPendingItems()` in `SoftBurn/Caching/iCloudDownloadManager.swift`. When a download state transitions to `.ready`, call `await FaceDetectionCache.shared.retryPendingItems()` (or pass the specific item ID to retry just that item). Ensure this doesn't create a circular dependency — the manager notifies the cache, not the other way.

- [x] T018 [US3] Build the project: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Fix any compilation errors.

**Checkpoint**: Face detection retries for late-downloaded iCloud items. Photos that download after initial prefetch get face-aware zoom on next playback appearance. Build and test.

---

## Phase 5: User Story 4 — Preview Panel Placeholder (Priority: P4)

**Goal**: Show a properly-framed placeholder in the preview panel when an iCloud item is still loading, so controls don't float unanchored.

**Independent Test**: Import an iCloud-only item, select it, open preview. The preview shows a fixed-size frame with centered spinner and properly positioned controls (not floating).

### Implementation for User Story 4

- [x] T019 [US4] Identify the preview panel view file (likely in `SoftBurn/Views/Preview/` or a similar location). Read the current preview implementation to understand how the image frame is determined and where the spinner is displayed.

- [x] T020 [US4] Modify the preview panel view to display a minimum-size placeholder frame when the image is nil. Use `PHAsset.pixelWidth` / `pixelHeight` from the MediaItem's Photos Library asset to determine the correct aspect ratio if available, otherwise default to 4:3. Render a neutral gray rectangle at that aspect ratio with a centered `ProgressView` spinner. Ensure all overlay controls (close button, rotation controls, etc.) are anchored to this placeholder frame's bounds.

- [x] T021 [US4] Ensure the preview auto-updates when the iCloud item finishes downloading. Subscribe to download state changes from `iCloudDownloadManager` for the selected item. When state transitions to `.ready`, re-load the image and replace the placeholder with the actual content.

- [x] T022 [US4] Build the project: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Fix any compilation errors.

**Checkpoint**: Preview panel shows properly-framed placeholder for loading iCloud items. Controls are correctly positioned. Preview auto-updates on download completion.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Cleanup, edge cases, and final integration testing.

- [x] T023 Add the new `iCloudDownloadManager.swift` file to the Xcode project (`SoftBurn.xcodeproj/project.pbxproj`) if not already included by the build system. Ensure it's in the correct target membership.

- [x] T024 Ensure `iCloudDownloadManager.stop()` is called during app shutdown or when the slideshow window closes, to cancel the NWPathMonitor and any in-flight download tasks. Wire this into the existing `stop()` / cleanup path (likely in `SlideshowPlayerState.stop()` or `SlideshowWindowController`).

- [x] T025 Handle the edge case where a Photos Library item is removed from the user's Photos Library while tracked by `iCloudDownloadManager`. When PHImageManager returns an error indicating the asset no longer exists, transition to `.unavailable` and do not retry.

- [x] T026 Final build and comprehensive testing: `xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build`. Run the app and test against the iCloud test table in `specs/mediabugs.md`: (1) IC-1 through IC-5: grid download state overlays, (2) IC-6 through IC-10: playback placeholders, (3) IC-17: face detection retry, (4) IC-18: thumbnail with download state, (5) All tests with Wi-Fi on, Wi-Fi off, and Wi-Fi toggled mid-operation.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — creates the download manager and wires it into import.
- **User Story 1 (Phase 2)**: Depends on Phase 1 — needs iCloudDownloadManager to observe states.
- **User Story 2 (Phase 3)**: Depends on Phase 1 — needs download state to decide when to show placeholder. Can run in parallel with US1 (different files: renderer + player state vs. grid views).
- **User Story 3 (Phase 4)**: Depends on Phase 1 — needs download completion notifications. Can run in parallel with US1/US2 (FaceDetectionCache is a separate file).
- **User Story 4 (Phase 5)**: Depends on Phase 1 — needs download state observation. Can run in parallel with US1/US2/US3 (preview panel is a separate file).
- **Polish (Phase 6)**: Depends on all user stories being complete.

### User Story Dependencies

- **User Story 1 (P1)**: Depends on Foundational. No dependencies on other stories.
- **User Story 2 (P2)**: Depends on Foundational. No dependencies on other stories.
- **User Story 3 (P3)**: Depends on Foundational. No dependencies on other stories.
- **User Story 4 (P4)**: Depends on Foundational. No dependencies on other stories.

### Within Each Phase

- Phase 1: T001 → T002 → T003 → T004 → T005 (sequential — building up the actor incrementally)
- Phase 2: T006 → T007 → T008 can be interleaved → T009
- Phase 3: T010 → T011 → T012 → T013 → T014 (sequential — building renderer + player state changes)
- Phase 4: T015 → T016 → T017 → T018 (sequential — cache changes then wiring)
- Phase 5: T019 → T020 → T021 → T022 (sequential — research then implement)
- Phase 6: T023, T024, T025 can run in parallel → T026

### Parallel Opportunities

```text
# After Phase 1 completes, these four user stories can run in parallel
# (they modify different files):

US1: ThumbnailView.swift, ThumbnailCache.swift (grid layer)
US2: MetalSlideshowRenderer.swift, SlideshowPlayerView.swift (playback layer)
US3: FaceDetectionCache.swift, iCloudDownloadManager.swift (cache layer)
US4: Preview panel view file (preview layer)

# Phase 6 cleanup tasks:
T023: Xcode project file
T024: Shutdown/cleanup path
T025: Edge case handling
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Create iCloudDownloadManager + wire into import
2. Complete Phase 2: Grid download state overlays
3. **STOP and VALIDATE**: Build, run, test grid with iCloud items (IC-1 through IC-5)
4. If grid shows correct download states and auto-refreshes, the core infrastructure is validated

### Incremental Delivery

1. Phase 1 → iCloudDownloadManager infrastructure ready
2. Add US1 → Grid shows download state (MVP!)
3. Add US2 → Playback shows placeholders instead of blank
4. Add US3 → Face detection retries for late downloads
5. Add US4 → Preview panel properly framed
6. Polish → Edge cases, cleanup, comprehensive testing

---

## Notes

- All user stories share the Phase 1 iCloudDownloadManager — it's the only cross-cutting dependency
- No test framework available — all validation is visual inspection + build verification
- The `Network` framework (`import Network`) is new to this project — needs to be added to target
- Download states are transient (in-memory only) — not persisted to .softburn files
- Commit after each phase checkpoint for easy rollback
