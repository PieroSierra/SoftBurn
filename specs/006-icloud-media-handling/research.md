# Research: iCloud Media Handling

**Feature**: 006-icloud-media-handling
**Date**: 2026-02-11

## Decision 1: Download State Tracking Architecture

**Decision**: New `iCloudDownloadState` published property on `MediaItem` (transient, not persisted), managed by a centralized `iCloudDownloadManager` actor.

**Rationale**: MediaItem is the natural unit — it's already observed everywhere (grid, preview, playback). A centralized manager avoids scattering download logic across ThumbnailCache, FaceDetectionCache, and SlideshowPlayerState. The actor model matches existing patterns (FaceDetectionCache, ThumbnailCache are actors).

**Alternatives considered**:
- **Enhance ThumbnailCache** — Too narrow. Download state affects playback, preview, and face detection, not just thumbnails. Would require duplicate state tracking elsewhere.
- **Per-view local state** — Each view tracks its own download state. Creates inconsistencies — grid might show "downloading" while playback sees "unavailable". Centralized source of truth is better.

## Decision 2: Network Monitoring

**Decision**: Use `NWPathMonitor` (Network framework) to detect connectivity changes. Monitor on a background queue. Publish state to `iCloudDownloadManager` which triggers retry of failed downloads.

**Rationale**: `NWPathMonitor` is the modern macOS API for network reachability. It's lightweight, event-driven (no polling), and built into the platform. The app already targets macOS 14+ which fully supports it.

**Alternatives considered**:
- **SCNetworkReachability** — Legacy API, callback-based, harder to integrate with Swift concurrency.
- **Polling with URLSession** — Wasteful. NWPathMonitor is purpose-built for this.
- **No monitoring, manual retry** — Poor UX. User would have to re-import or restart to retry failed iCloud items.

## Decision 3: Placeholder Strategy

**Decision**: Generate a Metal-compatible placeholder texture at app startup — a simple neutral gray with a centered SF Symbol (cloud.arrow.down for downloading, icloud.slash for unavailable). Use this texture in the renderer when image loading returns nil for a Photos Library item.

**Rationale**: The Metal renderer needs an `MTLTexture` — it can't display SwiftUI views. A pre-rendered placeholder texture loaded once at startup has zero per-frame cost. SF Symbols are available on all supported macOS versions and provide recognizable iconography.

**Alternatives considered**:
- **SwiftUI overlay on MetalView** — Z-ordering issues, doesn't participate in crossfade transitions, breaks the unified rendering pipeline.
- **Shader-generated placeholder** — Possible but complex. A static texture is simpler and just as effective.
- **Low-res iCloud thumbnail as placeholder** — Testing showed thumbnails appear instantly for iCloud items. Could use the low-res thumbnail WITH a downloading overlay. This is actually better for UX — the user sees a preview of the content with a clear "still downloading" indicator.

**Revised decision**: Use the low-res iCloud thumbnail (already available) as the texture, with a small overlay indicator for download state. For playback, if even the low-res image isn't available (rare), fall back to the neutral gray placeholder.

## Decision 4: Face Detection Retry Mechanism

**Decision**: Track items that failed face detection in a "pending retry" set within FaceDetectionCache. When `iCloudDownloadManager` signals an item has completed downloading, re-queue face detection for any items in the pending set.

**Rationale**: FaceDetectionCache already has the `inFlight` set pattern and respects concurrency limits. Adding a `pendingRetry` set is minimal. The trigger comes from the download manager, not polling — efficient and event-driven.

**Alternatives considered**:
- **Periodic retry timer** — Wasteful. Better to react to download completion events.
- **Re-run prefetch for all items** — Unnecessary work for items that already have faces cached. Targeted retry is more efficient.

## Decision 5: Preview Panel Fix

**Decision**: Add a default-size placeholder frame to the preview panel that displays when the image is nil. Use a fixed aspect ratio (e.g., 4:3 or the grid cell's aspect ratio) so controls have a reference frame.

**Rationale**: The preview already has a spinner. The issue is that when `image == nil`, the frame collapses to zero size and controls float. A minimum-size placeholder frame fixes the layout without changing preview logic.

**Alternatives considered**:
- **Intrinsic content size from PHAsset metadata** — PHAsset has `pixelWidth`/`pixelHeight` which could provide the correct aspect ratio even before download. This is better — use it if available, fall back to 4:3.

## Codebase Findings

### Current Failure Points (all silent)

| Component | iCloud item behavior | Code location |
|-----------|---------------------|---------------|
| ThumbnailCache | Returns nil → grid shows generic photo icon | ThumbnailCache.swift:128-141 |
| FaceDetectionCache | Returns [] → no face-aware zoom, never retried | FaceDetectionCache.swift:213-244 |
| Playback (photo) | Returns nil → black frame | SlideshowPlayerView.swift:302-372 |
| Playback (video) | Returns nil → black frame | VideoPlayerManager.swift:374+ |
| Preview | Shows spinner, no frame | Preview panel code |

### Existing Hooks

- `PhotosLibraryImageLoader.loadCGImage()` / `.loadNSImage()` — have error info dict but ignore it
- `PHImageErrorKey` in callback info — available but unused for state tracking
- `PooledVideoPlayer.status` — already tracks `.loading` / `.readyToPlay` / `.failed`
- `AppSessionState` dirty marking — triggered when face detection completes
- `ThumbnailView.isLoading` — boolean, but doesn't distinguish loading from failed

### No Network Monitoring Exists

Zero `NWPathMonitor`, `SCNetworkReachability`, or equivalent code found in the codebase. This is the most fundamental gap.
