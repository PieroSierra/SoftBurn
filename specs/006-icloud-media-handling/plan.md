# Implementation Plan: Improve iCloud Media Handling

**Branch**: `006-icloud-media-handling` | **Date**: 2026-02-11 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/006-icloud-media-handling/spec.md`

## Summary

Add download state tracking, visual feedback, graceful degradation, and retry logic for Photos Library items stored in iCloud. Currently, iCloud items that haven't downloaded appear as blank/generic placeholders with no error indication, face detection silently fails, and there's no retry mechanism. The fix adds: (1) a centralized iCloud download manager that tracks per-item download state, (2) network monitoring via NWPathMonitor for automatic retry, (3) placeholder textures for the Metal renderer during playback, (4) download state overlays in the grid, and (5) face detection retry for late-downloaded items.

## Technical Context

**Language/Version**: Swift 5.9+ (strict concurrency, Swift 6 compatible)
**Primary Dependencies**: SwiftUI, Metal 3, PhotoKit (PHImageManager, PHAssetResourceManager), Network framework (NWPathMonitor), Vision framework — all built-in macOS frameworks
**Storage**: In-memory state (download states are transient, not persisted to .softburn files)
**Testing**: Visual inspection only (GPU rendering pipeline, no unit test framework)
**Target Platform**: macOS 14+ (Sonoma and later)
**Project Type**: Single macOS app (Xcode project)
**Performance Goals**: 60fps rendering unaffected by download state checking; grid updates within 1s of state changes
**Constraints**: Must not block main thread; downloads are background operations; must work offline (graceful degradation)
**Scale/Scope**: Affects 6 files (new: 1, modified: 5). No new frameworks beyond Network.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

No project constitution configured. Default principles apply:
- No unnecessary dependencies (using only built-in macOS frameworks) ✅
- No over-engineering (minimal new abstractions — one new actor) ✅
- Consistent with existing patterns (actor model, @MainActor isolation) ✅

## Project Structure

### Documentation (this feature)

```text
specs/006-icloud-media-handling/
├── plan.md              # This file
├── research.md          # Phase 0 output (completed)
├── spec.md              # Feature specification
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (via /speckit.tasks)
```

### Source Code (files to create or modify)

```text
SoftBurn/
├── Caching/
│   ├── iCloudDownloadManager.swift     # NEW — centralized download state + retry
│   ├── PhotosLibraryImageLoader.swift  # MODIFY — report download state to manager
│   ├── FaceDetectionCache.swift        # MODIFY — pending retry set, re-trigger on download
│   └── ThumbnailCache.swift            # MODIFY — report state, trigger thumbnail refresh
├── Models/
│   └── Models.swift                    # MODIFY — add transient downloadState to MediaItem (or observed via manager)
├── Views/
│   ├── Grid/
│   │   └── ThumbnailView.swift         # MODIFY — download state overlay (spinner/unavailable icon)
│   └── Preview/
│       └── [preview panel file]        # MODIFY — placeholder frame for loading items
├── Rendering/
│   └── MetalSlideshowRenderer.swift    # MODIFY — placeholder texture for unavailable items
└── Views/Slideshow/
    └── SlideshowPlayerView.swift       # MODIFY — placeholder handling in prepareCurrentAndNext/loadNext
```

**Structure Decision**: All changes within the existing SoftBurn single-app structure. One new file (`iCloudDownloadManager.swift`) in `Caching/` to match existing actor pattern (FaceDetectionCache, ThumbnailCache). No new directories.

## Architecture

### Before (Current State)

```
Import → PhotosLibraryImageLoader.load*() → nil on failure (silent)
                                           ↓
Grid: shows generic photo icon         Playback: shows black frame
Face detection: caches [] (never retried)
No network monitoring. No retry. No per-item download state.
```

### After (Target State)

```
Import → iCloudDownloadManager.trackItem(item)
              ↓                    ↓
    PhotosLibraryImageLoader    NWPathMonitor
    reports download result     detects network changes
              ↓                    ↓
    downloadState updated     triggers retry queue
              ↓
    Observers react:
    ├── ThumbnailView: shows spinner/unavailable overlay
    ├── SlideshowPlayerState: loads placeholder texture for unavailable items
    ├── FaceDetectionCache: re-runs detection when item downloads
    └── Preview panel: shows framed placeholder with spinner
```

### Key Design Decisions

1. **iCloudDownloadManager** (new actor):
   - Singleton actor like FaceDetectionCache
   - Tracks `[MediaItem.ID: DownloadState]` where DownloadState = `.ready` / `.downloading` / `.unavailable(Error?)`
   - Manages NWPathMonitor on a background queue
   - Retry queue: when network becomes available, re-attempts failed downloads
   - Publishes state changes via `@Published` or AsyncStream for UI observation

2. **Download State Flow**:
   ```
   .downloading ──success──→ .ready
        │                      ↑
        │ failure              │ retry (network restored)
        ↓                      │
   .unavailable ──────────────┘
   ```

3. **Placeholder Texture**:
   - For playback: pre-rendered `MTLTexture` with cloud icon, created once at renderer init
   - When `currentImage == nil && item.isFromPhotosLibrary`: use placeholder texture instead of nil
   - Placeholder participates in crossfade transitions normally (it's just a texture)
   - When low-res iCloud thumbnail is available (common case): use that as the texture

4. **Face Detection Retry**:
   - FaceDetectionCache gains a `pendingRetry: Set<String>` alongside existing `inFlight: Set<String>`
   - When detection fails because image was nil (iCloud item): add to `pendingRetry` instead of caching `[]`
   - iCloudDownloadManager notifies FaceDetectionCache when an item completes download
   - FaceDetectionCache re-queues items from `pendingRetry`, respecting concurrency limit

5. **Grid Overlay**:
   - ThumbnailView observes download state from iCloudDownloadManager
   - Overlays: small cloud-with-arrow (downloading) or cloud-slash (unavailable) over thumbnail corner
   - Disappears when state becomes `.ready`

6. **Preview Placeholder**:
   - When image is nil, show a fixed-size frame (use PHAsset.pixelWidth/pixelHeight if available, else 4:3)
   - Centered ProgressView spinner within the frame
   - All controls anchored to the frame bounds

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| NWPathMonitor false positives (reports connected but iCloud unreachable) | Medium | Retry with backoff; don't retry more than 3 times without user action |
| PHImageManager callback never fires (network drops mid-download) | High (known issue) | Add timeout to download operations (30s); transition to `.unavailable` on timeout |
| Placeholder texture looks jarring in slideshow | Low | Use low-res iCloud thumbnail when available; only fall back to icon placeholder |
| Download state observation causes main thread pressure | Low | Manager is a background actor; UI updates throttled via Combine/AsyncSequence |
