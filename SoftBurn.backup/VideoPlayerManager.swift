//
//  VideoPlayerManager.swift
//  SoftBurn
//
//  Simple video player with manual looping.
//  Supports both filesystem and Photos Library videos.
//

import AVFoundation
import Combine
import Foundation
import Photos

// MARK: - Video Errors

enum VideoError: Error, LocalizedError {
    case notPlayable
    case assetLoadFailed(Error)
    case itemNotReady
    case photosLibraryAccessDenied
    case assetNotFound
    case invalidMediaType

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return "Video is not playable"
        case let .assetLoadFailed(error):
            return "Failed to load video asset: \(error.localizedDescription)"
        case .itemNotReady:
            return "Video item failed to become ready"
        case .photosLibraryAccessDenied:
            return "Photos Library access denied"
        case .assetNotFound:
            return "Video asset not found"
        case .invalidMediaType:
            return "Asset is not a video"
        }
    }
}

// MARK: - SoftBurnVideoPlayer

/// Simple video player that waits for readiness before returning.
/// Uses manual looping via seek-to-zero on end notification.
/// Named SoftBurnVideoPlayer to avoid conflict with SwiftUI/AVKit VideoPlayer.
@MainActor
final class SoftBurnVideoPlayer: ObservableObject {

    // MARK: - Public Properties

    /// The underlying AVPlayer for rendering
    let player: AVPlayer

    /// Current playback status
    @Published private(set) var status: PlayerStatus = .loading

    /// Video duration in seconds
    let duration: Double

    /// Video natural size (after rotation applied)
    let naturalSize: CGSize

    /// Rotation extracted from video track's preferredTransform
    let rotationDegrees: Int

    // MARK: - Status Types

    enum PlayerStatus: String, CustomStringConvertible {
        case loading
        case readyToPlay
        case failed

        var description: String { rawValue }
    }

    // MARK: - Private Properties

    /// The player item (needed for loop observer attachment)
    let playerItem: AVPlayerItem

    // Security-scoped resource tracking (for filesystem videos)
    private var securityScopedURL: URL?

    // MARK: - Initialization

    /// Initialize with a pre-loaded AVAsset. Waits for player item to be ready before returning.
    /// - Parameters:
    ///   - asset: The video asset (AVURLAsset or AVComposition)
    ///   - muted: Whether to mute audio
    ///   - securityScopedURL: Optional URL for security-scoped resource access
    ///   - isFromPhotosLibrary: True if the asset came from Photos Library (affects rotation handling)
    init(asset: AVAsset, muted: Bool, securityScopedURL: URL? = nil, isFromPhotosLibrary: Bool = false) async throws {
        self.securityScopedURL = securityScopedURL

        VideoDebugLogger.log("VideoPlayer init: starting asset load")

        // Pre-load essential properties
        let durationValue: CMTime
        let tracks: [AVAssetTrack]
        do {
            let (isPlayable, dur, trks) = try await asset.load(.isPlayable, .duration, .tracks)

            guard isPlayable else {
                VideoDebugLogger.log("VideoPlayer init: asset not playable")
                throw VideoError.notPlayable
            }

            durationValue = dur
            tracks = trks
        } catch let error as VideoError {
            throw error
        } catch {
            VideoDebugLogger.log("VideoPlayer init: asset load failed - \(error)")
            throw VideoError.assetLoadFailed(error)
        }

        self.duration = CMTimeGetSeconds(durationValue)
        VideoDebugLogger.log("VideoPlayer init: duration=\(duration)s")

        // Extract rotation and natural size from video track
        let videoTracks = tracks.filter { $0.mediaType == .video }
        if let videoTrack = videoTracks.first {
            do {
                let (naturalSizeValue, preferredTransform) = try await videoTrack.load(
                    .naturalSize, .preferredTransform)

                // Calculate rotation from transform
                let angle = atan2(preferredTransform.b, preferredTransform.a)
                let degrees = Int(round(angle * 180 / .pi))
                // Normalize to 0, 90, 180, 270
                var computedRotation = ((degrees % 360) + 360) % 360

                // Photos Library videos: The preferredTransform is designed for AVFoundation's
                // coordinate system (Y-down), but CVPixelBuffer textures in Metal use a different
                // convention. For Photos Library videos, we need to negate the rotation.
                // This swaps 90° ↔ 270° while leaving 0° and 180° unchanged.
                if isFromPhotosLibrary && computedRotation != 0 {
                    computedRotation = (360 - computedRotation) % 360
                    VideoDebugLogger.log("VideoPlayer init: Photos Library video rotation negated to \(computedRotation)°")
                }

                self.rotationDegrees = computedRotation

                // Apply rotation to get display size
                if rotationDegrees == 90 || rotationDegrees == 270 {
                    self.naturalSize = CGSize(
                        width: naturalSizeValue.height, height: naturalSizeValue.width)
                } else {
                    self.naturalSize = naturalSizeValue
                }
                VideoDebugLogger.log("VideoPlayer init: size=\(naturalSize), rotation=\(rotationDegrees)°, isFromPhotosLibrary=\(isFromPhotosLibrary)")
            } catch {
                self.rotationDegrees = 0
                self.naturalSize = .zero
                VideoDebugLogger.log("VideoPlayer init: failed to load track info - \(error)")
            }
        } else {
            self.rotationDegrees = 0
            self.naturalSize = .zero
            VideoDebugLogger.log("VideoPlayer init: no video tracks found")
        }

        // Create player item and player
        self.playerItem = AVPlayerItem(asset: asset)
        self.player = AVPlayer(playerItem: playerItem)
        player.isMuted = muted
        player.actionAtItemEnd = .none  // Keep last frame visible, don't auto-stop

        VideoDebugLogger.log("VideoPlayer init: waiting for item to be ready")

        // Wait for the item to be ready before returning
        let ready = await waitForReady(item: playerItem)

        if ready {
            self.status = .readyToPlay
            VideoDebugLogger.log("VideoPlayer init: ready to play")
        } else {
            self.status = .failed
            VideoDebugLogger.log("VideoPlayer init: failed to become ready - \(playerItem.error?.localizedDescription ?? "unknown error")")
            throw VideoError.itemNotReady
        }
    }

