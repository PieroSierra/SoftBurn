//
//  AudioComposer.swift
//  SoftBurn
//
//  Composes audio for video export.
//  Mixes background music (looped with fade in/out) with video audio tracks.
//  Uses AVAssetWriter for reliable audio encoding (AVAssetExportSession caused AudioQueue issues).
//
//  KNOWN ISSUE (January 2026):
//  Photos Library video audio extraction fails with AudioQueue errors:
//    "AudioQueueObject.cpp:3530  _Start: Error (-4) getting reporterIDs"
//  This appears to be a sandbox/entitlement issue. Video frames from Photos Library work fine,
//  but audio operations trigger AudioQueue initialization which fails.
//  See /specs/video-export-spec.md for details and attempted fixes.
//

import Foundation
import AVFoundation

/// Composes audio for video export
class AudioComposer {
    private let photos: [MediaItem]
    private let exportSettings: ExportSettings
    private let timeline: [SlideEntry]
    private let totalDuration: Double
    private let videoURLs: [UUID: URL]  // NEW: Pre-exported video URLs

    // Fade durations
    private static let fadeInDuration: Double = 1.5
    private static let fadeOutDuration: Double = 0.75

    init(photos: [MediaItem], exportSettings: ExportSettings, timeline: [SlideEntry], totalDuration: Double, videoURLs: [UUID: URL]) {
        self.photos = photos
        self.exportSettings = exportSettings
        self.timeline = timeline
        self.totalDuration = totalDuration
        self.videoURLs = videoURLs
    }

    /// Compose all audio and return URL to temporary file (nil if no audio)
    func composeAudio() async throws -> URL? {
        // First, check if we have any audio to compose
        let musicURL = getMusicURL()
        let hasMusic = musicURL != nil

        // Check for video audio only if enabled and there are videos
        var hasVideoAudio = false
        if exportSettings.playVideosWithSound {
            for entry in timeline {
                if entry.item.kind == .video {
                    hasVideoAudio = true
                    break
                }
            }
        }

        guard hasMusic || hasVideoAudio else {
            return nil
        }

        // Create composition
        let composition = AVMutableComposition()
        var addedAudio = false

        // Add background music if selected
        if let url = musicURL {
            do {
                let added = try await addBackgroundMusic(to: composition, from: url)
                addedAudio = addedAudio || added
            } catch {
                print("[AudioComposer] Warning: Failed to add background music: \(error)")
            }
        }

        // Add video audio tracks if enabled
        if exportSettings.playVideosWithSound {
            do {
                let added = try await addVideoAudio(to: composition)
                addedAudio = addedAudio || added
            } catch {
                print("[AudioComposer] Warning: Failed to add video audio: \(error)")
            }
        }

        guard addedAudio else {
            return nil
        }

        // Export using AVAssetWriter (more reliable than AVAssetExportSession)
        return try await exportCompositionWithWriter(composition)
    }

    // MARK: - Background Music

    private func getMusicURL() -> URL? {
        guard let selection = exportSettings.musicSelection else {
            return nil
        }

        let musicSelection = MusicPlaybackManager.MusicSelection.from(identifier: selection)

        switch musicSelection {
        case .none:
            return nil
        case .builtin(let id):
            return builtinMusicURL(for: id)
        case .custom(let url):
            return url
        }
    }

    private func builtinMusicURL(for id: MusicPlaybackManager.MusicSelection.BuiltinID) -> URL? {
        let filename: String
        switch id {
        case .winters_tale:
            filename = "Winter's tale"
        case .brighter_plans:
            filename = "Brighter plans"
        case .innovation:
            filename = "Innovation"
        }

        // Try subdirectory first
        if let url = Bundle.main.url(forResource: filename, withExtension: "mp3", subdirectory: "Resources/Music") {
            return url
        }

        // Fallback to bundle root
        return Bundle.main.url(forResource: filename, withExtension: "mp3")
    }

    private func addBackgroundMusic(to composition: AVMutableComposition, from musicURL: URL) async throws -> Bool {
        let musicAsset = AVURLAsset(url: musicURL)

        guard let musicTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first else {
            print("[AudioComposer] No audio track found in music file")
            return false
        }

        let musicDuration = try await musicAsset.load(.duration)
        let musicDurationSeconds = CMTimeGetSeconds(musicDuration)

        guard musicDurationSeconds > 0 else {
            print("[AudioComposer] Music duration is zero")
            return false
        }

        // Create audio track in composition
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            print("[AudioComposer] Failed to create composition track for music")
            return false
        }

        // Loop music to fill total duration
        var currentTime: CMTime = .zero
        let targetDuration = CMTime(seconds: totalDuration, preferredTimescale: 600)

        while CMTimeCompare(currentTime, targetDuration) < 0 {
            let remainingTime = CMTimeSubtract(targetDuration, currentTime)
            let segmentDuration = CMTimeMinimum(musicDuration, remainingTime)

            let timeRange = CMTimeRange(start: .zero, duration: segmentDuration)

            do {
                try compositionTrack.insertTimeRange(
                    timeRange,
                    of: musicTrack,
                    at: currentTime
                )
            } catch {
                print("[AudioComposer] Failed to insert music segment: \(error)")
                break
            }

            currentTime = CMTimeAdd(currentTime, segmentDuration)
        }

