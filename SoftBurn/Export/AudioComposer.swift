//
//  AudioComposer.swift
//  SoftBurn
//
//  Composes audio for video export.
//  Mixes background music (looped with fade in/out) with video audio tracks.
//
//  Volume Handling:
//  - Background music: Uses musicVolume setting (0-100%) with fade in/out
//  - Video audio: Always 100% volume (no fades)
//
//  Outputs to a temp M4A file which is then muxed with the rendered video
//  by ExportCoordinator using AVMutableComposition + AVAssetExportSession.
//

import Foundation
import AVFoundation

/// Composes audio for video export
/// Note: Sendable and nonisolated for use from ExportCoordinator actor
final class AudioComposer: Sendable {
    private let photos: [MediaItem]
    private let exportSettings: ExportSettings
    private let timeline: [SlideEntry]
    private let totalDuration: Double
    private let videoURLs: [UUID: URL]

    nonisolated init(photos: [MediaItem], exportSettings: ExportSettings, timeline: [SlideEntry], totalDuration: Double, videoURLs: [UUID: URL]) {
        self.photos = photos
        self.exportSettings = exportSettings
        self.timeline = timeline
        self.totalDuration = totalDuration
        self.videoURLs = videoURLs
    }

    /// Compose all audio and return URL to temporary file (nil if no audio)
    nonisolated func composeAudio() async throws -> URL? {
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

        // Create composition and track references
        let composition = AVMutableComposition()
        var musicTrack: AVMutableCompositionTrack?
        var videoAudioTracks: [AVMutableCompositionTrack] = []
        var addedAudio = false

        // Add background music if selected
        if let url = musicURL {
            do {
                let (track, added) = try await addBackgroundMusic(to: composition, from: url)
                musicTrack = track
                addedAudio = addedAudio || added
            } catch {
                print("[AudioComposer] Warning: Failed to add background music: \(error)")
            }
        }

        // Add video audio tracks if enabled
        if exportSettings.playVideosWithSound {
            do {
                let (tracks, added) = try await addVideoAudio(to: composition)
                videoAudioTracks = tracks
                addedAudio = addedAudio || added
            } catch {
                print("[AudioComposer] Warning: Failed to add video audio: \(error)")
            }
        }

        guard addedAudio else {
            return nil
        }

        // Export using AVAssetWriter (more reliable than AVAssetExportSession)
        return try await exportCompositionWithWriter(
            composition,
            musicTrack: musicTrack,
            videoAudioTracks: videoAudioTracks
        )
    }

    // MARK: - Background Music

    private nonisolated func getMusicURL() -> URL? {
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

    private nonisolated func builtinMusicURL(for id: MusicPlaybackManager.MusicSelection.BuiltinID) -> URL? {
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

    /// Returns (track, success) tuple
    private nonisolated func addBackgroundMusic(to composition: AVMutableComposition, from musicURL: URL) async throws -> (AVMutableCompositionTrack?, Bool) {
        let musicAsset = AVURLAsset(url: musicURL)

        guard let sourceTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first else {
            print("[AudioComposer] No audio track found in music file")
            return (nil, false)
        }

        let musicDuration = try await musicAsset.load(.duration)
        let musicDurationSeconds = CMTimeGetSeconds(musicDuration)

        guard musicDurationSeconds > 0 else {
            print("[AudioComposer] Music duration is zero")
            return (nil, false)
        }

        // Create audio track in composition
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            print("[AudioComposer] Failed to create composition track for music")
            return (nil, false)
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
                    of: sourceTrack,
                    at: currentTime
                )
            } catch {
                print("[AudioComposer] Failed to insert music segment: \(error)")
                break
            }

            currentTime = CMTimeAdd(currentTime, segmentDuration)
        }

