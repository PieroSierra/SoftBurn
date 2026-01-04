//
//  ContentView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var slideshowState = SlideshowState()
    @State private var isImporting = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
            
            Divider()
            
            // Main content area
            if slideshowState.isEmpty {
                EmptyStateView { urls in
                    Task {
                        await importPhotos(from: urls)
                    }
                }
            } else {
                PhotoGridView(
                    photos: slideshowState.photos,
                    selectedPhotoIDs: slideshowState.selectedPhotoIDs,
                    onPhotoTap: { photoID, isCommandKey, isShiftKey in
                        handlePhotoTap(photoID: photoID, isCommandKey: isCommandKey, isShiftKey: isShiftKey)
                    },
                    onDrop: { urls in
                        Task {
                            await importPhotos(from: urls)
                        }
                    },
                    onReorder: { sourceID, targetID in
                        slideshowState.movePhoto(withID: sourceID, toPositionOf: targetID)
                    }
                )
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.folder, .image],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result: result)
        }
    }
    
    // MARK: - Toolbar
    
    private var toolbar: some View {
        HStack {
            // Left side buttons
            HStack(spacing: 12) {
                Button(action: {
                    isImporting = true
                }) {
                    Image(systemName: "plus")
                }
                .help("Add photos")
                
                Button(action: {
                    // Save - not implemented in Phase 1
                }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save slideshow")
                .disabled(true)
                
                Button(action: {
                    // Open - not implemented in Phase 1
                }) {
                    Image(systemName: "folder")
                }
                .help("Open slideshow")
                .disabled(true)
            }
            
            Spacer()
            
            // Center: Photo count
            if !slideshowState.isEmpty {
                Text(photoCountText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Right side buttons
            HStack(spacing: 12) {
                Button(action: {
                    slideshowState.removeSelectedPhotos()
                }) {
                    Image(systemName: "trash")
                }
                .help("Remove from slideshow (does not delete files)")
                .disabled(!slideshowState.hasSelection)
                
                Button(action: {
                    // Settings - not implemented in Phase 1
                }) {
                    Image(systemName: "gearshape")
                }
                .help("Slideshow settings")
                .disabled(true)
                
                Button(action: {
                    // Play - not implemented in Phase 1
                }) {
                    Image(systemName: "play.fill")
                }
                .help("Play slideshow")
                .disabled(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var photoCountText: String {
        if slideshowState.hasSelection {
            return "\(slideshowState.selectedCount) of \(slideshowState.photoCount) selected"
        } else {
            return "\(slideshowState.photoCount) photos"
        }
    }
    
    // MARK: - Photo Import
    
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            // Start accessing security-scoped resources for all URLs
            // This ensures we maintain access to files selected via fileImporter
            for url in urls {
                _ = url.startAccessingSecurityScopedResource()
            }
            
            Task {
                await importPhotos(from: urls)
            }
        case .failure:
            // Silently ignore errors (as per spec)
            break
        }
    }
    
    private func importPhotos(from urls: [URL]) async {
        let photos = await PhotoDiscovery.discoverPhotos(from: urls)
        slideshowState.addPhotos(photos)
    }
    
    // MARK: - Selection Handling
    
    @State private var lastSelectedIndex: Int?
    
    private func handlePhotoTap(photoID: UUID, isCommandKey: Bool, isShiftKey: Bool) {
        guard let currentIndex = slideshowState.photos.firstIndex(where: { $0.id == photoID }) else {
            return
        }
        
        if isShiftKey, let lastIndex = lastSelectedIndex {
            // Range selection (shift+click)
            let startID = slideshowState.photos[lastIndex].id
            slideshowState.selectRange(from: startID, to: photoID)
        } else if isCommandKey {
            // Toggle selection (cmd+click for multi-select)
            slideshowState.toggleSelection(for: photoID)
        } else {
            // Single selection (replace current selection)
            slideshowState.deselectAll()
            slideshowState.toggleSelection(for: photoID)
        }
        
        lastSelectedIndex = currentIndex
    }
}

#Preview {
    ContentView()
}
