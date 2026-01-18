//
//  AboutWindowController.swift
//  SoftBurn
//

import AppKit
import SwiftUI

/// Presents a custom About window (Photos-style layout).
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    private init() {}

    @MainActor
    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AboutView(
            onAcknowledgements: {
                AcknowledgementsWindowController.shared.show()
            }
        )

        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.center()
        window.contentView = hostingView

        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

