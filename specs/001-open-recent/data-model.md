# Data Model: Open Recent Feature

**Date**: 2026-01-22
**Feature Branch**: `001-open-recent`

## Entity: RecentSlideshow

Represents a recently opened slideshow entry in the recents list.

### Fields

| Field | Type | Description | Constraints |
|-------|------|-------------|-------------|
| `id` | `UUID` | Unique identifier for the entry | Required, auto-generated |
| `url` | `URL` | File URL of the slideshow | Required, must be valid file path |
| `filename` | `String` | Display name (derived from URL) | Required, non-empty |
| `lastOpened` | `Date` | Timestamp when slideshow was last opened | Required, auto-set on creation |

### Swift Definition

```swift
import Foundation

/// Represents a recently opened slideshow for the Open Recent menu
struct RecentSlideshow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let lastOpened: Date

    /// Creates a new recent slideshow entry
    /// - Parameter url: The file URL of the slideshow
    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.filename = url.deletingPathExtension().lastPathComponent
        self.lastOpened = Date()
    }

    /// Whether the file still exists at the stored path
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
```

### Validation Rules

1. **URL Validity**: Must be a valid file URL (not remote)
2. **Filename Extraction**: Derived from URL's last path component, extension removed
3. **Timestamp**: Always set to current date on creation (not user-editable)

### State Transitions

```
[New Open] → Create RecentSlideshow → Add to list front
                    ↓
[Re-Open Same] → Update timestamp → Move to list front
                    ↓
[List Full (5)] → Remove oldest entry
                    ↓
[Clear List] → Remove all entries
```

---

## Entity: Recent List (Managed by RecentSlideshowsManager)

The manager maintains an ordered collection of RecentSlideshow entries.

### Business Rules

| Rule | Description |
|------|-------------|
| **Maximum Size** | List contains at most 5 entries |
| **Ordering** | Most recently opened first (descending by `lastOpened`) |
| **Uniqueness** | No duplicate URLs; reopening moves entry to front |
| **Persistence** | Survives app restart via UserDefaults |

### Operations

| Operation | Behavior |
|-----------|----------|
| `addOrUpdate(url:)` | Add new entry at front, or move existing to front; trim to 5 |
| `clearAll()` | Remove all entries |
| `remove(id:)` | Remove specific entry (optional, not in spec) |

### Persistence Format

```json
[
  {
    "id": "uuid-string",
    "url": "file:///path/to/slideshow.softburn",
    "filename": "slideshow",
    "lastOpened": "2026-01-22T10:30:00Z"
  }
]
```

Stored in UserDefaults under key: `"recents.list"`

---

## Manager: RecentSlideshowsManager

Singleton manager following `SlideshowSettings.swift` pattern.

### Swift Definition

```swift
import Foundation
import SwiftUI

/// Manages the list of recently opened slideshows
@MainActor
final class RecentSlideshowsManager: ObservableObject {
    static let shared = RecentSlideshowsManager()

    private static let maxItems = 5
    private static let storageKey = "recents.list"

    @AppStorage(storageKey) private var storedJSON: String = "[]"
    @Published private(set) var recentSlideshows: [RecentSlideshow] = []

    private init() {
        loadFromStorage()
    }

    /// Add or update a slideshow in the recents list
    func addOrUpdate(url: URL) {
        var list = recentSlideshows.filter { $0.url != url }
        let entry = RecentSlideshow(url: url)
        list.insert(entry, at: 0)
        if list.count > Self.maxItems {
            list = Array(list.prefix(Self.maxItems))
        }
        recentSlideshows = list
        saveToStorage()
    }

    /// Clear all recent entries
    func clearAll() {
        recentSlideshows = []
        saveToStorage()
    }

    /// Whether the list has any entries
    var isEmpty: Bool {
        recentSlideshows.isEmpty
    }

    // MARK: - Persistence

    private func loadFromStorage() {
        guard let data = storedJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentSlideshow].self, from: data) else {
            recentSlideshows = []
            return
        }
        recentSlideshows = decoded
    }

    private func saveToStorage() {
        guard let data = try? JSONEncoder().encode(recentSlideshows),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        storedJSON = json
    }
}
```

---

## Relationships

```
┌─────────────────────────────┐
│  RecentSlideshowsManager    │
│  (singleton, @MainActor)    │
├─────────────────────────────┤
│  recentSlideshows: [Recent] │──────┐
│  addOrUpdate(url:)          │      │
│  clearAll()                 │      │
└─────────────────────────────┘      │
                                     │ 1:N (max 5)
                                     ▼
                          ┌──────────────────────┐
                          │   RecentSlideshow    │
                          ├──────────────────────┤
                          │  id: UUID            │
                          │  url: URL            │
                          │  filename: String    │
                          │  lastOpened: Date    │
                          │  fileExists: Bool    │
                          └──────────────────────┘
```

---

## Integration Points

### When to Call `addOrUpdate(url:)`

Called from `ContentView.loadSlideshow(from:)` after successful document load:

```swift
private func loadSlideshow(from url: URL) {
    // ... existing document loading logic ...

    // Add to recents after successful load
    RecentSlideshowsManager.shared.addOrUpdate(url: url)
}
```

### When to Call `clearAll()`

Called from "Clear List" menu item handler via notification.

---

## Notes

- **No removal of missing files**: Files that no longer exist are kept in the list but shown as disabled. User can clear all or they'll naturally age out as new files are opened.
- **Thread Safety**: All operations on `@MainActor` - safe for UI updates.
- **Sendable**: `RecentSlideshow` is `Sendable` for safe cross-actor usage if needed.
