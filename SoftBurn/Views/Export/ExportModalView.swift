//
//  ExportModalView.swift
//  SoftBurn
//
//  Progress modal UI for video export.
//

import SwiftUI

/// Modal view showing export progress
struct ExportModalView: View {
    @Bindable var progress: ExportProgress
    let onCancel: () -> Void
    let onRevealInFinder: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("Exporting Video")
                .font(.headline)

            // Progress indicator
            if progress.phase.isTerminal {
                completionView
            } else {
                progressView
            }

            // Buttons
            HStack(spacing: 12) {
                if progress.phase.isTerminal {
                    if case .completed = progress.phase {
                        Button("Reveal in Finder") {
                            onRevealInFinder()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(30)
        .frame(width: 350)
    }

    @ViewBuilder
    private var progressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.progress)
                .progressViewStyle(.linear)

            Text(progress.progressText)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var completionView: some View {
        VStack(spacing: 12) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 40))
                .foregroundColor(statusColor)

            Text(progress.phase.displayText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var statusIcon: String {
        switch progress.phase {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        case .cancelled:
            return "xmark.circle"
        default:
            return "circle"
        }
    }

    private var statusColor: Color {
        switch progress.phase {
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        default:
            return .primary
        }
    }
}

#Preview("In Progress") {
    ExportModalView(
        progress: {
            let p = ExportProgress()
            p.phase = .renderingFrames
            p.totalFrames = 1000
            p.currentFrame = 350
            return p
        }(),
        onCancel: {},
        onRevealInFinder: {},
        onDismiss: {}
    )
}

#Preview("Completed") {
    ExportModalView(
        progress: {
            let p = ExportProgress()
            p.phase = .completed
            p.outputURL = URL(fileURLWithPath: "/Users/test/export.mov")
            return p
        }(),
        onCancel: {},
        onRevealInFinder: {},
        onDismiss: {}
    )
}

#Preview("Failed") {
    ExportModalView(
        progress: {
            let p = ExportProgress()
            p.phase = .failed("Disk full")
            return p
        }(),
        onCancel: {},
        onRevealInFinder: {},
        onDismiss: {}
    )
}
