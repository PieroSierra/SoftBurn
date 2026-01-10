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

/// Manages thumbnail generation and caching for performance
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private struct Key: Hashable {
        let url: URL
        let rotationDegrees: Int
    }

    private var cache: [Key: NSImage] = [:]
    private let thumbnailSize: CGFloat = 350 // Target size for longest edge
    
    private init() {}
    
    /// Generate or retrieve a thumbnail for a photo URL
    func thumbnail(for url: URL, rotationDegrees: Int = 0) async -> NSImage? {
        let rotation = MediaItem.normalizedRotationDegrees(rotationDegrees)
        let key = Key(url: url, rotationDegrees: rotation)
        // Check cache first
        if let cached = cache[key] {
            return cached
        }
        
        // Generate thumbnail
        guard let image = await generateThumbnail(for: url, rotationDegrees: rotation) else {
            return nil
        }
        
        // Cache it
        cache[key] = image
        return image
    }
    
    /// Generate a thumbnail from a photo URL
    private func generateThumbnail(for url: URL, rotationDegrees: Int) async -> NSImage? {
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
                generatorBox.generator.maximumSize = CGSize(width: self.thumbnailSize, height: self.thumbnailSize)
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
                    kCGImageSourceThumbnailMaxPixelSize: self.thumbnailSize,
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
                let scaled = Self.scaleImage(fullImage, toMaxSize: self.thumbnailSize)
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
            cache = cache.filter { $0.key.url != url }
        }
    }
}

