//
//  MusicPlaybackManager.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import AVFoundation
import Combine

/// Manages background music playback for slideshows
@MainActor
class MusicPlaybackManager: ObservableObject {
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var endObserver: NSObjectProtocol?
    private var fadeTimer: Timer?
    private var fadeTargetVolume: Float = 0.0
    private var fadeStartVolume: Float = 0.0
    private var fadeStartTime: Date?
    private var fadeDuration: Double = 0.0
    private var fadeCompletion: (() -> Void)?
    
    /// Music selection type
    enum MusicSelection: Equatable {
        case none
        case builtin(BuiltinID)
        case custom(URL)
        
        /// Identifier for built-in tracks (for persistence)
        enum BuiltinID: String, CaseIterable {
            case winters_tale = "winters_tale"
            case brighter_plans = "brighter_plans"
            case innovation = "innovation"
        }
        
        var identifier: String? {
            switch self {
            case .none:
                return nil
            case .builtin(let id):
                return id.rawValue
            case .custom(let url):
                return url.absoluteString
            }
        }
        
        static func from(identifier: String?) -> MusicSelection {
            guard let identifier = identifier else { return .none }
            
            // Check if it's a built-in track first (before checking for URLs)
            if let builtinID = BuiltinID(rawValue: identifier) {
                return .builtin(builtinID)
            }
            
            // Check if it's a file URL (custom music)
            // Try parsing as URL string (for absolute URLs like "file:///path")
            if let url = URL(string: identifier), url.isFileURL {
                return .custom(url)
            }
            
            // Fallback: try as file path (for paths starting with /)
            if identifier.hasPrefix("/") {
                return .custom(URL(fileURLWithPath: identifier))
            }
            
            return .none
        }
    }
    
    /// Built-in track filenames
    private static let builtinTrackFilenames: [MusicSelection.BuiltinID: String] = [
        .winters_tale: "Winter's tale.mp3",
        .brighter_plans: "Brighter plans.mp3",
        .innovation: "Innovation.mp3"
    ]
    
    /// Built-in track display names
    static let builtinTrackNames: [MusicSelection.BuiltinID: String] = [
        .winters_tale: "Winter's Tale",
        .brighter_plans: "Brighter Plans",
        .innovation: "Innovation"
    ]
    
    /// Get URL for a built-in track
    private static func url(for builtin: MusicSelection.BuiltinID) -> URL? {
        guard let filename = builtinTrackFilenames[builtin] else { return nil }
        let resourceName = filename.replacingOccurrences(of: ".mp3", with: "")
        
        // Try subdirectory first (if resources are organized in bundle)
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "mp3", subdirectory: "Resources/Music") {
            return url
        }
        
