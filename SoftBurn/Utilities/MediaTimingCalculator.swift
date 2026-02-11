//
//  MediaTimingCalculator.swift
//  SoftBurn
//
//  Shared timing calculations for slideshow playback and export.
//  Single source of truth for hold duration logic.
//

import Foundation

enum MediaTimingCalculator {
    /// Fixed transition duration (2 seconds). Used by both playback and export.
    static let transitionDuration: Double = 2.0

    /// Calculate how long a media item should hold as the sole visible slide.
    ///
    /// For non-plain transitions, the video is actually visible for longer than holdDuration:
    /// it starts playing during the incoming crossfade (2s) and continues through the outgoing
    /// crossfade (2s). So total video visibility = 2s + holdDuration + 2s = holdDuration + 4s.
    /// To play a video exactly once, holdDuration = videoDuration - 4s.
    ///
    /// - Parameters:
    ///   - kind: Whether the media is a photo or video
    ///   - videoDuration: The video's intrinsic duration (ignored for photos)
    ///   - slideDuration: The user-configured slide duration
    ///   - transitionStyle: The active transition style
    ///   - playVideosInFull: Whether "Play in Full" is enabled
    /// - Returns: The hold duration in seconds
    static func holdDuration(
        kind: MediaItem.Kind,
        videoDuration: Double?,
        slideDuration: Double,
        transitionStyle: SlideshowDocument.Settings.TransitionStyle,
        playVideosInFull: Bool
    ) -> Double {
        switch kind {
        case .photo:
            return slideDuration
        case .video:
            if playVideosInFull, let seconds = videoDuration {
                if transitionStyle != .plain {
                    let adjusted = seconds - 2 * transitionDuration
                    if adjusted > 0 {
                        return adjusted
                    }
                    // Video shorter than transition overlap — loop at normal slide duration
                    return slideDuration
                } else {
                    // Plain mode: only use video duration if longer than slide duration
                    if seconds > slideDuration {
                        return seconds
                    }
                }
            }
            return slideDuration
        }
    }
}
