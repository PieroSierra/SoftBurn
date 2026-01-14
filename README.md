WORK IN PROGRESS
---

# SoftBurn

> _A beautiful, free slideshow app for macOS that doesn't compromise on taste._

**[Hero screenshot coming soon]**

## Why SoftBurn?

There are surprisingly few free, beautiful, and simple media slideshow apps for the Mac. Most options are either feature-bloated consumer software, legacy tools from the iPhoto era, or slideshow modes buried in photo managers that feel like afterthoughts.

**SoftBurn exists to solve this problem.** It's built on a simple philosophy: slideshows should be pretty by default, easy to create, and a joy to watch. Leveraging macOS's LiquidGlass design language and Metal-accelerated rendering, SoftBurn delivers a modern, tasteful slideshow experience that feels native to the platform.

## Features

- **Effortlessly Beautiful** - Intelligent face detection + Ken Burns effects make every slideshow dynamic without manual tweaking
- **Film Simulation** - GPU-accelerated analog effects (35mm film grain, aged patina, VHS artifacts) for authentic vintage aesthetics
- **Metal-Accelerated** - Two-pass rendering pipeline for real-time effects without compromising performance
- **LiquidGlass Design** - Modern macOS styling that embraces system design language (Tahoe+)
- **Smart Caching** - Prefetched face detection and lazy thumbnail generation keep the UI responsive
- **Versatile Media** - Photos, videos, and custom music support
- **Persistent Projects** - Save slideshows as `.softburn` files with all settings and metadata

## Technical Highlights

SoftBurn is a love letter to native macOS development:

- **Swift 6 Concurrency** - Strict actor isolation with background processing for heavy operations
- **SwiftUI + Metal 3** - Hybrid rendering strategy: SwiftUI for simple transitions, Metal for advanced effects
- **Vision Framework** - Face detection zoom automatically centers on subjects
- **Zero Dependencies** - Pure Apple frameworks (no external packages)
- **Sandboxed & Secure** - Security-scoped bookmarks enable cross-session file access

### Architecture at a Glance

```
UI Layer (SwiftUI)
  ↓
State Management (@MainActor)
  ↓
Conditional Rendering Path:
  • SwiftUI Path → Direct transitions + CPU effects
  • Metal Path → Two-pass GPU pipeline (scene + patina)
  ↓
Background Actors (Face Detection, Thumbnails, Caching)
```

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation.

## Getting Started

### Prerequisites

- macOS 14+ (Sonoma)
- Xcode 15+
- Swift 5.9+

### Building

```bash
# Clone the repository
git clone https://github.com/yourusername/SoftBurn.git
cd SoftBurn

# Open in Xcode (recommended)
open SoftBurn.xcodeproj

# Or build from command line
xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build
```

No external dependencies to install - all frameworks are built into macOS.

### Running

1. Build and run in Xcode (⌘R)
2. Import photos/videos via the + button or drag-and-drop
3. Adjust settings in the sidebar (transition style, duration, effects)
4. Hit Play to launch the slideshow in fullscreen

## Project Structure

```
SoftBurn/
├── SoftBurnApp.swift           # App entry point
├── Views/
│   ├── ContentView.swift       # Main window UI
│   ├── PhotoGridView.swift     # Media library grid
│   └── SlideshowPlayerView.swift # Playback orchestration
├── Rendering/
│   ├── Metal/                  # Metal rendering pipeline
│   │   ├── MetalSlideshowRenderer.swift
│   │   ├── SlideshowShaders.metal
│   │   └── PatinaShaders.metal
│   └── SwiftUI/                # SwiftUI transition views
├── State/
│   ├── AppSessionState.swift   # Lifecycle & dirty tracking
│   ├── SlideshowState.swift    # Media library management
│   └── SlideshowSettings.swift # Persistent preferences
├── Services/
│   ├── FaceDetectionCache.swift
│   ├── ThumbnailCache.swift
│   └── MusicPlaybackManager.swift
└── Models/
    ├── MediaItem.swift
    └── SlideshowDocument.swift # .softburn file format
```

## Roadmap

- [ ] Multi-monitor support refinements
- [ ] Additional transition styles
- [ ] Export to video
- [ ] Cloud storage integration
- [ ] Customizable keyboard shortcuts

## Contributing

Contributions are welcome! Please:

1. Read [CLAUDE.md](CLAUDE.md) for architecture guidance
2. Place feature specs in `/specs` before implementing
3. Follow Swift concurrency best practices (@MainActor isolation)
4. Test on multiple macOS versions if changing UI

## License

[To be determined - add license here]