# Metal Pipeline Architecture

**Status:** Active (as of January 2026)
**Replaces:** SwiftUI-based rendering (deprecated)

## Overview

SoftBurn uses a **unified Metal pipeline** for all slideshow rendering, regardless of whether Patina effects are enabled. This approach provides:
- Consistent rendering behavior across all effect modes
- GPU-accelerated performance for photos and videos
- Elimination of dual-path complexity
- Better control over video decoder resource management

## Architecture Layers

### 1. View Layer
**File:** `SlideshowPlayerView.swift`

```swift
MetalSlideshowView(playerState: playerState, settings: settings)
```

- Always uses Metal for rendering (no conditional SwiftUI path)
- Wraps `MTKView` with custom delegate
- Provides player state and settings to renderer

### 2. Metal View Wrapper
**File:** `MetalSlideshowView.swift`

- SwiftUI wrapper around `MTKView`
- Creates and manages `MetalSlideshowRenderer`
- Forwards state updates to renderer
- Handles view lifecycle (drawableSize changes, etc.)

### 3. Core Renderer
**File:** `MetalSlideshowRenderer.swift`

The renderer executes a **two-pass pipeline**:

#### Pass 1: Scene Pass (Media Composition)
Renders media layers to an offscreen texture with:
- Background color clear
- Current media layer (with transforms, effects, opacity)
- Next media layer during transitions (with transforms, effects, opacity)
- Ken Burns motion (pan & zoom)
- Color effects (monochrome, silvertone, sepia)
- Face detection zoom targets
- Rotation handling (0°, 90°, 180°, 270°)

**Output:** Scene texture (RGBA, full resolution)

#### Pass 2: Patina Pass (Post-Processing)
Applies film/analog simulation effects:
- **When Patina = None:** Direct blit copy (no post-processing)
- **When Patina = 35mm/Aged Film/VHS:** Fullscreen post-processing pass

**Output:** Final frame to drawable

### 4. Shader Programs
**Files:** `SlideshowShaders.metal`, `PatinaShaders.metal`

#### SlideshowShaders.metal (Pass 1)
- **Vertex shader:** Applies scale, translation, rotation to unit quad
- **Fragment shader:** Samples texture (photos or video), applies color effects
- **Rotation:** Handles 90° multiples via UV coordinate transforms
- **Origin:** Both photos and videos use top-left origin in Metal

#### PatinaShaders.metal (Pass 2)
- **Vertex shader:** Fullscreen triangle (covers entire viewport)
- **Fragment shader:** Three effect modes:
  - **35mm Film:** Fine grain, soft focus, highlight rolloff, vignette
  - **Aged Film:** Coarser grain, frame jitter, brightness drift, dust specks
  - **VHS:** Scanlines, chroma bleeding, tear lines, tracking noise
- **Rotation-aware VHS:** Uses logical UV space for directional effects on rotated videos

## Video Player Pooling

**File:** `VideoPlayerPool.swift`

To prevent hardware decoder exhaustion (FigFilePlayer errors -12860, -12864, -12852):

### Problem
macOS limits simultaneous hardware-accelerated video decode sessions (~16-32). Creating new `AVPlayer` instances during transitions exhausts this pool, causing:
- Black video flashes
- Video cutouts mid-playback
- Decoder resource contention

### Solution: Player Pool
```
VideoPlayerPool (actor)
  ├─ Pool of PooledPlayer instances (max 4)
  ├─ Reuses AVPlayer by reconfiguring with new assets
  └─ Avoids creating new hardware decoder sessions
```

**Key Classes:**
- `VideoPlayerPool` (actor): Manages pool lifecycle
- `PooledPlayer`: Wraps `AVPlayer` with metadata (duration, size, rotation)
- `PooledVideoPlayer` (@MainActor): Provides same interface as old `SoftBurnVideoPlayer`

**Flow:**
1. `VideoPlayerManager.createPooledPlayer()` acquires from pool
2. `VideoPlayerPool.configure()` loads asset metadata and reconfigures player
3. Player reused across transitions instead of destroyed/recreated
4. Pool drained on slideshow exit

## Texture Management

