//
//  PlaybackImageLoader.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import AppKit
import SwiftUI
import Photos

/// Manages efficient loading of full-resolution images for slideshow playback.
/// Only keeps one image loaded at a time, with optional preloading of the next image.
actor PlaybackImageLoader {

    /// Cache for loaded images (max 2: current + next)
    private struct Key: Hashable {
        enum Source: Hashable {
            case filesystem(url: URL, rotation: Int)
            case photosLibrary(localIdentifier: String, rotation: Int)
        }
        let source: Source

        var rotationDegrees: Int {
            switch source {
            case .filesystem(_, let rotation):
                return rotation
            case .photosLibrary(_, let rotation):
                return rotation
            }
        }

        init(url: URL, rotationDegrees: Int) {
            self.source = .filesystem(url: url, rotation: rotationDegrees)
        }

        init(photosLibraryLocalIdentifier: String, rotationDegrees: Int) {
            self.source = .photosLibrary(localIdentifier: photosLibraryLocalIdentifier, rotation: rotationDegrees)
        }

        init(from item: MediaItem) {
            switch item.source {
            case .filesystem(let url):
                self.source = .filesystem(url: url, rotation: item.rotationDegrees)
            case .photosLibrary(let localID, _):
                self.source = .photosLibrary(localIdentifier: localID, rotation: item.rotationDegrees)
            }
        }
    }

    private var imageCache: [Key: NSImage] = [:]

    /// Currently displayed image URL
    private var currentKey: Key?

    /// Preloaded next image URL
    private var preloadedKey: Key?

    /// Load an image for playback from MediaItem
    func loadImage(for item: MediaItem) async -> NSImage? {
        let key = Key(from: item)
        print("📸 PlaybackImageLoader: Loading image for item \(item.id)")
        print("📸 PlaybackImageLoader: Key = \(key)")

        // Check cache first
        if let cached = imageCache[key] {
            print("📸 PlaybackImageLoader: Cache hit!")
            return cached
        }

        print("📸 PlaybackImageLoader: Cache miss, loading...")

        // Load based on source
        let image: NSImage?
        switch item.source {
        case .filesystem(let url):
            print("📸 PlaybackImageLoader: Loading from filesystem")
            image = await loadFromDisk(url: url, rotationDegrees: item.rotationDegrees)
        case .photosLibrary(let localID, _):
            print("📸 PlaybackImageLoader: Loading from Photos Library: \(localID)")
            image = await loadFromPhotosLibrary(localIdentifier: localID, rotationDegrees: item.rotationDegrees)
        }

        guard let loadedImage = image else {
            print("📸 PlaybackImageLoader: Failed to load image")
            return nil
        }

        print("📸 PlaybackImageLoader: Successfully loaded image: \(loadedImage.size)")

        // Cache the image
        imageCache[key] = loadedImage

        return loadedImage
    }

    /// Load an image for playback (full resolution) - legacy method for filesystem
    func loadImage(for url: URL, rotationDegrees: Int = 0) async -> NSImage? {
        let rotation = MediaItem.normalizedRotationDegrees(rotationDegrees)
        let key = Key(url: url, rotationDegrees: rotation)
        // Check cache first
        if let cached = imageCache[key] {
            return cached
        }

        // Load from disk
        guard let image = await loadFromDisk(url: url, rotationDegrees: rotation) else {
            return nil
        }

        // Cache the image
        imageCache[key] = image

        return image
    }
    
    /// Set the current image and optionally preload the next one
    func setCurrent(_ url: URL, rotationDegrees: Int = 0, preloadNext next: (url: URL, rotationDegrees: Int)?) async -> NSImage? {
        let current = Key(url: url, rotationDegrees: MediaItem.normalizedRotationDegrees(rotationDegrees))
        let nextKey: Key? = next.map { Key(url: $0.url, rotationDegrees: MediaItem.normalizedRotationDegrees($0.rotationDegrees)) }

        // Release old images (keep only current and preloaded)
        let keysToKeep = Set([current, nextKey].compactMap { $0 })
        imageCache = imageCache.filter { keysToKeep.contains($0.key) }
        
        currentKey = current
        preloadedKey = nextKey
        
        // Load current image
        let currentImage = await loadImage(for: url, rotationDegrees: rotationDegrees)
        
        // Preload next image in background (don't await)
        if let next = next {
            Task {
                _ = await self.loadImage(for: next.url, rotationDegrees: next.rotationDegrees)
            }
        }
        
        return currentImage
    }
    
    /// Clear all cached images
    func clearCache() {
        imageCache.removeAll()
        currentKey = nil
        preloadedKey = nil
    }
    
    /// Load image from disk (runs on background thread)
    private func loadFromDisk(url: URL, rotationDegrees: Int) async -> NSImage? {
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

        // Apply slideshow rotation metadata (after EXIF orientation, as NSImage loads it).
        let d = MediaItem.normalizedRotationDegrees(rotationDegrees)
        guard d != 0 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        guard let rotated = Self.rotateCGImage(cg, degrees: d) else { return image }
        return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
    }

    /// Load image from Photos Library
    private func loadFromPhotosLibrary(localIdentifier: String, rotationDegrees: Int) async -> NSImage? {
        // Load from Photos Library
        guard let image = await PhotosLibraryImageLoader.shared.loadFullResolutionNSImage(localIdentifier: localIdentifier) else {
            return nil
        }

        // Apply rotation if needed (Photos Library handles EXIF, we handle metadata rotation)
        let d = MediaItem.normalizedRotationDegrees(rotationDegrees)
        guard d != 0 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        guard let rotated = Self.rotateCGImage(cg, degrees: d) else { return image }
        return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
    }

    /// Rotate a CGImage around its center by a multiple of 90 degrees (counterclockwise).
    private static func rotateCGImage(_ cgImage: CGImage, degrees: Int) -> CGImage? {
        let d = MediaItem.normalizedRotationDegrees(degrees)
        guard d != 0 else { return cgImage }

        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let outSize: CGSize = (d == 90 || d == 270) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let ctx = CGContext(
            data: nil,
            width: Int(outSize.width),
            height: Int(outSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high

        ctx.translateBy(x: outSize.width / 2.0, y: outSize.height / 2.0)
        ctx.rotate(by: CGFloat(Double(d) * Double.pi / 180.0))
        ctx.translateBy(x: -CGFloat(w) / 2.0, y: -CGFloat(h) / 2.0)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        return ctx.makeImage()
    }
}

