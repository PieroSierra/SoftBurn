//
//  SoftBurnApp.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI

/// Notifications for triggering actions from menu
extension Notification.Name {
    static let openSlideshow = Notification.Name("SoftBurn.openSlideshow")
    static let saveSlideshow = Notification.Name("SoftBurn.saveSlideshow")
    static let exportAsVideo720p = Notification.Name("SoftBurn.exportAsVideo720p")
    static let exportAsVideo480p = Notification.Name("SoftBurn.exportAsVideo480p")
    static let addFromPhotosLibrary = Notification.Name("SoftBurn.addFromPhotosLibrary")
    static let addFromFiles = Notification.Name("SoftBurn.addFromFiles")
}

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
            // Replace default About panel with a custom one (Photos-style layout).
            CommandGroup(replacing: .appInfo) {
                Button {
                    AboutWindowController.shared.show()
                } label: {
                    Label("About SoftBurn", systemImage: "info.circle")
                }
            }

            // Replace File menu items with our custom ones
            CommandGroup(replacing: .newItem) {
                Button(action: {
                    NotificationCenter.default.post(name: .openSlideshow, object: nil)
                }) {
                    Label("Open Slideshow...", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(action: {
                    NotificationCenter.default.post(name: .saveSlideshow, object: nil)
                }) {
                    Label("Save Slideshow...", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)

                Divider()

                Menu {
                    Button(action: {
                        NotificationCenter.default.post(name: .addFromPhotosLibrary, object: nil)
                    }) {
                        Label("From Photos Library...", systemImage: "photo.on.rectangle")
                    }

                    Button(action: {
                        NotificationCenter.default.post(name: .addFromFiles, object: nil)
                    }) {
                        Label("From Files...", systemImage: "doc")
                    }
                } label: {
                    Label("Add Media", systemImage: "plus")
                }

                Divider()

                Menu {
                    Button(action: {
                        NotificationCenter.default.post(name: .exportAsVideo720p, object: nil)
                    }) {
                        Label("720p HD...", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("e", modifiers: .command)

                    Button(action: {
                        NotificationCenter.default.post(name: .exportAsVideo480p, object: nil)
                    }) {
                        Label("480p SD...", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                } label: {
                    Label("Export as Video", systemImage: "film")
                }
            }

            // Remove the Print item
            CommandGroup(replacing: .printItem) {}
        }
    }
}
