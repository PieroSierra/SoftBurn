//
//  SoftBurnApp.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI

@main
struct SoftBurnApp: App {
    @NSApplicationDelegateAdaptor(SoftBurnAppDelegate.self) private var appDelegate
    @StateObject private var session = AppSessionState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
        .softBurnWindowToolbarStyleForTahoe()
        .commands {
            // Add standard macOS commands
            CommandGroup(replacing: .newItem) {}
        }
    }
}
