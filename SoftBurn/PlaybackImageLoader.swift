//
//  PlaybackImageLoader.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import AppKit
import SwiftUI

/// Manages efficient loading of full-resolution images for slideshow playback.
/// Only keeps one image loaded at a time, with optional preloading of the next image.
actor PlaybackImageLoader {
    
    /// Cache for loaded images (max 2: current + next)
    private var imageCache: [URL: NSImage] = [:]
    
    /// Currently displayed image URL
    private var currentURL: URL?
    
    /// Preloaded next image URL
    private var preloadedURL: URL?
    
    /// Load an image for playback (full resolution)
    func loadImage(for url: URL) async -> NSImage? {
        // Check cache first
        if let cached = imageCache[url] {
            return cached
        }
        
        // Load from disk
        guard let image = await loadFromDisk(url: url) else {
            return nil
        }
        
        // Cache the image
        imageCache[url] = image
        
        return image
    }
    
    /// Set the current image and optionally preload the next one
    func setCurrent(_ url: URL, preloadNext nextURL: URL?) async -> NSImage? {
        // Release old images (keep only current and preloaded)
        let urlsToKeep = Set([url, nextURL].compactMap { $0 })
        imageCache = imageCache.filter { urlsToKeep.contains($0.key) }
        
        currentURL = url
        preloadedURL = nextURL
        
        // Load current image
        let currentImage = await loadImage(for: url)
        
        // Preload next image in background (don't await)
        if let nextURL = nextURL {
            Task {
                _ = await self.loadImage(for: nextURL)
            }
        }
        
        return currentImage
    }
    
    /// Clear all cached images
    func clearCache() {
        imageCache.removeAll()
        currentURL = nil
        preloadedURL = nil
    }
    
    /// Load image from disk (runs on background thread)
    private func loadFromDisk(url: URL) async -> NSImage? {
        // Access security-scoped resource if needed
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Load full resolution image
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }
        
        return image
    }
}

