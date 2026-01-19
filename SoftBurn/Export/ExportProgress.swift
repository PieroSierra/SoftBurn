//
//  ExportProgress.swift
//  SoftBurn
//
//  Progress tracking for video export.
//

import Foundation

/// Phases of video export
enum ExportPhase: Equatable {
    case preparing
    case renderingFrames
    case composingAudio
    case finalizing
    case completed
    case failed(String)
    case cancelled

    var displayText: String {
        switch self {
        case .preparing:
            return "Preparing..."
        case .renderingFrames:
            return "Rendering frames..."
        case .composingAudio:
            return "Composing audio..."
        case .finalizing:
            return "Finalizing..."
        case .completed:
            return "Export complete"
        case .failed(let message):
            return "Export failed: \(message)"
        case .cancelled:
            return "Export cancelled"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// Observable progress state for export UI
@MainActor
@Observable
final class ExportProgress {
    /// Current phase of export
    var phase: ExportPhase = .preparing

    /// Current frame being rendered (1-indexed for display)
    var currentFrame: Int = 0

    /// Total frames to render
    var totalFrames: Int = 0

    /// Whether the user has requested cancellation
    var isCancelled: Bool = false

    /// Output file URL (set when export completes)
    var outputURL: URL?

    /// Last non-terminal progress value (for failed/cancelled states)
    private var lastProgress: Double = 0.0

    /// Progress fraction (0.0 to 1.0)
    var progress: Double {
        guard totalFrames > 0 else { return 0.0 }

        let computed: Double
        switch phase {
        case .preparing:
            computed = 0.0
        case .renderingFrames:
            // Frame rendering is 80% of total progress
            computed = 0.8 * (Double(currentFrame) / Double(totalFrames))
        case .composingAudio:
            computed = 0.85
        case .finalizing:
            computed = 0.95
        case .completed:
            computed = 1.0
        case .failed, .cancelled:
            return lastProgress // Keep last progress value
        }

        lastProgress = computed
        return computed
    }

    /// Formatted progress string
    var progressText: String {
        switch phase {
        case .renderingFrames:
            return "Frame \(currentFrame) of \(totalFrames)"
        default:
            return phase.displayText
        }
    }

    /// Request cancellation
    func cancel() {
        isCancelled = true
    }

    /// Reset for a new export
    func reset() {
        phase = .preparing
        currentFrame = 0
        totalFrames = 0
        isCancelled = false
        outputURL = nil
        lastProgress = 0.0
    }

    /// Update frame progress (called from export coordinator)
    func updateFrame(_ frame: Int, of total: Int) {
        currentFrame = frame
        totalFrames = total
    }
}
