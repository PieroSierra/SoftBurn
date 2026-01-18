//
//  ViewerImageLoader.swift
//  SoftBurn
//

import AppKit
import Foundation

/// Full-resolution image loader for the sheet viewer.
/// Separate from slideshow playback to keep lifecycles decoupled.
actor ViewerImageLoader {
    /// Cache key that works for both filesystem and Photos Library items
    private struct CacheKey: Hashable {
        let key: String

        init(from item: MediaItem) {
            switch item.source {
            case .filesystem(let url):
                self.key = url.path
            case .photosLibrary(let localID, _):
                self.key = "photos://\(localID)"
            }
        }
    }

    private var cache: [CacheKey: NSImage] = [:]
    private var order: [CacheKey] = []
    private let maxCacheCount: Int = 3

    /// Load image from MediaItem (supports both filesystem and Photos Library)
    func load(item: MediaItem) async -> NSImage? {
        let cacheKey = CacheKey(from: item)

        if let cached = cache[cacheKey] {
            return cached
        }

        let image: NSImage?
        switch item.source {
        case .filesystem(let url):
            image = await loadFromFilesystem(url: url)
        case .photosLibrary(let localID, _):
            image = await PhotosLibraryImageLoader.shared.loadFullResolutionNSImage(localIdentifier: localID)
        }

        guard let image else { return nil }
        cache[cacheKey] = image
        order.append(cacheKey)

        if order.count > maxCacheCount, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }

        return image
    }

    /// Legacy method for URL-based loading (filesystem only)
    func load(url: URL) async -> NSImage? {
        // Create a temporary filesystem MediaItem for caching consistency
        let tempItem = await MainActor.run { MediaItem(url: url, kind: .photo) }
        return await load(item: tempItem)
    }

    private func loadFromFilesystem(url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return NSImage(contentsOf: url)
        }.value
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }
}


