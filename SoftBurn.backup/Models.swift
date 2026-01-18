//
//  Models.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import UniformTypeIdentifiers

/// Represents a media item in the slideshow (photo or video).
struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case photo
        case video
    }

    enum Source: Codable, Sendable, Hashable {
        case filesystem(URL)
        case photosLibrary(localIdentifier: String, cloudIdentifier: String?)
    }

    let id: UUID
    let source: Source
    let kind: Kind
    /// Non-destructive rotation metadata (degrees counterclockwise).
    /// Allowed values: 0, 90, 180, 270.
    /// Note: Only applicable to filesystem photos. Photos Library items handle rotation via PhotoKit.
    var rotationDegrees: Int

    init(url: URL, kind: Kind, rotationDegrees: Int = 0) {
        self.id = UUID()
        self.source = .filesystem(url)
        self.kind = kind
        self.rotationDegrees = MediaItem.normalizedRotationDegrees(rotationDegrees)
    }

    init(photosLibraryLocalIdentifier: String, cloudIdentifier: String?, kind: Kind) {
        self.id = UUID()
        self.source = .photosLibrary(localIdentifier: photosLibraryLocalIdentifier, cloudIdentifier: cloudIdentifier)
        self.kind = kind
        self.rotationDegrees = 0 // Photos Library handles EXIF rotation
    }

    /// Backward-compatible URL property (returns synthetic URL for Photos Library items)
    var url: URL {
        switch source {
        case .filesystem(let url):
            return url
        case .photosLibrary(let localID, _):
            return URL(string: "photos://asset/\(localID)")!
        }
    }

    /// Returns true if this item is from Photos Library
    var isFromPhotosLibrary: Bool {
        if case .photosLibrary = source { return true }
        return false
    }

    /// File name for display
    var fileName: String {
        switch source {
        case .filesystem(let url):
            return url.lastPathComponent
        case .photosLibrary(let localID, _):
            return "Photos: \(localID.prefix(8))..."
        }
    }
}

/// Supported media file types - helper functions are safe to call from any thread.
extension MediaItem {
    // Swift 6: if the project uses "Default actor = MainActor", mark these explicitly nonisolated
    // so they can be used from background threads/actors (thumbnail generation, discovery, etc).
    nonisolated static let supportedImageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"]
    nonisolated static let supportedVideoExtensions = ["mov", "mp4", "m4v"]

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedImageExtensions.contains(ext)
    }

    nonisolated static func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedVideoExtensions.contains(ext)
    }

    /// Normalize to one of {0, 90, 180, 270}.
    nonisolated static func normalizedRotationDegrees(_ degrees: Int) -> Int {
        // Wrap into [0, 360)
        var d = degrees % 360
        if d < 0 { d += 360 }
        // Snap to allowed values (defensive; rotation is always applied in 90° steps).
        switch d {
        case 0, 90, 180, 270:
            return d
        default:
            // Round to nearest 90
            let rounded = Int((Double(d) / 90.0).rounded()) * 90
            return normalizedRotationDegrees(rounded)
        }
    }

    mutating func rotateCounterclockwise90() {
        guard kind == .photo else { return }
        rotationDegrees = MediaItem.normalizedRotationDegrees(rotationDegrees + 90)
    }
}

