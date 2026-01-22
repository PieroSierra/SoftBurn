# Quickstart: Open Recent Feature

**Date**: 2026-01-22
**Feature Branch**: `001-open-recent`

## Overview

This guide provides step-by-step implementation instructions for the Open Recent feature in SoftBurn.

---

## Prerequisites

- Xcode with Swift 5.9+
- macOS 13+ target
- Existing SoftBurn project on branch `001-open-recent`

---

## Implementation Steps

### Step 1: Create RecentSlideshow Model

**File**: `SoftBurn/Models/RecentSlideshow.swift` (NEW)

```swift
import Foundation

/// Represents a recently opened slideshow for the Open Recent menu
struct RecentSlideshow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let lastOpened: Date

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.filename = url.deletingPathExtension().lastPathComponent
        self.lastOpened = Date()
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
```

### Step 2: Create RecentSlideshowsManager

**File**: `SoftBurn/State/RecentSlideshowsManager.swift` (NEW)

```swift
import Foundation
import SwiftUI

@MainActor
final class RecentSlideshowsManager: ObservableObject {
    static let shared = RecentSlideshowsManager()

    private static let maxItems = 5
    private static let storageKey = "recents.list"

    @AppStorage(storageKey) private var storedJSON: String = "[]"
    @Published private(set) var recentSlideshows: [RecentSlideshow] = []

    private init() { loadFromStorage() }

    func addOrUpdate(url: URL) {
        var list = recentSlideshows.filter { $0.url != url }
        list.insert(RecentSlideshow(url: url), at: 0)
        if list.count > Self.maxItems { list = Array(list.prefix(Self.maxItems)) }
        recentSlideshows = list
        saveToStorage()
    }

    func clearAll() {
        recentSlideshows = []
        saveToStorage()
    }

    var isEmpty: Bool { recentSlideshows.isEmpty }

    private func loadFromStorage() {
        guard let data = storedJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentSlideshow].self, from: data) else { return }
        recentSlideshows = decoded
    }

    private func saveToStorage() {
        guard let data = try? JSONEncoder().encode(recentSlideshows),
              let json = String(data: data, encoding: .utf8) else { return }
        storedJSON = json
    }
}
```

### Step 3: Add Notifications

**File**: `SoftBurn/App/SoftBurnApp.swift` - Add to notification extensions

```swift
extension Notification.Name {
    // ... existing notifications ...
    static let openRecentSlideshow = Notification.Name("SoftBurn.openRecentSlideshow")
    static let clearRecentList = Notification.Name("SoftBurn.clearRecentList")
}
```

### Step 4: Add File Menu "Open Recent" Submenu

**File**: `SoftBurn/App/SoftBurnApp.swift` - Add inside CommandGroup after "Open Slideshow"

```swift
Menu {
    ForEach(RecentSlideshowsManager.shared.recentSlideshows) { recent in
        Button(action: {
            NotificationCenter.default.post(name: .openRecentSlideshow, object: recent.url)
        }) {
            Text(recent.filename)
        }
        .disabled(!recent.fileExists)
    }

    if !RecentSlideshowsManager.shared.isEmpty {
        Divider()
    }

    Button("Clear List") {
        NotificationCenter.default.post(name: .clearRecentList, object: nil)
    }
    .disabled(RecentSlideshowsManager.shared.isEmpty)
} label: {
    Label("Open Recent", systemImage: "clock")
}
```

### Step 5: Add Toolbar Submenus

**File**: `SoftBurn/Views/Main/ContentView.swift`

Add `@ObservedObject var recentsManager = RecentSlideshowsManager.shared` to view properties.

**Legacy Toolbar** (inside File Menu dropdown):
```swift
Menu {
    ForEach(recentsManager.recentSlideshows) { recent in
        Button(recent.filename) {
            openRecentSlideshow(url: recent.url)
        }
        .disabled(!recent.fileExists)
    }
    if !recentsManager.isEmpty { Divider() }
    Button("Clear List") { recentsManager.clearAll() }
        .disabled(recentsManager.isEmpty)
} label: {
    Label("Open Recent", systemImage: "clock")
}
```

**LiquidGlass Toolbar**: Same pattern in navigation placement.

### Step 6: Add Notification Handlers

**File**: `SoftBurn/Views/Main/ContentView.swift` - Add to view body

```swift
.onReceive(NotificationCenter.default.publisher(for: .openRecentSlideshow)) { notification in
    guard let url = notification.object as? URL else { return }
    openRecentSlideshow(url: url)
}
.onReceive(NotificationCenter.default.publisher(for: .clearRecentList)) { _ in
    RecentSlideshowsManager.shared.clearAll()
}
```

### Step 7: Create Open Recent Handler

**File**: `SoftBurn/Views/Main/ContentView.swift` - Add function

```swift
private func openRecentSlideshow(url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else {
        // Show alert for missing file
        return
    }

    if !slideshowState.isEmpty {
        pendingOpenURL = url
        showOpenWarning = true
    } else {
        loadSlideshow(from: url)
    }
}
```

### Step 8: Update loadSlideshow to Track Recents

**File**: `SoftBurn/Views/Main/ContentView.swift` - Modify existing function

Add at end of successful load:
```swift
RecentSlideshowsManager.shared.addOrUpdate(url: url)
```

---

## Testing Checklist

1. [ ] Open 3 different slideshows → verify they appear in File menu recents (most recent first)
2. [ ] Click recent item → slideshow opens
3. [ ] Quit and relaunch app → recents persist
4. [ ] Open same slideshow twice → moves to top (no duplicates)
5. [ ] Open 6 slideshows → only 5 most recent shown
6. [ ] Move a .softburn file → menu item disabled, error on click
7. [ ] Click "Clear List" → all entries removed
8. [ ] Empty list → "Clear List" disabled
9. [ ] Legacy toolbar shows same recents as File menu
10. [ ] LiquidGlass toolbar (macOS 26+) shows same recents

---

## Build Commands

```bash
# Build Debug
xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Debug build

# Build Release
xcodebuild -project SoftBurn.xcodeproj -scheme SoftBurn -configuration Release build
```
