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

    let id: UUID
    let url: URL
    let kind: Kind

    init(url: URL, kind: Kind) {
        self.id = UUID()
        self.url = url
        self.kind = kind
    }

    /// File name for display
    var fileName: String {
        url.lastPathComponent
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
}

