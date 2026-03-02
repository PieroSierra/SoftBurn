//
//  RenameToSequenceView.swift
//  SoftBurn
//
//  Created on 2026-03-01.
//
//  Preview dialog for "Rename Files to Sequence".
//  Shows a flat, playback-order list of all planned renames before anything is touched.
//

import SwiftUI

struct RenameToSequenceView: View {
    let items: [RenamePreviewItem]
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var showingConfirmation = false

    private var renameableCount: Int {
        items.filter(\.isRenameable).count
    }

    private var hasPhotosLibraryItems: Bool {
        items.contains(where: \.isPhotosLibrary)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Rename Files to Sequence")
                    .font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            // Photos Library warning banner (shown only when relevant)
            if hasPhotosLibraryItems {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Items from your Photos Library cannot be renamed and will be skipped.")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            // Preview list
            List(items) { item in
                RenamePreviewRow(item: item)
                    .listRowSeparator(.visible)
            }
            .listStyle(.plain)
            .frame(minHeight: 200)

            Divider()

            // Bottom buttons
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    showingConfirmation = true
                } label: {
                    Text(renameableCount == 1
                         ? "Rename 1 File…"
                         : "Rename \(renameableCount) Files…")
                }
                .buttonStyle(.borderedProminent)
                .disabled(renameableCount == 0)
                .confirmationDialog(
                    renameableCount == 1
                        ? "Rename 1 file?"
                        : "Rename \(renameableCount) files?",
                    isPresented: $showingConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Rename", role: .destructive) {
                        onConfirm()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently rename files on disk. This cannot be undone.")
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 400, idealHeight: 500)
    }
}

// MARK: - Row View

private struct RenamePreviewRow: View {
    let item: RenamePreviewItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Position index
            Text("\(item.playbackIndex)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 32, alignment: .trailing)

            // Current path
            VStack(alignment: .leading, spacing: 2) {
                Text(item.parentFolderDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.currentFilename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Arrow
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .font(.caption)

            // New filename (or skip indicator)
            if item.isPhotosLibrary {
                Text("will not be renamed")
                    .font(.body)
                    .italic()
                    .foregroundStyle(.tertiary)
            } else if let newFilename = item.newFilename {
                Text(newFilename)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .opacity(item.isPhotosLibrary ? 0.5 : 1.0)
        .padding(.vertical, 2)
    }
}