        print("[AudioComposer] Added background music with volume \(exportSettings.musicVolume)%")
        return (compositionTrack, true)
    }

    // MARK: - Video Audio

    /// Returns (tracks, success) tuple
    private nonisolated func addVideoAudio(to composition: AVMutableComposition) async throws -> ([AVMutableCompositionTrack], Bool) {
        var tracks: [AVMutableCompositionTrack] = []
        var addedAny = false

        for entry in timeline {
            guard entry.item.kind == .video else {
                continue
            }

            // Use pre-exported URL from map
            guard let videoURL = videoURLs[entry.item.id] else {
                print("[AudioComposer] Warning: No pre-exported URL for video: \(entry.item.id)")
                continue
            }

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

            // Store reference for volume control (video audio at 100%)
            tracks.append(compositionTrack)

            // Calculate video audio duration: the audio should play for the entire time
            // the video is visible (incoming transition + hold phase + outgoing transition).
            let videoDuration = try await videoAsset.load(.duration)

            let hasIncomingTransition = entry.startTime > 0 && exportSettings.transitionStyle != .plain
            let incomingOffset: Double = hasIncomingTransition ? 2.0 : 0  // Fixed 2s crossfade
            let audioDuration = incomingOffset + entry.holdDuration + entry.transitionDuration
            let insertDuration = CMTime(seconds: audioDuration, preferredTimescale: 600)

            // Videos start playing when they first become visible during the previous slide's
            // outgoing transition. For the first slide there is no incoming transition.
            let insertTime = CMTime(seconds: entry.startTime - incomingOffset, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(insertDuration, videoDuration))

            do {
                try compositionTrack.insertTimeRange(
                    timeRange,
                    of: audioTrack,
                    at: insertTime
                )
                addedAny = true
                print("[AudioComposer] Added video audio at \(entry.startTime)s (100% volume)")
            } catch {
                print("[AudioComposer] Failed to insert video audio: \(error)")
            }
        }

        return (tracks, addedAny)
    }

    // MARK: - Export with AVAssetWriter (more reliable than AVAssetExportSession)

    private nonisolated func exportCompositionWithWriter(
        _ composition: AVMutableComposition,
        musicTrack: AVMutableCompositionTrack?,
        videoAudioTracks: [AVMutableCompositionTrack]
    ) async throws -> URL {
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
        let audioMix = createAudioMix(
            for: composition,
            musicTrack: musicTrack,
            videoAudioTracks: videoAudioTracks
        )

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

    /// Creates audio mix with volume settings:
    /// - Music track: Uses musicVolume setting with fade in/out
    /// - Video audio tracks: 100% volume (no fades)
    private nonisolated func createAudioMix(
        for composition: AVMutableComposition,
        musicTrack: AVMutableCompositionTrack?,
        videoAudioTracks: [AVMutableCompositionTrack]
    ) -> AVMutableAudioMix {
        let audioMix = AVMutableAudioMix()
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        // Apply volume to music track (with fades)
        if let track = musicTrack {
            let params = AVMutableAudioMixInputParameters(track: track)

            // Convert musicVolume (0-100) to float (0.0-1.0)
            let volume = Float(exportSettings.musicVolume) / 100.0

            // Fade durations (constants)
            let fadeInDuration: Double = 1.5
            let fadeOutDuration: Double = 0.75

            // Fade in at start
            let fadeInEnd = CMTime(seconds: fadeInDuration, preferredTimescale: 600)
            params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: .zero, duration: fadeInEnd))

            // Hold volume after fade in
            let holdEnd = CMTime(seconds: totalDuration - fadeOutDuration, preferredTimescale: 600)
            if CMTimeCompare(fadeInEnd, holdEnd) < 0 {
                params.setVolume(volume, at: fadeInEnd)
            }

            // Fade out at end
            let fadeOutStart = holdEnd
            let fadeOutEnd = CMTime(seconds: totalDuration, preferredTimescale: 600)
            let fadeOutRange = CMTimeSubtract(fadeOutEnd, fadeOutStart)
            if CMTimeCompare(fadeOutRange, .zero) > 0 {
                params.setVolumeRamp(
                    fromStartVolume: volume,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: fadeOutStart, duration: fadeOutRange)
                )
            }

            inputParameters.append(params)
        }

        // Apply 100% volume to video audio tracks (no fades)
        for track in videoAudioTracks {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(1.0, at: .zero)  // 100% volume
            inputParameters.append(params)
        }

        audioMix.inputParameters = inputParameters
        return audioMix
    }
}