        // Fallback to bundle root (if resources are flattened during build)
        return Bundle.main.url(forResource: resourceName, withExtension: "mp3")
    }
    
    /// Get URL for music selection
    private func url(for selection: MusicSelection) -> URL? {
        switch selection {
        case .none:
            return nil
        case .builtin(let id):
            return Self.url(for: id)
        case .custom(let url):
            // Verify file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("Music file not found: \(url.path)")
                return nil
            }
            return url
        }
    }
    
    /// Start music playback with fade-in
    func start(selection: MusicSelection, volume: Int) {
        stop(shouldFadeOut: false) // Stop any existing playback immediately
        
        guard selection != .none else { return }
        
        guard let musicURL = url(for: selection) else {
            print("Music file not available for selection")
            return
        }
        
        // Create player
        let item = AVPlayerItem(url: musicURL)
        let p = AVPlayer(playerItem: item)
        
        // Set initial volume to 0 for fade-in
        p.volume = 0.0
        
        // Apply volume scaling (0-100 -> 0.0-1.0)
        let targetVolume = Float(volume) / 100.0
        
        player = p
        playerItem = item
        
        // Install loop observer
        installLoopObserver()
        
        // Start playback
        p.play()
        
        // Fade in over 1-2 seconds
        fadeIn(targetVolume: targetVolume, duration: 1.5)
    }
    
    /// Stop music playback with optional fade-out
    func stop(shouldFadeOut: Bool = true) {
        if shouldFadeOut {
            // Fade out over 0.5-1 second, then stop
            performFadeOut(duration: 0.75) { [weak self] in
                Task { @MainActor in
                    self?.stopImmediately()
                }
            }
        } else {
            stopImmediately()
        }
    }
    
    private func stopImmediately() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        
        // Clear fade state
        fadeStartTime = nil
        fadeCompletion = nil
        
        removeLoopObserver()
        player?.pause()
        player = nil
        playerItem = nil
    }
    
    /// Update volume (for real-time volume changes)
    func setVolume(_ volume: Int) {
        let normalizedVolume = Float(volume) / 100.0
        player?.volume = normalizedVolume
    }
    
    // MARK: - Fade Effects
    
    private func fadeIn(targetVolume: Float, duration: Double) {
        guard player != nil else { return }
        
        fadeTimer?.invalidate()
        fadeStartTime = Date()
        fadeStartVolume = 0.0
        fadeTargetVolume = targetVolume
        fadeDuration = duration
        fadeCompletion = nil
        
        fadeTimer = Timer.scheduledTimer(
            timeInterval: 1.0/60.0,
            target: self,
            selector: #selector(handleFadeInTimer(_:)),
            userInfo: nil,
            repeats: true
        )
    }
    
    @objc private func handleFadeInTimer(_ timer: Timer) {
        guard let player = player,
              let startTime = fadeStartTime else {
            timer.invalidate()
            fadeTimer = nil
            return
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(1.0, elapsed / fadeDuration)
        
        // Ease-in-out curve for smoother fade
        let easedProgress = progress < 0.5 
            ? 2 * progress * progress 
            : 1 - pow(-2 * progress + 2, 2) / 2
        
        let currentVolume = fadeStartVolume + (fadeTargetVolume - fadeStartVolume) * Float(easedProgress)
        player.volume = currentVolume
        
        if progress >= 1.0 {
            player.volume = fadeTargetVolume
            timer.invalidate()
            fadeTimer = nil
            fadeStartTime = nil
        }
    }
    
    private func performFadeOut(duration: Double, completion: @escaping () -> Void) {
        guard let player = player else {
            completion()
            return
        }
        
        fadeTimer?.invalidate()
        fadeStartTime = Date()
        fadeStartVolume = player.volume
        fadeTargetVolume = 0.0
        fadeDuration = duration
        fadeCompletion = completion
        
        fadeTimer = Timer.scheduledTimer(
            timeInterval: 1.0/60.0,
            target: self,
            selector: #selector(handleFadeOutTimer(_:)),
            userInfo: nil,
            repeats: true
        )
    }
    
    @objc private func handleFadeOutTimer(_ timer: Timer) {
        guard let player = player,
              let startTime = fadeStartTime else {
            timer.invalidate()
            fadeTimer = nil
            fadeCompletion?()
            fadeCompletion = nil
            return
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let progress = min(1.0, elapsed / fadeDuration)
        
        // Ease-in-out curve for smoother fade
        let easedProgress = progress < 0.5 
            ? 2 * progress * progress 
            : 1 - pow(-2 * progress + 2, 2) / 2
        
        let currentVolume = fadeStartVolume * (1.0 - Float(easedProgress))
        player.volume = currentVolume
        
        if progress >= 1.0 {
            player.volume = 0.0
            timer.invalidate()
            fadeTimer = nil
            fadeStartTime = nil
            let completion = fadeCompletion
            fadeCompletion = nil
            completion?()
        }
    }
    
    // MARK: - Looping
    
    private func installLoopObserver() {
        guard let item = playerItem, let _ = player else { return }
        
        removeLoopObserver()
        
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // Notification is delivered on main queue, so we're on the main actor
            MainActor.assumeIsolated {
                // Restart from beginning for seamless loop
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }
    }
    
    private func removeLoopObserver() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }
}
