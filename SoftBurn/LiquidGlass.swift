//
//  LiquidGlass.swift
//  SoftBurn
//
//  macOS 26 (Tahoe) adopts Liquid Glass styling for floating UI.
//  We keep the window chrome standard and apply glass only to our
//  custom toolbar + popovers, with a strict fallback for older macOS.
//

import SwiftUI

extension View {
    /// Background for our top toolbar strip.
    /// On macOS 26 we let the system handle glass.
    /// On older macOS we use a semi-transparent material so content scrolls under.
    @ViewBuilder
    func softBurnToolbarBackground() -> some View {
        if #available(macOS 26.0, *) {
            // On Tahoe we do NOT draw a toolbar surface ourselves.
            // The system toolbar (via .toolbar / .toolbarBackground) owns the chrome.
            self
        } else {
            // Semi-transparent so photos can scroll underneath and show through
            self.background(.ultraThinMaterial)
        }
    }

    /// Applies the system-managed Liquid Glass toolbar surface on macOS 26+.
    ///
    /// This must be attached to the view that owns `.toolbar { ... }` so the OS can
    /// treat it as window chrome. We intentionally do not hardcode blur/opacity.
    @ViewBuilder
    func softBurnWindowToolbarLiquidGlass() -> some View {
        if #available(macOS 26.0, *) {
            self
                // macOS 26 SDK exposes the Visibility-based toolbarBackground API publicly.
                // The Liquid Glass rendering is system-managed once the toolbar is treated as chrome.
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            self
        }
    }
}

extension Scene {
    /// Use unified toolbar style which participates in Tahoe's Liquid Glass chrome on macOS 26+.
    /// On older macOS it's a standard unified toolbar. No availability check needed (available since macOS 11).
    func softBurnWindowToolbarStyleForTahoe() -> some Scene {
        self.windowToolbarStyle(.unified)
    }
}

