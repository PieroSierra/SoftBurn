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
    let photos: [MediaItem]
    let selectedPhotoIDs: Set<UUID>
    let onPhotoTap: (UUID, Bool, Bool) -> Void // photoID, isCommandKey, isShiftKey
    let onOpenViewer: (UUID) -> Void
    let onDrop: ([URL]) -> Void
    let onReorder: ([UUID], UUID) -> Void // sourceIDs (all selected), targetID
    let onDragStart: (UUID) -> Void // Called when drag starts to select the item
    let onDeselectAll: () -> Void // Called when clicking on whitespace
    
    // Thumbnail cache for drag previews
    @State private var thumbnailCache: [UUID: NSImage] = [:]
    
    // Grid configuration - fixed size columns for consistent layout
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
    ]
    
    var body: some View {
        ScrollView {
            ZStack {
                // Background tap target for deselecting
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDeselectAll()
                    }
                
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
                        .onTapGesture(count: 2) {
                            // Double-click: open viewer for clicked photo (in slideshow order)
                            onPhotoTap(photo.id, false, false)
                            onOpenViewer(photo.id)
                        }
                        .onAppear {
                            // Pre-cache thumbnails for drag previews
                            Task {
                                if let thumbnail = await ThumbnailCache.shared.thumbnail(for: photo.url) {
                                    thumbnailCache[photo.id] = thumbnail
                                }
                            }
                        }
                        .onDrag {
                            // Select the item when drag starts
                            onDragStart(photo.id)
                            return NSItemProvider(object: photo.id.uuidString as NSString)
                        } preview: {
                            // Show actual thumbnail(s) as drag preview
                            dragPreview(for: photo.id)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let sourceIDString = items.first,
                                  let sourceID = UUID(uuidString: sourceIDString),
                                  sourceID != photo.id else {
                                return false
                            }
                            
                            // Collect all selected IDs to move (maintain order)
                            let idsToMove: [UUID] = {
                                if selectedPhotoIDs.contains(sourceID) {
                                    // Move all selected items, maintaining their relative order
                                    return photos.filter { selectedPhotoIDs.contains($0.id) }.map { $0.id }
                                } else {
                                    return [sourceID]
                                }
                            }()
                            
                            withAnimation(.easeInOut(duration: 0.25)) {
                                onReorder(idsToMove, photo.id)
                            }
                            return true
                        }
                    }
                }
                .padding(16)
                .animation(.easeInOut(duration: 0.25), value: photos.map { $0.id })
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleExternalDrop(providers: providers)
        }
    }
    
    /// Create drag preview showing actual thumbnail(s)
    @ViewBuilder
    private func dragPreview(for photoID: UUID) -> some View {
        // Get all selected photos, or just the dragged one if not selected
        let draggedIDs: [UUID] = {
            if selectedPhotoIDs.contains(photoID) {
                // Drag all selected items
                return photos.filter { selectedPhotoIDs.contains($0.id) }.map { $0.id }
            } else {
                // Just drag this one
                return [photoID]
            }
        }()
        
        let previewSize: CGFloat = 80
        let maxPreviews = min(draggedIDs.count, 3)
        let visibleIDs = Array(draggedIDs.prefix(maxPreviews))
        let stackOffset: CGFloat = 8
        let padding: CGFloat = 30 // Generous padding for shadows and badge
        
        ZStack {
            ForEach(Array(visibleIDs.enumerated()), id: \.element) { index, id in
                if let thumbnail = thumbnailCache[id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: previewSize, height: previewSize)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        .offset(x: CGFloat(index) * stackOffset, y: CGFloat(index) * stackOffset)
                        .zIndex(Double(maxPreviews - index))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(width: previewSize, height: previewSize)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundColor(.secondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        .offset(x: CGFloat(index) * stackOffset, y: CGFloat(index) * stackOffset)
                        .zIndex(Double(maxPreviews - index))
                }
            }
            
            // Badge showing count if more than one
            if draggedIDs.count > 1 {
                Text("\(draggedIDs.count)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: previewSize / 2 + CGFloat(maxPreviews - 1) * stackOffset / 2 + 8,
                            y: -previewSize / 2 - 4)
                    .zIndex(100)
            }
        }
        .padding(padding)
        .frame(width: previewSize + CGFloat(maxPreviews - 1) * stackOffset + padding * 2,
               height: previewSize + CGFloat(maxPreviews - 1) * stackOffset + padding * 2)
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


