//
//  AudioComposer.swift
//  SoftBurn
//
//  Composes audio for video export.
//  Mixes background music (looped with fade in/out) with video audio tracks.
//

import Foundation
import AVFoundation

/// Composes audio for video export
class AudioComposer {
    private let photos: [MediaItem]
    private let exportSettings: ExportSettings
    private let timeline: [SlideEntry]
    private let totalDuration: Double

    // Fade durations
    private static let fadeInDuration: Double = 1.5
    private static let fadeOutDuration: Double = 0.75

    init(photos: [MediaItem], exportSettings: ExportSettings, timeline: [SlideEntry], totalDuration: Double) {
        self.photos = photos
        self.exportSettings = exportSettings
        self.timeline = timeline
        self.totalDuration = totalDuration
    }

    /// Compose all audio and return URL to temporary file (nil if no audio)
    func composeAudio() async throws -> URL? {
        let composition = AVMutableComposition()

        var hasAudio = false

        // Add background music if selected
        if let musicURL = getMusicURL() {
            try await addBackgroundMusic(to: composition, from: musicURL)
            hasAudio = true
        }

        // Add video audio tracks if enabled
        if exportSettings.playVideosWithSound {
            let addedVideoAudio = try await addVideoAudio(to: composition)
            hasAudio = hasAudio || addedVideoAudio
        }

        guard hasAudio else {
            return nil
        }

        // Export composition to temporary file
        return try await exportComposition(composition)
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

    private func addBackgroundMusic(to composition: AVMutableComposition, from musicURL: URL) async throws {
        let musicAsset = AVURLAsset(url: musicURL)

        guard let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first else {
            return
        }

        let musicDuration = try await musicAsset.load(.duration)
        let musicDurationSeconds = CMTimeGetSeconds(musicDuration)

        guard musicDurationSeconds > 0 else {
            return
        }

        // Create audio track in composition
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return
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
                print("Failed to insert music segment: \(error)")
                break
            }

            currentTime = CMTimeAdd(currentTime, segmentDuration)
        }
    }

    // MARK: - Video Audio

    private func addVideoAudio(to composition: AVMutableComposition) async throws -> Bool {
        var addedAny = false

        for entry in timeline {
            guard entry.item.kind == .video else {
                continue
            }

            let videoAsset = AVURLAsset(url: entry.item.url)

            guard let audioTrack = try? await videoAsset.loadTracks(withMediaType: .audio).first else {
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
                print("Failed to insert video audio: \(error)")
            }
        }

        return addedAny
    }

    // MARK: - Export

    private func exportComposition(_ composition: AVMutableComposition) async throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.audioCompositionFailed("Failed to create export session")
        }

        exportSession.outputURL = tempURL
        exportSession.outputFileType = .m4a

        // Create audio mix for volume/fades
        let audioMix = createAudioMix(for: composition)
        exportSession.audioMix = audioMix

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return tempURL
        case .failed:
            throw ExportError.audioCompositionFailed(exportSession.error?.localizedDescription ?? "Unknown error")
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.audioCompositionFailed("Unexpected export status")
        }
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