### Photo Textures
**Loading:** `MTKTextureLoader` from filesystem or Photos Library
**Caching:** Two-slot cache (current + next)
**Promotion:** When slide advances, `nextPhotoTexture` → `currentPhotoTexture` (avoids reload flash)

**PhotoKey:**
```swift
enum Source {
    case filesystem(url: URL, rotation: Int)
    case photosLibrary(localIdentifier: String, rotation: Int)
}
```

### Video Textures
**Loading:** `AVPlayerItemVideoOutput` + `CVMetalTextureCache` (GPU path, zero-copy)
**Source:** `VideoTextureSource` manages output attachment and frame sampling
**Rotation:** Extracted from video track's `preferredTransform` during player configuration

**Flow:**
```
AVPlayerItem → AVPlayerItemVideoOutput → CVPixelBuffer → CVMetalTexture → MTLTexture
```

## Transition Rendering

### Opacity Calculation
**Critical Fix:** Calculate transition state directly from `animationProgress`, not from `isTransitioning` flag.

**Why:** Avoids race condition where:
- Renderer sees `animationProgress >= transitionStart` → draws next photo
- But `isTransitioning` still false → next photo has opacity=1.0 → **flash**

**Solution:**
```swift
let isInTransition = animationProgress >= transitionStart && animationProgress < 1.0
let opacity = !isInTransition ? (slot == .current ? 1.0 : 0.0)
                               : (slot == .current ? 1.0 - transitionProgress
                                                   : transitionProgress)
```

### Ken Burns Motion
Both current and next media move simultaneously during transition:
- Current: Already moving (started in previous transition)
- Next: Starts moving at transition begin
- Motion duration: `holdDuration + 2 × transitionDuration`

**Start offsets:**
- Pan & Zoom: Random (10-20% in each axis)
- Zoom: Centered (0, 0)

**End offsets:**
- With face detection: Pan toward detected face centroid
- Without: Pan toward center (0, 0)

## Rotation Handling

### Metadata Extraction
From video track's `preferredTransform`:
```swift
let angle = atan2(transform.b, transform.a)
let degrees = ((Int(angle * 180 / .pi) % 360) + 360) % 360
```

### Shader Application
**rotateUV() function:**
- Applies 90° rotations via UV swizzling (no trigonometry)
- **Critical:** Both photos and videos use **top-left origin**
- No special Y-flip needed for videos (removed incorrect assumption)

**Rotation cases:**
- 0°: `uv` (identity)
- 90°: `(1 - uv.y, uv.x)` (portrait)
- 180°: `(1 - uv.x, 1 - uv.y)` (upside down)
- 270°: `(uv.y, 1 - uv.x)` (portrait, other way)

### VHS Rotation-Aware Effects
**Problem:** VHS effects (tear lines, scanlines) are directional and assume screen orientation.

**Solution:** Transform UV to "logical orientation" for directional effects:
```metal
float2 logicalUV = transformUVForRotation(uv, currentRotation);
// Use logicalUV for tear line Y position, scanline calculations
// Apply effects in logical space, then sample in screen space
```

## Uniforms and Parameters

### LayerUniforms (Scene Pass)
```metal
struct LayerUniforms {
    float2 scale;           // NDC scale for fitted media
    float2 translate;       // NDC offset (Ken Burns)
    float  opacity;         // Crossfade alpha
    int    effectMode;      // 0=none, 1=mono, 2=silver, 3=sepia
    int    rotationDegrees; // 0, 90, 180, 270
    int    debugShowFaces;  // Face box overlay toggle
    int    faceBoxCount;    // 0-8
    int    isVideoTexture;  // 1=video, 0=photo (for future use)
    float4 faceBoxes[8];    // Vision normalized rects
}
```

### PatinaUniforms (Patina Pass)
```metal
struct PatinaUniforms {
    int    mode;            // 0=none, 1=35mm, 2=aged, 3=VHS
    float  time;            // Animation time (seconds)
    float2 resolution;      // Drawable size
    float  seed;            // Random seed (per-session)
    int    currentRotation; // For VHS rotation-aware effects
    PatinaParams35mm p35;
    PatinaParamsAgedFilm aged;
    PatinaParamsVHS vhs;
}
```

