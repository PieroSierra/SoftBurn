//
//  PhotoDiscovery.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation

/// Handles discovery of photos in folders
enum PhotoDiscovery {
    /// Recursively discover photos in a folder
    static func discoverPhotos(in url: URL) async -> [PhotoItem] {
        var photos: [PhotoItem] = []
        
        guard url.startAccessingSecurityScopedResource() else {
            return photos
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: [.skipsHiddenFiles]
        )
        
        guard let enumerator = enumerator else {
            return photos
        }
        
        for case let fileURL as URL in enumerator {
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
    
    /// Discover photos from multiple URLs (files or folders)
    static func discoverPhotos(from urls: [URL]) async -> [PhotoItem] {
        var allPhotos: [PhotoItem] = []
        
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }
            
            if isDirectory.boolValue {
                let photos = await discoverPhotos(in: url)
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
}