    deinit {
        player.pause()

        // Release security-scoped resource
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Public Methods

    func play() {
        player.play()
        VideoDebugLogger.log("play() called, rate=\(player.rate)")
    }

    func pause() {
        player.pause()
        VideoDebugLogger.log("pause() called")
    }

    /// Clean up when done with the player
    func invalidate() {
        VideoDebugLogger.log("invalidate() called")
        player.pause()

        // Release security-scoped resource
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
    }

    // MARK: - Private Methods

    /// Wait for the player item to become ready (or fail)
    private func waitForReady(item: AVPlayerItem) async -> Bool {
        // If already ready or failed, return immediately
        if item.status == .readyToPlay {
            return true
        }
        if item.status == .failed {
            return false
        }

        // Wait for status change using continuation
        return await withCheckedContinuation { continuation in
            var observer: NSKeyValueObservation?
            var resumed = false

            observer = item.observe(\.status, options: [.new]) { observedItem, _ in
                guard !resumed else { return }

                if observedItem.status == .readyToPlay {
                    resumed = true
                    observer?.invalidate()
                    continuation.resume(returning: true)
                } else if observedItem.status == .failed {
                    resumed = true
                    observer?.invalidate()
                    continuation.resume(returning: false)
                }
            }

            // Double-check in case status changed between our check and observer setup
            if !resumed {
                if item.status == .readyToPlay {
                    resumed = true
                    observer?.invalidate()
                    continuation.resume(returning: true)
                } else if item.status == .failed {
                    resumed = true
                    observer?.invalidate()
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

// MARK: - VideoPlayerManager

/// Factory actor for creating SoftBurnVideoPlayer instances from MediaItems
actor VideoPlayerManager {
    static let shared = VideoPlayerManager()

    private init() {}

    /// Create a video player for a MediaItem
    /// - Parameters:
    ///   - item: The media item (must be a video)
    ///   - muted: Whether to mute audio
    /// - Returns: A configured SoftBurnVideoPlayer, or nil if creation failed
    func createPlayer(for item: MediaItem, muted: Bool) async -> SoftBurnVideoPlayer? {
        guard item.kind == .video else {
            VideoDebugLogger.log("createPlayer: item is not a video")
            return nil
        }

        switch item.source {
        case let .filesystem(url):
            return await createFromFilesystem(url: url, muted: muted)
        case let .photosLibrary(localID, _):
            return await createFromPhotosLibrary(localIdentifier: localID, muted: muted)
        }
    }

    /// Create a pooled video player for a MediaItem (uses VideoPlayerPool for reuse)
    /// - Parameters:
    ///   - item: The media item (must be a video)
    ///   - muted: Whether to mute audio
    /// - Returns: A configured PooledVideoPlayer, or nil if creation failed
    @MainActor
    func createPooledPlayer(for item: MediaItem, muted: Bool) async -> PooledVideoPlayer? {
        guard item.kind == .video else {
            VideoDebugLogger.log("createPooledPlayer: item is not a video")
            return nil
        }

        switch item.source {
        case let .filesystem(url):
            return await createPooledFromFilesystem(url: url, muted: muted)
        case let .photosLibrary(localID, _):
            return await createPooledFromPhotosLibrary(localIdentifier: localID, muted: muted)
        }
    }

    // MARK: - Pooled Player Creation

    @MainActor
    private func createPooledFromFilesystem(url: URL, muted: Bool) async -> PooledVideoPlayer? {
        VideoDebugLogger.log("Creating pooled player from filesystem: \(url.lastPathComponent)")

        // Acquire a player from the pool
        guard let pooledPlayer = await VideoPlayerPool.shared.acquire() else {
            VideoDebugLogger.log("Failed to acquire player from pool")
            return nil
        }

        // Start security-scoped access
        let didStart = url.startAccessingSecurityScopedResource()
        VideoDebugLogger.log("Security-scoped access started: \(didStart)")

        let asset = AVURLAsset(url: url)

        do {
            try await VideoPlayerPool.shared.configure(
                pooledPlayer,
                with: asset,
                muted: muted,
                securityScopedURL: didStart ? url : nil
            )
            VideoDebugLogger.log("Pooled filesystem player configured successfully")
            return PooledVideoPlayer(pooledPlayer: pooledPlayer)
        } catch {
            VideoDebugLogger.log("Failed to configure pooled filesystem player: \(error)")
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
            await VideoPlayerPool.shared.release(pooledPlayer)
            return nil
        }
    }

    @MainActor
    private func createPooledFromPhotosLibrary(localIdentifier: String, muted: Bool) async -> PooledVideoPlayer? {
        VideoDebugLogger.log("Creating pooled player from Photos Library: \(localIdentifier)")

        // Fetch the PHAsset
        guard
            let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
                .firstObject
        else {
            VideoDebugLogger.log("PHAsset not found for identifier")
            return nil
        }

        guard phAsset.mediaType == .video else {
            VideoDebugLogger.log("PHAsset is not a video")
            return nil
        }

        // Request the AVAsset from Photos Library
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, info in
                Task { @MainActor in
                    guard let avAsset else {
                        if let error = info?[PHImageErrorKey] as? Error {
                            VideoDebugLogger.log("Photos Library requestAVAsset failed: \(error)")
                        } else {
                            VideoDebugLogger.log("Photos Library requestAVAsset returned nil")
                        }
                        continuation.resume(returning: nil)
                        return
                    }

                    // Acquire a player from the pool
                    guard let pooledPlayer = await VideoPlayerPool.shared.acquire() else {
                        VideoDebugLogger.log("Failed to acquire player from pool for Photos Library video")
                        continuation.resume(returning: nil)
                        return
                    }

                    do {
                        try await VideoPlayerPool.shared.configure(
                            pooledPlayer,
                            with: avAsset,
                            muted: muted,
                            securityScopedURL: nil,
                            isFromPhotosLibrary: true
                        )
                        VideoDebugLogger.log("Pooled Photos Library player configured successfully")
                        continuation.resume(returning: PooledVideoPlayer(pooledPlayer: pooledPlayer))
                    } catch {
                        VideoDebugLogger.log("Failed to configure pooled Photos Library player: \(error)")
                        await VideoPlayerPool.shared.release(pooledPlayer)
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    // MARK: - Private Methods

    private func createFromFilesystem(url: URL, muted: Bool) async -> SoftBurnVideoPlayer? {
        VideoDebugLogger.log("Creating player from filesystem: \(url.lastPathComponent)")

        // Start security-scoped access
        let didStart = url.startAccessingSecurityScopedResource()
        VideoDebugLogger.log("Security-scoped access started: \(didStart)")

        let asset = AVURLAsset(url: url)

        do {
            let player = try await SoftBurnVideoPlayer(
                asset: asset,
                muted: muted,
                securityScopedURL: didStart ? url : nil
            )
            VideoDebugLogger.log("Filesystem player created successfully")
            return player
        } catch {
            VideoDebugLogger.log("Failed to create filesystem player: \(error)")
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
            return nil
        }
    }

    private func createFromPhotosLibrary(localIdentifier: String, muted: Bool) async -> SoftBurnVideoPlayer? {
        VideoDebugLogger.log("Creating player from Photos Library: \(localIdentifier)")

        // Fetch the PHAsset
        guard
            let phAsset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
                .firstObject
        else {
            VideoDebugLogger.log("PHAsset not found for identifier")
            return nil
        }

        guard phAsset.mediaType == .video else {
            VideoDebugLogger.log("PHAsset is not a video")
            return nil
        }

        // Request the AVAsset from Photos Library
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true  // Allow iCloud download
        options.deliveryMode = .highQualityFormat
        options.version = .current  // Get edited version if available

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) {
                avAsset, _, info in
                Task {
                    guard let avAsset else {
                        if let error = info?[PHImageErrorKey] as? Error {
                            VideoDebugLogger.log("Photos Library requestAVAsset failed: \(error)")
                        } else {
                            VideoDebugLogger.log("Photos Library requestAVAsset returned nil")
                        }
                        continuation.resume(returning: nil)
                        return
                    }

                    // Log what type we got
                    if avAsset is AVURLAsset {
                        VideoDebugLogger.log("Photos Library returned AVURLAsset")
                    } else if avAsset is AVComposition {
                        VideoDebugLogger.log("Photos Library returned AVComposition (edited video)")
                    } else {
                        VideoDebugLogger.log("Photos Library returned \(type(of: avAsset))")
                    }

                    // Create the player
                    do {
                        let player = try await SoftBurnVideoPlayer(
                            asset: avAsset,
                            muted: muted,
                            securityScopedURL: nil,
                            isFromPhotosLibrary: true
                        )
                        VideoDebugLogger.log("Photos Library player created successfully")
                        continuation.resume(returning: player)
                    } catch {
                        VideoDebugLogger.log("Failed to create Photos Library player: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}
