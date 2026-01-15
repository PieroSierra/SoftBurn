# Mac Photos Library Integration - Implementation Plan

## Overview

Add native Mac Photos Library support to SoftBurn, allowing users to add photos and videos from their Photos app alongside filesystem files in the same slideshow. Photos Library assets will be accessed directly via PhotoKit (no filesystem export) with cross-device support for users with iCloud Photos enabled.

## User Requirements

- ✅ Mix Photos Library and filesystem media in same slideshow
- ✅ Direct PhotoKit access during playback (no export)
- ✅ Cross-device support for same iCloud account (cloudIdentifier + localIdentifier)
- ✅ Two separate menu items: "From Files..." and "From Photos Library..."
- ✅ Backward compatible with existing .softburn files

## Technical Approach

### Data Model Changes (Version 6 Document Format)

**MediaItem Enhancement:**
- Add discriminated union `Source` enum: `.filesystem(URL)` or `.photosLibrary(localIdentifier: String, cloudIdentifier: String?)`
- Maintain backward-compatible `url` computed property
- localIdentifier: device-specific (primary)
- cloudIdentifier: iCloud account-wide (for cross-device resolution)

**SlideshowDocument v6:**
- Bump version to 6
- Add `photosLibraryIdentifiers` field for Photos Library metadata
- Keep existing `bookmarksByPath` for filesystem items
- Face detection cache keys: `"file://path"` or `"photos://localID"`
- Auto-migrate v5 documents on load

### PhotoKit Integration Layer

**New File: PhotosLibraryManager.swift**
- Singleton @MainActor class for authorization and asset management
- Request Photos Library authorization (`.readWrite`)
- Convert PHAsset arrays to MediaItems (extract identifiers)
- Resolve cloudIdentifier → localIdentifier on document open (cross-device)
- Handle authorization states: notDetermined, authorized, denied

**Asset Resolution Strategy:**
1. Try `PHAsset.fetchAssets(withCloudIdentifiers:)` first (iCloud sync)
2. Fallback to `PHAsset.fetchAssets(withLocalIdentifiers:)` if cloud fails
3. Mark unavailable if both fail (show placeholder)

### UI Integration

**ContentView Changes:**
- Add "From Photos Library..." toolbar button (macOS 26 + legacy UI)
- Request authorization before opening picker
- Show alert if authorization denied (link to System Settings)

**New File: PhotosPickerView.swift**
- NSViewControllerRepresentable wrapper for PHPickerViewController
- Configuration: unlimited selection, filter = images + videos
- Convert PHPickerResult → PHAsset → MediaItem
- Call `slideshowState.addPhotos()` on selection

**Visual Indicators:**
- Badge on thumbnails for Photos Library items (blue photo icon)
- Placeholder view for unavailable assets (iCloud symbol + "Not Available")
- Show source in filename display

### Rendering Pipeline Updates

**MetalSlideshowRenderer.swift:**
- Extend `PhotoKey` to support `.photosLibrary(localIdentifier)`
- New method: `loadTextureFromPhotosLibrary(localIdentifier:)`
  - Fetch PHAsset via localIdentifier
  - Request full-size image via PHImageManager (synchronous, high quality, network allowed)
  - Convert CGImage → MTLTexture using `MTKTextureLoader.newTexture(cgImage:)`
- Performance: Same as filesystem (decode/upload identical, fetch adds 0-50ms)

**PlaybackImageLoader.swift:**
- Extend `loadImage(for:)` to handle `.photosLibrary` source
- New method: `loadFromPhotosLibrary(localIdentifier:)`
  - Fetch PHAsset
  - Request NSImage via PHImageManager
  - Apply rotation if needed

**New File: PhotosLibraryImageLoader.swift**
- Centralized actor for PHImageManager requests
- Methods: `loadCGImage()` (Metal path), `loadNSImage()` (SwiftUI path)
- Handle async requests with proper options

### Thumbnail & Face Detection Support

**ThumbnailCache.swift:**
- Extend `thumbnail(for:)` to handle `.photosLibrary` source
- Request 350x350 thumbnail from PHImageManager
- Cache key: localIdentifier
- Photos Library handles EXIF orientation automatically

**FaceDetectionCache.swift:**
- Extend cache keys: `"photos://localID"` for Photos Library items
- Request full-size CGImage from PHAsset, run Vision framework
- Face detection works identically for both sources

### Document Persistence

**Save Flow:**
- Extract Photos Library identifiers from MediaItems
- Save as `photosLibraryIdentifiers: [String: (local: String, cloud: String?)]`
- Keep existing bookmarks for filesystem items
- Face rects keyed by source-specific string

**Load Flow:**
- Resolve Photos Library assets via PhotosLibraryManager
- Filter unavailable items (not synced, deleted)
- Apply security-scoped bookmarks for filesystem items
- Ingest face detection cache

### Edge Case Handling

1. **Authorization Denied:** Show alert with link to System Settings
2. **iCloud Photos Disabled:** Still save localIdentifier (device-specific warning)
3. **Network Required:** Show loading indicator during iCloud download (progressHandler)
4. **Asset Deleted:** Skip slide during playback, show placeholder in grid
5. **Rotation:** Disable rotate button for Photos Library items (PhotoKit handles EXIF)

## Implementation Steps

### Step 1: Data Model Foundation
**Files:** Models.swift, SlideshowDocument.swift

