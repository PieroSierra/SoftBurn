//
//  SlideshowPlayerView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import AppKit
import Combine
import AVKit

/// Full-screen slideshow player view
struct SlideshowPlayerView: View {
    let photos: [MediaItem]
    let settings: SlideshowSettings
    let onExit: () -> Void
    
    @StateObject private var playerState: SlideshowPlayerState
    @StateObject private var musicManager = MusicPlaybackManager()
    @State private var isExiting = false
    
    /// Creates a slideshow player view.
    /// - Parameters:
    ///   - photos: All photos in the slideshow
    ///   - settings: Slideshow settings
    ///   - startingPhotoID: If provided and shuffle is OFF, playback starts from this photo.
    ///                      If shuffle is ON, this is ignored and playback starts randomly.
    ///   - onExit: Callback when the slideshow exits
    init(photos: [MediaItem], settings: SlideshowSettings, startingPhotoID: UUID? = nil, onExit: @escaping () -> Void) {
        self.photos = photos
        self.settings = settings
        self.onExit = onExit
        
        // Create playback list (shuffle if needed)
        let playbackPhotos: [MediaItem]
        let startIndex: Int
        
        if settings.shuffle {
            playbackPhotos = photos.shuffled()
            startIndex = 0 // Shuffle always starts from the beginning of the shuffled list
        } else {
            playbackPhotos = photos
            // Find the starting index based on startingPhotoID
            if let id = startingPhotoID,
               let idx = photos.firstIndex(where: { $0.id == id }) {
                startIndex = idx
            } else {
                startIndex = 0
            }
        }
        
        _playerState = StateObject(wrappedValue: SlideshowPlayerState(
            photos: playbackPhotos,
            slideDuration: settings.slideDuration,
            transitionStyle: settings.transitionStyle,
            playVideosWithSound: settings.playVideosWithSound,
            playVideosInFull: settings.playVideosInFull,
            startIndex: startIndex
        ))
    }
    
    var body: some View {
        ZStack {
            // Background
            settings.backgroundColor
                .ignoresSafeArea()
            
            // Only render content if not exiting
            if !isExiting {
                // UNIFIED METAL PIPELINE: Always use Metal for rendering.
                // When Patina is .none, the MetalSlideshowRenderer will skip the
                // Patina post-processing pass and blit directly to the drawable.
                MetalSlideshowView(
                    playerState: playerState,
                    settings: settings
                )
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // Any mouse click exits (same as "any key").
        .contentShape(Rectangle())
        .onTapGesture {
            performSafeExit()
        }
        .onAppear {
            NSCursor.hide()
            playerState.start()
            
            // Start music if selected
            if let musicSelection = settings.musicSelection {
                let selection = MusicPlaybackManager.MusicSelection.from(identifier: musicSelection)
                musicManager.start(selection: selection, volume: settings.musicVolume)
            }
        }
        .onKeyboardEvent(
            onLeftArrow: { playerState.previousSlide() },
            onRightArrow: { playerState.nextSlide() },
            onExit: { performSafeExit() }
        )
    }
    
    /// Safe exit sequence: stop animations, wait for GPU, then close
    private func performSafeExit() {
        // Prevent re-entrancy
        guard !isExiting else { return }
        isExiting = true
        
        // 1. Stop all timers and animations immediately
        playerState.stop()
        
        // 2. Fade out music (with fade-out)
        musicManager.stop(shouldFadeOut: true)
        
        // 3. Show cursor immediately
        NSCursor.unhide()
        
        // 4. Wait for SwiftUI to process the state change and stop rendering
        //    Allow extra time for music fade-out (0.75s) + buffer (0.25s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // 5. Now safe to close the window
            onExit()
        }
    }
}

// MARK: - Player State

/// Manages slideshow playback state and timing
@MainActor
class SlideshowPlayerState: ObservableObject {
    let photos: [MediaItem]
    let slideDuration: Double
    let transitionStyle: SlideshowDocument.Settings.TransitionStyle
    let playVideosWithSound: Bool
    let playVideosInFull: Bool

    /// Fixed transition duration (2 seconds as per spec)
    static let transitionDuration: Double = 2.0

    @Published var currentIndex: Int = 0
    @Published var currentImage: NSImage?
    @Published var nextImage: NSImage?
    @Published var currentVideo: PooledVideoPlayer?
    @Published var nextVideo: PooledVideoPlayer?
    @Published var currentKind: MediaItem.Kind = .photo
    @Published var nextKind: MediaItem.Kind = .photo
    @Published var currentHoldDuration: Double = 5.0

