//
//  SoftBurnAppDelegate.swift
//  SoftBurn
//

import AppKit

final class SoftBurnAppDelegate: NSObject, NSApplicationDelegate {
    /// Called by macOS when the user double-clicks a .softburn file in Finder,
    /// or opens one via "Open With", drag-to-dock, etc.
    /// Window("SoftBurn", id: "main") is a single-instance scene — no second window is ever created.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Task @MainActor: one run-loop hop so ContentView is settled (cold launch),
        // and ensures @MainActor isolation for AppSessionState access.
        // makeKeyAndOrderFront is safe here with WindowGroup (unlike Window scene,
        // it doesn't trigger windowShouldClose via SwiftUI lifecycle).
        Task { @MainActor in
            NSApp.windows.first(where: { !$0.isSheet })?.makeKeyAndOrderFront(nil)
            AppSessionState.shared.pendingFileOpenURL = url
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // All windows were closed — show the main window
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = AppSessionState.shared

        if session.shouldWarnOnCloseOrQuit {
            session.requestQuit()
            return .terminateCancel
        }

        return .terminateNow
    }
}


