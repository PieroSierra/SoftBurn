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
    /// The pasteboard type used by Photos.app for dragging asset identifiers.
    static let photosPasteboardType = NSPasteboard.PasteboardType("com.apple.photos.pasteboard.identifier")

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
    private static func extractIdentifiers(from pasteboard: NSPasteboard) -> [String]? {
        guard let data = pasteboard.data(forType: photosPasteboardType) else {
            return nil
        }

        // Photos.app writes identifiers as a property list (array of strings)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }

        // Handle both array of strings and array of dictionaries with "identifier" key
        if let identifiers = plist as? [String] {
            return identifiers
        } else if let dicts = plist as? [[String: Any]] {
            return dicts.compactMap { $0["identifier"] as? String }
        }

        return nil
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
