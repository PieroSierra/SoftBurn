//
//  VideoPlayerPool.swift
//  SoftBurn
//
//  Pool of reusable SoftBurnVideoPlayer instances to avoid hardware decoder exhaustion.
//  macOS limits simultaneous hardware-accelerated decode sessions (~16-32).
//  Creating new AVPlayers in quick succession during transitions can exhaust this pool,
//  causing FigFilePlayer errors (-12860, -12864, -12852) and video black flashes.
//

import AVFoundation
import Combine
import Foundation

// MARK: - VideoPlayerPool

/// Pool of reusable SoftBurnVideoPlayer instances to avoid hardware decoder exhaustion.
///
/// macOS limits simultaneous hardware-accelerated video decoding sessions (~16-32).
/// Creating new AVPlayers in quick succession during transitions exhausts this pool,
/// causing FigFilePlayer errors and video black flashes/cutouts.
///
/// This pool maintains a small set of reusable players that can be reconfigured
/// with new assets rather than creating new decoder sessions.
actor VideoPlayerPool {
    static let shared = VideoPlayerPool()

    /// A pooled player entry that wraps a reusable AVPlayer
    final class PooledPlayer: @unchecked Sendable {
        let player: AVPlayer
        private(set) var currentItem: AVPlayerItem?
        private(set) var isInUse: Bool = false
        private var securityScopedURL: URL?

        /// Video metadata (extracted from current asset)
        private(set) var duration: Double = 0
        private(set) var naturalSize: CGSize = .zero
        private(set) var rotationDegrees: Int = 0

        init() {
            self.player = AVPlayer()
            player.actionAtItemEnd = .none // Keep last frame visible
        }

        @MainActor
        func configure(with item: AVPlayerItem, metadata: VideoMetadata, securityScopedURL: URL?) async {
            // Release old security-scoped resource
            if let url = self.securityScopedURL {
                url.stopAccessingSecurityScopedResource()
            }

            self.currentItem = item
            self.securityScopedURL = securityScopedURL
            self.duration = metadata.duration
            self.naturalSize = metadata.naturalSize
            self.rotationDegrees = metadata.rotationDegrees

            VideoDebugLogger.log("PooledPlayer.configure: setting rotationDegrees=\(metadata.rotationDegrees)°")

            // Replace the player item (reuses the hardware decoder session)
            player.replaceCurrentItem(with: item)
        }

        @MainActor
        func markInUse() {
            isInUse = true
        }

        @MainActor
        func release() {
            isInUse = false
            player.pause()
            // Don't remove the item - keep it for potential reuse
        }

        @MainActor
        func invalidate() {
            isInUse = false
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentItem = nil

            // Release security-scoped resource
            if let url = securityScopedURL {
                url.stopAccessingSecurityScopedResource()
                securityScopedURL = nil
            }

            duration = 0
            naturalSize = .zero
            rotationDegrees = 0
        }
    }

    /// Video metadata extracted during asset loading
    struct VideoMetadata: Sendable {
        let duration: Double
        let naturalSize: CGSize
        let rotationDegrees: Int
    }

    // MARK: - Properties

    /// Maximum number of pooled players
    /// Current + Next + 2 prefetch buffer (based on user preference setting)
    private let maxPoolSize = 4

    /// Pool of reusable players
    private var pool: [PooledPlayer] = []

    /// Whether the pool has been warmed up
    private var isWarmedUp = false

    private init() {}

    // MARK: - Public Methods

    /// Warm up the pool by pre-creating players
    /// Call this when starting a slideshow to avoid initial allocation delays
    func warmUp(count: Int = 2) async {
        guard !isWarmedUp else { return }

        let toCreate = min(count, maxPoolSize - pool.count)
        for _ in 0..<toCreate {
            let player = PooledPlayer()
            pool.append(player)
        }
        isWarmedUp = true
        let poolCount = pool.count
        await MainActor.run {
            VideoDebugLogger.log("VideoPlayerPool: warmed up with \(poolCount) players")
        }
    }

    /// Acquire a player from the pool
    /// Returns an existing unused player, or creates a new one if under the pool limit
    @MainActor
    func acquire() async -> PooledPlayer? {
        // First, try to find an unused player
        for player in await getPool() {
            if !player.isInUse {
                player.markInUse()
                VideoDebugLogger.log("VideoPlayerPool: acquired existing player (pool size: \(await poolCount()))")
                return player
            }
        }

        // If no unused player available and under limit, create a new one
        let currentCount = await poolCount()
        if currentCount < maxPoolSize {
            let player = PooledPlayer()
            player.markInUse()
            await addToPool(player)
            VideoDebugLogger.log("VideoPlayerPool: created new player (pool size: \(await poolCount()))")
            return player
        }

        VideoDebugLogger.log("VideoPlayerPool: no players available (pool full at \(maxPoolSize))")
        return nil
    }

    /// Release a player back to the pool for reuse
    @MainActor
    func release(_ player: PooledPlayer) async {
        player.release()
        VideoDebugLogger.log("VideoPlayerPool: released player back to pool")
    }

    /// Configure a pooled player with a new asset
    /// This reuses the existing decoder session rather than creating a new one
    @MainActor
    func configure(
        _ player: PooledPlayer,
        with asset: AVAsset,
        muted: Bool,
        securityScopedURL: URL? = nil
    ) async throws {
        VideoDebugLogger.log("VideoPlayerPool: configuring player with new asset")

        // Load essential properties
        let durationValue: CMTime
        let tracks: [AVAssetTrack]
        do {
            let (isPlayable, dur, trks) = try await asset.load(.isPlayable, .duration, .tracks)

            guard isPlayable else {
                VideoDebugLogger.log("VideoPlayerPool: asset not playable")
                throw VideoError.notPlayable
            }

            durationValue = dur
            tracks = trks
        } catch let error as VideoError {
            throw error
        } catch {
            VideoDebugLogger.log("VideoPlayerPool: asset load failed - \(error)")
            throw VideoError.assetLoadFailed(error)
        }

        let duration = CMTimeGetSeconds(durationValue)

        // Extract rotation and natural size from video track
        var naturalSize: CGSize = .zero
        var rotationDegrees: Int = 0

        let videoTracks = tracks.filter { $0.mediaType == .video }
        if let videoTrack = videoTracks.first {
            do {
                let (naturalSizeValue, preferredTransform) = try await videoTrack.load(
                    .naturalSize, .preferredTransform)

                // Calculate rotation from transform
                let angle = atan2(preferredTransform.b, preferredTransform.a)
                let degrees = Int(round(angle * 180 / .pi))
                rotationDegrees = ((degrees % 360) + 360) % 360

                // Apply rotation to get display size
                if rotationDegrees == 90 || rotationDegrees == 270 {
                    naturalSize = CGSize(
                        width: naturalSizeValue.height, height: naturalSizeValue.width)
                } else {
                    naturalSize = naturalSizeValue
                }
                VideoDebugLogger.log("VideoPlayerPool: extracted rotation=\(rotationDegrees)°, transform=(\(preferredTransform.a), \(preferredTransform.b), \(preferredTransform.c), \(preferredTransform.d))")
            } catch {
                VideoDebugLogger.log("VideoPlayerPool: failed to load track info - \(error)")
            }
        }

        let metadata = VideoMetadata(
            duration: duration,
            naturalSize: naturalSize,
            rotationDegrees: rotationDegrees
        )

        // Create new player item
        let playerItem = AVPlayerItem(asset: asset)

        // Configure the pooled player
        await player.configure(with: playerItem, metadata: metadata, securityScopedURL: securityScopedURL)
        player.player.isMuted = muted

        // Wait for the item to be ready
        let ready = await waitForReady(item: playerItem)

        if !ready {
            VideoDebugLogger.log("VideoPlayerPool: item failed to become ready")
            throw VideoError.itemNotReady
        }

        VideoDebugLogger.log("VideoPlayerPool: player configured successfully (duration: \(duration)s)")
    }

    /// Drain the pool, releasing all players
    /// Call this when ending a slideshow
    func drain() async {
        for player in pool {
            await MainActor.run {
                player.invalidate()
            }
        }
        pool.removeAll()
        isWarmedUp = false
        await MainActor.run {
            VideoDebugLogger.log("VideoPlayerPool: drained all players")
        }
    }

    // MARK: - Private Helpers

    private func getPool() -> [PooledPlayer] {
        return pool
    }

    private func poolCount() -> Int {
        return pool.count
    }

    private func addToPool(_ player: PooledPlayer) {
        pool.append(player)
    }

    private func clearPool() {
        pool.removeAll()
    }

    /// Wait for the player item to become ready (or fail)
    @MainActor
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

// MARK: - PooledVideoPlayer (Wrapper for SlideshowPlayerState)

/// A wrapper that provides the same interface as SoftBurnVideoPlayer but uses pooled players
@MainActor
final class PooledVideoPlayer: ObservableObject {

    // MARK: - Public Properties

    /// The underlying AVPlayer for rendering
    var player: AVPlayer { pooledPlayer.player }

    /// Current playback status
    @Published private(set) var status: PlayerStatus = .loading

    /// Video duration in seconds
    var duration: Double { pooledPlayer.duration }

    /// Video natural size (after rotation applied)
    var naturalSize: CGSize { pooledPlayer.naturalSize }

    /// Rotation extracted from video track's preferredTransform
    var rotationDegrees: Int { pooledPlayer.rotationDegrees }

    /// The underlying player item
    var playerItem: AVPlayerItem? { pooledPlayer.currentItem }

    // MARK: - Status Types

    enum PlayerStatus: String, CustomStringConvertible {
        case loading
        case readyToPlay
        case failed

        var description: String { rawValue }
    }

    // MARK: - Private Properties

    private let pooledPlayer: VideoPlayerPool.PooledPlayer

    // MARK: - Initialization

    init(pooledPlayer: VideoPlayerPool.PooledPlayer) {
        self.pooledPlayer = pooledPlayer
        self.status = .readyToPlay
    }

    // MARK: - Public Methods

    func play() {
        player.play()
        VideoDebugLogger.log("PooledVideoPlayer: play() called, rate=\(player.rate)")
    }

    func pause() {
        player.pause()
        VideoDebugLogger.log("PooledVideoPlayer: pause() called")
    }

    /// Clean up when done with the player (returns to pool instead of destroying)
    func invalidate() {
        VideoDebugLogger.log("PooledVideoPlayer: invalidate() called - releasing to pool")
        Task {
            await VideoPlayerPool.shared.release(pooledPlayer)
        }
    }
}
