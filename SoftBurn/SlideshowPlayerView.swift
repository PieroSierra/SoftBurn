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
                    PanAndZoomTransitionView(playerState: playerState)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
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
        
        // Load the new next image
        let nextIndex = (currentIndex + 1) % photos.count
        let nextURL = photos[nextIndex].url
        
        Task { [weak self] in
            guard let self = self, !self.isStopped else { return }
            if let image = await imageLoader.loadImage(for: nextURL) {
                guard !self.isStopped else { return }
                self.nextImage = image
            }
        }
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
                        idSeed: playerState.photos[playerState.currentIndex].url.absoluteString,
                        startScale: startScale,
                        endScale: endScale,
                        motionElapsed: currentMotionElapsed,
                        motionTotal: motionTotalDuration,
                        opacity: playerState.isTransitioning ? (1.0 - transitionProgress) : 1.0
                    )
                }
                
                // Next image: only during transition; starts moving immediately.
                if playerState.isTransitioning, let image = playerState.nextImage {
                    let nextIndex = (playerState.currentIndex + 1) % max(1, playerState.photos.count)
                    KenBurnsImageView(
                        image: image,
                        idSeed: playerState.photos[nextIndex].url.absoluteString,
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
    let idSeed: String
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
    
    private var startOffset: CGSize {
        KenBurnsDeterministic.offset(for: idSeed)
    }
    
    private var offset: CGSize {
        // Linearly interpolate from (startOffset) -> (0,0)
        CGSize(width: startOffset.width * (1.0 - progress), height: startOffset.height * (1.0 - progress))
    }
    
    var body: some View {
        GeometryReader { geo in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                // Offsets are normalized relative to the visible frame.
                .offset(x: offset.width * geo.size.width, y: offset.height * geo.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .opacity(opacity)
        }
    }
}

private enum KenBurnsDeterministic {
    /// Stable (cross-launch) 64-bit FNV-1a hash.
    private static func fnv1a64(_ s: String) -> UInt64 {
        let prime: UInt64 = 1099511628211
        var hash: UInt64 = 14695981039346656037
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= prime
        }
        return hash
    }
    
    /// Deterministic offset in roughly ±(10–20%) range, drifting toward center.
    static func offset(for seed: String) -> CGSize {
        let h = fnv1a64(seed)
        let xBits = Double(h & 0xFFFF) / 65535.0
        let yBits = Double((h >> 16) & 0xFFFF) / 65535.0
        
        // Map to [-0.20, 0.20]
        var x = (xBits * 0.40) - 0.20
        var y = (yBits * 0.40) - 0.20
        
        // Ensure we don't end up too close to center (want a subtle pan).
        if abs(x) < 0.10 { x = x < 0 ? -0.12 : 0.12 }
        if abs(y) < 0.10 { y = y < 0 ? -0.12 : 0.12 }
        
        return CGSize(width: x, height: y)
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

