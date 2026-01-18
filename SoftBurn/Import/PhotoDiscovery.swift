//
//  PhotoDiscovery.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation

/// Handles discovery of media items (photos + videos) in folders
enum PhotoDiscovery {
    /// Recursively discover media in a folder (runs synchronously, call from background if needed)
    private static func discoverMediaSync(in url: URL) -> [MediaItem] {
        var items: [MediaItem] = []
        
        guard url.startAccessingSecurityScopedResource() else {
            return items
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return items
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            // Check if it's a regular file
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            
            // Image
            if MediaItem.isImageFile(fileURL) {
                items.append(MediaItem(url: fileURL, kind: .photo))
                continue
            }
            
            // Video
            if MediaItem.isVideoFile(fileURL) {
                items.append(MediaItem(url: fileURL, kind: .video))
            }
        }
        
        return items
    }
    
    /// Discover media from multiple URLs synchronously
    private static func discoverMediaSync(from urls: [URL]) -> [MediaItem] {
        var allItems: [MediaItem] = []
        
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            
            if isDirectory.boolValue {
                let items = discoverMediaSync(in: url)
                allItems.append(contentsOf: items)
            } else {
                // Single file
                if MediaItem.isImageFile(url) {
                    allItems.append(MediaItem(url: url, kind: .photo))
                } else if MediaItem.isVideoFile(url) {
                    allItems.append(MediaItem(url: url, kind: .video))
                }
            }
        }
        
        return allItems
    }
    
    /// Recursively discover media in a folder (async wrapper)
    static func discoverPhotos(in url: URL) async -> [MediaItem] {
        let result = discoverMediaSync(in: url)
        return result
    }
    
    /// Discover media from multiple URLs (files or folders)
    static func discoverPhotos(from urls: [URL]) async -> [MediaItem] {
        let result = discoverMediaSync(from: urls)
        return result
    }
}

