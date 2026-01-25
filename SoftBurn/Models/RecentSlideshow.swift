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
    /// Security-scoped bookmark data (base64 encoded) for sandboxed access after app restart
    let bookmarkData: String?

    /// Creates a new recent slideshow entry
    /// - Parameter url: The file URL of the slideshow
    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.filename = url.deletingPathExtension().lastPathComponent
        self.lastOpened = Date()
        // Create security-scoped bookmark for sandboxed access
        self.bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ).base64EncodedString()
    }

    /// Whether the file still exists at the stored path
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Resolves the security-scoped bookmark and returns a URL with access, if available
    /// Returns nil if bookmark is missing or stale
    func resolveBookmark() -> URL? {
        guard let bookmarkData = bookmarkData,
              let data = Data(base64Encoded: bookmarkData) else {
            return nil
        }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        // If stale, the bookmark is no longer valid
        if isStale {
            return nil
        }

        return resolvedURL
    }
}
