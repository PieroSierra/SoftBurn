//
//  MainWindowDelegate.swift
//  SoftBurn
//

import AppKit

final class MainWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MainWindowDelegate()

    private override init() {
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let session = AppSessionState.shared

        if session.allowWindowCloseOnce {
            session.allowWindowCloseOnce = false
            return true
        }

        if session.shouldWarnOnCloseOrQuit {
            session.requestClose(window: sender)
            return false
        }

        return true
    }
}