    /// Vision face boxes (normalized rects, origin bottom-left).
    /// These are rotated into the slideshow's rotation metadata space for consistency with rendering.
    @Published var currentFaceBoxes: [CGRect] = []
    @Published var nextFaceBoxes: [CGRect] = []

    /// Ken Burns end targets (normalized offsets, where (0,0) is center; +y is down in view space).
    @Published var currentEndOffset: CGSize = .zero
    @Published var nextEndOffset: CGSize = .zero

    /// Ken Burns start offsets (randomized per load/loop pass).
    @Published var currentStartOffset: CGSize = .zero
    @Published var nextStartOffset: CGSize = .zero
    
    /// Animation progress (0 = start, 1 = end of current slide)
    @Published var animationProgress: Double = 0

    /// Whether we're in the transition phase
    @Published var isTransitioning: Bool = false

    /// Whether the player has been stopped - prevents any more updates
    @Published private(set) var isStopped: Bool = false

    /// Whether the next video is ready to play (always true for photos)
    @Published var nextVideoReady: Bool = true

    private let imageLoader = PlaybackImageLoader()
    private var slideTimer: Timer?
    private var animationTimer: Timer?
    private var isRunning = false
    private var didStartNextVideoThisCycle: Bool = false
    private var waitingForVideoStartTime: Date?

    /// Observers for video loop detection
    private var currentVideoLoopObserver: NSObjectProtocol?
    private var nextVideoLoopObserver: NSObjectProtocol?

    /// Maximum time to wait for a video to be ready before proceeding anyway
    private static let maxWaitForVideoSeconds: Double = 3.0
    
    /// Total duration for one complete slide cycle (for current item)
    var totalSlideDuration: Double {
        switch transitionStyle {
        case .plain:
            return currentHoldDuration
        case .crossFade, .panAndZoom, .zoom:
            return SlideshowPlayerState.transitionDuration + currentHoldDuration
        }
    }
    
    /// The index to start playback from (defaults to 0)
    private let startIndex: Int
    
    init(
        photos: [MediaItem],
        slideDuration: Double,
        transitionStyle: SlideshowDocument.Settings.TransitionStyle,
        playVideosWithSound: Bool,
        playVideosInFull: Bool,
        startIndex: Int = 0
    ) {
        self.photos = photos
        self.slideDuration = slideDuration
        self.transitionStyle = transitionStyle
        self.playVideosWithSound = playVideosWithSound
        self.playVideosInFull = playVideosInFull
        self.startIndex = startIndex
    }
    
    func start() {
        guard !photos.isEmpty, !isStopped else { return }
        isRunning = true
        // Use the provided start index (clamped to valid range)
        currentIndex = max(0, min(startIndex, photos.count - 1))
        animationProgress = 0
        isTransitioning = false
        didStartNextVideoThisCycle = false

        Task { @MainActor in
            // Warm up the video player pool before starting playback
            await VideoPlayerPool.shared.warmUp(count: 2)
            await prepareCurrentAndNext()
            startTimers()
        }
    }
    
    func stop() {
        // Mark as stopped FIRST to prevent any pending tasks from updating
        isStopped = true
        isRunning = false

        // Invalidate timers synchronously
        slideTimer?.invalidate()
        animationTimer?.invalidate()
        slideTimer = nil
        animationTimer = nil

        // Remove loop observers
        removeLoopObservers()

        // Clear images to release GPU resources
        currentImage = nil
        nextImage = nil
        currentVideo?.invalidate()
        nextVideo?.invalidate()
        currentVideo = nil
        nextVideo = nil
        currentKind = .photo
        nextKind = .photo
        currentHoldDuration = slideDuration
        currentFaceBoxes = []
        nextFaceBoxes = []
        currentEndOffset = .zero
        nextEndOffset = .zero
        currentStartOffset = .zero
        nextStartOffset = .zero
        didStartNextVideoThisCycle = false
        nextVideoReady = true
        waitingForVideoStartTime = nil

        // Drain the video player pool
        Task {
            await VideoPlayerPool.shared.drain()
        }

        // Clear the image loader cache (fire and forget - no await needed)
        Task.detached { [imageLoader] in
            await imageLoader.clearCache()
        }
    }
    
