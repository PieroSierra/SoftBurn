# Research: Open Recent Feature

**Date**: 2026-01-22
**Feature Branch**: `001-open-recent`

## Summary

Research findings for implementing the Open Recent feature in SoftBurn. All technical decisions are informed by existing codebase patterns.

---

## Decision 1: State Management Pattern

**Decision**: Use `@MainActor` singleton with `@AppStorage` for JSON persistence

**Rationale**:
- Matches existing `SlideshowSettings.swift` pattern exactly
- `@AppStorage` provides automatic UserDefaults synchronization
- `@Published` properties enable reactive SwiftUI updates
- `@MainActor` ensures thread safety for UI state

**Alternatives Considered**:
- **NSDocumentController.recentDocumentURLs**: Rejected because SoftBurn is not a document-based app (doesn't use `NSDocument`)
- **Core Data**: Overkill for 5 simple entries; adds unnecessary complexity
- **File-based storage**: Less integrated than UserDefaults for app preferences

---

## Decision 2: Data Persistence Format

**Decision**: JSON-encoded array stored in UserDefaults via `@AppStorage`

**Rationale**:
- Simple Codable struct serializes cleanly to JSON
- UserDefaults handles persistence lifecycle automatically
- Works within macOS sandbox without additional entitlements
- Consistent with how `SlideshowSettings` stores complex preferences

**Data Structure**:
```swift
struct RecentSlideshow: Codable, Identifiable {
    let id: UUID
    let url: URL
    let filename: String
    let lastOpened: Date
}
```

**Alternatives Considered**:
- **Security-scoped bookmarks for URLs**: Not needed - we only store the path for display and attempt access when user clicks; if file moved/deleted, we show error gracefully
- **Storing full SlideshowDocument metadata**: Unnecessary complexity; filename is sufficient for menu display

---

## Decision 3: Menu Integration Approach

**Decision**: Use SwiftUI `Menu` component with `NotificationCenter` for cross-module communication

**Rationale**:
- File menu uses `CommandGroup` in `SoftBurnApp.swift` with notification pattern
- Toolbar menus use SwiftUI `Menu` component
- Notifications allow decoupled communication between menu commands and `ContentView` handlers
- Existing pattern: `.openSlideshow`, `.saveSlideshow` notifications

**Integration Points**:
1. **File Menu** (`SoftBurnApp.swift`): Add "Open Recent" submenu in `CommandGroup(replacing: .newItem)`
2. **Legacy Toolbar** (`ContentView.swift` lines 587-633): Add submenu to File dropdown
3. **LiquidGlass Toolbar** (`ContentView.swift` lines 150-194): Add submenu to navigation placement

**Alternatives Considered**:
- **Direct method calls**: Would require passing handlers through view hierarchy; notifications are cleaner
- **Environment values**: Overkill for simple menu actions; existing notification pattern works well

---

## Decision 4: Missing File Handling

**Decision**: Check file existence at display time; show error alert on click

**Rationale**:
- Checking `FileManager.default.fileExists(atPath:)` is fast and non-blocking
- Disabled state provides visual feedback that file is unavailable
- Alert on click explains the issue clearly
- No automatic removal - user may restore file and want entry preserved

**Behavior**:
- Menu item appears normally but with `.disabled(true)` if file missing
- Clicking disabled item (if somehow triggered) shows "File Not Found" alert
- "Clear List" removes all entries including missing ones

**Alternatives Considered**:
- **Remove missing files automatically**: Could frustrate users who temporarily moved files
- **Show "missing" icon**: SF Symbols don't have a good "missing file" variant; disabled state is sufficient
- **Gray out filename**: `.disabled()` already provides this visual treatment

---

## Decision 5: Deduplication Strategy

**Decision**: Remove existing entry before adding new one at front

**Rationale**:
- Ensures most recent access is always at top
- Prevents list from filling with duplicates
- Simple array operation: filter out matching URL, then prepend

**Implementation**:
```swift
func addOrUpdate(url: URL) {
    var list = recentSlideshows.filter { $0.url != url }
    let entry = RecentSlideshow(id: UUID(), url: url, filename: url.lastPathComponent, lastOpened: Date())
    list.insert(entry, at: 0)
    if list.count > 5 { list = Array(list.prefix(5)) }
    recentSlideshows = list
    persist()
}
```

---

## Decision 6: Sandboxed File Access

**Decision**: Store URL path strings only; rely on `loadSlideshow(from:)` existing flow for security-scoped access

**Rationale**:
- `loadSlideshow(from:)` already handles `startAccessingSecurityScopedResource()`
- Recent entries are just for display; actual file access uses existing document loading flow
- User clicked on file via menu = user intent for access (consistent with file picker)

**Important Note**: When opening from recents, user intent is implied. The existing `fileImporter` flow creates security-scoped bookmarks on successful load, which are stored in `.softburn` documents. The recents menu simply triggers the same flow.

---

## Decision 7: Toolbar Icon

**Decision**: Use `clock` SF Symbol for "Open Recent" button

**Rationale**:
- Standard macOS convention for "recent" items
- Available in all supported macOS versions (13+)
- Specified in feature requirements (FR-001 through FR-003)

---

## Existing Patterns Reference

### SlideshowSettings.swift Pattern (lines 13-111)
```swift
@MainActor
class SlideshowSettings: ObservableObject {
    static let shared = SlideshowSettings()

    @AppStorage("settings.key") private var storedValue: String = ""
    @Published var publishedValue: SomeType {
        didSet { persist() }
    }

    private init() { loadFromStorage() }
    private func loadFromStorage() { /* decode JSON */ }
    private func persist() { /* encode to JSON */ }
}
```

### Notification Pattern (SoftBurnApp.swift)
```swift
extension Notification.Name {
    static let openSlideshow = Notification.Name("SoftBurn.openSlideshow")
}

// In menu:
Button(action: {
    NotificationCenter.default.post(name: .openSlideshow, object: nil)
}) { Label("Open Slideshow...", systemImage: "folder") }

// In ContentView:
.onReceive(NotificationCenter.default.publisher(for: .openSlideshow)) { _ in
    // handle action
}
```

---

## Open Questions Resolved

| Question | Resolution |
|----------|------------|
| How to persist across restarts? | `@AppStorage` with JSON encoding |
| Where to add menu items? | CommandGroup + toolbar Menus |
| How to handle moved files? | Disable menu item, show error on click |
| What icon to use? | `clock` SF Symbol |
| Thread safety? | `@MainActor` singleton pattern |
| Maximum entries? | 5 (per spec) |

---

## No Blocking Issues

All technical decisions are resolved. Ready for Phase 1 design artifacts.
