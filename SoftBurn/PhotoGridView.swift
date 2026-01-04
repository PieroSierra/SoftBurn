//
//  PhotoGridView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// Grid view displaying photo thumbnails
struct PhotoGridView: View {
    let photos: [PhotoItem]
    let selectedPhotoIDs: Set<UUID>
    let onPhotoTap: (UUID, Bool, Bool) -> Void // photoID, isCommandKey, isShiftKey
    let onDrop: ([URL]) -> Void
    let onReorder: (UUID, UUID) -> Void // sourceID, targetID
    
    // Grid configuration - fixed size columns for consistent layout
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(photos) { photo in
                    ThumbnailView(
                        photo: photo,
                        isSelected: selectedPhotoIDs.contains(photo.id)
                    ) {
                        let event = NSApp.currentEvent
                        let isCommandKey = event?.modifierFlags.contains(.command) == true
                        let isShiftKey = event?.modifierFlags.contains(.shift) == true
                        onPhotoTap(photo.id, isCommandKey, isShiftKey)
                    }
                    .draggable(photo.id.uuidString) {
                        // Drag preview
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: 100, height: 100)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundColor(.accentColor)
                            )
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let sourceIDString = items.first,
                              let sourceID = UUID(uuidString: sourceIDString),
                              sourceID != photo.id else {
                            return false
                        }
                        onReorder(sourceID, photo.id)
                        return true
                    }
                }
            }
            .padding(16)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleExternalDrop(providers: providers)
        }
    }
    
    private func handleExternalDrop(providers: [NSItemProvider]) -> Bool {
        // Only handle external file drops, not internal reordering
        // Check if this is an internal drag by looking for our UUID string type
        let hasInternalDrag = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        if hasInternalDrag {
            return false
        }
        
        Task {
            var urls: [URL] = []
            
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) {
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    } else if let url = item as? URL {
                        urls.append(url)
                    }
                }
            }
            
            if !urls.isEmpty {
                await MainActor.run {
                    onDrop(urls)
                }
            }
        }
        
        return true
    }
}


