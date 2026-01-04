//
//  Models.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import UniformTypeIdentifiers

/// Represents a photo in the slideshow
struct PhotoItem: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let url: URL
    
    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
    
    /// File name for display
    var fileName: String {
        url.lastPathComponent
    }
}

/// Supported image file types - helper functions are nonisolated for background thread use
extension PhotoItem {
    static let supportedExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"]
    
    /// Check if a URL points to an image file (safe to call from any thread)
    static func isImageFile(_ url: URL) -> Bool {
        // Use extension check which is thread-safe
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }
}

