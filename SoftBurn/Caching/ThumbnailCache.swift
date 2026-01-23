//
//  ThumbnailCache.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
@preconcurrency import AVFoundation
import Photos

/// Manages thumbnail generation and caching for performance
actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Size bucket for cache keying - limits cache explosion by grouping sizes
    enum SizeBucket: Hashable {
        case standard    // Up to 350pt (covers 100-420pt zoom levels)
        case large       // Up to 700pt (covers 680pt zoom level + Retina)

        var targetSize: CGFloat {
            switch self {
            case .standard: return 350
            case .large: return 700
            }
        }

        static func from(requestedSize: CGFloat?) -> SizeBucket {
            guard let size = requestedSize, size > 350 else { return .standard }
            return .large
        }
    }

    private struct Key: Hashable {
        enum Source: Hashable {
            case filesystem(url: URL, rotation: Int)
            case photosLibrary(localIdentifier: String, rotation: Int)
        }
        let source: Source
        let sizeBucket: SizeBucket

        init(url: URL, rotationDegrees: Int, sizeBucket: SizeBucket = .standard) {
            self.source = .filesystem(url: url, rotation: rotationDegrees)
            self.sizeBucket = sizeBucket
        }

        init(photosLibraryLocalIdentifier: String, rotationDegrees: Int, sizeBucket: SizeBucket = .standard) {
            self.source = .photosLibrary(localIdentifier: photosLibraryLocalIdentifier, rotation: rotationDegrees)
            self.sizeBucket = sizeBucket
        }

        init(from item: MediaItem, sizeBucket: SizeBucket = .standard) {
            switch item.source {
            case .filesystem(let url):
                self.source = .filesystem(url: url, rotation: item.rotationDegrees)
            case .photosLibrary(let localID, _):
                self.source = .photosLibrary(localIdentifier: localID, rotation: item.rotationDegrees)
            }
            self.sizeBucket = sizeBucket
        }
    }

    private var cache: [Key: NSImage] = [:]

    private init() {}

    /// Generate or retrieve a thumbnail for a MediaItem
    /// - Parameters:
    ///   - item: The media item to generate a thumbnail for
    ///   - requestedSize: Optional requested size for the thumbnail (determines cache bucket)
    func thumbnail(for item: MediaItem, requestedSize: CGFloat? = nil) async -> NSImage? {
        let bucket = SizeBucket.from(requestedSize: requestedSize)
        let key = Key(from: item, sizeBucket: bucket)

        // Check cache first
        if let cached = cache[key] {
            return cached
        }


        // Generate thumbnail based on source
        let image: NSImage?
        let targetSize = bucket.targetSize
        switch item.source {
        case .filesystem(let url):
            image = await generateThumbnail(for: url, rotationDegrees: item.rotationDegrees, targetSize: targetSize)
        case .photosLibrary(let localID, _):
            image = await generateThumbnailFromPhotosLibrary(localIdentifier: localID, rotationDegrees: item.rotationDegrees, targetSize: targetSize)
        }

        if let generatedImage = image {
            cache[key] = generatedImage
        } else {
        }
        return image
    }

    /// Generate or retrieve a thumbnail for a photo URL (legacy method)
    /// - Parameters:
    ///   - url: The file URL to generate a thumbnail for
    ///   - rotationDegrees: Rotation to apply (0, 90, 180, 270)
    ///   - requestedSize: Optional requested size for the thumbnail (determines cache bucket)
    func thumbnail(for url: URL, rotationDegrees: Int = 0, requestedSize: CGFloat? = nil) async -> NSImage? {
        let rotation = MediaItem.normalizedRotationDegrees(rotationDegrees)
        let bucket = SizeBucket.from(requestedSize: requestedSize)
        let key = Key(url: url, rotationDegrees: rotation, sizeBucket: bucket)
        // Check cache first
        if let cached = cache[key] {
            return cached
        }

        // Generate thumbnail
        let targetSize = bucket.targetSize
        guard let image = await generateThumbnail(for: url, rotationDegrees: rotation, targetSize: targetSize) else {
            return nil
        }

        // Cache it
        cache[key] = image
        return image
    }

    /// Generate a thumbnail from Photos Library
    private func generateThumbnailFromPhotosLibrary(localIdentifier: String, rotationDegrees: Int, targetSize: CGFloat = 350) async -> NSImage? {
        // Photos Library handles EXIF orientation automatically
        let cgTargetSize = CGSize(width: targetSize, height: targetSize)
        guard let image = await PhotosLibraryImageLoader.shared.loadNSImage(localIdentifier: localIdentifier, targetSize: cgTargetSize) else {
            return nil
        }

        // Apply slideshow rotation metadata (after EXIF orientation, as Photos Library loads it)
        let d = MediaItem.normalizedRotationDegrees(rotationDegrees)
        guard d != 0 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        guard let rotated = Self.rotateCGImage(cg, degrees: d) else { return image }
        return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
    }
    
    /// Generate a thumbnail from a photo URL
    private func generateThumbnail(for url: URL, rotationDegrees: Int, targetSize: CGFloat = 350) async -> NSImage? {
        let thumbnailSize = targetSize
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
            
            // Video thumbnail
            if MediaItem.isVideoFile(resolvedURL) {
                let asset = AVURLAsset(url: resolvedURL)
                // Swift 6: AVAssetImageGenerator is not Sendable; wrap it to avoid Sendable capture warnings.
                final class GeneratorBox: @unchecked Sendable {
                    let generator: AVAssetImageGenerator
                    init(_ g: AVAssetImageGenerator) { self.generator = g }
                }

                let generatorBox = GeneratorBox(AVAssetImageGenerator(asset: asset))
                generatorBox.generator.appliesPreferredTrackTransform = true
                generatorBox.generator.maximumSize = CGSize(width: thumbnailSize, height: thumbnailSize)
                let cg: CGImage? = await withCheckedContinuation { continuation in
                    let times = [NSValue(time: .zero)]
                    generatorBox.generator.generateCGImagesAsynchronously(forTimes: times) { _, image, _, result, _ in
                        switch result {
                        case .succeeded:
                            continuation.resume(returning: image)
                        default:
                            continuation.resume(returning: nil)
                        }
                        generatorBox.generator.cancelAllCGImageGeneration()
                    }
                }
                if let cg {
                    // Videos are not rotatable; ignore rotationDegrees.
                    if let sdr = Self.renderToSDR(cgImage: cg) {
                        return NSImage(cgImage: sdr, size: NSSize(width: sdr.width, height: sdr.height))
                    }
                    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
                return nil
            }

            // Prefer ImageIO thumbnail generation to avoid triggering HDR decoding paths in NSImage that can spam logs.
            if let imageSource = CGImageSourceCreateWithURL(resolvedURL as CFURL, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
               ) {
                // Force SDR by rendering into an sRGB bitmap context.
                let base = Self.renderToSDR(cgImage: image) ?? image

                // Apply slideshow rotation metadata (after EXIF transform).
                let rotated = (rotationDegrees == 0) ? base : (Self.rotateCGImage(base, degrees: rotationDegrees) ?? base)
                return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
            }
            
            // Last-resort fallback: NSImage (may trigger HDR logs on some assets).
            if let fullImage = NSImage(contentsOf: resolvedURL) {
                // This path does not guarantee EXIF-orientation correctness, but is best-effort.
                let scaled = Self.scaleImage(fullImage, toMaxSize: thumbnailSize)
                if rotationDegrees == 0 { return scaled }
                guard let cg = scaled.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return scaled }
                if let rotated = Self.rotateCGImage(cg, degrees: rotationDegrees) {
                    return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
                }
                return scaled
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
    
    /// Render a CGImage into an 8-bit sRGB bitmap (SDR), to avoid HDR/gain-map decode paths for thumbnails.
    private static func renderToSDR(cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
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

        // Move origin to center, rotate, then draw centered.
        ctx.translateBy(x: outSize.width / 2.0, y: outSize.height / 2.0)
        ctx.rotate(by: CGFloat(Double(d) * Double.pi / 180.0))
        ctx.translateBy(x: -CGFloat(w) / 2.0, y: -CGFloat(h) / 2.0)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        return ctx.makeImage()
    }
    
    /// Clear the cache (useful for memory management)
    func clearCache() {
        cache.removeAll()
    }
    
    /// Remove specific entries from cache
    func removeCache(for urls: [URL]) {
        // Remove all rotation variants for these URLs.
        for url in urls {
            cache = cache.filter { key, _ in
                if case .filesystem(let keyURL, _) = key.source {
                    return keyURL != url
                }
                return true
            }
        }
    }
}

