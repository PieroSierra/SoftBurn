//
//  ContentView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// Custom UTType for .softburn files
extension UTType {
    static var softburn: UTType {
        // Use the exported type from Info.plist
        UTType(exportedAs: "com.softburn.slideshow")
    }
}

/// Tracks which file operation is active
enum FileImportMode {
    case photos
    case slideshow
}

struct ContentView: View {
    @StateObject private var slideshowState = SlideshowState()
    @State private var isImporting = false
    @State private var importMode: FileImportMode = .photos
    @State private var isSaving = false
    @State private var showOpenWarning = false
    @State private var pendingOpenURL: URL?
    
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
                    onReorder: { sourceIDs, targetID in
                        slideshowState.movePhotos(withIDs: sourceIDs, toPositionOf: targetID)
                    },
                    onDragStart: { photoID in
                        // Select the dragged item if not already selected
                        if !slideshowState.selectedPhotoIDs.contains(photoID) {
                            slideshowState.deselectAll()
                            slideshowState.toggleSelection(for: photoID)
                        }
                    },
                    onDeselectAll: {
                        slideshowState.deselectAll()
                    }
                )
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        // Single file importer for both photos and slideshows
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importMode == .photos ? [.folder, .image] : [.softburn],
            allowsMultipleSelection: importMode == .photos
        ) { result in
            switch importMode {
            case .photos:
                handleFileImport(result: result)
            case .slideshow:
                handleOpenSlideshow(result: result)
            }
        }
        // Save slideshow dialog
        .fileExporter(
            isPresented: $isSaving,
            document: SlideshowFileDocument(photos: slideshowState.photos),
            contentType: .softburn,
            defaultFilename: "My Slideshow"
        ) { result in
            // Silently handle save result
            if case .failure(let error) = result {
                print("Save error: \(error.localizedDescription)")
            }
        }
        // Warning dialog when opening with existing photos
        .alert("Replace Current Slideshow?", isPresented: $showOpenWarning) {
            Button("Cancel", role: .cancel) {
                pendingOpenURL = nil
            }
            Button("Replace", role: .destructive) {
                if let url = pendingOpenURL {
                    loadSlideshow(from: url)
                    pendingOpenURL = nil
                }
            }
        } message: {
            Text("Opening a slideshow will replace the \(slideshowState.photoCount) photos currently in your slideshow.")
        }
        // CMD+A to select all
        .background(
            Button("") {
                slideshowState.selectAll()
            }
            .keyboardShortcut("a", modifiers: .command)
            .opacity(0)
        )
        // CMD+S to save
        .background(
            Button("") {
                if !slideshowState.isEmpty {
                    isSaving = true
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .opacity(0)
        )
        // CMD+O to open
        .background(
            Button("") {
                importMode = .slideshow
                isImporting = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .opacity(0)
        )
    }
    
    // MARK: - Toolbar
    
    private var toolbar: some View {
        HStack {
            // Left side buttons
            HStack(spacing: 12) {
                Button(action: {
                    importMode = .photos
                    isImporting = true
                }) {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .help("Add photos")
                
                Button(action: {
                    isSaving = true
                }) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 20, height: 20)
                }
                .help("Save slideshow")
                .disabled(slideshowState.isEmpty)
                
                Button(action: {
                    importMode = .slideshow
                    isImporting = true
                }) {
                    Image(systemName: "folder")
                        .frame(width: 20, height: 20)
                }
                .help("Open slideshow")
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
                        .frame(width: 20, height: 20)
                }
                .help("Remove from slideshow (does not delete files)")
                .disabled(!slideshowState.hasSelection)
                
                Button(action: {
                    // Settings - not implemented in Phase 1
                }) {
                    Image(systemName: "gearshape")
                        .frame(width: 20, height: 20)
                }
                .help("Slideshow settings")
                .disabled(true)
                
                Button(action: {
                    // Play - not implemented in Phase 1
                }) {
                    Image(systemName: "play.fill")
                        .frame(width: 20, height: 20)
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
    
    // MARK: - Save/Open
    
    private func handleOpenSlideshow(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // If we have existing photos, show warning dialog
            if !slideshowState.isEmpty {
                pendingOpenURL = url
                showOpenWarning = true
            } else {
                loadSlideshow(from: url)
            }
            
        case .failure:
            // Silently ignore errors
            break
        }
    }
    
    private func loadSlideshow(from url: URL) {
        do {
            // Access security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            let document = try SlideshowDocument.load(from: url)
            let photos = document.loadPhotos()
            
            // Replace current photos
            slideshowState.replacePhotos(with: photos)
            
        } catch {
            print("Error loading slideshow: \(error.localizedDescription)")
        }
    }
}

// MARK: - FileDocument for Save

/// Wrapper for fileExporter compatibility
struct SlideshowFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.softburn] }
    static var writableContentTypes: [UTType] { [.softburn] }
    
    var document: SlideshowDocument
    
    init(photos: [PhotoItem]) {
        self.document = SlideshowDocument(photos: photos)
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.document = try SlideshowDocument.decode(from: data)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try document.encode()
        return FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    ContentView()
}