    func nextSlide() {
        guard isRunning, !isStopped else { return }
        currentIndex = (currentIndex + 1) % photos.count
        animationProgress = 0
        isTransitioning = false
        didStartNextVideoThisCycle = false
        pauseAndInvalidateVideos()
        Task { @MainActor in
            await prepareCurrentAndNext()
            restartTimers()
        }
    }

    func previousSlide() {
        guard isRunning, !isStopped else { return }
        currentIndex = (currentIndex - 1 + photos.count) % photos.count
        animationProgress = 0
        isTransitioning = false
        didStartNextVideoThisCycle = false
        pauseAndInvalidateVideos()
        Task { @MainActor in
            await prepareCurrentAndNext()
            restartTimers()
        }
    }
    
    private func prepareCurrentAndNext() async {
        guard !isStopped, !photos.isEmpty else { return }

        let currentItem = photos[currentIndex]
        let nextIndex = (currentIndex + 1) % photos.count
        let nextItem = photos[nextIndex]

        currentKind = currentItem.kind
        nextKind = nextItem.kind

        // Compute current hold duration (videos may use intrinsic duration).
        currentHoldDuration = await holdDuration(for: currentItem)

        // Start offsets depend on the transition style:
        // - Pan & Zoom: random start, then move toward face/center
        // - Zoom: start centered (0,0), then move toward face/center
        currentStartOffset = Self.startOffset(for: transitionStyle)
        nextStartOffset = Self.startOffset(for: transitionStyle)

        // Reset face/camera targets by default.
        currentFaceBoxes = []
        nextFaceBoxes = []
        currentEndOffset = .zero
        nextEndOffset = .zero

        // Load current
        switch currentItem.kind {
        case .photo:
            currentVideo?.invalidate()
            currentVideo = nil
            // Use MediaItem-based method to support both filesystem and Photos Library
            if let image = await imageLoader.loadImage(for: currentItem) {
                guard !isStopped else { return }
                currentImage = image
            } else {
                currentImage = nil
            }

            let faces = await FaceDetectionCache.shared.cachedFaces(for: currentItem) ?? []
            // Rotate faces in Vision space to match the rotated bitmap we render.
            let rotatedFaces = Self.rotateVisionRects(faces, degrees: currentItem.rotationDegrees)
            currentFaceBoxes = rotatedFaces
            currentEndOffset = Self.faceTargetOffset(from: rotatedFaces)
        case .video:
            currentImage = nil
            currentVideo = await createVideoPlayer(for: currentItem, shouldAutoPlay: true)
        }

        // Load next
        switch nextItem.kind {
        case .photo:
            nextVideo?.invalidate()
            nextVideo = nil
            // Use MediaItem-based method to support both filesystem and Photos Library
            nextImage = await imageLoader.loadImage(for: nextItem)

            let faces = await FaceDetectionCache.shared.cachedFaces(for: nextItem) ?? []
            let rotatedFaces = Self.rotateVisionRects(faces, degrees: nextItem.rotationDegrees)
            nextFaceBoxes = rotatedFaces
            nextEndOffset = Self.faceTargetOffset(from: rotatedFaces)
        case .video:
            nextImage = nil
            nextFaceBoxes = []
            nextEndOffset = .zero
            nextVideo = await createVideoPlayer(for: nextItem, shouldAutoPlay: false)
        }

        // Set up readiness monitoring for next video
        updateNextVideoReadiness()
    }
    
