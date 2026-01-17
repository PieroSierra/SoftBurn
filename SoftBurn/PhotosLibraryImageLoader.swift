//
//  PhotosLibraryImageLoader.swift
//  SoftBurn
//
//  Created by Claude Code on 14/01/2026.
//

import Foundation
import Photos
import AppKit
import CoreGraphics

/// Centralized actor for loading images from Photos Library
actor PhotosLibraryImageLoader {
    static let shared = PhotosLibraryImageLoader()

    private init() {}

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

                if let error = info?[PHImageErrorKey] as? Error {
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

                if let error = info?[PHImageErrorKey] as? Error {
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

    // MARK: - Video URL Loading (for non-looping playback)

    /// Get video URL for Photos Library video asset.
    /// Used for single video playback (e.g., PhotoViewerSheet), not slideshow.
    /// For slideshow playback with looping, use VideoPlayerManager instead.
    func getVideoURL(localIdentifier: String) async -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }

        guard asset.mediaType == .video else {
            return nil
        }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let urlAsset = avAsset as? AVURLAsset {
                    continuation.resume(returning: urlAsset.url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
