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
                if let sdr = Self.renderToSDR(cgImage: image) {
                    return NSImage(cgImage: sdr, size: NSSize(width: sdr.width, height: sdr.height))
                }
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            
            // Last-resort fallback: NSImage (may trigger HDR logs on some assets).
            if let fullImage = NSImage(contentsOf: resolvedURL) {
                return Self.scaleImage(fullImage, toMaxSize: self.thumbnailSize)
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

