//
//  ExportPreset.swift
//  SoftBurn
//
//  Resolution presets for video export.
//

import Foundation
import AVFoundation

/// Resolution presets for video export
enum ExportPreset: String, CaseIterable, Identifiable {
    case hd720p = "720p"
    case sd480p = "480p"

    var id: String { rawValue }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .hd720p: return "720p HD"
        case .sd480p: return "480p SD"
        }
    }

    /// Video dimensions
    var width: Int {
        switch self {
        case .hd720p: return 1280
        case .sd480p: return 854
        }
    }

    var height: Int {
        switch self {
        case .hd720p: return 720
        case .sd480p: return 480
        }
    }

    /// Frame rate (30fps for both presets)
    var frameRate: Int { 30 }

    /// Video codec settings for AVAssetWriter
    var videoSettings: [String: Any] {
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2 // Keyframe every 2 seconds
            ]
        ]
    }

    /// Bit rate based on resolution
    private var bitRate: Int {
        switch self {
        case .hd720p: return 5_000_000  // 5 Mbps
        case .sd480p: return 2_500_000  // 2.5 Mbps
        }
    }

    /// Audio settings for AVAssetWriter (AAC stereo)
    static var audioSettings: [String: Any] {
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
    }

    /// CGSize for convenience
    var size: CGSize {
        CGSize(width: width, height: height)
    }

    /// Frame duration in seconds
    var frameDuration: Double {
        1.0 / Double(frameRate)
    }

    /// CMTime for frame duration
    var frameTime: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(frameRate))
    }
}
