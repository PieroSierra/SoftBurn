//
//  SoftBurnAppDelegate.swift
//  SoftBurn
//

import AppKit

final class SoftBurnAppDelegate: NSObject, NSApplicationDelegate {
    /// Called by macOS when the user double-clicks a .softburn file in Finder,
    /// or opens one via "Open With", drag-to-dock, etc.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Three async hops let SwiftUI create and fully settle any extra window it opens
        // for this file-open event (onAppear fires and sees nil pendingFileOpenURL → noop).
        // Only after the extra window is closed do we set the URL, so the original window
        // is the only one that can handle it.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    let keyWindows = NSApp.windows.filter { $0.canBecomeKey }
                    keyWindows.dropFirst().forEach { $0.close() }
                    keyWindows.first?.makeKeyAndOrderFront(nil)
                    Task { @MainActor in
                        AppSessionState.shared.pendingFileOpenURL = url
                    }
                }
            }
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