        return true
    }

    // MARK: - Video Audio

    private func addVideoAudio(to composition: AVMutableComposition) async throws -> Bool {
        var addedAny = false

        for entry in timeline {
            guard entry.item.kind == .video else {
                continue
            }

            // NEW: Use pre-exported URL from map instead of calling getVideoURL()
            guard let videoURL = videoURLs[entry.item.id] else {
                print("[AudioComposer] Warning: No pre-exported URL for video: \(entry.item.id)")
                continue
            }

            // Use the pre-exported URL directly (no more async Photos Library access)
            let videoAsset = AVURLAsset(url: videoURL)

            guard let audioTrack = try? await videoAsset.loadTracks(withMediaType: .audio).first else {
                // Video has no audio track - skip silently
                continue
            }

            // Create audio track for video audio
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                continue
            }

            // Calculate video audio duration
            let videoDuration = try await videoAsset.load(.duration)
            let insertDuration: CMTime

            if exportSettings.playVideosInFull {
                insertDuration = videoDuration
            } else {
                // Use slide duration
                insertDuration = CMTime(seconds: exportSettings.slideDuration, preferredTimescale: 600)
            }

            // Insert at slide start time
            let insertTime = CMTime(seconds: entry.startTime, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(insertDuration, videoDuration))

            do {
                try compositionTrack.insertTimeRange(
                    timeRange,
                    of: audioTrack,
                    at: insertTime
                )
                addedAny = true
            } catch {
                print("[AudioComposer] Failed to insert video audio: \(error)")
            }
        }

        return addedAny
    }

    // MARK: - Export with AVAssetWriter (more reliable than AVAssetExportSession)

    private func exportCompositionWithWriter(_ composition: AVMutableComposition) async throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        // Delete existing file if present
        try? FileManager.default.removeItem(at: tempURL)

        // Create writer
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .m4a)

        // Audio output settings (AAC)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(audioInput) else {
            throw ExportError.audioCompositionFailed("Cannot add audio input to writer")
        }
        writer.add(audioInput)

        // Create reader
        let reader = try AVAssetReader(asset: composition)

        // Get all audio tracks and merge them
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ExportError.audioCompositionFailed("No audio tracks in composition")
        }

        // Create audio mix for volume/fades
        let audioMix = createAudioMix(for: composition)

        // Use AVAssetReaderAudioMixOutput to mix all tracks with volume control
        let readerSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2
        ]

        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: readerSettings)
        mixOutput.audioMix = audioMix

        guard reader.canAdd(mixOutput) else {
            throw ExportError.audioCompositionFailed("Cannot add mix output to reader")
        }
        reader.add(mixOutput)

        // Start reading and writing
        guard reader.startReading() else {
            throw ExportError.audioCompositionFailed("Failed to start reading: \(reader.error?.localizedDescription ?? "unknown")")
        }

        guard writer.startWriting() else {
            throw ExportError.audioCompositionFailed("Failed to start writing: \(writer.error?.localizedDescription ?? "unknown")")
        }

        writer.startSession(atSourceTime: .zero)

        // Process samples
        while let sampleBuffer = mixOutput.copyNextSampleBuffer() {
            while !audioInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            if !audioInput.append(sampleBuffer) {
                print("[AudioComposer] Warning: Failed to append audio sample")
            }
        }

        audioInput.markAsFinished()

        // Finish writing
        await writer.finishWriting()

        if let error = writer.error {
            throw ExportError.audioCompositionFailed("Writer error: \(error.localizedDescription)")
        }

        return tempURL
    }

    private func createAudioMix(for composition: AVMutableComposition) -> AVMutableAudioMix {
        let audioMix = AVMutableAudioMix()
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        // Get the first audio track (background music)
        if let musicTrack = composition.tracks(withMediaType: .audio).first {
            let params = AVMutableAudioMixInputParameters(track: musicTrack)

            // Apply music volume
            let volume = Float(exportSettings.musicVolume) / 100.0

            // Fade in at start
            let fadeInEnd = CMTime(seconds: Self.fadeInDuration, preferredTimescale: 600)
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: .zero, duration: fadeInEnd))

            // Hold volume
            let holdEnd = CMTime(seconds: totalDuration - Self.fadeOutDuration, preferredTimescale: 600)
            if CMTimeCompare(fadeInEnd, holdEnd) < 0 {
                params.setVolume(volume, at: fadeInEnd)
            }

            // Fade out at end
            let fadeOutStart = holdEnd
            let fadeOutEnd = CMTime(seconds: totalDuration, preferredTimescale: 600)
            let fadeOutDuration = CMTimeSubtract(fadeOutEnd, fadeOutStart)
            if CMTimeCompare(fadeOutDuration, .zero) > 0 {
                params.setVolumeRamp(
                    fromStartVolume: volume,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: fadeOutStart, duration: fadeOutDuration)
                )
            }

            inputParameters.append(params)
        }

        audioMix.inputParameters = inputParameters
        return audioMix
    }
}
