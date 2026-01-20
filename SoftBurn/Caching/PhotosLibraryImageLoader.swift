//
//  PhotosLibraryImageLoader.swift
//  SoftBurn
//
//  Centralized actor for loading images and videos from Photos Library.
//
//  VIDEO LOADING NOTE (January 2026):
//  getVideoURL() uses PHAssetResourceManager.writeData() instead of PHImageManager.requestAVAsset()
//  because the latter triggers AudioQueue initialization which fails in sandbox with:
//    "AudioQueueObject.cpp:3530  _Start: Error (-4) getting reporterIDs"
//
//  The PHAssetResourceManager approach exports the video to a temp file, which works for
//  video frame extraction. However, audio extraction from these files STILL triggers
//  AudioQueue errors elsewhere in the pipeline.
//  See /specs/video-export-spec.md for full details.
//

import Foundation
import Photos
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Centralized actor for loading images from Photos Library
actor PhotosLibraryImageLoader {
    static let shared = PhotosLibraryImageLoader()

    private init() {}

    // Cache of exported video URLs to avoid re-exporting
    private var videoURLCache: [String: URL] = [:]

    // MARK: - CGImage Loading (for Metal rendering)

    /// Load CGImage from Photos Library asset (for Metal texture conversion)
    func loadCGImage(localIdentifier: String, targetSize: CGSize) async -> CGImage? {

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }


        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true // Allow iCloud download
        options.isSynchronous = false // IMPORTANT: Use async with continuation
        options.resizeMode = .exact

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in

                if info?[PHImageErrorKey] != nil {
                    continuation.resume(returning: nil)
                    return
                }

                if let image = image,
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - NSImage Loading (for SwiftUI rendering)

    /// Load NSImage from Photos Library asset (for SwiftUI path)
    func loadNSImage(localIdentifier: String, targetSize: CGSize) async -> NSImage? {

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true // Allow iCloud download
        options.isSynchronous = false // IMPORTANT: Use async with continuation
        options.resizeMode = .exact

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in

                if info?[PHImageErrorKey] != nil {
                    continuation.resume(returning: nil)
                    return
                }

                if let image = image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Full Resolution Loading

    /// Load full resolution CGImage for face detection or high-quality rendering
    func loadFullResolutionCGImage(localIdentifier: String) async -> CGImage? {
        // Use PHImageManagerMaximumSize for full resolution
        return await loadCGImage(localIdentifier: localIdentifier, targetSize: PHImageManagerMaximumSize)
    }

    /// Load full resolution NSImage
    func loadFullResolutionNSImage(localIdentifier: String) async -> NSImage? {
        return await loadNSImage(localIdentifier: localIdentifier, targetSize: PHImageManagerMaximumSize)
    }

    // MARK: - Video URL Loading

    /// Get video URL for Photos Library video asset.
    /// Uses PHAssetResourceManager to export to a temp file, avoiding AudioQueue issues
    /// that occur with PHImageManager.requestAVAsset.
    func getVideoURL(localIdentifier: String) async -> URL? {
        // Check cache first
        if let cachedURL = videoURLCache[localIdentifier] {
            // Verify file still exists
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                return cachedURL
            } else {
                videoURLCache.removeValue(forKey: localIdentifier)
            }
        }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }

        guard asset.mediaType == .video else {
            return nil
        }

        // Get the video resource
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) else {
            print("[PhotosLibraryImageLoader] No video resource found for asset: \(localIdentifier)")
            return nil
        }

        // Create temp file URL
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoftBurnVideoExport", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Use a stable filename based on the asset ID
        let safeIdentifier = localIdentifier.replacingOccurrences(of: "/", with: "_")
        let uti = videoResource.uniformTypeIdentifier
        let fileExtension: String
        if let utType = UTType(uti),
           let ext = utType.preferredFilenameExtension {
            fileExtension = ext
        } else {
            fileExtension = "mov"
        }
        let tempURL = tempDir.appendingPathComponent("\(safeIdentifier).\(fileExtension)")

        // If file already exists, use it
        if FileManager.default.fileExists(atPath: tempURL.path) {
            videoURLCache[localIdentifier] = tempURL
            return tempURL
        }

        // Export using PHAssetResourceManager (doesn't trigger AudioQueue)
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            manager.writeData(for: videoResource, toFile: tempURL, options: options) { error in
                if let error = error {
                    print("[PhotosLibraryImageLoader] Failed to export video: \(error)")
                    continuation.resume(returning: nil)
                } else {
                    // Cache the URL
                    Task {
                        await self.cacheVideoURL(localIdentifier: localIdentifier, url: tempURL)
                    }
                    continuation.resume(returning: tempURL)
                }
            }
        }
    }

    private func cacheVideoURL(localIdentifier: String, url: URL) {
        videoURLCache[localIdentifier] = url
    }

    /// Clean up cached video files (call on app termination or when done with export)
    func cleanupVideoCache() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoftBurnVideoExport", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDir)
        videoURLCache.removeAll()
    }
}
