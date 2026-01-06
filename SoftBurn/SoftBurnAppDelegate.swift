//
//  SoftBurnAppDelegate.swift
//  SoftBurn
//

import AppKit

final class SoftBurnAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = AppSessionState.shared

        if session.shouldWarnOnCloseOrQuit {
            session.requestQuit()
            return .terminateCancel
        }

        return .terminateNow
    }
}