All tuning parameters (grain intensity, blur radius, etc.) are live-editable via `PatinaTuningStore`.

## Performance Characteristics

### Advantages of Unified Metal Pipeline
- **Single code path:** No SwiftUI/Metal branching
- **GPU-resident:** Photos and videos rendered on GPU (no CPU roundtrip)
- **Efficient blending:** Hardware alpha blending for crossfades
- **Zero-copy video:** CVPixelBuffer → Metal texture directly
- **Player reuse:** Eliminates decoder thrashing

### Bottlenecks
- **Photo loading:** MTKTextureLoader can block main thread (async loading mitigates)
- **Video decoder pool:** Limited by macOS to ~16-32 sessions
- **Face detection:** CPU-bound (run during import, cached in .softburn files)

### Optimizations
1. **Texture promotion:** Reuse nextPhotoTexture when slide advances
2. **Player pooling:** Limit pool size to 4 (current + next + 2 buffer)
3. **Async loading:** Photos Library textures load asynchronously
4. **Prefetching:** Next photo/video loaded during current slide display

## Files Modified from SwiftUI Pipeline

### Removed/Deprecated
- SwiftUI transition views (PlainTransitionView, CrossFadeTransitionView, PanAndZoomTransitionView)
- KenBurnsImageView, KenBurnsVideoView (SwiftUI wrappers)
- PostProcessingEffect view modifier (CPU-side effects)
- Conditional rendering path in SlideshowPlayerView

### Added
- VideoPlayerPool.swift (player pooling)
- PooledVideoPlayer wrapper class
- Blit pass for Patina=none case

### Modified
- MetalSlideshowRenderer: Always active, conditional Patina pass
- SlideshowShaders.metal: Fixed video rotation assumptions
- PatinaShaders.metal: Added rotation-aware VHS effects
- VideoPlayerManager: Added createPooledPlayer() methods
- SlideshowPlayerState: Uses PooledVideoPlayer type

## Debug Logging

**Video debug logging** (enabled via `VideoDebugLogger`):
- Player pool lifecycle (warm up, acquire, release, drain)
- Rotation extraction from video tracks
- Player configuration events
- Texture source updates

**Example output:**
```
[Video] VideoPlayerPool: warmed up with 2 players
[Video] VideoPlayerPool: extracted rotation=90°, transform=(0.0, 1.0, -1.0, 0.0)
[Video] PooledPlayer.configure: setting rotationDegrees=90°
[Video] VideoTextureSource: setPooledPlayer rotation=90°
```

## Known Limitations

1. **Video flash on transitions:** Brief flash still occurs during video-to-video transitions (decoder resource contention persists despite pooling)
2. **Photos Library async loading:** First frame may show placeholder if texture not ready
3. **Memory pressure:** Large textures (4K+ photos) can cause memory warnings on older Macs
4. **Patina performance:** Complex effects (VHS with all features enabled) can drop to ~30fps on Intel Macs

## Future Improvements

1. **Metal texture cache for photos:** Similar to video texture cache to avoid reloading
2. **Larger player pool:** Dynamically adjust pool size based on available memory
3. **Prewarming:** Load first N textures before slideshow starts
4. **Shader optimizations:** Reduce overdraw, optimize VHS noise generation
5. **HDR support:** Extend pipeline to support HDR photo/video rendering

## Testing Checklist

When modifying the Metal pipeline:

- [ ] Test all transition styles (Plain, Crossfade, Pan & Zoom)
- [ ] Test all Patina modes (None, 35mm, Aged Film, VHS)
- [ ] Test all color effects (None, Monochrome, Silvertone, Sepia)
- [ ] Test photo sources (filesystem + Photos Library)
- [ ] Test video sources (filesystem + Photos Library)
- [ ] Test video rotations (0°, 90°, 180°, 270°)
- [ ] Test face detection zoom (on/off)
- [ ] Test photo-to-photo transitions (flash check)
- [ ] Test video-to-video transitions (decoder errors check)
- [ ] Test mixed content (photo → video → photo)
- [ ] Verify no FigFilePlayer errors in console
- [ ] Verify smooth 60fps playback (Performance profiler)
