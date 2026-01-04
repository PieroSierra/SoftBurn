//
//  PhotoDiscovery.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation

/// Handles discovery of photos in folders
enum PhotoDiscovery {
    /// Recursively discover photos in a folder (runs synchronously, call from background if needed)
    private static func discoverPhotosSync(in url: URL) -> [PhotoItem] {
        var photos: [PhotoItem] = []
        
        guard url.startAccessingSecurityScopedResource() else {
            return photos
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return photos
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            // Check if it's a regular file
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            
            // Check if it's an image file
            if PhotoItem.isImageFile(fileURL) {
                photos.append(PhotoItem(url: fileURL))
            }
        }
        
        return photos
    }
    
    /// Discover photos from multiple URLs synchronously
    private static func discoverPhotosSync(from urls: [URL]) -> [PhotoItem] {
        var allPhotos: [PhotoItem] = []
        
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            
            if isDirectory.boolValue {
                let photos = discoverPhotosSync(in: url)
                allPhotos.append(contentsOf: photos)
            } else {
                // Single file
                if PhotoItem.isImageFile(url) {
                    allPhotos.append(PhotoItem(url: url))
                }
            }
        }
        
        return allPhotos
    }
    
    /// Recursively discover photos in a folder (async wrapper)
    static func discoverPhotos(in url: URL) async -> [PhotoItem] {
        // Run synchronous work on background thread, return result to caller
        let result = discoverPhotosSync(in: url)
        return result
    }
    
    /// Discover photos from multiple URLs (files or folders)
    static func discoverPhotos(from urls: [URL]) async -> [PhotoItem] {
        // Run synchronous work on background thread, return result to caller
        let result = discoverPhotosSync(from: urls)
        return result
    }
}

