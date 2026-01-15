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
        print("📸 Loading CGImage for: \(localIdentifier), size: \(targetSize)")

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            print("📸 Failed to fetch asset")
            return nil
        }

        print("📸 Asset found: \(asset.mediaType.rawValue)")

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
                print("📸 Image request callback - image: \(image != nil), info: \(String(describing: info))")

                if let error = info?[PHImageErrorKey] as? Error {
                    print("📸 Error loading image: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                if let image = image,
                   let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    print("📸 Successfully loaded CGImage: \(cgImage.width)x\(cgImage.height)")
                    continuation.resume(returning: cgImage)
                } else {
                    print("📸 Failed to convert to CGImage")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - NSImage Loading (for SwiftUI rendering)

    /// Load NSImage from Photos Library asset (for SwiftUI path)
    func loadNSImage(localIdentifier: String, targetSize: CGSize) async -> NSImage? {
        print("📸 Loading NSImage for: \(localIdentifier), size: \(targetSize)")

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            print("📸 Failed to fetch asset")
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
                print("📸 NSImage request callback - image: \(image != nil)")

                if let error = info?[PHImageErrorKey] as? Error {
                    print("📸 Error loading NSImage: \(error)")
                    continuation.resume(returning: nil)
                    return
                }

                if let image = image {
                    print("📸 Successfully loaded NSImage: \(image.size)")
                    continuation.resume(returning: image)
                } else {
                    print("📸 Failed to load NSImage")
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

    /// Get playable video URL for Photos Library video asset
    func getVideoURL(localIdentifier: String) async -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            print("📸 Video: Failed to fetch asset")
            return nil
        }

        guard asset.mediaType == .video else {
            print("📸 Video: Asset is not a video")
            return nil
        }

        print("📸 Video: Requesting playable URL for \(localIdentifier)")

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, audioMix, info in
                if let urlAsset = avAsset as? AVURLAsset {
                    print("📸 Video: Got playable URL: \(urlAsset.url)")
                    continuation.resume(returning: urlAsset.url)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    print("📸 Video: Error getting URL: \(error)")
                    continuation.resume(returning: nil)
                } else {
                    print("📸 Video: Failed to get URL (not a URL asset)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
