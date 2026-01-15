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
                if settings.patina == .none {
                    // SwiftUI path (no Metal): media + transforms + optional Effects
                    Group {
                        switch settings.transitionStyle {
                        case .plain:
                            PlainTransitionView(playerState: playerState)
                        case .crossFade:
                            CrossFadeTransitionView(playerState: playerState)
                        case .panAndZoom, .zoom:
                            PanAndZoomTransitionView(
                                playerState: playerState,
                                zoomOnFaces: settings.zoomOnFaces,
                                debugShowFaces: settings.debugShowFaces
                            )
                        }
                    }
                    // Effects apply to media content only (not background)
                    .postProcessingEffect(settings.effect)
                } else {
                    // Metal path: media + geometry + effects composited into texture,
                    // then Patina post-pass, then present.
                    MetalSlideshowView(
                        playerState: playerState,
                        settings: settings
                    )
                    .allowsHitTesting(false)
                }
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
    @Published var currentVideoPlayer: AVPlayer?
    @Published var nextVideoPlayer: AVPlayer?
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
    
    private let imageLoader = PlaybackImageLoader()
    private var slideTimer: Timer?
    private var animationTimer: Timer?
    private var isRunning = false
    private var didStartNextVideoThisCycle: Bool = false
    private var currentVideoEndObserver: NSObjectProtocol?
    private var nextVideoEndObserver: NSObjectProtocol?
    
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
        
        // Clear images to release GPU resources
        currentImage = nil
        nextImage = nil
        currentVideoPlayer?.pause()
        nextVideoPlayer?.pause()
        currentVideoPlayer = nil
        nextVideoPlayer = nil
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
        removeVideoObservers()
        
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
        pauseAndResetVideos()
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
        pauseAndResetVideos()
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
            currentVideoPlayer?.pause()
            currentVideoPlayer = nil
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
            if let url = await getPlayableURL(for: currentItem) {
                currentVideoPlayer = makePlayer(url: url, shouldAutoPlay: true)
                installVideoEndObserver(for: currentVideoPlayer, slot: .current)
            } else {
                currentVideoPlayer = nil
            }
        }

        // Load next
        switch nextItem.kind {
        case .photo:
            nextVideoPlayer?.pause()
            nextVideoPlayer = nil
            // Use MediaItem-based method to support both filesystem and Photos Library
            nextImage = await imageLoader.loadImage(for: nextItem)

            let faces = await FaceDetectionCache.shared.cachedFaces(for: nextItem) ?? []
            let rotatedFaces = Self.rotateVisionRects(faces, degrees: nextItem.rotationDegrees)
            nextFaceBoxes = rotatedFaces
            nextEndOffset = Self.faceTargetOffset(from: rotatedFaces)
        case .video:
            nextImage = nil
            if let url = await getPlayableURL(for: nextItem) {
                nextVideoPlayer = makePlayer(url: url, shouldAutoPlay: false)
                installVideoEndObserver(for: nextVideoPlayer, slot: .next)
            } else {
                nextVideoPlayer = nil
            }
        }
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
        if currentKind == .video, let outgoing = currentVideoPlayer, outgoing !== nextVideoPlayer {
            outgoing.pause()
        }

        // Move to next slide
        currentIndex = (currentIndex + 1) % photos.count
        animationProgress = 0
        isTransitioning = false
        didStartNextVideoThisCycle = false

        // Promote "next" into "current" (preserve playback during overlap).
        currentKind = nextKind
        currentImage = nextImage
        currentVideoPlayer = nextVideoPlayer
        currentFaceBoxes = nextFaceBoxes
        currentEndOffset = nextEndOffset
        currentStartOffset = nextStartOffset

        // Promote end observer token if needed
        if let t = currentVideoEndObserver { NotificationCenter.default.removeObserver(t) }
        currentVideoEndObserver = nextVideoEndObserver
        nextVideoEndObserver = nil

        // Clear next slots before loading new next
        nextImage = nil
        nextVideoPlayer = nil
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
            nextVideoPlayer?.pause()
            nextVideoPlayer = nil
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
            if let url = await getPlayableURL(for: nextItem) {
                nextVideoPlayer = makePlayer(url: url, shouldAutoPlay: false)
                installVideoEndObserver(for: nextVideoPlayer, slot: .next)
            } else {
                nextVideoPlayer = nil
            }
        }

        scheduleNextAdvance()
    }

    private func holdDuration(for item: MediaItem) async -> Double {
        switch item.kind {
        case .photo:
            return slideDuration
        case .video:
            if playVideosInFull, let seconds = await VideoMetadataCache.shared.durationSeconds(for: item.url) {
                return seconds
            }
            return slideDuration
        }
    }

    private func makePlayer(url: URL, shouldAutoPlay: Bool) -> AVPlayer {
        // Start accessing security-scoped resource (important for Photos Library URLs)
        let didStartAccess = url.startAccessingSecurityScopedResource()

        // Note: We don't stop access here because the player needs ongoing access
        // The URL will be released when the player is deallocated

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = !playVideosWithSound
        if shouldAutoPlay {
            p.play()
        } else {
            p.pause()
            p.seek(to: .zero)
        }
        return p
    }

    /// Get playable URL for a MediaItem (handles both filesystem and Photos Library)
    private func getPlayableURL(for item: MediaItem) async -> URL? {
        switch item.source {
        case .filesystem(let url):
            return url
        case .photosLibrary(let localID, _):
            return await PhotosLibraryImageLoader.shared.getVideoURL(localIdentifier: localID)
        }
    }

    private enum VideoSlot { case current, next }

    private func installVideoEndObserver(for player: AVPlayer?, slot: VideoSlot) {
        guard let player, let item = player.currentItem else { return }

        let token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            // Freeze on last frame while fade continues.
            player.pause()
            item.seek(to: item.duration, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }

        switch slot {
        case .current:
            if let t = currentVideoEndObserver { NotificationCenter.default.removeObserver(t) }
            currentVideoEndObserver = token
        case .next:
            if let t = nextVideoEndObserver { NotificationCenter.default.removeObserver(t) }
            nextVideoEndObserver = token
        }
    }

    private func removeVideoObservers() {
        if let t = currentVideoEndObserver { NotificationCenter.default.removeObserver(t) }
        if let t = nextVideoEndObserver { NotificationCenter.default.removeObserver(t) }
        currentVideoEndObserver = nil
        nextVideoEndObserver = nil
    }

    private func pauseAndResetVideos() {
        currentVideoPlayer?.pause()
        nextVideoPlayer?.pause()
        removeVideoObservers()
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
        
        let progressIncrement = deltaTime / totalSlideDuration
        animationProgress = min(1.0, animationProgress + progressIncrement)
        
        // Update transition state
        if transitionStyle != .plain {
            let transitionStartProgress = currentHoldDuration / totalSlideDuration
            let willTransition = animationProgress >= transitionStartProgress && animationProgress < 1.0
            if willTransition, !isTransitioning {
                // Transition is starting: begin next video playback now (true overlap).
                if nextKind == .video, !didStartNextVideoThisCycle {
                    nextVideoPlayer?.play()
                    didStartNextVideoThisCycle = true
                }
            }
            isTransitioning = willTransition
        }
    }
}

