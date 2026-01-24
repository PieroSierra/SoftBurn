//
//  PhotoViewerSheet.swift
//  SoftBurn
//

import SwiftUI
import AVKit

struct PhotoViewerSheet: View {
    @ObservedObject var slideshowState: SlideshowState
    let startingPhotoID: UUID
    let onDismiss: () -> Void
    /// Callback to start slideshow from a specific photo ID.
    /// The viewer will be dismissed before the slideshow starts.
    var onPlaySlideshow: ((UUID) -> Void)?

    @ObservedObject private var settings = SlideshowSettings.shared

    @State private var currentIndex: Int = 0
    @State private var image: NSImage?
    @State private var isLoading: Bool = false
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var videoPresentationSize: CGSize?

    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var keyMonitor: Any?

    private let loader = ViewerImageLoader()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmed background over the app
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                // Photo "card" (the only visible container)
                photoCard(in: geo.size)
                    .animation(.spring(response: 0.28, dampingFraction: 0.92), value: photoCardSize(in: geo.size))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            resolveStartingIndex()
            installKeyMonitor()
            Task { await loadCurrentMedia() }
        }
        .onDisappear {
            removeKeyMonitor()
            removeEndObserver()
            player?.pause()
        }
        .onChange(of: slideshowState.photos.map(\.id)) { _, _ in
            // Keep index valid if photos are removed.
            clampIndexOrDismiss()
            Task { await loadCurrentMedia() }
        }
    }

    @ViewBuilder
    private func hudButton(systemName: String, foregroundColor: Color = Color.white.opacity(0.9), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(foregroundColor)
                .frame(width: 34, height: 28)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func photoCard(in containerSize: CGSize) -> some View {
        let size = photoCardSize(in: containerSize)
        let cornerRadius: CGFloat = 18

        ZStack {
            if isLoading, image == nil, player == nil {
                ProgressView()
                    .tint(.white)
            } else if let image {
                ZoomableImage(
                    image: image,
                    scale: $scale,
                    offset: $offset
                )
            } else if let player {
                ViewerAVPlayerView(player: player)
                    .onAppear {
                        // Start playback immediately (muted by default via global setting).
                        player.play()
                    }
            } else {
                Image(systemName: "photo")
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.ultraThinMaterial.opacity(0.0)) // keep layout stable without showing a "card" color
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 12)
        .overlay(alignment: .topLeading) {
            hudButton(systemName: "xmark") { onDismiss() }
                .padding(12)
                .help("Close")
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                if currentItem?.kind == .video {
                    // Use native AVPlayerView controls (on hover) instead of duplicating controls.
                }

                hudButton(systemName: "trash") { removeCurrentPhoto() }
                    .help("Remove from slideshow (does not delete files)")
                    .disabled(slideshowState.photos.isEmpty)

                hudButton(systemName: "rotate.left") { rotateCurrentPhoto() }
                    .help("Rotate counterclockwise")
                    .disabled(currentItem?.kind != .photo)
            }
                .padding(12)
        }
        .overlay(alignment: .bottom) {
            if !slideshowState.photos.isEmpty {
                Text("\(currentIndex + 1) / \(slideshowState.photos.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }

    private func photoCardSize(in containerSize: CGSize) -> CGSize {
        // Keep a comfortable margin from the sheet edges.
        let maxW = max(200, containerSize.width - 80)
        let maxH = max(200, containerSize.height - 80)
        let maxSize = CGSize(width: maxW, height: maxH)

        if let image {
            return fittedSize(container: maxSize, image: image.size)
        }

        if let s = videoPresentationSize, s.width > 0, s.height > 0 {
            return fittedSize(container: maxSize, image: s)
        }

        // Placeholder while loading.
        return CGSize(width: min(520, maxSize.width), height: min(360, maxSize.height))
    }

    private func resolveStartingIndex() {
        if let idx = slideshowState.photos.firstIndex(where: { $0.id == startingPhotoID }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
    }

    private func clampIndexOrDismiss() {
        let count = slideshowState.photos.count
        if count == 0 {
            onDismiss()
            return
        }
        if currentIndex >= count {
            currentIndex = max(0, count - 1)
        }
    }

    private func resetTransform() {
        scale = 1.0
        offset = .zero
    }

    private func showPrevious() {
        guard !slideshowState.photos.isEmpty else { return }
        currentIndex = (currentIndex - 1 + slideshowState.photos.count) % slideshowState.photos.count
        resetTransform()
        Task { await loadCurrentMedia() }
    }

    private func showNext() {
        guard !slideshowState.photos.isEmpty else { return }
        currentIndex = (currentIndex + 1) % slideshowState.photos.count
        resetTransform()
        Task { await loadCurrentMedia() }
    }

    private func removeCurrentPhoto() {
        guard !slideshowState.photos.isEmpty else { return }
        let removingIndex = currentIndex
        let id = slideshowState.photos[removingIndex].id

        slideshowState.removePhoto(withID: id)

        // After removal:
        // - if there is a "next" at same index, show it
        // - else show previous
        if slideshowState.photos.isEmpty {
            onDismiss()
            return
        }

        if removingIndex < slideshowState.photos.count {
            currentIndex = removingIndex
        } else {
            currentIndex = max(0, slideshowState.photos.count - 1)
        }

        resetTransform()
        Task { await loadCurrentMedia() }
    }
    
    private func playFromCurrentPhoto() {
        guard !slideshowState.photos.isEmpty,
              let item = currentItem else { return }
        
        // Dismiss the viewer first, then start the slideshow
        onDismiss()
        
        // Use a slight delay to ensure the viewer is dismissed before slideshow starts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onPlaySlideshow?(item.id)
        }
    }

    private func rotateCurrentPhoto() {
        guard let item = currentItem, item.kind == .photo else { return }
        slideshowState.rotatePhotoCounterclockwise(withID: item.id)
        resetTransform()
        Task { await loadCurrentMedia() }
    }

    private var currentItem: MediaItem? {
        guard currentIndex >= 0, currentIndex < slideshowState.photos.count else { return nil }
        return slideshowState.photos[currentIndex]
    }

    private func loadCurrentMedia() async {
        guard !slideshowState.photos.isEmpty else {
            await MainActor.run {
                image = nil
                player = nil
                isLoading = false
            }
            return
        }

        let item = slideshowState.photos[currentIndex]
        await MainActor.run { isLoading = true }

        // Stop previous video
        await MainActor.run {
            removeEndObserver()
            player?.pause()
            player = nil
            videoPresentationSize = nil
        }

        switch item.kind {
        case .photo:
            let loaded = await loader.load(item: item)
            await MainActor.run {
                self.image = Self.applyRotationForPreview(loaded, degrees: item.rotationDegrees)
                self.isLoading = false
            }
        case .video:
            await MainActor.run {
                self.image = nil
            }

            // Get the actual video URL (handles both filesystem and Photos Library)
            let videoURL: URL?
            switch item.source {
            case .filesystem(let url):
                videoURL = url
            case .photosLibrary(let localID, _):
                videoURL = await PhotosLibraryImageLoader.shared.getVideoURL(localIdentifier: localID)
            }

            guard let videoURL else {
                await MainActor.run {
                    self.isLoading = false
                }
                return
            }

            // Create player on main
            await MainActor.run {
                let playerItem = AVPlayerItem(url: videoURL)
                let p = AVPlayer(playerItem: playerItem)
                p.isMuted = !settings.playVideosWithSound
                self.player = p
                installEndObserver(for: playerItem)
                self.isLoading = false
            }

            // Fetch presentation size (for sizing the photo card like photos).
            let size = await VideoMetadataCache.shared.presentationSize(for: videoURL)
            await MainActor.run {
                self.videoPresentationSize = size
            }
        }
    }

    private func fittedSize(container: CGSize, image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return container }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Allow command-based shortcuts (Cmd+Tab, Cmd+Q, etc).
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) { return event }

            switch event.keyCode {
            case 53: // Escape
                onDismiss()
                return nil
            case 123: // Left arrow
                showPrevious()
                return nil
            case 124: // Right arrow
                showNext()
                return nil
            case 125, 126: // Down, Up
                // Prevent the underlying grid from changing selection while preview is visible.
                return nil
            case 49: // Space
                if currentItem?.kind == .video {
                    togglePlayPause()
                    return nil
                }
                return event
            case 51, 117: // Delete, Forward Delete
                removeCurrentPhoto()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func installEndObserver(for item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            // Freeze on last frame
            self.player?.pause()
            item.seek(to: item.duration, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    // MARK: - Rotation (Preview)

    /// For preview, rotate the bitmap itself so layout sizing (portrait/landscape) updates correctly.
    /// This is non-destructive and never writes to disk.
    private static func applyRotationForPreview(_ image: NSImage?, degrees: Int) -> NSImage? {
        guard let image else { return nil }
        let d = MediaItem.normalizedRotationDegrees(degrees)
        guard d != 0 else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        guard let rotated = rotateCGImage(cg, degrees: d) else { return image }
        return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
    }

    /// Rotate a CGImage around its center by a multiple of 90 degrees (counterclockwise).
    private static func rotateCGImage(_ cgImage: CGImage, degrees: Int) -> CGImage? {
        let d = MediaItem.normalizedRotationDegrees(degrees)
        guard d != 0 else { return cgImage }

        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        let outSize: CGSize = (d == 90 || d == 270) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let ctx = CGContext(
            data: nil,
            width: Int(outSize.width),
            height: Int(outSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high

        ctx.translateBy(x: outSize.width / 2.0, y: outSize.height / 2.0)
        ctx.rotate(by: CGFloat(Double(d) * Double.pi / 180.0))
        ctx.translateBy(x: -CGFloat(w) / 2.0, y: -CGFloat(h) / 2.0)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        return ctx.makeImage()
    }
}

private struct ZoomableImage: View {
    let image: NSImage
    @Binding var scale: CGFloat
    @Binding var offset: CGSize

    @State private var gestureStartScale: CGFloat = 1.0
    @State private var gestureStartOffset: CGSize = .zero

    private let minZoom: CGFloat = 1.0
    private let maxZoom: CGFloat = 4.0

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedSize(container: geo.size, image: image.size)
            let maxOffset = maxOffset(container: geo.size, fitted: fitted, scale: scale)

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .gesture(magnificationGesture())
                .simultaneousGesture(dragGesture(maxOffset: maxOffset))
                .onChange(of: scale) { _, newScale in
                    // Clamp offset whenever scale changes.
                    offset = clamped(offset, maxOffset: maxOffset)
                    if newScale <= 1.0 {
                        offset = .zero
                    }
                }
        }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if gestureStartScale == 1.0 && scale != 1.0 {
                    gestureStartScale = scale
                } else if gestureStartScale == 1.0 {
                    gestureStartScale = scale
                }
                scale = clamp(gestureStartScale * value, minZoom, maxZoom)
            }
            .onEnded { _ in
                gestureStartScale = scale
            }
    }

    private func dragGesture(maxOffset: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                if gestureStartOffset == .zero && offset != .zero {
                    gestureStartOffset = offset
                }
                let proposed = CGSize(
                    width: gestureStartOffset.width + value.translation.width,
                    height: gestureStartOffset.height + value.translation.height
                )
                offset = clamped(proposed, maxOffset: maxOffset)
            }
            .onEnded { _ in
                gestureStartOffset = offset
            }
    }

    private func fittedSize(container: CGSize, image: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return container }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func maxOffset(container: CGSize, fitted: CGSize, scale: CGFloat) -> CGSize {
        // After scaling, the content size in view coordinates is fitted * scale.
        let content = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        let maxX = max(0, (content.width - container.width) / 2.0)
        let maxY = max(0, (content.height - container.height) / 2.0)
        return CGSize(width: maxX, height: maxY)
    }

    private func clamped(_ offset: CGSize, maxOffset: CGSize) -> CGSize {
        CGSize(
            width: min(maxOffset.width, max(-maxOffset.width, offset.width)),
            height: min(maxOffset.height, max(-maxOffset.height, offset.height))
        )
    }

    private func clamp(_ v: CGFloat, _ minV: CGFloat, _ maxV: CGFloat) -> CGFloat {
        min(maxV, max(minV, v))
    }
}


