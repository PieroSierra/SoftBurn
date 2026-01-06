//
//  ScreenIdleSleepController.swift
//  SoftBurn
//
//  Prevents macOS from starting the screen saver / display sleep while slideshow playback is active.
//

import Foundation
import IOKit.pwr_mgt

/// Manages a system power assertion to keep the display awake.
/// Scoped explicitly to slideshow playback (not general app usage).
final class ScreenIdleSleepController {
    static let shared = ScreenIdleSleepController()

    private var assertionID: IOPMAssertionID = 0
    private var isActive: Bool = false

    private init() {}

    func start(reason: String = "SoftBurn slideshow playback") {
        guard !isActive else { return }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )

        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
        } else {
            // Best-effort: silently fail (screensaver may still engage).
            assertionID = 0
            isActive = false
        }
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }
}


