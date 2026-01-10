//
//  SlideshowDocument.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import CoreGraphics

/// Represents a saved slideshow document
struct SlideshowDocument: Codable {
    /// Document format version for future compatibility
    let version: Int
    
    /// Document metadata
    var metadata: Metadata
    
    /// Ordered list of photo file paths (legacy; v1-v3)
    var photoPaths: [String]

    /// Ordered list of media items (v4+). If present, this is the authoritative list.
    var mediaItems: [MediaEntry]?
    
    /// Security-scoped bookmarks per photo path (base64-encoded).
    /// Required for sandboxed access across app launches.
    var bookmarksByPath: [String: String]?

    /// Persisted face rectangles per photo path (normalized, Vision coordinate space).
    /// Keyed by the same path strings used in `photoPaths`.
    /// - Note: Missing entries mean "unknown" (may be detected later and saved on next save).
    var faceRectsByPath: [String: [FaceRect]]?

    /// Global slideshow settings (placeholder for future features)
    var settings: Settings
    
    /// File extension for slideshow documents
    static let fileExtension = "softburn"
    
    /// Current document format version
    static let currentVersion = 5
    
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
        var playVideosWithSound: Bool
        var playVideosInFull: Bool
        /// Music selection: nil = none, "winters_tale" / "brighter_plans" / "innovation" = built-in, or custom file URL string
        var musicSelection: String?
        /// Music volume (0-100), default 60
        var musicVolume: Int
        
        init() {
            self.shuffle = false
            self.transitionStyle = .panAndZoom
            self.zoomOnFaces = true
            self.backgroundColor = "#000000"
            self.slideDuration = 5.0
            self.playVideosWithSound = false
            self.playVideosInFull = false
            self.musicSelection = nil
            self.musicVolume = 60
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.shuffle = (try? c.decode(Bool.self, forKey: .shuffle)) ?? false
            self.transitionStyle = (try? c.decode(TransitionStyle.self, forKey: .transitionStyle)) ?? .panAndZoom
            self.zoomOnFaces = (try? c.decode(Bool.self, forKey: .zoomOnFaces)) ?? true
            self.backgroundColor = (try? c.decode(String.self, forKey: .backgroundColor)) ?? "#000000"
            self.slideDuration = (try? c.decode(Double.self, forKey: .slideDuration)) ?? 5.0
            self.playVideosWithSound = (try? c.decode(Bool.self, forKey: .playVideosWithSound)) ?? false
            self.playVideosInFull = (try? c.decode(Bool.self, forKey: .playVideosInFull)) ?? false
            self.musicSelection = try? c.decode(String.self, forKey: .musicSelection)
            self.musicVolume = (try? c.decode(Int.self, forKey: .musicVolume)) ?? 60
        }
        
        enum TransitionStyle: String, Codable, CaseIterable {
            case panAndZoom = "Pan & Zoom"
            case zoom = "Zoom"
            case crossFade = "Cross Fade"
            case plain = "Plain"

            /// UI ordering requirement: Pan & Zoom, Zoom, Cross-fade, Plain
            static var allCases: [TransitionStyle] {
                [.panAndZoom, .zoom, .crossFade, .plain]
            }

            /// Display name (keeps persisted raw values stable for backwards compatibility).
            var displayName: String {
                switch self {
                case .panAndZoom: return "Pan & Zoom"
                case .zoom: return "Zoom"
                case .crossFade: return "Cross-fade"
                case .plain: return "Plain"
                }
            }
        }
    }

    struct MediaEntry: Codable, Hashable {
        var kind: MediaItem.Kind
        var path: String
        /// Non-destructive rotation metadata (degrees counterclockwise).
        /// Allowed values: 0, 90, 180, 270.
        var rotationDegrees: Int

        init(kind: MediaItem.Kind, path: String, rotationDegrees: Int = 0) {
            self.kind = kind
            self.path = path
            self.rotationDegrees = MediaItem.normalizedRotationDegrees(rotationDegrees)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try c.decode(MediaItem.Kind.self, forKey: .kind)
            self.path = try c.decode(String.self, forKey: .path)
            self.rotationDegrees = MediaItem.normalizedRotationDegrees((try? c.decode(Int.self, forKey: .rotationDegrees)) ?? 0)
        }
    }

    /// Codable representation of a normalized CGRect (Vision-style).
    struct FaceRect: Codable, Hashable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(rect: CGRect) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }
    
    // MARK: - Initialization
    
    init(photos: [MediaItem], title: String = "Untitled Slideshow") {
        self.version = Self.currentVersion
        self.metadata = Metadata(title: title)
        self.photoPaths = photos.filter { $0.kind == .photo }.map { $0.url.path } // legacy compatibility
        self.mediaItems = photos.map { MediaEntry(kind: $0.kind, path: $0.url.path, rotationDegrees: $0.rotationDegrees) }
        self.bookmarksByPath = nil
        self.faceRectsByPath = nil
        self.settings = Settings()
    }

    // Convenience alias for clarity
    init(items: [MediaItem], title: String = "Untitled Slideshow") {
        self.init(photos: items, title: title)
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
    func loadMediaItems() -> [MediaItem] {
        let entries: [MediaEntry] = mediaItems ?? photoPaths.map { MediaEntry(kind: .photo, path: $0) }
        var items: [MediaItem] = []

        for entry in entries {
            var url = URL(fileURLWithPath: entry.path)

            // If a bookmark is present, resolve it and start security-scoped access.
            if let bookmarkString = bookmarksByPath?[entry.path],
               let bookmarkData = Data(base64Encoded: bookmarkString) {
                var isStale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    url = resolved
                    _ = url.startAccessingSecurityScopedResource()
                }
            }
            
            // Check if file exists (silently skip missing files)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            
            switch entry.kind {
            case .photo:
                guard MediaItem.isImageFile(url) else { continue }
                items.append(MediaItem(url: url, kind: .photo, rotationDegrees: entry.rotationDegrees))
            case .video:
                guard MediaItem.isVideoFile(url) else { continue }
                // Videos are not rotatable; ignore any persisted rotation.
                items.append(MediaItem(url: url, kind: .video, rotationDegrees: 0))
            }
        }

        return items
    }
}

