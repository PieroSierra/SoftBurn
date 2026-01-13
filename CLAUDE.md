# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SoftBurn is a native macOS slideshow application built with SwiftUI and Metal. It provides sophisticated slideshow creation and playback with advanced visual effects, face detection zoom capabilities, and film/analog simulation through GPU-accelerated rendering.

**Tech Stack:**
- Swift 5.9+ with strict concurrency (Swift 6 compatible)
- SwiftUI + AppKit for UI
- Metal 3 for GPU-accelerated rendering
- Vision framework for face detection
- AVFoundation for video/audio playback

## Build Commands

```bash
# Build the project (Release configuration is default)
xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build

# Build for Release
xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Release build

# Clean build folder
xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn clean

# Open in Xcode (recommended for development)
open SoftBurn.xcodeproj
```

**Note:** There are no external dependencies - all frameworks are built-in macOS frameworks.

## Architecture Overview

### Layered Architecture

```
UI Layer (SwiftUI)
    ContentView → PhotoGridView → SlideshowPlayerView

State Management Layer
    AppSessionState (dirty state, pending actions)
    SlideshowState (media items, selection)
    SlideshowSettings (UserDefaults-backed preferences)

Rendering & Effects Layer
    SwiftUI Path: Transition views + PostProcessingEffect
    Metal Path: MetalSlideshowView + Two-pass pipeline (scene + patina)

Services Layer
    PhotoDiscovery, FaceDetectionCache, ThumbnailCache, MusicPlaybackManager

Data & Persistence Layer
    SlideshowDocument (.softburn JSON format with security-scoped bookmarks)
```

### State Management

Three primary observable objects coordinate app state:

1. **AppSessionState** (@MainActor, singleton) - Tracks dirty/clean state for unsaved changes, manages app lifecycle (quit/close with prompts)

2. **SlideshowState** (@MainActor, @ObservableObject) - Array of MediaItems with CRUD operations, selection tracking, rotation metadata

3. **SlideshowSettings** (@MainActor, singleton) - UserDefaults-backed settings (transition style, duration, effects, music) and per-document properties

### Two-Path Rendering Strategy

The app uses **conditional rendering** based on whether Patina effects are enabled:

**SwiftUI Path** (no Patina):
- Direct transition view rendering (PlainTransitionView, CrossFadeTransitionView, PanAndZoomTransitionView)
- PostProcessingEffect modifier applied for monochrome/silvertone/sepia
- Lower overhead, simpler pipeline

**Metal Path** (Patina enabled):
- MetalSlideshowView wraps MTKView with custom delegate
- MetalSlideshowRenderer executes two-pass pipeline:
  - Pass 1: Render media with transforms to offscreen texture
  - Pass 2: Apply Patina post-processing (35mm film, aged film, VHS simulation)
- SlideshowShaders.metal + PatinaShaders.metal implement GPU kernels

### Concurrency Model

Uses Swift's actor model with strict @MainActor isolation:

- **Main Actor**: All UI state (AppSessionState, SlideshowState, SlideshowSettings, SlideshowPlayerState)
- **Actors** (background): FaceDetectionCache, ThumbnailCache, VideoMetadataCache
- **Sendable**: MediaItem, SlideshowDocument, and all data passed between actors

Key design: Heavy operations (face detection, thumbnails) run on background actors; UI state always on main thread.

### File Format

`.softburn` files are JSON-based with:
- Versioned format (v5 current) for backward compatibility
- MediaItem array with URLs and rotation metadata
- Security-scoped bookmarks for sandboxed file access
- Cached face detection rects (not regenerated on load)
- Slideshow settings snapshot

## Key Files & Entry Points

**App Entry:**
- `SoftBurnApp.swift` - @main entry point, window group setup
- `ContentView.swift` - Root view, file I/O orchestration, slideshow launch

**Core State:**
- `AppSessionState.swift` - Dirty state tracking and lifecycle
- `SlideshowState.swift` - Media library management
- `SlideshowSettings.swift` - Persistent preferences

**Rendering Pipeline:**
- `SlideshowPlayerView.swift` - Playback container, routing to SwiftUI vs Metal path
- `MetalSlideshowView.swift` + `MetalSlideshowRenderer.swift` - Metal rendering implementation
- `SlideshowShaders.metal` - Media rendering shaders
- `PatinaShaders.metal` - Film simulation shaders (grain, scratches, vignette, color shifts)
- `PostProcessingEffect.swift` - SwiftUI-based effects (CPU-side)

