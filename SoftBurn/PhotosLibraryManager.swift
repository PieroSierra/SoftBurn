//
//  PhotosLibraryManager.swift
//  SoftBurn
//
//  Created by Claude Code on 14/01/2026.
//

import Foundation
import Photos
import AppKit
import Combine

/// Manages Photos Library access, authorization, and asset resolution.
@MainActor
final class PhotosLibraryManager: ObservableObject {
    static let shared = PhotosLibraryManager()

    @Published var authorizationStatus: PHAuthorizationStatus

    private init() {
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - Authorization

    /// Request authorization to access Photos Library
    func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        print("📸 PHPhotoLibrary authorization result: \(status.rawValue)")
        self.authorizationStatus = status

        // Log what status we got
        switch status {
        case .authorized:
            print("📸 Authorization: authorized")
        case .denied:
            print("📸 Authorization: denied")
        case .notDetermined:
            print("📸 Authorization: notDetermined")
        case .restricted:
            print("📸 Authorization: restricted")
        case .limited:
            print("📸 Authorization: limited")
        @unknown default:
            print("📸 Authorization: unknown")
        }

        return status == .authorized || status == .limited
    }

    // MARK: - Asset Conversion

    /// Convert PHAsset array to MediaItems with identifiers extracted
    func createMediaItems(from assets: [PHAsset]) -> [MediaItem] {
        return assets.compactMap { asset -> MediaItem? in
            let kind: MediaItem.Kind
            switch asset.mediaType {
            case .image:
                kind = .photo
            case .video:
                kind = .video
            default:
                return nil // Skip unknown types
            }

            let localID = asset.localIdentifier
            // Note: PHAsset doesn't expose cloudIdentifier directly in the API
            // For now, cloudIdentifier will be nil (device-specific only)
            let cloudID: String? = nil

            return MediaItem(photosLibraryLocalIdentifier: localID, cloudIdentifier: cloudID, kind: kind)
        }
    }

    // MARK: - Asset Resolution (Cross-Device)

    /// Resolve Photos Library asset by localIdentifier
    /// Note: cloudIdentifier resolution for cross-device support can be added in future updates
    func resolveAsset(cloudIdentifier: String?, localIdentifier: String) async -> PHAsset? {
        // For now, use localIdentifier directly
        // TODO: Implement cloudIdentifier → localIdentifier mapping for cross-device support
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return fetchResult.firstObject
    }

    /// Resolve multiple assets in bulk (for document loading)
    func resolveAssets(from items: [MediaItem]) async -> [MediaItem] {
        var resolvedItems: [MediaItem] = []

        for item in items {
            guard case .photosLibrary(let localID, let cloudID) = item.source else {
                // Not a Photos Library item, pass through
                resolvedItems.append(item)
                continue
            }

            // Verify asset exists
            if let _ = await resolveAsset(cloudIdentifier: cloudID, localIdentifier: localID) {
                resolvedItems.append(item)
            } else {
                print("Photos Library asset not found: \(localID)")
                // Skip unavailable assets (deleted or not synced)
            }
        }

        return resolvedItems
    }

    // MARK: - Cache Key Helper

    /// Generate cache key for Photos Library item (for face detection and other caches)
    static func cacheKey(for localIdentifier: String) -> String {
        return "photos://\(localIdentifier)"
    }
}
