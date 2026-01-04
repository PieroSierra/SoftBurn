//
//  SlideshowDocument.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation

/// Represents a saved slideshow document
struct SlideshowDocument: Codable {
    /// Document format version for future compatibility
    let version: Int
    
    /// Document metadata
    var metadata: Metadata
    
    /// Ordered list of photo file paths (stored as strings for portability)
    var photoPaths: [String]
    
    /// Global slideshow settings (placeholder for future features)
    var settings: Settings
    
    /// File extension for slideshow documents
    static let fileExtension = "softburn"
    
    /// Current document format version
    static let currentVersion = 1
    
    // MARK: - Nested Types
    
    struct Metadata: Codable {
        var title: String
        var creationDate: Date
        var lastModifiedDate: Date
        
        init(title: String = "Untitled Slideshow") {
            self.title = title
            self.creationDate = Date()
            self.lastModifiedDate = Date()
        }
    }
    
    struct Settings: Codable {
        var shuffle: Bool
        var transitionStyle: TransitionStyle
        var zoomOnFaces: Bool
        var backgroundColor: String // Hex color string
        var slideDuration: Double // seconds per slide
        
        init() {
            self.shuffle = false
            self.transitionStyle = .panAndZoom
            self.zoomOnFaces = true
            self.backgroundColor = "#000000"
            self.slideDuration = 5.0
        }
        
        enum TransitionStyle: String, Codable, CaseIterable {
            case panAndZoom = "Pan & Zoom"
            case crossFade = "Cross Dissolve"
            case plain = "Plain"
        }
    }
    
    // MARK: - Initialization
    
    init(photos: [PhotoItem], title: String = "Untitled Slideshow") {
        self.version = Self.currentVersion
        self.metadata = Metadata(title: title)
        self.photoPaths = photos.map { $0.url.path }
        self.settings = Settings()
    }
    
    // MARK: - Serialization
    
    /// Encode document to JSON data
    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    
    /// Decode document from JSON data
    static func decode(from data: Data) throws -> SlideshowDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SlideshowDocument.self, from: data)
    }
    
    /// Save document to a file URL
    func save(to url: URL) throws {
        var doc = self
        doc.metadata.lastModifiedDate = Date()
        let data = try doc.encode()
        try data.write(to: url)
    }
    
    /// Load document from a file URL
    static func load(from url: URL) throws -> SlideshowDocument {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }
    
    // MARK: - Photo Loading
    
    /// Convert stored paths back to PhotoItems, filtering out missing files
    func loadPhotos() -> [PhotoItem] {
        var photos: [PhotoItem] = []
        
        for path in photoPaths {
            let url = URL(fileURLWithPath: path)
            
            // Check if file exists (silently skip missing files)
            guard FileManager.default.fileExists(atPath: path) else {
                continue
            }
            
            // Verify it's still an image file
            guard PhotoItem.isImageFile(url) else {
                continue
            }
            
            photos.append(PhotoItem(url: url))
        }
        
        return photos
    }
}

