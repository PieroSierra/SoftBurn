//
//  SlideshowSettings.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import Combine

/// Manages global slideshow settings with persistence
@MainActor
class SlideshowSettings: ObservableObject {
    static let shared = SlideshowSettings()
    
    // MARK: - Persisted Settings (UserDefaults)
    
    @AppStorage("settings.transitionStyle") private var storedTransitionStyle: String = "Pan & Zoom"
    @AppStorage("settings.shuffle") private var storedShuffle: Bool = false
    @AppStorage("settings.zoomOnFaces") private var storedZoomOnFaces: Bool = true
    @AppStorage("settings.backgroundColor") private var storedBackgroundColor: String = "#000000"
    @AppStorage("settings.slideDuration") private var storedSlideDuration: Double = 5.0
    @AppStorage("settings.playVideosWithSound") private var storedPlayVideosWithSound: Bool = false
    @AppStorage("settings.playVideosInFull") private var storedPlayVideosInFull: Bool = false
    
#if DEBUG
    @AppStorage("settings.debugShowFaces") private var storedDebugShowFaces: Bool = false
#endif
    
    // MARK: - Published Properties (for UI binding)
    
    @Published var transitionStyle: SlideshowDocument.Settings.TransitionStyle = .panAndZoom {
        didSet { storedTransitionStyle = transitionStyle.rawValue }
    }
    
    @Published var shuffle: Bool = false {
        didSet { storedShuffle = shuffle }
    }
    
    @Published var zoomOnFaces: Bool = true {
        didSet { storedZoomOnFaces = zoomOnFaces }
    }
    
    @Published var backgroundColor: Color = .black {
        didSet { storedBackgroundColor = backgroundColor.toHex() }
    }
    
    @Published var slideDuration: Double = 5.0 {
        didSet { storedSlideDuration = slideDuration }
    }
    
    @Published var playVideosWithSound: Bool = false {
        didSet { storedPlayVideosWithSound = playVideosWithSound }
    }
    
    @Published var playVideosInFull: Bool = false {
        didSet { storedPlayVideosInFull = playVideosInFull }
    }
    
    /// Music selection (per-document, not persisted to UserDefaults)
    @Published var musicSelection: String? = nil
    
    /// Music volume (0-100, per-document, not persisted to UserDefaults)
    @Published var musicVolume: Int = 60
    
    /// Custom music file URL (per-document, not persisted to UserDefaults)
    @Published var customMusicURL: URL? = nil
    
    /// Debug-only: draw detected face rectangles over the slideshow image.
    /// This property exists in Release too (always false), but the UI toggle is only shown in DEBUG builds.
#if DEBUG
    @Published var debugShowFaces: Bool = false {
        didSet { storedDebugShowFaces = debugShowFaces }
    }
#else
    @Published var debugShowFaces: Bool = false
#endif
    
    // MARK: - Initialization
    
    private init() {
        // Load from UserDefaults
        loadFromStorage()
    }
    
    private func loadFromStorage() {
        transitionStyle = SlideshowDocument.Settings.TransitionStyle(rawValue: storedTransitionStyle) ?? .panAndZoom
        shuffle = storedShuffle
        zoomOnFaces = storedZoomOnFaces
        backgroundColor = Color(hex: storedBackgroundColor) ?? .black
        slideDuration = storedSlideDuration
        playVideosWithSound = storedPlayVideosWithSound
        playVideosInFull = storedPlayVideosInFull
#if DEBUG
        debugShowFaces = storedDebugShowFaces
#endif
    }
    
    // MARK: - Import/Export for File Save/Load
    
    /// Export current settings to document format
    func toDocumentSettings() -> SlideshowDocument.Settings {
        var settings = SlideshowDocument.Settings()
        settings.transitionStyle = transitionStyle
        settings.shuffle = shuffle
        settings.zoomOnFaces = zoomOnFaces
        settings.backgroundColor = storedBackgroundColor
        settings.slideDuration = slideDuration
        settings.playVideosWithSound = playVideosWithSound
        settings.playVideosInFull = playVideosInFull
        settings.musicSelection = musicSelection
        settings.musicVolume = musicVolume
        return settings
    }
    
    /// Import settings from a loaded document (overrides app settings)
    func applyFromDocument(_ settings: SlideshowDocument.Settings) {
        transitionStyle = settings.transitionStyle
        shuffle = settings.shuffle
        zoomOnFaces = settings.zoomOnFaces
        backgroundColor = Color(hex: settings.backgroundColor) ?? .black
        slideDuration = settings.slideDuration
        playVideosWithSound = settings.playVideosWithSound
        playVideosInFull = settings.playVideosInFull
        musicSelection = settings.musicSelection
        musicVolume = settings.musicVolume
        
        // Restore custom music URL if it's a custom selection
        if let selection = settings.musicSelection,
           let url = URL(string: selection),
           url.isFileURL {
            customMusicURL = url
        } else {
            customMusicURL = nil
        }
    }
}

// MARK: - Color Extensions

extension Color {
    /// Initialize from hex string (e.g., "#FF5500" or "FF5500")
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        guard hexSanitized.count == 6 else { return nil }
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let red = Double((rgb & 0xFF0000) >> 16) / 255.0
        let green = Double((rgb & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: red, green: green, blue: blue)
    }
    
    /// Convert to hex string
    func toHex() -> String {
        guard let components = NSColor(self).cgColor.components else { return "#000000" }
        
        let r: CGFloat = components.count > 0 ? components[0] : 0
        let g: CGFloat = components.count > 1 ? components[1] : 0
        let b: CGFloat = components.count > 2 ? components[2] : 0
        
        return String(format: "#%02X%02X%02X",
                      Int(r * 255),
                      Int(g * 255),
                      Int(b * 255))
    }
}

