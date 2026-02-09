//
//  PhotosLibraryDropHandler.swift
//  SoftBurn
//
//  Handles drag-and-drop from Photos.app into SoftBurn.
//

import AppKit
import Photos

@MainActor
final class PhotosLibraryDropHandler {
    /// The pasteboard type used by Photos.app for dragging asset references.
    static let photosPasteboardType = NSPasteboard.PasteboardType("com.apple.photos.object-reference.asset")

    /// Result of processing a Photos Library drop.
    enum DropResult {
        case photosLibraryItems([MediaItem])
        case notPhotosLibraryDrop
        case authorizationDenied
    }

    /// Check if the pasteboard contains Photos Library identifiers.
    static func isPhotosLibraryDrop(pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(photosPasteboardType) == true
    }

    /// Process a drop from Photos.app, returning MediaItems or an error state.
    static func handleDrop(pasteboard: NSPasteboard) async -> DropResult {
        guard isPhotosLibraryDrop(pasteboard: pasteboard) else {
            return .notPhotosLibraryDrop
        }

        // Extract identifiers from pasteboard
        guard let identifiers = extractIdentifiers(from: pasteboard), !identifiers.isEmpty else {
            return .notPhotosLibraryDrop
        }

        // Request authorization if needed
        let authorized = await PhotosLibraryManager.shared.requestAuthorization()
        guard authorized else {
            return .authorizationDenied
        }

        // Fetch PHAssets for the identifiers
        let assets = fetchAssets(identifiers: identifiers)
        guard !assets.isEmpty else {
            return .photosLibraryItems([])
        }

        // Convert to MediaItems using existing infrastructure
        let mediaItems = PhotosLibraryManager.shared.createMediaItems(from: assets)
        return .photosLibraryItems(mediaItems)
    }

    // MARK: - Private Helpers

    /// Extract local identifiers from the Photos pasteboard data.
    /// Photos.app creates one pasteboard item per dragged photo, so we need to iterate all items.
    private static func extractIdentifiers(from pasteboard: NSPasteboard) -> [String]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            print("[PhotosLibraryDropHandler] No pasteboard items")
            return nil
        }

        print("[PhotosLibraryDropHandler] Processing \(items.count) pasteboard items")

        var identifiers: [String] = []

        for (index, item) in items.enumerated() {
            guard let data = item.data(forType: photosPasteboardType) else {
                continue
            }

            // Parse the plist data for this item
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any] else {
                continue
            }

            // Extract localIdentifier from the dictionary
            if let localId = dict["localIdentifier"] as? String {
                identifiers.append(localId)
                print("[PhotosLibraryDropHandler] Item \(index): localIdentifier = \(localId)")
            }
        }

        print("[PhotosLibraryDropHandler] Extracted \(identifiers.count) identifiers")
        return identifiers.isEmpty ? nil : identifiers
    }

    /// Fetch PHAssets for the given local identifiers.
    private static func fetchAssets(identifiers: [String]) -> [PHAsset] {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }
}
