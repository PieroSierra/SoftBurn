//
//  EmptyStateView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The empty state view shown when no photos are imported
struct EmptyStateView: View {
    let onDrop: ([URL]) -> Void
    let onDropPhotosLibraryItems: ([MediaItem]) -> Void
    let onPhotosDropAuthorizationDenied: () -> Void
    var onOpenSlideshow: ((URL) -> Void)? = nil

    var body: some View {
        ZStack {
            // AppKit drop zone for proper pasteboard access
            EmptyStateDropZone(
                onDropFiles: onDrop,
                onDropPhotosLibraryItems: onDropPhotosLibraryItems,
                onPhotosDropAuthorizationDenied: onPhotosDropAuthorizationDenied,
                onOpenSlideshow: onOpenSlideshow
            )

            // Visual content (non-interactive)
            VStack(spacing: 20) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 64))
                    .foregroundColor(.secondary)

                Text("Add Photos or Videos to Get Started")
                    .font(.title2)
                    .foregroundColor(.primary)

                Text("Drag photos or folders here, or use the Add Media button")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .allowsHitTesting(false) // Pass through mouse events to AppKit drop zone
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Transparent so window background shows through (toolbar overlays on top)
        .background(Color.clear)
    }
}

// MARK: - AppKit Drop Zone

/// AppKit-backed view for handling drag-and-drop with direct NSPasteboard access.
/// Required because Photos.app drops include both file URLs and Photos identifiers,
/// and we need to check for Photos identifiers BEFORE falling back to file URLs.
struct EmptyStateDropZone: NSViewRepresentable {
    let onDropFiles: ([URL]) -> Void
    let onDropPhotosLibraryItems: ([MediaItem]) -> Void
    let onPhotosDropAuthorizationDenied: () -> Void
    var onOpenSlideshow: ((URL) -> Void)? = nil

    func makeNSView(context: Context) -> EmptyStateDropView {
        let view = EmptyStateDropView()
        view.onDropFiles = onDropFiles
        view.onDropPhotosLibraryItems = onDropPhotosLibraryItems
        view.onPhotosDropAuthorizationDenied = onPhotosDropAuthorizationDenied
        view.onOpenSlideshow = onOpenSlideshow
        return view
    }

    func updateNSView(_ nsView: EmptyStateDropView, context: Context) {
        nsView.onDropFiles = onDropFiles
        nsView.onDropPhotosLibraryItems = onDropPhotosLibraryItems
        nsView.onPhotosDropAuthorizationDenied = onPhotosDropAuthorizationDenied
        nsView.onOpenSlideshow = onOpenSlideshow
    }
}

@MainActor
final class EmptyStateDropView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onDropPhotosLibraryItems: (([MediaItem]) -> Void)?
    var onPhotosDropAuthorizationDenied: (() -> Void)?
    var onOpenSlideshow: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.photosLibraryIdentifier, .fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.photosLibraryIdentifier, .fileURL])
    }

    override var isFlipped: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        print("[EmptyStateDropView] draggingEntered - types: \(pb.types ?? [])")
        // Photos Library drops - check BEFORE .fileURL since Photos provides both
        if pb.types?.contains(.photosLibraryIdentifier) == true {
            print("[EmptyStateDropView] Detected Photos Library drop")
            return .copy
        }
        if pb.types?.contains(.fileURL) == true {
            print("[EmptyStateDropView] Detected file URL drop")
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        print("[EmptyStateDropView] performDragOperation - types: \(pb.types ?? [])")

        // Photos Library drop - check BEFORE .fileURL since Photos provides both
        if pb.types?.contains(.photosLibraryIdentifier) == true {
            print("[EmptyStateDropView] Processing Photos Library drop")
            Task { @MainActor in
                let result = await PhotosLibraryDropHandler.handleDrop(pasteboard: pb)
                print("[EmptyStateDropView] Drop result: \(result)")
                switch result {
                case .photosLibraryItems(let items):
                    print("[EmptyStateDropView] Got \(items.count) items")
                    if !items.isEmpty {
                        self.onDropPhotosLibraryItems?(items)
                    }
                case .authorizationDenied:
                    self.onPhotosDropAuthorizationDenied?()
                case .notPhotosLibraryDrop:
                    break
                }
            }
            return true
        }

        // File URL drop
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        // A single .softburn file = open slideshow, not add media
        if urls.count == 1, urls[0].pathExtension.lowercased() == "softburn", let handler = onOpenSlideshow {
            let url = urls[0]
            // Must call startAccessing synchronously while drag session is still active;
            // the sandbox extension expires when performDragOperation returns.
            // ContentView (via the scopeActive flag) owns the matching stop call.
            _ = url.startAccessingSecurityScopedResource()
            DispatchQueue.main.async {
                handler(url)
            }
            return true
        }
        onDropFiles?(urls)
        return true
    }
}