    private func startTimers() {
        guard !isStopped else { return }
        
        scheduleNextAdvance()
        
        // Animation timer for smooth progress updates (60fps)
        let frameInterval = 1.0 / 60.0
        animationTimer = Timer.scheduledTimer(
            timeInterval: frameInterval,
            target: self,
            selector: #selector(handleAnimationTimer(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    private func scheduleNextAdvance() {
        slideTimer?.invalidate()
        slideTimer = Timer.scheduledTimer(
            timeInterval: totalSlideDuration,
            target: self,
            selector: #selector(handleAdvanceTimer(_:)),
            userInfo: nil,
            repeats: false
        )
    }
    
    private func restartTimers() {
        slideTimer?.invalidate()
        animationTimer?.invalidate()
        startTimers()
    }
    
    private func advanceSlide() async {
        guard isRunning, !isStopped else { return }

        // Stop any outgoing current video immediately (audio should not linger).
        if currentKind == .video, let outgoing = currentVideo, outgoing !== nextVideo {
            outgoing.pause()
            // Remove old current loop observer
            if let observer = currentVideoLoopObserver {
                NotificationCenter.default.removeObserver(observer)
                currentVideoLoopObserver = nil
            }
        }

        // Move to next slide
        currentIndex = (currentIndex + 1) % photos.count
        animationProgress = 0
        isTransitioning = false
        didStartNextVideoThisCycle = false

        // Promote "next" into "current" (preserve playback during overlap).
        currentKind = nextKind
        currentImage = nextImage
        // Invalidate old current video before replacing
        if currentVideo !== nextVideo {
            currentVideo?.invalidate()
        }
        currentVideo = nextVideo
        currentFaceBoxes = nextFaceBoxes
        currentEndOffset = nextEndOffset
        currentStartOffset = nextStartOffset

        // Transfer next loop observer to current
        if let observer = nextVideoLoopObserver {
            // Remove old current observer first
            if let oldObserver = currentVideoLoopObserver {
                NotificationCenter.default.removeObserver(oldObserver)
            }
            currentVideoLoopObserver = observer
            nextVideoLoopObserver = nil
        }

        // Ensure the promoted video is playing (it should have started during transition,
        // but explicitly play to handle edge cases where it didn't start)
        if currentKind == .video, let videoPlayer = currentVideo {
            videoPlayer.play()
            // If no loop observer yet (video wasn't started during transition), install one
            if currentVideoLoopObserver == nil {
                installLoopObserver(for: videoPlayer, isCurrent: true)
            }
        }

        // Clear next slots before loading new next
        nextImage = nil
        nextVideo = nil
        nextFaceBoxes = []
        nextEndOffset = .zero
        nextStartOffset = .zero
        nextKind = .photo

        // Compute hold duration for new current
        let currentItem = photos[currentIndex]
        currentHoldDuration = await holdDuration(for: currentItem)

        // Load new next
        let newNextIndex = (currentIndex + 1) % photos.count
        let nextItem = photos[newNextIndex]
        nextKind = nextItem.kind
        nextStartOffset = Self.startOffset(for: transitionStyle)

        switch nextItem.kind {
        case .photo:
            nextVideo?.invalidate()
            nextVideo = nil
            // Use MediaItem-based method to support both filesystem and Photos Library
            nextImage = await imageLoader.loadImage(for: nextItem)

            let faces = await FaceDetectionCache.shared.cachedFaces(for: nextItem) ?? []
            let rotatedFaces = Self.rotateVisionRects(faces, degrees: nextItem.rotationDegrees)
            nextFaceBoxes = rotatedFaces
            nextEndOffset = Self.faceTargetOffset(from: rotatedFaces)
        case .video:
            nextImage = nil
            nextFaceBoxes = []
            nextEndOffset = .zero
            nextVideo = await createVideoPlayer(for: nextItem, shouldAutoPlay: false)
        }

        // Set up readiness monitoring for next video
        updateNextVideoReadiness()

        scheduleNextAdvance()
    }

    private func holdDuration(for item: MediaItem) async -> Double {
        switch item.kind {
        case .photo:
            return slideDuration
        case .video:
            if playVideosInFull, let seconds = await VideoMetadataCache.shared.durationSeconds(for: item) {
                return seconds
            }
            return slideDuration
        }
    }

    /// Create a video player for a MediaItem and install loop observer
    /// Uses VideoPlayerPool to reuse AVPlayer instances and avoid hardware decoder exhaustion
    private func createVideoPlayer(for item: MediaItem, shouldAutoPlay: Bool) async -> PooledVideoPlayer? {
        guard let player = await VideoPlayerManager.shared.createPooledPlayer(
            for: item,
            muted: !playVideosWithSound
        ) else {
            return nil
        }

        if shouldAutoPlay {
            player.play()
            installLoopObserver(for: player, isCurrent: true)
        }

        return player
    }

    /// Install a loop observer for a video player
    private func installLoopObserver(for videoPlayer: PooledVideoPlayer, isCurrent: Bool) {
        guard let playerItem = videoPlayer.playerItem else { return }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak videoPlayer] _ in
            guard let videoPlayer else { return }
            MainActor.assumeIsolated {
                videoPlayer.player.seek(to: .zero) { finished in
                    if finished {
                        MainActor.assumeIsolated {
                            videoPlayer.player.play()
                        }
                    }
                }
            }
        }

        if isCurrent {
            // Remove old observer
            if let oldObserver = currentVideoLoopObserver {
                NotificationCenter.default.removeObserver(oldObserver)
            }
            currentVideoLoopObserver = observer
        } else {
            // Remove old observer
            if let oldObserver = nextVideoLoopObserver {
                NotificationCenter.default.removeObserver(oldObserver)
            }
            nextVideoLoopObserver = observer
        }
    }

