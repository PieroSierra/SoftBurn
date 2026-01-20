//
//  ExportCoordinator.swift
//  SoftBurn
//
//  Main orchestrator for video export.
//  Builds timeline, renders frames, and writes to QuickTime .mov file.
//
//  ARCHITECTURE:
//  1. Build timeline (SlideEntry array with timing, face boxes, motion offsets)
//  2. Compose audio to temp M4A (background music + video audio)
//  3. Set up AVAssetWriter with video + audio inputs
//  4. Render video frames using OfflineSlideshowRenderer (Metal pipeline)
//  5. Write audio samples from temp M4A
//  6. Finalize MOV file
//
//  See /specs/video-export-spec.md for implementation details and known issues.
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

        // Compose audio FIRST (before setting up writer)
        // This allows us to add audio input before starting the session
        await MainActor.run { progress.phase = .composingAudio }

        let audioComposer = AudioComposer(
            photos: photos,
            exportSettings: exportSettings,
            timeline: slideTimeline,
            totalDuration: totalDuration
        )

        let audioURL = try await audioComposer.composeAudio()

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

        // Audio input (add BEFORE starting session)
        var audioInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioReaderOutput: AVAssetReaderTrackOutput?

        if let audioURL = audioURL {
            let audioAsset = AVURLAsset(url: audioURL)
            if let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first {
                // Create audio input with explicit AAC settings
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: ExportPreset.audioSettings)
                input.expectsMediaDataInRealTime = false

                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input

                    // Set up reader with PCM output for format conversion
                    let reader = try AVAssetReader(asset: audioAsset)
                    let readerSettings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatLinearPCM),
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ]
                    let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerSettings)
                    if reader.canAdd(output) {
                        reader.add(output)
                        audioReader = reader
                        audioReaderOutput = output
                    }
                }
            }
        }

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

        // Start writing (after adding ALL inputs)
        guard writer.startWriting() else {
            throw ExportError.videoWriterFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        // Start audio reader if we have one
        if let reader = audioReader {
            guard reader.startReading() else {
                throw ExportError.audioCompositionFailed("Failed to start reading audio")
            }
        }

        // Render video frames
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

        // Write audio samples if we have audio
        if let audioInput = audioInput, let readerOutput = audioReaderOutput {
            while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                while !audioInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
                if !audioInput.append(sampleBuffer) {
                    print("[Export] Warning: Failed to append audio sample")
                }
            }
            audioInput.markAsFinished()
        }

        // Finalize
        await MainActor.run { progress.phase = .finalizing }

        await writer.finishWriting()

        if let error = writer.error {
            throw ExportError.videoWriterFailed(error.localizedDescription)
        }

        // Clean up temp audio file
        if let audioURL = audioURL {
            try? FileManager.default.removeItem(at: audioURL)
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

        // Load textures - pass frame time for video playback position
        let currentTexture = try await loadTexture(for: current, frameTime: time, renderer: renderer)
        let nextTexture: MTLTexture?
        if let next = nextEntry {
            nextTexture = try await loadTexture(for: next, frameTime: time, renderer: renderer)
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
                isNext: true,
                currentEntry: current  // Pass current entry for correct transition timing
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

    private func loadTexture(for entry: SlideEntry, frameTime: Double, renderer: OfflineSlideshowRenderer) async throws -> MTLTexture? {
        let item = entry.item

        switch item.kind {
        case .photo:
            // Use the new MediaItem-based loading that handles both filesystem and Photos Library
            return await renderer.loadTexture(from: item)

        case .video:
            // Get or create video reader
            let reader: VideoFrameReader
            if let existing = videoReaders[item.id] {
                reader = existing
            } else {
                // For Photos Library videos, we need to get the actual file URL
                let videoURL: URL
                switch item.source {
                case .filesystem(let url):
                    videoURL = url
                case .photosLibrary(let localID, _):
                    guard let url = await PhotosLibraryImageLoader.shared.getVideoURL(localIdentifier: localID) else {
                        return nil
                    }
                    videoURL = url
                }
                reader = try await VideoFrameReader(url: videoURL, device: device)
                videoReaders[item.id] = reader
            }

            // Calculate video playback time:
            // - Video starts playing when it becomes visible (at entry.startTime - transitionDuration for "next" slot)
            // - For simplicity, we use the time relative to when the slide's cycle starts
            // - The video should play from the beginning when the slide starts its cycle
            let videoTime = max(0, frameTime - entry.startTime)
            return try await reader.frame(atSeconds: videoTime)
        }
    }

    private func calculateTransform(
        for entry: SlideEntry,
        animationProgress: Double,
        isNext: Bool,
        currentEntry: SlideEntry? = nil
    ) -> MediaTransform {
        // Ken Burns parameters
        let startScale: Double = 1.0
        let endScale: Double = 1.4

        /*
         * MOTION TIMING for Ken Burns effect:
         *
         * The motion spans the entire visible duration of the slide:
         * - Starts when the slide first becomes visible (incoming transition)
         * - Ends when the slide finishes (hold + outgoing transition)
         *
         * For "current" slot: motion is relative to current slide's cycle
         * - cycleElapsed starts at 0
         * - motionElapsed = cycleElapsed + transitionDuration (from previous slide)
         *
         * For "next" slot: motion is relative to CURRENT slide's cycle during transition
         * - The next slide becomes visible during current's transition phase
         * - Its motion should start immediately when it begins fading in
         *
         * LAST SLIDE FIX: When the last slide has transitionDuration=0 (no outgoing),
         * the motion total is: incoming transition + holdDuration (not 2x transition)
         */

        let motionElapsed: Double
        let motionTotal: Double

        if isNext {
            /*
             * For "next" slot: Motion starts when the slide begins fading in.
             * This happens during the CURRENT (outgoing) slide's transition phase.
             *
             * animationProgress is relative to the CURRENT slide's cycle.
             * entry is the NEXT slide's SlideEntry.
             * currentEntry (if provided) is the CURRENT slide's SlideEntry.
             *
             * Motion total = incomingTransition + holdDuration + outgoingTransition
             * The incoming transition is from the PREVIOUS slide (the current slide's
             * outgoing transition = Self.transitionDuration), and outgoing is
             * entry.transitionDuration (0 for last slide).
             */
            let incomingTransition = Self.transitionDuration  // Always 2.0s
            motionTotal = incomingTransition + entry.holdDuration + entry.transitionDuration

            // Calculate how far into the current slide's transition phase we are
            // animationProgress ranges from 0.0 to 1.0 over the current slide's cycle
            // Transition starts at: currentEntry.holdDuration / currentEntry.totalDuration
            let transitionProgress: Double
            if let current = currentEntry, current.totalDuration > 0 {
                let transitionStart = current.holdDuration / current.totalDuration
                if animationProgress >= transitionStart {
                    let transitionPhaseDuration = 1.0 - transitionStart
                    if transitionPhaseDuration > 0 {
                        transitionProgress = min(1.0, (animationProgress - transitionStart) / transitionPhaseDuration)
                    } else {
                        transitionProgress = 1.0
                    }
                } else {
                    transitionProgress = 0.0
                }
            } else {
                // Fallback if no currentEntry provided
                transitionProgress = 0.0
            }

            // Motion starts at transitionProgress = 0 (when "next" first appears)
            // transitionProgress goes 0→1 during the incoming transition (2s)
            motionElapsed = transitionProgress * incomingTransition
        } else {
            // For "current" slot
            // motionTotal = incomingTransition + holdDuration + outgoingTransition
            // This MUST match the "next" slot calculation for continuity when
            // a slide transitions from "next" to "current"
            let incomingTransition = Self.transitionDuration  // Always 2.0s
            let cycleElapsed = animationProgress * entry.totalDuration
            motionTotal = incomingTransition + entry.holdDuration + entry.transitionDuration
            motionElapsed = cycleElapsed + incomingTransition
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
