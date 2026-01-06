//
//  SlideshowPlayerView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import AppKit
import Combine

/// Full-screen slideshow player view
struct SlideshowPlayerView: View {
    let photos: [PhotoItem]
    let settings: SlideshowSettings
    let onExit: () -> Void
    
    @StateObject private var playerState: SlideshowPlayerState
    @State private var isExiting = false
    
    init(photos: [PhotoItem], settings: SlideshowSettings, onExit: @escaping () -> Void) {
        self.photos = photos
        self.settings = settings
        self.onExit = onExit
        
        // Create playback list (shuffle if needed)
        let playbackPhotos: [PhotoItem]
        if settings.shuffle {
            playbackPhotos = photos.shuffled()
        } else {
            playbackPhotos = photos
        }
        
        _playerState = StateObject(wrappedValue: SlideshowPlayerState(
            photos: playbackPhotos,
            slideDuration: settings.slideDuration,
            transitionStyle: settings.transitionStyle
        ))
    }
    
    var body: some View {
        ZStack {
            // Background
            settings.backgroundColor
                .ignoresSafeArea()
            
            // Only render content if not exiting
            if !isExiting {
                // Slide content based on transition style
                switch settings.transitionStyle {
                case .plain:
                    PlainTransitionView(playerState: playerState)
                case .crossFade:
                    CrossFadeTransitionView(playerState: playerState)
                case .panAndZoom:
                    PanAndZoomTransitionView(
                        playerState: playerState,
                        zoomOnFaces: settings.zoomOnFaces,
                        debugShowFaces: settings.debugShowFaces
                    )
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
        
        // 2. Show cursor immediately
        NSCursor.unhide()
        
        // 3. Wait for SwiftUI to process the state change and stop rendering
        //    100ms gives plenty of time for the render loop to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 4. Now safe to close the window
            onExit()
        }
    }
}

// MARK: - Player State

/// Manages slideshow playback state and timing
@MainActor
class SlideshowPlayerState: ObservableObject {
    let photos: [PhotoItem]
    let slideDuration: Double
    let transitionStyle: SlideshowDocument.Settings.TransitionStyle
    
    /// Fixed transition duration (2 seconds as per spec)
    static let transitionDuration: Double = 2.0
    
    @Published var currentIndex: Int = 0
    @Published var currentImage: NSImage?
    @Published var nextImage: NSImage?

    /// Vision face boxes (normalized rects, origin bottom-left).
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
    
    /// Total duration for one complete slide cycle
    var totalSlideDuration: Double {
        switch transitionStyle {
        case .plain:
            return slideDuration
        case .crossFade, .panAndZoom:
            return SlideshowPlayerState.transitionDuration + slideDuration
        }
    }
    
    init(photos: [PhotoItem], slideDuration: Double, transitionStyle: SlideshowDocument.Settings.TransitionStyle) {
        self.photos = photos
        self.slideDuration = slideDuration
        self.transitionStyle = transitionStyle
    }
    
    func start() {
        guard !photos.isEmpty, !isStopped else { return }
        isRunning = true
        currentIndex = 0
        loadCurrentSlide()
        startTimers()
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
        currentFaceBoxes = []
        nextFaceBoxes = []
        currentEndOffset = .zero
        nextEndOffset = .zero
        currentStartOffset = .zero
        nextStartOffset = .zero
        
        // Clear the image loader cache (fire and forget - no await needed)
        Task.detached { [imageLoader] in
            await imageLoader.clearCache()
        }
    }
    
    func nextSlide() {
        guard isRunning, !isStopped else { return }
        currentIndex = (currentIndex + 1) % photos.count
        animationProgress = 0
        isTransitioning = transitionStyle != .plain
        loadCurrentSlide()
        restartTimers()
    }
    
    func previousSlide() {
        guard isRunning, !isStopped else { return }
        currentIndex = (currentIndex - 1 + photos.count) % photos.count
        animationProgress = 0
        isTransitioning = transitionStyle != .plain
        loadCurrentSlide()
        restartTimers()
    }
    
    private func loadCurrentSlide() {
        guard !isStopped else { return }
        
        let currentURL = photos[currentIndex].url
        let nextIndex = (currentIndex + 1) % photos.count
        let nextURL = photos[nextIndex].url
        
        Task { [weak self] in
            guard let self = self, !self.isStopped else { return }
            
            // Load current image
            if let image = await imageLoader.setCurrent(currentURL, preloadNext: nextURL) {
                guard !self.isStopped else { return }
                self.currentImage = image
            }
            
            // Load next image for transitions
            guard !self.isStopped else { return }
            if let image = await imageLoader.loadImage(for: nextURL) {
                guard !self.isStopped else { return }
                self.nextImage = image
            }

            // Pull cached face data (no detection here) and choose a target per-load.
            guard !self.isStopped else { return }
            let currentFaces = await FaceDetectionCache.shared.cachedFaces(for: currentURL) ?? []
            let nextFaces = await FaceDetectionCache.shared.cachedFaces(for: nextURL) ?? []
            guard !self.isStopped else { return }

            self.currentFaceBoxes = currentFaces
            self.nextFaceBoxes = nextFaces
            self.currentEndOffset = Self.faceTargetOffset(from: currentFaces)
            self.nextEndOffset = Self.faceTargetOffset(from: nextFaces)

            // Randomize start offsets per load (so the same photo can start differently each loop pass)
            self.currentStartOffset = Self.randomStartOffset()
            self.nextStartOffset = Self.randomStartOffset()
        }
    }
    
    private func startTimers() {
        guard !isStopped else { return }
        
        // Main slide timer - fires when it's time to advance
        slideTimer = Timer.scheduledTimer(withTimeInterval: totalSlideDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isStopped else { return }
                self.advanceSlide()
            }
        }
        
        // Animation timer for smooth progress updates (60fps)
        let frameInterval = 1.0 / 60.0
        animationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isStopped else { return }
                self.updateAnimationProgress(deltaTime: frameInterval)
            }
        }
    }
    
    private func restartTimers() {
        slideTimer?.invalidate()
        animationTimer?.invalidate()
        startTimers()
    }
    
    private func advanceSlide() {
        guard isRunning, !isStopped else { return }
        
        // Move to next slide
        currentIndex = (currentIndex + 1) % photos.count
        animationProgress = 0
        isTransitioning = transitionStyle != .plain
        
        // Swap images: next becomes current
        currentImage = nextImage
        currentFaceBoxes = nextFaceBoxes
        currentEndOffset = nextEndOffset
        currentStartOffset = nextStartOffset
        
        // Load the new next image
        let nextIndex = (currentIndex + 1) % photos.count
        let nextURL = photos[nextIndex].url
        
        Task { [weak self] in
            guard let self = self, !self.isStopped else { return }
            if let image = await imageLoader.loadImage(for: nextURL) {
                guard !self.isStopped else { return }
                self.nextImage = image
            }

            // Cached face data + random face selection for the new "next"
            guard !self.isStopped else { return }
            let faces = await FaceDetectionCache.shared.cachedFaces(for: nextURL) ?? []
            guard !self.isStopped else { return }
            self.nextFaceBoxes = faces
            self.nextEndOffset = Self.faceTargetOffset(from: faces)
            self.nextStartOffset = Self.randomStartOffset()
        }
    }

    // MARK: - Face targeting

    private static func faceTargetOffset(from faces: [CGRect]) -> CGSize {
        guard let face = faces.randomElement() else {
            return .zero
        }

        // Vision boundingBox is normalized, origin bottom-left.
        let centerX = face.midX
        let centerY = face.midY

        // Convert face center to a translation that moves the IMAGE such that the face moves toward the VIEW center.
        // - If the face is to the right (centerX > 0.5), we must shift the image left (negative), and vice-versa.
        // - Vision's Y is bottom-left; SwiftUI's Y is top-left, so the sign for Y differs from naive subtraction.
        //
        // Result is a normalized offset where (0,0) means centered, +y means down (SwiftUI).
        var x = 0.5 - centerX
        var y = centerY - 0.5

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
    
    private func updateAnimationProgress(deltaTime: Double) {
        guard isRunning, !isStopped else { return }
        
        let progressIncrement = deltaTime / totalSlideDuration
        animationProgress = min(1.0, animationProgress + progressIncrement)
        
        // Update transition state
        if transitionStyle != .plain {
            let transitionStartProgress = slideDuration / totalSlideDuration
            isTransitioning = animationProgress >= transitionStartProgress && animationProgress < 1.0
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
        if !playerState.isStopped, let image = playerState.currentImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Cross-fade transition: true overlap (A fades out while B fades in)
struct CrossFadeTransitionView: View {
    @ObservedObject var playerState: SlideshowPlayerState
    
    private var transitionStartProgress: Double {
        playerState.slideDuration / playerState.totalSlideDuration
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
                if let image = playerState.currentImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(playerState.isTransitioning ? (1.0 - transitionProgress) : 1.0)
                }
                
                // Transition phase: fade next in while current fades out.
                if playerState.isTransitioning, let image = playerState.nextImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(transitionProgress)
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
        playerState.slideDuration / playerState.totalSlideDuration
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
        playerState.slideDuration + (2.0 * SlideshowPlayerState.transitionDuration)
    }
    
    /// Current photo has already been moving since its fade-in began in the previous transition.
    private var currentMotionElapsed: Double {
        cycleElapsed + SlideshowPlayerState.transitionDuration
    }
    
    /// Next photo begins moving right at transition start.
    private var nextMotionElapsed: Double {
        max(0.0, cycleElapsed - playerState.slideDuration)
    }
    
    var body: some View {
        if !playerState.isStopped {
            ZStack {
                // Current image: always moving; fades out during transition.
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
                        opacity: playerState.isTransitioning ? (1.0 - transitionProgress) : 1.0
                    )
                }
                
                // Next image: only during transition; starts moving immediately.
                if playerState.isTransitioning, let image = playerState.nextImage {
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
                        opacity: transitionProgress
                    )
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

