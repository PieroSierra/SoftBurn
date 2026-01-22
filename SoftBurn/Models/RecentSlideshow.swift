//
//  RecentSlideshow.swift
//  SoftBurn
//
//  Created by Claude on 22/01/2026.
//

import Foundation

/// Represents a recently opened slideshow for the Open Recent menu
struct RecentSlideshow: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let lastOpened: Date

    /// Creates a new recent slideshow entry
    /// - Parameter url: The file URL of the slideshow
    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.filename = url.deletingPathExtension().lastPathComponent
        self.lastOpened = Date()
    }

    /// Whether the file still exists at the stored path
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