    /// Remove loop observer for a video
    private func removeLoopObservers() {
        if let observer = currentVideoLoopObserver {
            NotificationCenter.default.removeObserver(observer)
            currentVideoLoopObserver = nil
        }
        if let observer = nextVideoLoopObserver {
            NotificationCenter.default.removeObserver(observer)
            nextVideoLoopObserver = nil
        }
    }

    /// Pause and invalidate all video players
    private func pauseAndInvalidateVideos() {
        removeLoopObservers()
        currentVideo?.pause()
        nextVideo?.pause()
        currentVideo?.invalidate()
        nextVideo?.invalidate()
        currentVideo = nil
        nextVideo = nil
    }

    /// Update next video readiness state based on VideoPlayer status
    private func updateNextVideoReadiness() {
        waitingForVideoStartTime = nil

        // Photos are always ready
        if nextKind == .photo {
            nextVideoReady = true
            return
        }

        // Check if video exists and its status
        guard let video = nextVideo else {
            nextVideoReady = false
            return
        }

        nextVideoReady = (video.status == .readyToPlay)
    }

    @objc private func handleAnimationTimer(_ timer: Timer) {
        guard !isStopped else { return }
        let frameInterval = 1.0 / 60.0
        updateAnimationProgress(deltaTime: frameInterval)
    }

    @objc private func handleAdvanceTimer(_ timer: Timer) {
        guard !isStopped else { return }
        Task { @MainActor in
            await self.advanceSlide()
        }
    }

    // MARK: - Face targeting