**Transitions:**
- `PlainTransitionView.swift` - Direct image display
- `CrossFadeTransitionView.swift` - Fade between slides
- `PanAndZoomTransitionView.swift` - Ken Burns effect with face-detection zoom

**Caching & Discovery:**
- `FaceDetectionCache.swift` - Vision framework face detection (actor, prefetch during import)
- `ThumbnailCache.swift` - Thumbnail generation (actor, on-demand)
- `PhotoDiscovery.swift` - Recursive folder scanning

**Audio:**
- `MusicPlaybackManager.swift` - Built-in tracks + custom music file support

**Window Management:**
- `SlideshowWindowController.swift` - Fullscreen borderless window, presentation options
- `MainWindowDelegate.swift` - Intercepts close for unsaved changes prompt

## Feature Specifications

When creating specifications for new features, place them in the `/specs` folder to keep the repository organized. Specification documents should describe:
- Feature requirements and goals
- Implementation approach and architecture decisions
- Files that will be modified or created
- User-facing behavior and UI changes

## Common Development Patterns

### Adding New Effects

1. For SwiftUI effects: Extend `PostProcessingEffect.swift` with new cases
2. For Metal effects: Add shader functions to `PatinaShaders.metal` and parameters to `SlideshowSettings`
3. Effects tuning: Use EffectTuningView debug window (recent addition for parameter adjustment)

### Working with Media

- Media is represented by `MediaItem` (Codable, Sendable, Identifiable)
- Rotation is non-destructive (stored as 0/90/180/270° metadata)
- Face detection runs once during import/open, cached for lifetime
- Security-scoped bookmarks enable cross-session file access in sandboxed environment

### Slideshow Playback Flow

1. User clicks "Play" → `ContentView.playSlideshow()`
2. Create `SlideshowPlayerView` with photos + settings
3. `SlideshowWindowController.present()` creates fullscreen window
4. `SlideshowPlayerState` manages timer-based transitions
5. Choose rendering path: check `settings.patina` → route to Metal or SwiftUI
6. Exit via Esc → `performSafeExit()` → stop timers, fade music, close window

### Thumbnail & Face Detection

- **ThumbnailCache**: Generates on-demand during grid scroll, respects rotation, handles video frames
- **FaceDetectionCache**: Prefetch during import with limit of 3 parallel detections (maintains UI responsiveness)
- Face detection results persisted in `.softburn` files to avoid regeneration

## Recent Development Focus

From git history, recent work includes:
- Effects parameter tuning and debug UI
- Metal pipeline refinement
- Dark mode fixes
- Rotation support in main window
- Major refactor to Metal-based effects pipeline

Current state: Stable, production-ready with ongoing polish on effects parameters.

## File Operations

### Import
1. fileImporter dialog → folders/images/videos
2. PhotoDiscovery.discoverPhotos() recursively scans
3. SlideshowState.addPhotos() adds MediaItems
4. AppSessionState marks dirty
5. FaceDetectionCache.prefetch() runs in background

### Save
1. Capture current state (photos + settings)
2. Extract face rects from FaceDetectionCache
3. Create security-scoped bookmarks for each file URL
4. Create SlideshowDocument and encode to JSON
5. AppSessionState.markClean()

### Open
1. fileImporter for .softburn files
2. Decode SlideshowDocument (handles version migration)
3. Start bookmark access for each media URL
4. Populate SlideshowState with photos
5. Ingest cached face rects into FaceDetectionCache (avoid recomputation)
6. AppSessionState.markClean()

## Threading & Performance

- Face detection limited to 3 concurrent operations to maintain UI responsiveness
- Metal rendering uses double-buffering via MTKView
- Thumbnail generation is lazy (on-demand during scroll)
- Video metadata cached to avoid repeated AVAsset introspection
- Main thread never blocked during import/export (async operations)

## macOS Version Compatibility

- macOS 26+ (Tahoe): LiquidGlass styling
- Older versions: Graceful fallback UI
- All features work across supported versions (no breaking dependencies on latest APIs)
