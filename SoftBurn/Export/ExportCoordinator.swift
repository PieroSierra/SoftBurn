//
//  ExportCoordinator.swift
//  SoftBurn
//
//  Main orchestrator for video export.
//  Builds timeline, renders frames, and writes to QuickTime .mov file.
//

import Foundation
import AVFoundation
import Metal
import MetalKit
import AppKit
import SwiftUI

/// Captured settings for export (avoid @MainActor isolation issues)
struct ExportSettings: Sendable {
    let transitionStyle: SlideshowDocument.Settings.TransitionStyle
    let slideDuration: Double
    let playVideosWithSound: Bool
    let playVideosInFull: Bool
    let zoomOnFaces: Bool
    let effect: SlideshowDocument.Settings.PostProcessingEffect
    let patina: SlideshowDocument.Settings.PatinaEffect
    let backgroundColor: MTLClearColor
    let musicSelection: String?
    let musicVolume: Int

    @MainActor
    init(from settings: SlideshowSettings) {
        self.transitionStyle = settings.transitionStyle
        self.slideDuration = settings.slideDuration
        self.playVideosWithSound = settings.playVideosWithSound
        self.playVideosInFull = settings.playVideosInFull
        self.zoomOnFaces = settings.zoomOnFaces
        self.effect = settings.effect
        self.patina = settings.patina
        self.musicSelection = settings.musicSelection
        self.musicVolume = settings.musicVolume

        // Convert color to MTLClearColor
        let ns = NSColor(settings.backgroundColor).usingColorSpace(.deviceRGB) ?? NSColor.black
        self.backgroundColor = MTLClearColor(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }
}

/// Main coordinator for video export
actor ExportCoordinator {
    private let photos: [MediaItem]
    private let exportSettings: ExportSettings
    private let preset: ExportPreset
    private let progress: ExportProgress

    // Cached preset values
    private let frameRate: Int
    private let presetWidth: Int
    private let presetHeight: Int
    private let videoSettings: [String: Any]

    // Metal device
    private let device: MTLDevice

    // Video readers for video items
    private var videoReaders: [UUID: VideoFrameReader] = [:]

    // Timeline
    private var slideTimeline: [SlideEntry] = []
    private var totalDuration: Double = 0
    private var totalFrames: Int = 0

    // Transition duration (matches playback)
    private static let transitionDuration: Double = 2.0

    @MainActor
    init(photos: [MediaItem], settings: SlideshowSettings, preset: ExportPreset, progress: ExportProgress) {
        self.photos = photos
        self.exportSettings = ExportSettings(from: settings)
        self.preset = preset
        self.progress = progress

        // Cache preset values to avoid actor isolation issues
        self.frameRate = preset.frameRate
        self.presetWidth = preset.width
        self.presetHeight = preset.height
        self.videoSettings = preset.videoSettings

        // Get Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
    }

    /// Main export function
    func export(to outputURL: URL) async throws {
        // Check for cancellation before starting
        if await progress.isCancelled { throw ExportError.cancelled }

        await MainActor.run { progress.phase = .preparing }

        // Build timeline
        try await buildTimeline()

        // Initialize renderer
        let renderer = try await MainActor.run {
            try OfflineSlideshowRenderer(
                device: device,
                preset: preset,
                settings: SlideshowSettings.shared
            )
        }
        renderer.setExportStartTime(0)

        // Calculate total frames
        totalFrames = Int(ceil(totalDuration * Double(frameRate)))

        let frameCount = totalFrames
        await MainActor.run {
            progress.totalFrames = frameCount
            progress.phase = .renderingFrames
        }

        // Create asset writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // Video input
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // Pixel buffer adaptor
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: presetWidth,
            kCVPixelBufferHeightKey as String: presetHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceAttributes
        )

        // Start writing
        guard writer.startWriting() else {
            throw ExportError.videoWriterFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Render loop
        for frameIndex in 0..<totalFrames {
            // Check for cancellation
            if await progress.isCancelled {
                writer.cancelWriting()
                throw ExportError.cancelled
            }

            // Wait for writer to be ready
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            // Calculate frame time
            let frameTime = Double(frameIndex) / Double(frameRate)
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(frameRate))

            // Render frame
            let pixelBuffer = try await renderFrame(at: frameTime, renderer: renderer)

            // Append to video
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw ExportError.videoWriterFailed("Failed to append frame \(frameIndex)")
            }

            // Update progress
            let currentFrame = frameIndex + 1
            let total = totalFrames
            await MainActor.run {
                progress.updateFrame(currentFrame, of: total)
            }
        }

        // Finish video writing
        videoInput.markAsFinished()

        // Compose and add audio
        await MainActor.run { progress.phase = .composingAudio }

        // Create audio composer and add audio track
        let audioComposer = AudioComposer(
            photos: photos,
            exportSettings: exportSettings,
            timeline: slideTimeline,
            totalDuration: totalDuration
        )

        if let audioURL = try await audioComposer.composeAudio() {
            // Add audio to the export
            try await addAudioTrack(to: writer, from: audioURL)
        }

