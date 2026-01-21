//
//  ExportCoordinator.swift
//  SoftBurn
//
//  Main orchestrator for video export.
//  Builds timeline, renders frames, and writes to QuickTime .mov file.
//
//  ARCHITECTURE (Two-Phase Export):
//  1. Build timeline (SlideEntry array with timing, face boxes, motion offsets)
//  2. Pre-export Photos Library videos to temp files
//  3. Compose audio to temp M4A file (if music or video audio enabled)
//  4. Render video frames to temp video-only MOV file
//  5. Mux video + audio using AVMutableComposition + AVAssetExportSession
//  6. Clean up temp files
//
//  This two-phase approach avoids AVAssetWriter interleaved writing issues
//  by using AVFoundation's composition APIs for the audio muxing step.
//
//  See /specs/video-export-spec.md for implementation details.
//

import Foundation
import AVFoundation
import Metal
import MetalKit
import AppKit
import SwiftUI
@preconcurrency import CoreVideo

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

    // Pre-exported video URLs (filesystem and Photos Library)
    private var videoURLs: [UUID: URL] = [:]

    // Temp file URLs for cleanup
    private var audioTempURL: URL?
    private var videoTempURL: URL?

    // Timeline
    private var slideTimeline: [SlideEntry] = []
    private var totalDuration: Double = 0
    private var totalFrames: Int = 0

    // Transition duration (matches playback)
    private static let transitionDuration: Double = 2.0

    init(photos: [MediaItem], exportSettings: ExportSettings, preset: ExportPreset, progress: ExportProgress, frameRate: Int, presetWidth: Int, presetHeight: Int, videoSettings: [String: Any], device: MTLDevice) {
        self.photos = photos
        self.exportSettings = exportSettings
        self.preset = preset
        self.progress = progress
        self.frameRate = frameRate
        self.presetWidth = presetWidth
        self.presetHeight = presetHeight
        self.videoSettings = videoSettings
        self.device = device
    }

    @MainActor
    static func create(photos: [MediaItem], settings: SlideshowSettings, preset: ExportPreset, progress: ExportProgress) -> ExportCoordinator {
        // Extract all values on MainActor before creating actor
        let exportSettings = ExportSettings(from: settings)
        let frameRate = preset.frameRate
        let presetWidth = preset.width
        let presetHeight = preset.height
        let videoSettings = preset.videoSettings

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        return ExportCoordinator(
            photos: photos,
            exportSettings: exportSettings,
            preset: preset,
            progress: progress,
            frameRate: frameRate,
            presetWidth: presetWidth,
            presetHeight: presetHeight,
            videoSettings: videoSettings,
            device: device
        )
    }

    /// Main export function
    func export(to outputURL: URL) async throws {
        // Check for cancellation before starting
        if await progress.isCancelled { throw ExportError.cancelled }

        // Phase 1: Preparing - Build timeline
        await MainActor.run { progress.phase = .preparing }

        // Build timeline
        try await buildTimeline()

        // Pre-export Photos Library videos to temp files (for VideoFrameReader and AudioComposer)
        print("[ExportCoordinator] Pre-exporting Photos Library videos...")
        videoURLs = try await preparePhotosLibraryVideos()

        // Phase 2: Compose audio (if music or video audio enabled)
        await MainActor.run { progress.phase = .composingAudio }
        audioTempURL = try await composeAudioIfNeeded()
        if let url = audioTempURL {
            print("[ExportCoordinator] Audio composed to: \(url.path)")
        }

        // Initialize renderer
        let renderer = try await MainActor.run {
            let r = try OfflineSlideshowRenderer(
                device: device,
                preset: preset,
                settings: SlideshowSettings.shared
            )
            r.setExportStartTime(0)
            return r
        }

        // Calculate total frames
        totalFrames = Int(ceil(totalDuration * Double(frameRate)))

        let frameCount = totalFrames
        await MainActor.run {
            progress.totalFrames = frameCount
            progress.phase = .renderingFrames
        }

        // Phase 3: Render video frames
        // If we have audio, render to temp file first, then mux
        // If no audio, render directly to output
        let hasAudio = audioTempURL != nil

        if hasAudio {
            // Render to temp video file
            videoTempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try await renderVideoOnly(to: videoTempURL!, renderer: renderer)

            // Phase 4: Mux video + audio
            await MainActor.run { progress.phase = .finalizing }
            try await muxAudioWithVideo(videoURL: videoTempURL!, audioURL: audioTempURL!, outputURL: outputURL)
        } else {
            // Render directly to output (no audio)
            try await renderVideoOnly(to: outputURL, renderer: renderer)
            await MainActor.run { progress.phase = .finalizing }
        }

        // Clean up
        await cleanup()
    }

    /// Compose audio to temp file if there's music or video audio enabled
    private func composeAudioIfNeeded() async throws -> URL? {
        let composer = AudioComposer(
            photos: photos,
            exportSettings: exportSettings,
            timeline: slideTimeline,
            totalDuration: totalDuration,
            videoURLs: videoURLs
        )
        return try await composer.composeAudio()
    }

    /// Render video frames to output file (video-only, no audio)
    private func renderVideoOnly(to outputURL: URL, renderer: OfflineSlideshowRenderer) async throws {
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

        await writer.finishWriting()

        if let error = writer.error {
            throw ExportError.videoWriterFailed(error.localizedDescription)
        }
    }

    /// Mux video file with audio file using AVMutableComposition
    private func muxAudioWithVideo(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        print("[ExportCoordinator] Muxing video + audio...")

        let composition = AVMutableComposition()

        // Load video asset
        let videoAsset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.videoWriterFailed("No video track in rendered video")
        }
        let videoDuration = try await videoAsset.load(.duration)

        // Add video track to composition
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.videoWriterFailed("Failed to create video track in composition")
        }

        let videoTimeRange = CMTimeRange(start: .zero, duration: videoDuration)
        try compositionVideoTrack.insertTimeRange(videoTimeRange, of: videoTrack, at: .zero)

        // Load audio asset
        let audioAsset = AVURLAsset(url: audioURL)
        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            // Add audio track to composition
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ExportError.audioCompositionFailed("Failed to create audio track in composition")
            }

            // Audio duration may differ from video - use video duration as reference
            let audioTimeRange = CMTimeRange(start: .zero, duration: videoDuration)
            try compositionAudioTrack.insertTimeRange(audioTimeRange, of: audioTrack, at: .zero)
        }

        // Export the composition
        // Use passthrough for video (already H.264), will re-encode audio if needed
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.videoWriterFailed("Failed to create export session")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            print("[ExportCoordinator] Muxing complete")
        case .failed:
            throw ExportError.videoWriterFailed("Export session failed: \(exportSession.error?.localizedDescription ?? "unknown")")
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.videoWriterFailed("Export session ended with unexpected status: \(exportSession.status.rawValue)")
        }
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

    /// Pre-export all Photos Library videos to temp files
    /// Returns map of MediaItem UUID to temp file URL
    private func preparePhotosLibraryVideos() async throws -> [UUID: URL] {
        var videoURLs: [UUID: URL] = [:]

        for item in photos where item.kind == .video {
            switch item.source {
            case .filesystem(let url):
                // Already have filesystem URL
                videoURLs[item.id] = url
            case .photosLibrary(let localID, _):
                // Export to temp file for VideoFrameReader
                guard let url = await PhotosLibraryImageLoader.shared.getVideoURL(localIdentifier: localID) else {
                    throw ExportError.videoWriterFailed("Failed to export Photos Library video: \(localID)")
                }
                videoURLs[item.id] = url
                print("[ExportCoordinator] Pre-exported Photos Library video: \(item.id) -> \(url.path)")
            }
        }

        return videoURLs
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
        return try await MainActor.run {
            try renderer.renderFrame(
                currentTexture: currentTexture,
                nextTexture: nextTexture,
                currentTransform: currentTransform,
                nextTransform: nextTransform,
                animationProgress: animationProgress,
                transitionStart: transitionStart,
                frameTime: time
            )
        }
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
            // Use VideoFrameReader for all videos (filesystem and Photos Library)
            let reader: VideoFrameReader
            if let existing = videoReaders[item.id] {
                reader = existing
            } else {
                let videoURL: URL
                switch item.source {
                case .filesystem(let url):
                    videoURL = url
                case .photosLibrary(let localID, _):
                    // Use pre-exported temp file URL
                    guard let url = await PhotosLibraryImageLoader.shared.getVideoURL(localIdentifier: localID) else {
                        print("[ExportCoordinator] Warning: No video URL for Photos Library video: \(item.id)")
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
        // Video reader cleanup
        for reader in videoReaders.values {
            await reader.close()
        }
        videoReaders.removeAll()
        videoURLs.removeAll()

        // Temp file cleanup
        if let url = audioTempURL {
            try? FileManager.default.removeItem(at: url)
            print("[ExportCoordinator] Removed temp audio file: \(url.path)")
        }
        audioTempURL = nil

        if let url = videoTempURL {
            try? FileManager.default.removeItem(at: url)
            print("[ExportCoordinator] Removed temp video file: \(url.path)")
        }
        videoTempURL = nil
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

    nonisolated var totalDuration: Double {
        holdDuration + transitionDuration
    }
}
