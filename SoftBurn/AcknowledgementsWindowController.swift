//
//  AcknowledgementsWindowController.swift
//  SoftBurn
//

import AppKit
import SwiftUI

final class AcknowledgementsWindowController {
    static let shared = AcknowledgementsWindowController()

    private var window: NSWindow?

    private init() {}

    @MainActor
    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AcknowledgementsView()
        let hostingView = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.isReleasedWhenClosed = false
        window.title = "Acknowledgements"
        window.center()
        window.contentView = hostingView

        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