    /// Rotate Vision-style normalized rects (origin bottom-left) by multiples of 90 degrees counterclockwise.
    private static func rotateVisionRects(_ rects: [CGRect], degrees: Int) -> [CGRect] {
        let d = MediaItem.normalizedRotationDegrees(degrees)
        guard d != 0 else { return rects }

        func rotatePoint(_ p: CGPoint) -> CGPoint {
            switch d {
            case 90:
                // (x, y) -> (1 - y, x)
                return CGPoint(x: 1.0 - p.y, y: p.x)
            case 180:
                return CGPoint(x: 1.0 - p.x, y: 1.0 - p.y)
            case 270:
                return CGPoint(x: p.y, y: 1.0 - p.x)
            default:
                return p
            }
        }

        return rects.map { r in
            let p1 = rotatePoint(CGPoint(x: r.minX, y: r.minY))
            let p2 = rotatePoint(CGPoint(x: r.maxX, y: r.minY))
            let p3 = rotatePoint(CGPoint(x: r.maxX, y: r.maxY))
            let p4 = rotatePoint(CGPoint(x: r.minX, y: r.maxY))
            let xs = [p1.x, p2.x, p3.x, p4.x]
            let ys = [p1.y, p2.y, p3.y, p4.y]
            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? 0
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    private static func faceTargetOffset(from faces: [CGRect]) -> CGSize {
        guard let face = faces.randomElement() else {
            return .zero
        }

        // Translation to move the IMAGE such that the face moves toward the VIEW center.
        // Result is a normalized offset where (0,0) means centered, +y means down (SwiftUI).
        //
        // Our face boxes are Vision-style (origin bottom-left). Convert to the same "offset" convention used elsewhere:
        // - If the face is to the right (x > 0.5), shift the image left (negative), and vice-versa.
        // - Vision's Y is bottom-left; SwiftUI's Y is top-left, so the sign differs.
        var x = 0.5 - face.midX
        var y = face.midY - 0.5

        // Clamp to a safe range so we don't pan too far.
        let clamp: Double = 0.25
        x = min(clamp, max(-clamp, x))
        y = min(clamp, max(-clamp, y))

        return CGSize(width: x, height: y)
    }

    // MARK: - Start offset randomization

    private static func randomStartOffset() -> CGSize {
        func randAxis() -> Double { Double.random(in: -0.20...0.20) }

        var x = randAxis()
        var y = randAxis()

        // Ensure at least one axis has a meaningful offset (~10–20%).
        if abs(x) < 0.10 && abs(y) < 0.10 {
            if Bool.random() {
                x = (Bool.random() ? 1 : -1) * Double.random(in: 0.10...0.20)
            } else {
                y = (Bool.random() ? 1 : -1) * Double.random(in: 0.10...0.20)
            }
        }

        return CGSize(width: x, height: y)
    }

    private static func startOffset(for style: SlideshowDocument.Settings.TransitionStyle) -> CGSize {
        switch style {
        case .panAndZoom:
            return randomStartOffset()
        case .zoom:
            return .zero
        case .crossFade, .plain:
            // Not used by those transitions, but keep deterministic.
            return .zero
        }
    }
    
    private func updateAnimationProgress(deltaTime: Double) {
        guard isRunning, !isStopped else { return }

        // Update transition state
        if transitionStyle != .plain {
            let transitionStartProgress = currentHoldDuration / totalSlideDuration

            // Check if we should wait for next video to be ready
            let shouldStartTransition = animationProgress >= transitionStartProgress && animationProgress < 1.0

            if shouldStartTransition && !isTransitioning {
                // Re-check next video readiness (LoopingVideoPlayer status may have changed)
                if nextKind == .video {
                    nextVideoReady = (nextVideo?.status == .readyToPlay)
                }

                // If next is a video and not ready, pause progress until ready (with timeout)
                if nextKind == .video && !nextVideoReady {
                    // Start tracking wait time
                    if waitingForVideoStartTime == nil {
                        waitingForVideoStartTime = Date()
                    }
                    let waited = Date().timeIntervalSince(waitingForVideoStartTime!)
                    if waited < Self.maxWaitForVideoSeconds {
                        // Don't update progress, wait for video to be ready
                        return
                    }
                    // Timeout reached - proceed anyway to prevent infinite wait
                }
                // Video is ready (or timed out) - clear wait state and start transition
                waitingForVideoStartTime = nil

                // Begin next video playback now (true overlap).
                if nextKind == .video, !didStartNextVideoThisCycle, let videoPlayer = nextVideo {
                    videoPlayer.play()
                    installLoopObserver(for: videoPlayer, isCurrent: false)
                    didStartNextVideoThisCycle = true
                }
            }
            isTransitioning = shouldStartTransition
        }

        // Update progress (after potential wait for video)
        let progressIncrement = deltaTime / totalSlideDuration
        animationProgress = min(1.0, animationProgress + progressIncrement)
    }
}

// Swift 6: Timer callbacks are `@Sendable`; this type is main-actor isolated and only touched on the main actor.
// Marking it unchecked-sendable avoids noisy warnings for safe usage patterns here.
extension SlideshowPlayerState: @unchecked Sendable {}

// MARK: - Keyboard Event Handling

/// Manages keyboard event monitoring for slideshow - must be bulletproof for exit!
class KeyboardMonitorController {
    static let shared = KeyboardMonitorController()
    
    private var monitor: Any?
    private var isExiting = false
    
    private init() {}
    
    func install(
        onLeftArrow: @escaping () -> Void,
        onRightArrow: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) {
        // Remove any existing monitor first
        removeMonitor()
        isExiting = false
        
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, !self.isExiting else { return nil }
            
            switch event.keyCode {
            case 123: // Left arrow
                onLeftArrow()
                return nil
            case 124: // Right arrow
                onRightArrow()
                return nil
            default:
                // Safety: do NOT trap system escape hatches.
                // - ⌘Tab should keep working
                // - ⌘⌥⎋ (Force Quit) should keep working
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let shouldPassThrough: Bool = flags.contains(.command)

                // Any other key exits - mark as exiting to prevent re-entrancy
                self.isExiting = true
                self.removeMonitor()
                
                // Call exit on next run loop to ensure monitor is fully removed
                DispatchQueue.main.async {
                    onExit()
                }
                return shouldPassThrough ? event : nil
            }
        }
    }
    
    func removeMonitor() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// View modifier that installs a local keyboard event monitor
struct KeyboardEventMonitor: ViewModifier {
    let onLeftArrow: () -> Void
    let onRightArrow: () -> Void
    let onExit: () -> Void
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                KeyboardMonitorController.shared.install(
                    onLeftArrow: onLeftArrow,
                    onRightArrow: onRightArrow,
                    onExit: onExit
                )
            }
            .onDisappear {
                KeyboardMonitorController.shared.removeMonitor()
            }
    }
}

extension View {
    func onKeyboardEvent(
        onLeftArrow: @escaping () -> Void,
        onRightArrow: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardEventMonitor(
            onLeftArrow: onLeftArrow,
            onRightArrow: onRightArrow,
            onExit: onExit
        ))
    }
}

