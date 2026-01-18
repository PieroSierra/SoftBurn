//
//  PlaybackDisplaySelection.swift
//  SoftBurn
//
//  Multi-monitor playback target selection (app preference).
//

import AppKit

/// Stable display identifier (CGDirectDisplayID wrapped as Int for AppStorage).
typealias PlaybackDisplayID = Int

struct PlaybackDisplayOption: Identifiable, Hashable {
    /// 0 = App Display; otherwise CGDirectDisplayID
    let id: PlaybackDisplayID
    let title: String
}

enum PlaybackDisplaySelection {
    static let appDisplayID: PlaybackDisplayID = 0

    static func stableID(for screen: NSScreen) -> PlaybackDisplayID? {
        // NSScreenNumber is a CGDirectDisplayID
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return n.intValue
    }

    static func screen(for id: PlaybackDisplayID) -> NSScreen? {
        guard id != appDisplayID else { return nil }
        return NSScreen.screens.first(where: { stableID(for: $0) == id })
    }

    /// Best-effort to find the "app window" screen (the display containing the main app window).
    @MainActor
    static func currentAppScreen(excluding windowToExclude: NSWindow? = nil) -> NSScreen? {
        // Prefer key window if it isn't the slideshow window.
        if let w = NSApp.keyWindow, w !== windowToExclude, let s = w.screen {
            return s
        }
        // Otherwise, find a visible non-slideshow window.
        if let w = NSApp.windows.first(where: { $0 !== windowToExclude && $0.isVisible && $0.screen != nil }) {
            return w.screen
        }
        return NSScreen.main
    }

    /// Returns external display options relative to the "app display" at the time the picker is shown.
    @MainActor
    static func externalDisplayOptions(relativeTo appScreen: NSScreen?) -> [PlaybackDisplayOption] {
        guard NSScreen.screens.count > 1 else { return [] }
        let app = appScreen ?? NSScreen.main

        // Treat "external" as any other connected screen besides the current app display.
        let others = NSScreen.screens.filter { $0 !== app }

        return others.enumerated().compactMap { idx, screen in
            guard let id = stableID(for: screen) else { return nil }
            return PlaybackDisplayOption(id: id, title: "Monitor \(idx + 1)")
        }
    }
}

