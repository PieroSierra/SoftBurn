//
//  EffectTuningWindowController.swift
//  SoftBurn
//

import AppKit
import SwiftUI

#if DEBUG

/// Non-modal floating window for live-tuning Patina parameters (debug only).
final class EffectTuningWindowController {
    static let shared = EffectTuningWindowController()

    private var window: NSPanel?

    private init() {}

    @MainActor
    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = EffectTuningView()
            .environmentObject(PatinaTuningStore.shared)

        let hostingView = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.isReleasedWhenClosed = false
        panel.title = "Effect Settings"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.center()
        panel.contentView = hostingView

        self.window = panel

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#endif

