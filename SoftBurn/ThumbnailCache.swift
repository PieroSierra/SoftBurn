//
//  ThumbnailCache.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import AppKit
import SwiftUI

/// Manages thumbnail generation and caching for performance
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private var cache: [URL: NSImage] = [:]
    private let thumbnailSize: CGFloat = 350 // Target size for longest edge
    
    private init() {}
    
    /// Generate or retrieve a thumbnail for a photo URL
    func thumbnail(for url: URL) async -> NSImage? {
        // Check cache first
        if let cached = cache[url] {
            return cached
        }
        
        // Generate thumbnail
        guard let image = await generateThumbnail(for: url) else {
            return nil
        }
        
        // Cache it
        cache[url] = image
        return image
    }
    
    /// Generate a thumbnail from a photo URL
    private func generateThumbnail(for url: URL) async -> NSImage? {
        return await Task.detached {
            // Resolve the URL to ensure it's accessible
            let resolvedURL: URL
            if url.isFileURL {
                // Resolve symlinks and ensure path is absolute
                resolvedURL = (try? URL(resolvingAliasFileAt: url)) ?? url
            } else {
                resolvedURL = url
            }
            
            // Attempt to access security-scoped resource if needed
            let accessing = resolvedURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
            }
            
            // Ensure URL is accessible
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                return nil
            }
            
            // Try loading with NSImage first (simpler, more reliable)
            if let fullImage = NSImage(contentsOf: resolvedURL) {
                return Self.scaleImage(fullImage, toMaxSize: self.thumbnailSize)
            }
            
            // Fallback: Use ImageIO for efficient thumbnail generation
            if let imageSource = CGImageSourceCreateWithURL(resolvedURL as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: self.thumbnailSize,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
               ) {
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            
            return nil
        }.value
    }
    
    /// Scale an image to a maximum size while maintaining aspect ratio
    private static func scaleImage(_ image: NSImage, toMaxSize maxSize: CGFloat) -> NSImage {
        let size = image.size
        let maxDimension = max(size.width, size.height)
        
        guard maxDimension > maxSize else {
            return image
        }
        
        let scale = maxSize / maxDimension
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        
        let scaledImage = NSImage(size: newSize)
        scaledImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver,
                   fraction: 1.0)
        scaledImage.unlockFocus()
        
        return scaledImage
    }
    
    /// Clear the cache (useful for memory management)
    func clearCache() {
        cache.removeAll()
    }
    
    /// Remove specific entries from cache
    func removeCache(for urls: [URL]) {
        for url in urls {
            cache.removeValue(forKey: url)
        }
    }
}

