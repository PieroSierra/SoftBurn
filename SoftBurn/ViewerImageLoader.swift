//
//  ViewerImageLoader.swift
//  SoftBurn
//

import AppKit
import Foundation

/// Full-resolution image loader for the sheet viewer.
/// Separate from slideshow playback to keep lifecycles decoupled.
actor ViewerImageLoader {
    private var cache: [URL: NSImage] = [:]
    private var order: [URL] = []
    private let maxCacheCount: Int = 3

    func load(url: URL) async -> NSImage? {
        if let cached = cache[url] {
            return cached
        }

        let image: NSImage? = await Task.detached(priority: .utility) {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return NSImage(contentsOf: url)
        }.value

        guard let image else { return nil }
        cache[url] = image
        order.append(url)

        if order.count > maxCacheCount, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }

        return image
    }

    func clear() {
        cache.removeAll()
        order.removeAll()
    }
}


