//
//  Models.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import UniformTypeIdentifiers

/// Represents a photo in the slideshow
struct PhotoItem: Identifiable, Hashable, Codable {
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

/// Supported image file types
extension PhotoItem {
    static let supportedImageTypes: [UTType] = [
        .jpeg, .png, .gif, .bmp, .tiff, .heic, .heif, .webP
    ]
    
    static func isImageFile(_ url: URL) -> Bool {
        guard let fileType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            // Fallback to extension check
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"].contains(ext)
        }
        return supportedImageTypes.contains(where: { fileType.conforms(to: $0) })
    }
}

