//
//  ZoomLevel.swift
//  SoftBurn
//
//  Created by Claude Code on 23/01/2026.
//

import Foundation

/// Represents a discrete thumbnail size stop in the grid.
/// Users step through these predefined levels using toolbar buttons or pinch gestures.
struct ZoomLevel: Identifiable, Equatable, Sendable {
    let id: Int
    let pointSize: CGFloat
    let displayName: String

    /// All available zoom levels from dense (100pt) to preview (680pt)
    static let all: [ZoomLevel] = [
        ZoomLevel(id: 0, pointSize: 100, displayName: "Dense"),
        ZoomLevel(id: 1, pointSize: 140, displayName: "Comfortable"),
        ZoomLevel(id: 2, pointSize: 220, displayName: "Medium"),       // Default
        ZoomLevel(id: 3, pointSize: 320, displayName: "Large"),
        ZoomLevel(id: 4, pointSize: 420, displayName: "Very Large"),
        ZoomLevel(id: 5, pointSize: 680, displayName: "Preview")
    ]

    /// Default zoom level index (Medium / 220pt)
    static let defaultIndex = 2

    /// Find the nearest zoom level to a proposed size
    static func nearest(to proposedSize: CGFloat) -> ZoomLevel {
        all.min { abs($0.pointSize - proposedSize) < abs($1.pointSize - proposedSize) } ?? all[defaultIndex]
    }
}
