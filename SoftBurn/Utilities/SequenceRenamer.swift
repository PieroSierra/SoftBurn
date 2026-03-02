//
//  SequenceRenamer.swift
//  SoftBurn
//
//  Created on 2026-03-01.
//
//  Computes the proposed rename preview for "Rename Files to Sequence".
//  Pure algorithm — no side effects, no UI, no file I/O.
//

import Foundation

// MARK: - RenamePreviewItem

/// Represents a single row in the rename preview dialog.
/// One item per entry in the slideshow, in playback order.
struct RenamePreviewItem: Identifiable, Sendable {
    /// Mirrors MediaItem.id — used to update SlideshowState after a successful rename.
    let id: UUID
    /// 1-based position in the slideshow (display only).
    let playbackIndex: Int
    /// Last path component of the immediate parent folder, or "Photos Library" for library items.
    let parentFolderDisplayName: String
    /// Last path component of the current file URL (filename + extension).
    let currentFilename: String
    /// Proposed new filename (e.g. "0003-photo.jpg"). nil for Photos Library items.
    let newFilename: String?
    /// Full URL of the current file. Used for FileManager.moveItem.
    let currentURL: URL
    /// Full URL of the proposed new location. nil for Photos Library items.
    let newURL: URL?
    /// true if this item is from the Photos Library and cannot be renamed.
    let isPhotosLibrary: Bool

    /// true if this item will be renamed (filesystem item with a valid new URL).
    var isRenameable: Bool {
        !isPhotosLibrary && newURL != nil
    }
}

// MARK: - RenamePreviewData

/// Identifiable wrapper used with `.sheet(item:)` to atomically bind the preview data
/// and sheet presentation, avoiding the SwiftUI timing issue where separate `isPresented`
/// + data state can cause the sheet to open with stale (empty) data.
struct RenamePreviewData: Identifiable {
    let id = UUID()
    let items: [RenamePreviewItem]
}

// MARK: - SequenceRenamer

/// Stateless utility that builds a rename preview from the current slideshow order.
enum SequenceRenamer {

    /// Builds a flat, playback-order list of rename proposals from the given media items.
    ///
    /// Rules:
    /// - Photos Library items receive a skip-indicator row (newFilename = nil).
    /// - Filesystem items receive a zero-padded 4-digit sequence prefix scoped to their
    ///   immediate parent folder. Counters increment as each folder's files are encountered
    ///   in playback order (non-contiguous files from the same folder still get consecutive numbers).
    /// - Any existing leading `\d{4}-` prefix is stripped before the new prefix is applied,
    ///   making the operation idempotent across multiple invocations.
    ///
    /// - Parameter items: The ordered slideshow items (SlideshowState.photos).
    /// - Returns: One RenamePreviewItem per input item, in the same order.
    static func buildPreview(for items: [MediaItem]) -> [RenamePreviewItem] {
        var folderCounters: [URL: Int] = [:]

        return items.enumerated().map { (index, item) in
            let playbackIndex = index + 1

            switch item.source {
            case .photosLibrary:
                return RenamePreviewItem(
                    id: item.id,
                    playbackIndex: playbackIndex,
                    parentFolderDisplayName: "Photos Library",
                    currentFilename: item.fileName,
                    newFilename: nil,
                    currentURL: item.url,
                    newURL: nil,
                    isPhotosLibrary: true
                )

            case .filesystem(let currentURL):
                let parentFolder = currentURL.deletingLastPathComponent()
                let parentFolderDisplayName = parentFolder.lastPathComponent

                // Increment this folder's counter.
                let count = (folderCounters[parentFolder] ?? 0) + 1
                folderCounters[parentFolder] = count

                // Build the new base name: strip any leading \d{4}- prefix first.
                var baseName = currentURL.deletingPathExtension().lastPathComponent
                if baseName.count > 5 {
                    let prefix = baseName.prefix(5)
                    let digits = prefix.prefix(4)
                    let separator = prefix.dropFirst(4).first
                    let allDigits = digits.allSatisfy { $0.isASCII && $0.isNumber }
                    if allDigits && separator == "-" {
                        baseName = String(baseName.dropFirst(5))
                    }
                }

                let ext = currentURL.pathExtension
                let newFilename: String
                if ext.isEmpty {
                    newFilename = String(format: "%04d-%@", count, baseName)
                } else {
                    newFilename = String(format: "%04d-%@.%@", count, baseName, ext)
                }
                let newURL = parentFolder.appendingPathComponent(newFilename)

                return RenamePreviewItem(
                    id: item.id,
                    playbackIndex: playbackIndex,
                    parentFolderDisplayName: parentFolderDisplayName,
                    currentFilename: currentURL.lastPathComponent,
                    newFilename: newFilename,
                    currentURL: currentURL,
                    newURL: newURL,
                    isPhotosLibrary: false
                )
            }
        }
    }
}
