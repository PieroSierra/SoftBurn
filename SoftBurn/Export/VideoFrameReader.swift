//
//  VideoFrameReader.swift
//  SoftBurn
//
//  Frame-accurate video frame extraction using AVAssetReader.
//  Used during export to get precise frames at arbitrary timestamps.
//

import Foundation
import AVFoundation
import Metal
import MetalKit
import CoreVideo

/// Actor for extracting video frames at specific timestamps
actor VideoFrameReader {
    private let asset: AVAsset
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader

    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var videoTrack: AVAssetTrack?

    private let videoDuration: CMTime
    private let rotationDegrees: Int

    // Cache for efficient frame reuse
    private var lastSampleBuffer: CMSampleBuffer?
    private var lastTexture: MTLTexture?
    private var lastTimestamp: CMTime = .invalid

    // Texture cache for GPU-efficient pixel buffer conversion
    private var textureCache: CVMetalTextureCache?

    init(url: URL, device: MTLDevice) async throws {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)

        // Start security-scoped access if needed
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Load asset
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        self.asset = asset

        // Get video track
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw ExportError.videoWriterFailed("No video track found in \(url.lastPathComponent)")
        }
        self.videoTrack = videoTrack

        // Get duration
        self.videoDuration = try await asset.load(.duration)

        // Calculate rotation from transform
        let transform = try await videoTrack.load(.preferredTransform)
        self.rotationDegrees = Self.rotationFromTransform(transform)

        // Create texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache
    }

    /// Get the video duration in seconds
    var durationSeconds: Double {
        CMTimeGetSeconds(videoDuration)
    }

    /// Get the rotation degrees extracted from the video's preferred transform
    var rotation: Int {
        rotationDegrees
    }

    /// Extract a frame at the given time (wraps if time exceeds duration)
    func frame(at time: CMTime) async throws -> MTLTexture? {
        // Wrap time to video duration (for looping)
        let wrappedTime = wrapTime(time)

        // Check cache
        if CMTimeCompare(wrappedTime, lastTimestamp) == 0, let cached = lastTexture {
            return cached
        }

        // Need to seek to new position - recreate reader
        try await setupReader(startingAt: wrappedTime)

        // Read the next sample
        guard let output = trackOutput else {
            return nil
        }

        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            return nil
        }

        // Convert to texture
        guard let texture = try await sampleBufferToTexture(sampleBuffer) else {
            return nil
        }

        // Cache
        lastSampleBuffer = sampleBuffer
        lastTexture = texture
        lastTimestamp = wrappedTime

        return texture
    }

    /// Get a frame at a specific time in seconds
    func frame(atSeconds seconds: Double) async throws -> MTLTexture? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try await frame(at: time)
    }

    private func wrapTime(_ time: CMTime) -> CMTime {
        guard CMTimeCompare(videoDuration, .zero) > 0 else {
            return .zero
        }

        let timeSeconds = CMTimeGetSeconds(time)
        let durationSeconds = CMTimeGetSeconds(videoDuration)

        if timeSeconds < 0 {
            return .zero
        }

        if timeSeconds >= durationSeconds {
            let wrappedSeconds = timeSeconds.truncatingRemainder(dividingBy: durationSeconds)
            return CMTime(seconds: wrappedSeconds, preferredTimescale: time.timescale)
        }

        return time
    }

    private func setupReader(startingAt time: CMTime) async throws {
        // Clean up old reader
        assetReader?.cancelReading()
        assetReader = nil
        trackOutput = nil

        guard let videoTrack = self.videoTrack else {
            return
        }

        // Create reader
        let reader = try AVAssetReader(asset: asset)

        // Configure output for GPU-compatible pixel format
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        output.supportsRandomAccess = true

        reader.add(output)

        // Set time range starting from requested time
        let endTime = videoDuration
        reader.timeRange = CMTimeRange(start: time, end: endTime)

        guard reader.startReading() else {
            throw ExportError.videoWriterFailed("Failed to start reading video: \(reader.error?.localizedDescription ?? "unknown")")
        }

        self.assetReader = reader
        self.trackOutput = output
    }

    private func sampleBufferToTexture(_ sampleBuffer: CMSampleBuffer) async throws -> MTLTexture? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0, height > 0, let cache = textureCache else {
            return nil
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(cvTex)
    }

    private static func rotationFromTransform(_ transform: CGAffineTransform) -> Int {
        // Detect rotation from preferredTransform
        let angle = atan2(transform.b, transform.a)
        let degrees = Int(round(angle * 180 / .pi))

        // Normalize to 0, 90, 180, 270
        switch degrees {
        case -90, 270:
            return 270
        case 90, -270:
            return 90
        case 180, -180:
            return 180
        default:
            return 0
        }
    }

    /// Close the reader and release resources
    func close() {
        assetReader?.cancelReading()
        assetReader = nil
        trackOutput = nil
        lastSampleBuffer = nil
        lastTexture = nil
        lastTimestamp = .invalid
    }
}