        // Finalize
        await MainActor.run { progress.phase = .finalizing }

        await writer.finishWriting()

        if let error = writer.error {
            throw ExportError.videoWriterFailed(error.localizedDescription)
        }

        // Clean up
        await cleanup()
    }

    // MARK: - Timeline Building

    private func buildTimeline() async throws {
        slideTimeline = []
        var currentTime: Double = 0

        for (index, item) in photos.enumerated() {
            // Calculate hold duration
            let holdDuration: Double
            if item.kind == .video && exportSettings.playVideosInFull {
                holdDuration = await getVideoDuration(item) ?? exportSettings.slideDuration
            } else {
                holdDuration = exportSettings.slideDuration
            }

            // Calculate transition duration
            let transitionDuration: Double
            if exportSettings.transitionStyle == .plain || index == photos.count - 1 {
                transitionDuration = 0
            } else {
                transitionDuration = Self.transitionDuration
            }

            // Get face boxes for Ken Burns
            let faceBoxes = await getFaceBoxes(for: item)
            let rotatedFaces = rotateFaceBoxes(faceBoxes, degrees: item.rotationDegrees)

            // Generate random start offset
            let startOffset = randomStartOffset()
            let endOffset = faceTargetOffset(from: rotatedFaces)

            let entry = SlideEntry(
                item: item,
                startTime: currentTime,
                holdDuration: holdDuration,
                transitionDuration: transitionDuration,
                faceBoxes: rotatedFaces,
                startOffset: startOffset,
                endOffset: endOffset
            )

            slideTimeline.append(entry)
            currentTime += holdDuration + transitionDuration
        }

        totalDuration = currentTime
    }

    private func getVideoDuration(_ item: MediaItem) async -> Double? {
        await VideoMetadataCache.shared.durationSeconds(for: item.url)
    }

    private func getFaceBoxes(for item: MediaItem) async -> [CGRect] {
        guard item.kind == .photo else { return [] }
        return await FaceDetectionCache.shared.cachedFaces(for: item) ?? []
    }

    // MARK: - Frame Rendering

    private func renderFrame(at time: Double, renderer: OfflineSlideshowRenderer) async throws -> CVPixelBuffer {
        // Find current and next slides
        let (currentEntry, nextEntry, animationProgress) = findSlides(at: time)

        guard let current = currentEntry else {
            throw ExportError.renderFailed("No slide found at time \(time)")
        }

        // Load textures
        let currentTexture = try await loadTexture(for: current.item, renderer: renderer)
        let nextTexture: MTLTexture?
        if let next = nextEntry {
            nextTexture = try await loadTexture(for: next.item, renderer: renderer)
        } else {
            nextTexture = nil
        }

        // Calculate transforms
        let currentTransform = calculateTransform(
            for: current,
            animationProgress: animationProgress,
            isNext: false
        )

        let nextTransform: MediaTransform?
        if let next = nextEntry {
            nextTransform = calculateTransform(
                for: next,
                animationProgress: animationProgress,
                isNext: true
            )
        } else {
            nextTransform = nil
        }

        // Calculate transition start
        let transitionStart = current.holdDuration / current.totalDuration

        // Render
        return try renderer.renderFrame(
            currentTexture: currentTexture,
            nextTexture: nextTexture,
            currentTransform: currentTransform,
            nextTransform: nextTransform,
            animationProgress: animationProgress,
            transitionStart: transitionStart,
            frameTime: time
        )
    }

    private func findSlides(at time: Double) -> (current: SlideEntry?, next: SlideEntry?, animationProgress: Double) {
        /*
         * TIMELINE MODEL (must match live playback in SlideshowPlayerState):
         *
         * Live playback uses: totalSlideDuration = transitionDuration + holdDuration
         * where the transition happens at the END of each slide's cycle.
         *
         * Example with 5s hold + 2s transition:
         * - Total cycle = 7s
         * - Hold phase: progress 0 → 0.71 (5/7)
         * - Transition phase: progress 0.71 → 1.0
         *
         * During transition, BOTH current and next are drawn with crossfade.
         * The next slide starts fading in while current fades out.
         *
         * IMPORTANT: The export timeline startTime marks when each slide BEGINS its cycle,
         * not when it first becomes visible (next slides are visible earlier during previous
         * slide's transition). This matches the live playback model exactly.
         */
        for (index, entry) in slideTimeline.enumerated() {
            // Each slide's cycle runs from startTime to startTime + totalDuration
            // The totalDuration = holdDuration + transitionDuration
            let entryEndTime = entry.startTime + entry.totalDuration

            if time >= entry.startTime && time < entryEndTime {
                let localTime = time - entry.startTime
                let progress = localTime / entry.totalDuration

                // Get next slide - needed for transition rendering
                let nextEntry: SlideEntry?
                if index + 1 < slideTimeline.count {
                    nextEntry = slideTimeline[index + 1]
                } else {
                    nextEntry = nil
                }

                return (entry, nextEntry, progress)
            }
        }

        // Default to last slide
        if let last = slideTimeline.last {
            return (last, nil, 1.0)
        }

        return (nil, nil, 0)
    }

    private func loadTexture(for item: MediaItem, renderer: OfflineSlideshowRenderer) async throws -> MTLTexture? {
        switch item.kind {
        case .photo:
            return renderer.loadTexture(from: item.url, rotationDegrees: item.rotationDegrees)

        case .video:
            // Get or create video reader
            let reader: VideoFrameReader
            if let existing = videoReaders[item.id] {
                reader = existing
            } else {
                reader = try await VideoFrameReader(url: item.url, device: device)
                videoReaders[item.id] = reader
            }

            // Find the local time within this video
            guard let entry = slideTimeline.first(where: { $0.item.id == item.id }) else {
                return nil
            }

            // Calculate video playback time
            // For now, use a simple approach - videos play from start
            // More sophisticated timing would track actual video position
            return try await reader.frame(atSeconds: 0)
        }
    }

    private func calculateTransform(
        for entry: SlideEntry,
        animationProgress: Double,
        isNext: Bool
    ) -> MediaTransform {
        // Ken Burns parameters
        let startScale: Double = 1.0
        let endScale: Double = 1.4

        // Calculate motion elapsed
        let cycleElapsed = animationProgress * entry.totalDuration
        let motionTotal = entry.holdDuration + (2.0 * Self.transitionDuration)

        let motionElapsed: Double
        if isNext {
            motionElapsed = max(0, cycleElapsed - entry.holdDuration)
        } else {
            motionElapsed = cycleElapsed + Self.transitionDuration
        }

        let motionProgress = motionTotal > 0 ? min(1.0, max(0.0, motionElapsed / motionTotal)) : 1.0

        let scale: Double
        let offset: CGSize

        if exportSettings.transitionStyle == .panAndZoom || exportSettings.transitionStyle == .zoom {
            scale = startScale + ((endScale - startScale) * motionProgress)

            let effectiveEnd = exportSettings.zoomOnFaces ? entry.endOffset : .zero
            offset = CGSize(
                width: (entry.startOffset.width * (1.0 - motionProgress)) + (effectiveEnd.width * motionProgress),
                height: (entry.startOffset.height * (1.0 - motionProgress)) + (effectiveEnd.height * motionProgress)
            )
        } else {
            scale = 1.0
            offset = .zero
        }

        return MediaTransform(
            rotationDegrees: entry.item.rotationDegrees,
            scale: scale,
            offset: offset,
            faceBoxes: entry.faceBoxes,
            isVideo: entry.item.kind == .video
        )
    }

    // MARK: - Audio

    private func addAudioTrack(to writer: AVAssetWriter, from audioURL: URL) async throws {
        let audioAsset = AVURLAsset(url: audioURL)

        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            return // No audio to add
        }

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: ExportPreset.audioSettings)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(audioInput) else {
            return
        }
        writer.add(audioInput)

        // Read and write audio samples
        let reader = try AVAssetReader(asset: audioAsset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(output)

        guard reader.startReading() else {
            throw ExportError.audioCompositionFailed("Failed to start reading audio")
        }

        while let sampleBuffer = output.copyNextSampleBuffer() {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            audioInput.append(sampleBuffer)
        }

        audioInput.markAsFinished()
    }

    // MARK: - Helpers

    private func randomStartOffset() -> CGSize {
        guard exportSettings.transitionStyle == .panAndZoom else {
            return .zero
        }

        func randAxis() -> Double { Double.random(in: -0.20...0.20) }

        var x = randAxis()
        var y = randAxis()

        // Ensure at least one axis has meaningful offset
        if abs(x) < 0.10 && abs(y) < 0.10 {
            if Bool.random() {
                x = (Bool.random() ? 1 : -1) * Double.random(in: 0.10...0.20)
            } else {
                y = (Bool.random() ? 1 : -1) * Double.random(in: 0.10...0.20)
            }
        }

        return CGSize(width: x, height: y)
    }

    private func faceTargetOffset(from faces: [CGRect]) -> CGSize {
        guard let face = faces.randomElement() else {
            return .zero
        }

        var x = 0.5 - face.midX
        var y = face.midY - 0.5

        let clamp: Double = 0.25
        x = min(clamp, max(-clamp, x))
        y = min(clamp, max(-clamp, y))

        return CGSize(width: x, height: y)
    }

    private func rotateFaceBoxes(_ rects: [CGRect], degrees: Int) -> [CGRect] {
        let d = MediaItem.normalizedRotationDegrees(degrees)
        guard d != 0 else { return rects }

        func rotatePoint(_ p: CGPoint) -> CGPoint {
            switch d {
            case 90:
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

    private func cleanup() async {
        for reader in videoReaders.values {
            await reader.close()
        }
        videoReaders.removeAll()
    }
}

// MARK: - Supporting Types

/// Entry in the export timeline
struct SlideEntry: Sendable {
    let item: MediaItem
    let startTime: Double
    let holdDuration: Double
    let transitionDuration: Double
    let faceBoxes: [CGRect]
    let startOffset: CGSize
    let endOffset: CGSize

    var totalDuration: Double {
        holdDuration + transitionDuration
    }
}
