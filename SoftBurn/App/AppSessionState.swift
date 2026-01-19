//
//  AppSessionState.swift
//  SoftBurn
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppSessionState: ObservableObject {
    static let shared = AppSessionState()

    enum PendingAction {
        case quit
        case closeWindow
    }

    @Published var isDirty: Bool = false
    @Published var showUnsavedChangesAlert: Bool = false
    @Published var isExporting: Bool = false
    
    /// Whether the current slideshow has any photos.
    /// Used to suppress "unsaved changes" prompts when the canvas is empty.
    @Published var hasPhotos: Bool = false

    private(set) var pendingAction: PendingAction?
    private weak var pendingWindow: NSWindow?

    /// Allows a single window close without re-prompting (used for “Don’t Save”).
    var allowWindowCloseOnce: Bool = false

    private init() {}

    func markDirty() {
        guard !isDirty else { return }
        isDirty = true
    }

    func markClean() {
        isDirty = false
    }
    
    var shouldWarnOnCloseOrQuit: Bool {
        isDirty && hasPhotos
    }

    func requestQuit() {
        pendingAction = .quit
        showUnsavedChangesAlert = true
    }

    func requestClose(window: NSWindow?) {
        pendingAction = .closeWindow
        pendingWindow = window
        showUnsavedChangesAlert = true
    }

    func cancelPendingAction() {
        pendingAction = nil
        pendingWindow = nil
        showUnsavedChangesAlert = false
    }

    func discardChangesAndPerformPendingAction() {
        // Allow termination/close without re-prompting.
        isDirty = false
        showUnsavedChangesAlert = false

        switch pendingAction {
        case .quit:
            pendingAction = nil
            NSApp.terminate(nil)
        case .closeWindow:
            allowWindowCloseOnce = true
            let window = pendingWindow
            pendingAction = nil
            pendingWindow = nil
            window?.performClose(nil)
        case .none:
            break
        }
    }

    func performPendingActionAfterSuccessfulSave() {
        // Save succeeded; we are now “clean”
        isDirty = false
        showUnsavedChangesAlert = false

        switch pendingAction {
        case .quit:
            pendingAction = nil
            NSApp.terminate(nil)
        case .closeWindow:
            allowWindowCloseOnce = true
            let window = pendingWindow
            pendingAction = nil
            pendingWindow = nil
            window?.performClose(nil)
        case .none:
            break
        }
    }
}