// Swift 6: Timer callbacks are `@Sendable`; this type is main-actor isolated and only touched on the main actor.
// Marking it unchecked-sendable avoids noisy warnings for safe usage patterns here.
extension SlideshowPlayerState: @unchecked Sendable {}

// MARK: - Transition Views

/// Plain transition: instant replacement, no animation
struct PlainTransitionView: View {
    @ObservedObject var playerState: SlideshowPlayerState
    
    var body: some View {
        if !playerState.isStopped {
            switch playerState.currentKind {
            case .photo:
                if let image = playerState.currentImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .video:
                if let player = playerState.currentVideoPlayer {
                    PlayerLayerView(player: player, videoGravity: .resizeAspect)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Cross-fade transition: true overlap (A fades out while B fades in)
struct CrossFadeTransitionView: View {
    @ObservedObject var playerState: SlideshowPlayerState
    
    private var transitionStartProgress: Double {
        playerState.currentHoldDuration / playerState.totalSlideDuration
    }
    
    /// Progress through the transition (0-1 during transition window)
    private var transitionProgress: Double {
        let start = transitionStartProgress
        guard playerState.animationProgress >= start else { return 0.0 }
        let duration = (1.0 - start)
        if duration <= 0 { return 1.0 }
        return min(1.0, (playerState.animationProgress - start) / duration)
    }
    
    var body: some View {
        if !playerState.isStopped {
            ZStack {
                // Hold phase: just show current.
                Group {
                    switch playerState.currentKind {
                    case .photo:
                        if let image = playerState.currentImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                    case .video:
                        if let player = playerState.currentVideoPlayer {
                            PlayerLayerView(player: player, videoGravity: .resizeAspect)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(playerState.animationProgress < 1.0 ? (playerState.isTransitioning ? (1.0 - transitionProgress) : 1.0) : 0.0)

                // Transition phase: fade next in while current fades out.
                // Keep rendering next image until advanceSlide() completes (animationProgress < 1.0 ensures no gap)
                if playerState.animationProgress >= transitionStartProgress {
                    Group {
                        switch playerState.nextKind {
                        case .photo:
                            if let image = playerState.nextImage {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            }
                        case .video:
                            if let player = playerState.nextVideoPlayer {
                                PlayerLayerView(player: player, videoGravity: .resizeAspect)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(min(1.0, transitionProgress))
                }
            }
        }
    }
}

/// Ken Burns (Pan & Zoom): both images move continuously, and cross-fade overlaps.
struct PanAndZoomTransitionView: View {
    @ObservedObject var playerState: SlideshowPlayerState
    let zoomOnFaces: Bool
    let debugShowFaces: Bool
    
    private let startScale: Double = 1.0
    private let endScale: Double = 1.4
    
    private var transitionStartProgress: Double {
        playerState.currentHoldDuration / playerState.totalSlideDuration
    }
    
    /// Progress through the transition window (0-1)
    private var transitionProgress: Double {
        let start = transitionStartProgress
        guard playerState.animationProgress >= start else { return 0.0 }
        let duration = (1.0 - start)
        if duration <= 0 { return 1.0 }
        return min(1.0, (playerState.animationProgress - start) / duration)
    }
    
    /// Elapsed seconds within the current cycle (0..totalSlideDuration)
    private var cycleElapsed: Double {
        playerState.animationProgress * playerState.totalSlideDuration
    }
    
    /// Total motion time for one photo (fade-in + hold + fade-out)
    private var motionTotalDuration: Double {
        playerState.currentHoldDuration + (2.0 * SlideshowPlayerState.transitionDuration)
    }
    
    /// Current photo has already been moving since its fade-in began in the previous transition.
    private var currentMotionElapsed: Double {
        cycleElapsed + SlideshowPlayerState.transitionDuration
    }
    
    /// Next photo begins moving right at transition start.
    private var nextMotionElapsed: Double {
        max(0.0, cycleElapsed - playerState.currentHoldDuration)
    }
    
    var body: some View {
        if !playerState.isStopped {
            ZStack {
                // Current image: always moving; fades out during transition.
                Group {
                    switch playerState.currentKind {
                    case .photo:
                        if let image = playerState.currentImage {
                            KenBurnsImageView(
                                image: image,
                                startOffset: playerState.currentStartOffset,
                                endOffset: playerState.currentEndOffset,
                                useFaceTarget: zoomOnFaces,
                                faceBoxes: playerState.currentFaceBoxes,
                                debugShowFaces: debugShowFaces,
                                startScale: startScale,
                                endScale: endScale,
                                motionElapsed: currentMotionElapsed,
                                motionTotal: motionTotalDuration,
                                opacity: playerState.animationProgress < 1.0 ? (playerState.isTransitioning ? (1.0 - transitionProgress) : 1.0) : 0.0
                            )
                        }
                    case .video:
                        if let player = playerState.currentVideoPlayer {
                            KenBurnsVideoView(
                                player: player,
                                startOffset: playerState.currentStartOffset,
                                endOffset: .zero,
                                startScale: startScale,
                                endScale: endScale,
                                motionElapsed: currentMotionElapsed,
                                motionTotal: motionTotalDuration,
                                opacity: playerState.animationProgress < 1.0 ? (playerState.isTransitioning ? (1.0 - transitionProgress) : 1.0) : 0.0
                            )
                        }
                    }
                }

                // Next image: starts moving during transition; stays visible until advanceSlide() completes
                if playerState.animationProgress >= transitionStartProgress {
                    Group {
                        switch playerState.nextKind {
                        case .photo:
                            if let image = playerState.nextImage {
                                KenBurnsImageView(
                                    image: image,
                                    startOffset: playerState.nextStartOffset,
                                    endOffset: playerState.nextEndOffset,
                                    useFaceTarget: zoomOnFaces,
                                    faceBoxes: playerState.nextFaceBoxes,
                                    debugShowFaces: debugShowFaces,
                                    startScale: startScale,
                                    endScale: endScale,
                                    motionElapsed: nextMotionElapsed,
                                    motionTotal: motionTotalDuration,
                                    opacity: min(1.0, transitionProgress)
                                )
                            }
                        case .video:
                            if let player = playerState.nextVideoPlayer {
                                KenBurnsVideoView(
                                    player: player,
                                    startOffset: playerState.nextStartOffset,
                                    endOffset: .zero,
                                    startScale: startScale,
                                    endScale: endScale,
                                    motionElapsed: nextMotionElapsed,
                                    motionTotal: motionTotalDuration,
                                    opacity: min(1.0, transitionProgress)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Ken Burns Helpers

private struct KenBurnsImageView: View {
    let image: NSImage
    let startOffset: CGSize
    let endOffset: CGSize
    let useFaceTarget: Bool
    let faceBoxes: [CGRect]
    let debugShowFaces: Bool
    let startScale: Double
    let endScale: Double
    let motionElapsed: Double
    let motionTotal: Double
    let opacity: Double
    
    private var progress: Double {
        guard motionTotal > 0 else { return 1.0 }
        return min(1.0, max(0.0, motionElapsed / motionTotal))
    }
    
    private var scale: CGFloat {
        CGFloat(startScale + ((endScale - startScale) * progress))
    }
    
    private var effectiveEndOffset: CGSize {
        useFaceTarget ? endOffset : .zero
    }
    
    private var offset: CGSize {
        // Linearly interpolate from startOffset -> endOffset (face center or center)
        CGSize(
            width: (startOffset.width * (1.0 - progress)) + (effectiveEndOffset.width * progress),
            height: (startOffset.height * (1.0 - progress)) + (effectiveEndOffset.height * progress)
        )
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)

                if debugShowFaces, !faceBoxes.isEmpty {
                    FaceBoxesOverlay(image: image, faceBoxes: faceBoxes)
                }
            }
                .scaleEffect(scale)
                // Offsets are normalized relative to the visible frame.
                .offset(x: offset.width * geo.size.width, y: offset.height * geo.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(opacity)
        }
    }
}

private struct KenBurnsVideoView: View {
    let player: AVPlayer
    let startOffset: CGSize
    let endOffset: CGSize
    let startScale: Double
    let endScale: Double
    let motionElapsed: Double
    let motionTotal: Double
    let opacity: Double

    private var progress: Double {
        guard motionTotal > 0 else { return 1.0 }
        return min(1.0, max(0.0, motionElapsed / motionTotal))
    }

    private var scale: CGFloat {
        CGFloat(startScale + ((endScale - startScale) * progress))
    }

    private var offset: CGSize {
        CGSize(
            width: (startOffset.width * (1.0 - progress)) + (endOffset.width * progress),
            height: (startOffset.height * (1.0 - progress)) + (endOffset.height * progress)
        )
    }

    var body: some View {
        GeometryReader { geo in
            PlayerLayerView(player: player, videoGravity: .resizeAspect)
                .allowsHitTesting(false)
                .scaleEffect(scale)
                .offset(x: offset.width * geo.size.width, y: offset.height * geo.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(opacity)
        }
    }
}

private struct FaceBoxesOverlay: View {
    let image: NSImage
    let faceBoxes: [CGRect]

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            let img = image.size
            let scale = min(container.width / max(1, img.width), container.height / max(1, img.height))
            let fitted = CGSize(width: img.width * scale, height: img.height * scale)
            let origin = CGPoint(
                x: (container.width - fitted.width) / 2.0,
                y: (container.height - fitted.height) / 2.0
            )

            ZStack(alignment: .topLeading) {
                ForEach(Array(faceBoxes.enumerated()), id: \.offset) { _, box in
                    // Vision normalized rect origin is bottom-left; SwiftUI is top-left.
                    let x = origin.x + (box.minX * fitted.width)
                    let y = origin.y + ((1.0 - box.maxY) * fitted.height)
                    let w = box.width * fitted.width
                    let h = box.height * fitted.height

                    Rectangle()
                        .stroke(Color.red.opacity(0.9), lineWidth: 2)
                        .frame(width: w, height: h)
                        .position(x: x + (w / 2.0), y: y + (h / 2.0))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

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