1. Add `MediaItem.Source` enum with `.filesystem` and `.photosLibrary` cases
2. Add computed `url` property for backward compatibility
3. Update `SlideshowDocument` to version 6 with `photosLibraryIdentifiers` field
4. Implement v5 → v6 migration logic
5. Update `MediaEntry` codec to handle both sources

### Step 2: PhotoKit Foundation
**Files:** PhotosLibraryManager.swift (NEW)

1. Create `PhotosLibraryManager` singleton class (@MainActor)
2. Implement `requestAuthorization()` with PHPhotoLibrary API
3. Implement `createMediaItems(from: [PHAsset])` with identifier extraction
4. Implement `resolveAsset()` with cloudIdentifier → localIdentifier fallback
5. Add authorization status publishing

### Step 3: UI Integration
**Files:** ContentView.swift, PhotosPickerView.swift (NEW)

1. Add "From Photos Library..." button to toolbar (both UI styles)
2. Create `PhotosPickerView` NSViewControllerRepresentable
3. Implement PHPickerViewControllerDelegate
4. Add authorization flow (request → picker or alert)
5. Wire up selection handler to `slideshowState.addPhotos()`

### Step 4: Metal Rendering Path
**Files:** MetalSlideshowRenderer.swift, PhotosLibraryImageLoader.swift (NEW)

1. Extend `PhotoKey` struct with `.photosLibrary` case
2. Create `PhotosLibraryImageLoader` actor for centralized requests
3. Implement `loadTextureFromPhotosLibrary()` in renderer
4. Add PHAsset fetch + PHImageManager request (synchronous, full quality)
5. Convert CGImage → MTLTexture using existing MTKTextureLoader

### Step 5: SwiftUI Rendering Path
**Files:** PlaybackImageLoader.swift

1. Extend `loadImage(for:)` to switch on `MediaItem.source`
2. Implement `loadFromPhotosLibrary()` method
3. Use `PhotosLibraryImageLoader.loadNSImage()` for consistency
4. Handle rotation if needed

### Step 6: Thumbnail & Face Detection
**Files:** ThumbnailCache.swift, FaceDetectionCache.swift

1. Update `ThumbnailCache.thumbnail(for:)` to handle `.photosLibrary`
2. Request 350x350 thumbnail via PHImageManager
3. Update `FaceDetectionCache` cache key generation
4. Implement face detection for PHAsset (request CGImage → Vision)

### Step 7: Document Persistence
**Files:** ContentView.swift, SlideshowDocument.swift

1. Update `beginSave()` to extract Photos Library identifiers
2. Add `photosLibraryIdentifiers` to document encoding
3. Update `loadSlideshow()` to resolve Photos Library assets
4. Handle unavailable assets gracefully (filter + log)

### Step 8: Visual Polish & Edge Cases
**Files:** PhotoGridView.swift, ContentView.swift

1. Add badge overlay for Photos Library items in grid
2. Create `UnavailableAssetView` placeholder
3. Implement authorization denied alert
4. Add iCloud Photos disabled warning
5. Show loading indicator for network downloads
6. Disable rotate button for Photos Library selections

### Step 9: Testing & Verification
1. Import from Photos Library (single device)
2. Mix Photos Library + filesystem in same slideshow
3. Play slideshow with mixed sources (both Metal and SwiftUI paths)
4. Save and reload document
5. Cross-device test (Mac A → Mac B, same iCloud account)
6. Test with iCloud Photos disabled (localIdentifier only)
7. Test authorization denied flow
8. Delete asset from Photos Library, verify graceful handling

## Critical Files to Modify

1. **Models.swift** - Add `MediaItem.Source` enum (foundation)
2. **SlideshowDocument.swift** - Version 6 format with Photos Library metadata
3. **ContentView.swift** - UI integration for PhotosPicker and authorization
4. **MetalSlideshowRenderer.swift** - PHAsset → CGImage → MTLTexture loading
5. **PlaybackImageLoader.swift** - PHAsset → NSImage loading
6. **ThumbnailCache.swift** - Thumbnail generation for PHAsset
7. **FaceDetectionCache.swift** - Face detection for PHAsset
8. **PhotoGridView.swift** - Visual indicators for source type

## New Files to Create

1. **PhotosLibraryManager.swift** - Authorization and asset management
2. **PhotosPickerView.swift** - PHPickerViewController wrapper
3. **PhotosLibraryImageLoader.swift** - Centralized PHImageManager requests

## Verification Plan

### Unit Tests
- MediaItem.Source encoding/decoding
- Document v5 → v6 migration
- Cache key generation for mixed sources

### Integration Tests
- End-to-end import from Photos Library
- Mixed slideshow playback (both rendering paths)
- Save/load round-trip with Photos Library items
- Cross-device asset resolution

### Manual Testing
1. Import photos/videos from Photos app
2. Verify thumbnails and face detection work
3. Play slideshow with Ken Burns zoom on Photos Library faces
4. Save slideshow, quit app, reopen
5. Transfer .softburn to another Mac (same iCloud account)
6. Test all edge cases (auth denied, iCloud disabled, deleted assets)

## Benefits

- ✅ Native Photos Library integration (users expect this in modern macOS apps)
- ✅ Zero disk usage (no export needed)
- ✅ Cross-device portability (same iCloud account)
- ✅ Mixed sources (filesystem + Photos in same slideshow)
- ✅ Backward compatible (v5 documents continue working)
- ✅ Graceful degradation (missing assets show placeholders)
- ✅ Maintains performance (same decode/upload pipeline as filesystem)
