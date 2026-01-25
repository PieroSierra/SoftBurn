//
//  ContentView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import Photos

/// Custom UTType for .softburn files
extension UTType {
    static var softburn: UTType {
        // Prefer looking up the exported type (from Info.plist) to avoid "expected to be declared" warnings.
        // Fall back to filename-extension based type so open/save still works even if the target isn't using our Info.plist.
        UTType("com.softburn.slideshow")
            ?? UTType(filenameExtension: "softburn", conformingTo: .json)
            ?? .json
    }
}

/// Tracks which file operation is active
enum FileImportMode {
    case photos
    case slideshow
}

/// Toolbar style override for previews
enum ToolbarStyleOverride {
    case automatic  // Use OS version detection
    case liquidGlass  // Force LiquidGlass toolbar (macOS 26+ style)
    case classic  // Force classic toolbar (pre-macOS 26 style)
}

struct ContentView: View {
    @StateObject private var slideshowState = SlideshowState()
    @StateObject private var gridZoomState = GridZoomState.shared
    @ObservedObject private var settings = SlideshowSettings.shared
    @ObservedObject private var recentsManager = RecentSlideshowsManager.shared
    @EnvironmentObject private var session: AppSessionState
    @State private var isImporting = false

    /// Override for toolbar style (used in previews)
    var toolbarStyleOverride: ToolbarStyleOverride = .automatic

    /// Computed property to determine if we should use LiquidGlass toolbar
    private var useLiquidGlassToolbar: Bool {
        switch toolbarStyleOverride {
        case .automatic:
            if #available(macOS 26.0, *) {
                return true
            } else {
                return false
            }
        case .liquidGlass:
            return true
        case .classic:
            return false
        }
    }
    @State private var importMode: FileImportMode = .photos
    @State private var isSaving = false
    @State private var exportDocument = SlideshowFileDocument(photos: [])
    @State private var showOpenWarning = false
    @State private var showSettings = false
    @State private var pendingOpenURL: URL?
    @State private var isPlayingSlideshow = false
    @State private var slideshowStartingPhotoID: UUID?
    @State private var isShowingViewer = false
    @State private var viewerStartID: UUID?
    @State private var mainWindowSize: CGSize = CGSize(width: 1000, height: 700)
    @State private var isImportingFromPhotos = false
    @State private var isExporting = false
    @State private var exportPreset: ExportPreset = .hd720p
    @State private var exportProgress = ExportProgress()
    @State private var showMissingFileAlert = false
    @State private var missingFilename: String = ""

    /// Height of our custom toolbar (used for content inset on older macOS).
    private let customToolbarHeight: CGFloat = 44

    var body: some View {
        contentWithModifiers
            .onReceive(NotificationCenter.default.publisher(for: .openSlideshow)) { _ in
                importMode = .slideshow
                isImporting = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveSlideshow)) { _ in
                beginSave()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportAsVideo1080p)) { _ in
                handleExport(preset: .hd1080p)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportAsVideo720p)) { _ in
                handleExport(preset: .hd720p)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportAsVideo480p)) { _ in
                handleExport(preset: .sd480p)
            }
            .onReceive(NotificationCenter.default.publisher(for: .addFromPhotosLibrary)) { _ in
                Task {
                    let status = await PhotosLibraryManager.shared.requestAuthorization()
                    if status {
                        isImportingFromPhotos = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .addFromFiles)) { _ in
                importMode = .photos
                isImporting = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .openRecentSlideshow)) { notification in
                guard let recent = notification.object as? RecentSlideshow else { return }
                openRecentSlideshow(recent: recent)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearRecentList)) { _ in
                recentsManager.clearAll()
            }
    }

    private func handleExport(preset: ExportPreset) {
        guard !slideshowState.isEmpty else { return }
        guard !isExporting else { return }
        exportPreset = preset
        beginExport()
    }

    private var contentWithModifiers: some View {
        contentPart3
    }

    private var contentPart1: some View {
        ZStack {
            // Background color for the window
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()

            // Main content area (fills entire space, scrolls under toolbar)
            contentArea
                .ignoresSafeArea(edges: .top) // Extend under system toolbar on macOS 26

            // On older macOS (or when forced to classic), overlay our custom toolbar + fade gradient
            if !useLiquidGlassToolbar {
                VStack(spacing: 0) {
                    toolbar

                    // Fade gradient so content fades as it scrolls under toolbar
                    LinearGradient(
                        colors: [
                            Color(NSColor.controlBackgroundColor).opacity(0.9),
                            Color(NSColor.controlBackgroundColor).opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 20)

                    Spacer()
                }
            }
            // On macOS 26, the Liquid Glass toolbar handles its own blending - no extra gradient needed

            // Full-screen overlay viewer (no sheet chrome)
            if isShowingViewer, let startID = viewerStartID {
                PhotoViewerSheet(
                    slideshowState: slideshowState,
                    startingPhotoID: startID,
                    onDismiss: {
                        isShowingViewer = false
                        viewerStartID = nil
                    },
                    onPlaySlideshow: { photoID in
                        // Start slideshow from the specified photo
                        startSlideshow(fromPhotoID: photoID)
                    }
                )
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .toolbar {
            if #available(macOS 26.0, *), useLiquidGlassToolbar {
                // Left side: File and Add menus
                ToolbarItemGroup(placement: .navigation) {
                    // File dropdown
                    Menu {
                        Button(action: {
                            importMode = .slideshow
                            isImporting = true
                        }) {
                            Label("Open Slideshow...", systemImage: "folder")
                        }

                        // Open Recent submenu
                        Menu {
                            ForEach(recentsManager.recentSlideshows) { recent in
                                Button(recent.filename) {
                                    openRecentSlideshow(recent: recent)
                                }
                                .disabled(!recent.fileExists)
                            }
                            if !recentsManager.isEmpty {
                                Divider()
                            }
                            Button("Clear List") {
                                recentsManager.clearAll()
                            }
                            .disabled(recentsManager.isEmpty)
                        } label: {
                            Label("Open Recent", systemImage: "clock")
                        }

                        Button(action: {
                            beginSave()
                        }) {
                            Label("Save Slideshow...", systemImage: "square.and.arrow.down")
                        }
                        .disabled(slideshowState.isEmpty)

                        Divider()
                        
                        Menu {
                            Button(action: {
                                handleExport(preset: .hd1080p)
                            }) {
                                Label("1080p Full HD...", systemImage: "square.and.arrow.down")
                            }

                            Button(action: {
                                handleExport(preset: .hd720p)
                            }) {
                                Label("720p HD...", systemImage: "square.and.arrow.down")
                            }

                            Button(action: {
                                handleExport(preset: .sd480p)
                            }) {
                                Label("480p SD...", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Label("Export as Video", systemImage: "film")
                        }
                        .disabled(slideshowState.isEmpty)
                    } label: {
                        Label("File", systemImage: "doc")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("File operations")
                    .disabled(isShowingViewer)
                    
                    // Add dropdown
                    Menu {
                        Button(action: {
                            Task {
                                let status = await PhotosLibraryManager.shared.requestAuthorization()
                                if status {
                                    isImportingFromPhotos = true
                                }
                            }
                        }) {
                            Label("From Photos Library...", systemImage: "photo.on.rectangle")
                        }

                        Button(action: {
                            importMode = .photos
                            isImporting = true
                        }) {
                            Label("From Files...", systemImage: "doc")
                        }
                    } label: {
                        Label("Add Media", systemImage: "plus")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Add media")
                    .disabled(isShowingViewer)
                    

                }

                // Center status (always render to maintain toolbar spacing)
                ToolbarItem(placement: .principal) {
                    Text(slideshowState.isEmpty ? "" : photoCountText)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .opacity(isShowingViewer ? 0.4 : 1.0) // Dim when viewer is open
                        .frame(maxWidth: .infinity) // Expand to fill available space
                }

                // Trailing controls - disabled when viewer is open
                ToolbarItemGroup(placement: .automatic) {
                    // Zoom controls
                    ControlGroup {
                        Button(action: {
                            gridZoomState.zoomOut()
                        }) {
                            Image(systemName: "minus")
                        }
                        .help("Zoom out")
                        .disabled(!gridZoomState.canZoomOut || slideshowState.isEmpty || isShowingViewer)
                        
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 1, height: 16)
                    
                        Button(action: {
                            gridZoomState.zoomIn()
                        }) {
                            Image(systemName: "plus")
                        }
                        .help("Zoom in")
                        .disabled(!gridZoomState.canZoomIn || slideshowState.isEmpty || isShowingViewer)
                    }
                }
                
                // Break inglass toolbar
                ToolbarSpacer(.fixed)
                
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: {
                        if let photoID = slideshowState.singleSelectedPhotoID {
                            slideshowState.rotatePhotoCounterclockwise(withID: photoID)
                        }
                    }) {
                        Image(systemName: "rotate.left")
                    }
                    .help("Rotate counterclockwise")
                    .disabled(!slideshowState.hasSinglePhotoSelection || isShowingViewer)
                   
                    Button(action: {
                        slideshowState.removeSelectedPhotos()
                    }) {
                        Image(systemName: "trash")
                    }
                    .help("Remove from slideshow")
                    .disabled(!slideshowState.hasSelection || isShowingViewer)

                    Button(action: {
                        showSettings.toggle()
                    }) {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("Slideshow settings")
                    .disabled(isShowingViewer)
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                        // On macOS 26 the system popover adopts the new glass styling automatically.
                        // Do not wrap in custom backgrounds or clip shapes.
                        SettingsPopoverView(settings: settings)
                    }

                    Button(action: {
                        startSlideshow()
                    }) {
                        Label("Play", systemImage: "play.fill")
                            .foregroundStyle((slideshowState.isEmpty || isShowingViewer) ? Color.secondary : Color.blue)
                    }
                    .help("Play slideshow")
                    .disabled(slideshowState.isEmpty || isShowingViewer)
                }
            }
        }
        .toolbar(removing: .title)
        .softBurnWindowToolbarLiquidGlass()
    }

    private var contentPart2: some View {
        contentPart1
        // Single file importer for both photos and slideshows
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importMode == .photos ? [.folder, .image, .movie] : [.softburn],
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
            document: exportDocument,
            contentType: .softburn,
            defaultFilename: "My Slideshow"
        ) { result in
            // Silently handle save result
            switch result {
            case .success(let savedURL):
                recentsManager.addOrUpdate(url: savedURL)
                session.markClean()
                session.performPendingActionAfterSuccessfulSave()
            case .failure(let error):
                print("Save error: \(error.localizedDescription)")
            }
        }
        .photosLibraryIntegration(
            isImportingFromPhotos: $isImportingFromPhotos,
            onSelection: handlePhotosLibrarySelection
        )
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
        // Unsaved changes prompt (Quit / Close window)
        .alert("You have unsaved changes", isPresented: $session.showUnsavedChangesAlert) {
            Button("Save") {
                beginSave()
            }
            Button("Don’t Save", role: .destructive) {
                session.discardChangesAndPerformPendingAction()
            }
            Button("Cancel", role: .cancel) {
                session.cancelPendingAction()
            }
        } message: {
            Text("Do you want to save the changes you made to your slideshow?")
        }
        // Missing file alert for recent slideshows
        .alert("File Not Found", isPresented: $showMissingFileAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The slideshow \"\(missingFilename)\" could not be found. It may have been moved or deleted.")
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
                beginSave()
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
        // Space: open viewer for selected photo
        .background(
            Button("") {
                openViewerForSelection()
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
            .disabled(!slideshowState.hasSelection)
        )
    }

    private var contentPart3: some View {
        contentPart2
        // Launch slideshow when isPlayingSlideshow becomes true
        .onChange(of: isPlayingSlideshow) { _, isPlaying in
            if isPlaying {
                openSlideshowWindow()
            }
        }
        // Keep session in sync with whether the canvas has any photos.
        .onChange(of: slideshowState.isEmpty) { _, isEmpty in
            session.hasPhotos = !isEmpty
            if isEmpty {
                // If nothing remains, treat the session as safe to quit/close without warning.
                session.markClean()
            }
        }
        .background(WindowAccessor { window in
            // Intercept window close (Cmd+W / red close button) to show unsaved changes prompt.
            if window.delegate !== MainWindowDelegate.shared {
                window.delegate = MainWindowDelegate.shared
            }
            // Track window size for large viewer presentation.
            mainWindowSize = window.frame.size
        })
        // Mark dirty on settings changes
        .onChange(of: settings.transitionStyle) { session.markDirty() }
        .onChange(of: settings.shuffle) { session.markDirty() }
        .onChange(of: settings.zoomOnFaces) { session.markDirty() }
        .onChange(of: settings.backgroundColor) { session.markDirty() }
        .onChange(of: settings.slideDuration) { session.markDirty() }
        .onChange(of: settings.musicSelection) { session.markDirty() }
        .onChange(of: settings.musicVolume) { session.markDirty() }
        // Delete/Backspace: remove selection (grid)
        .onDeleteCommand {
            slideshowState.removeSelectedPhotos()
        }
        // Keep the "preview anchor" in sync with keyboard-driven selection changes.
        .onChange(of: slideshowState.selectedPhotoIDs) { _, newSelection in
            if newSelection.isEmpty {
                lastSelectedIndex = nil
                return
            }

            // If there's exactly one selected item, always anchor to it.
            if newSelection.count == 1, let id = newSelection.first,
               let idx = slideshowState.photos.firstIndex(where: { $0.id == id }) {
                lastSelectedIndex = idx
                return
            }

            // If we have an anchor and it's still selected, keep it.
            if let idx = lastSelectedIndex,
               idx >= 0, idx < slideshowState.photos.count,
               newSelection.contains(slideshowState.photos[idx].id) {
                return
            }

            // Otherwise, pick the first selected item in slideshow order.
            if let firstIdx = slideshowState.photos.firstIndex(where: { newSelection.contains($0.id) }) {
                lastSelectedIndex = firstIdx
            }
        }
        // Export modal sheet
        .sheet(isPresented: $isExporting) {
            ExportModalView(
                progress: exportProgress,
                onCancel: {
                    exportProgress.cancel()
                },
                onRevealInFinder: {
                    if let url = exportProgress.outputURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    isExporting = false
                },
                onDismiss: {
                    isExporting = false
                }
            )
        }
    }
    
    // MARK: - Slideshow Window
    
    /// Starts the slideshow, computing the starting photo based on selection.
    /// - If there's a selection and shuffle is OFF, starts from the last selected photo.
    /// - If shuffle is ON, starts randomly (ignores selection).
    /// - If no selection, starts from the first photo.
    /// - Parameter fromPhotoID: Optional explicit photo ID to start from (e.g., from viewer).
    ///                          If provided, this takes precedence over selection.
    private func startSlideshow(fromPhotoID explicitID: UUID? = nil) {
        // Determine starting photo ID
        var startID: UUID? = nil
        
        if let explicitID {
            // Explicit ID provided (e.g., from viewer Play button)
            startID = explicitID
        } else if slideshowState.hasSelection {
            // Use the last selected photo (same logic as viewer preview)
            if let idx = lastSelectedIndex, idx < slideshowState.photos.count {
                startID = slideshowState.photos[idx].id
            } else if let firstSelected = slideshowState.photos.first(where: { slideshowState.selectedPhotoIDs.contains($0.id) }) {
                startID = firstSelected.id
            }
        }
        // If no selection and no explicit ID, startID remains nil (starts from beginning)
        
        slideshowStartingPhotoID = startID
        isPlayingSlideshow = true
    }
    
    private func openSlideshowWindow() {
        SlideshowWindowController.shared.onClose = { [self] in
            isPlayingSlideshow = false
            slideshowStartingPhotoID = nil
        }

        let slideshowView = SlideshowPlayerView(
            photos: slideshowState.photos,
            settings: settings,
            startingPhotoID: slideshowStartingPhotoID,
            onExit: {
                SlideshowWindowController.shared.close()
            }
        )

        SlideshowWindowController.shared.present(
            rootView: AnyView(slideshowView),
            backgroundColor: NSColor(settings.backgroundColor),
            displayID: settings.playbackDisplayID
        )
    }
    
    private func closeSlideshowWindow() {
        SlideshowWindowController.shared.close()
    }
    
    // MARK: - Content Area
    
    @ViewBuilder
    private var contentArea: some View {
        // Calculate toolbar inset so content starts below toolbar but can scroll under it.
        // On macOS 26 content extends under system toolbar via ignoresSafeArea.
        // On older macOS we extend under our custom toolbar + fade gradient.
        let toolbarInset: CGFloat = {
            if #available(macOS 26.0, *) {
                return 52 // Approximate height of system toolbar so content starts visible below it
            } else {
                return customToolbarHeight + 20 // Toolbar + fade gradient
            }
        }()
        
        if slideshowState.isEmpty {
            EmptyStateView { urls in
                Task {
                    await importPhotos(from: urls)
                }
            }
        } else {
            PhotoGridView(
                photos: slideshowState.photos,
                selectedPhotoIDs: $slideshowState.selectedPhotoIDs,
                toolbarInset: toolbarInset,
                zoomPointSize: gridZoomState.currentPointSize,
                onZoomLevelChange: { newLevelIndex in
                    gridZoomState.currentLevelIndex = newLevelIndex
                },
                onUserClickItem: { photoID in
                    if let idx = slideshowState.photos.firstIndex(where: { $0.id == photoID }) {
                        lastSelectedIndex = idx
                    }
                },
                onOpenViewer: { photoID in
                    openViewer(for: photoID)
                },
                onPreviewSelection: {
                    openViewerForSelection()
                },
                onDrop: { urls in
                    Task {
                        await importPhotos(from: urls)
                    }
                },
                onReorderToIndex: { sourceIDs, destinationIndex in
                    slideshowState.movePhotos(withIDs: sourceIDs, toIndex: destinationIndex)
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
    
    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            // Left side: File and Add menus
            HStack(spacing: 12) {
                // File dropdown
                Menu {
                    Button(action: {
                        importMode = .slideshow
                        isImporting = true
                    }) {
                        Label("Open Slideshow...", systemImage: "folder")
                    }

                    // Open Recent submenu
                    Menu {
                        ForEach(recentsManager.recentSlideshows) { recent in
                            Button(recent.filename) {
                                openRecentSlideshow(recent: recent)
                            }
                            .disabled(!recent.fileExists)
                        }
                        if !recentsManager.isEmpty {
                            Divider()
                        }
                        Button("Clear List") {
                            recentsManager.clearAll()
                        }
                        .disabled(recentsManager.isEmpty)
                    } label: {
                        Label("Open Recent", systemImage: "clock")
                    }

                    Button(action: {
                        beginSave()
                    }) {
                        Label("Save Slideshow...", systemImage: "square.and.arrow.down")
                    }
                    .disabled(slideshowState.isEmpty)

                    Divider()

                    Menu {
                        Button(action: {
                            handleExport(preset: .hd1080p)
                        }) {
                            Label("1080p Full HD...", systemImage: "square.and.arrow.down")
                        }

                        Button(action: {
                            handleExport(preset: .hd720p)
                        }) {
                            Label("720p HD...", systemImage: "square.and.arrow.down")
                        }

                        Button(action: {
                            handleExport(preset: .sd480p)
                        }) {
                            Label("480p SD...", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Export as Video", systemImage: "film")
                    }
                    .disabled(slideshowState.isEmpty)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .frame(width: 20, height: 20)
                        Text("File")
                    }
                }
                .help("File operations")
                .disabled(isShowingViewer)

                // Add dropdown
                Menu {
                    Button(action: {
                        Task {
                            let status = await PhotosLibraryManager.shared.requestAuthorization()
                            if status {
                                isImportingFromPhotos = true
                            }
                        }
                    }) {
                        Label("From Photos Library...", systemImage: "photo.on.rectangle")
                    }

                    Button(action: {
                        importMode = .photos
                        isImporting = true
                    }) {
                        Label("From Files...", systemImage: "doc")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                        Text("Add")
                    }
                }
                .help("Add media")
                .disabled(isShowingViewer)
            }
            
            Spacer()
            
            // Center: Photo count
            if !slideshowState.isEmpty {
                Text(photoCountText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .opacity(isShowingViewer ? 0.4 : 1.0) // Dim when viewer is open
            }
            
            Spacer()

            // Right side buttons - disabled when viewer is open
            HStack(spacing: 12) {
                // Zoom controls group
                ControlGroup {
                    Button(action: {
                        gridZoomState.zoomOut()
                    }) {
                        Image(systemName: "minus")
                            .frame(width: 20, height: 20)
                    }
                    .help("Zoom out")
                    .disabled(!gridZoomState.canZoomOut || slideshowState.isEmpty || isShowingViewer)

                    Button(action: {
                        gridZoomState.zoomIn()
                    }) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                    }
                    .help("Zoom in")
                    .disabled(!gridZoomState.canZoomIn || slideshowState.isEmpty || isShowingViewer)
                }


                Button(action: {
                    if let photoID = slideshowState.singleSelectedPhotoID {
                        slideshowState.rotatePhotoCounterclockwise(withID: photoID)
                    }
                }) {
                    Image(systemName: "rotate.left")
                        .frame(width: 20, height: 20)
                }
                .help("Rotate counterclockwise")
                .disabled(!slideshowState.hasSinglePhotoSelection || isShowingViewer)

                Button(action: {
                    slideshowState.removeSelectedPhotos()
                }) {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .help("Remove from slideshow")
                .disabled(!slideshowState.hasSelection || isShowingViewer)
                

                // Settings button (standalone for proper popover anchoring)
                Button(action: {
                    showSettings.toggle()
                }) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 20, height: 20)
                }
                .help("Slideshow settings")
                .disabled(isShowingViewer)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopoverView(settings: settings)
                }

                // Play button
                Button(action: {
                    startSlideshow()
                }) {
                    Image(systemName: "play.fill")
                        .frame(width: 20, height: 20)
                        .foregroundStyle((slideshowState.isEmpty || isShowingViewer) ? Color.secondary : Color.blue)
                }
                .help("Play slideshow")
                .disabled(slideshowState.isEmpty || isShowingViewer)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .softBurnToolbarBackground()
    }
    
    private var photoCountText: String {
        if slideshowState.hasSelection {
            return "  \(slideshowState.selectedCount) of \(slideshowState.photoCount) selected  "
        } else {
            return "  \(slideshowState.photoCount) items  "
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

        // Face detection prefetch (import-time only; never during playback)
        Task.detached(priority: .utility) {
            await FaceDetectionCache.shared.prefetch(items: photos)
        }
    }
    
    // MARK: - Selection Handling
    
    @State private var lastSelectedIndex: Int?

    // MARK: - Viewer

    private func openViewer(for photoID: UUID) {
        guard !slideshowState.photos.isEmpty else { return }
        viewerStartID = photoID
        isShowingViewer = true
    }

    private func openViewerForSelection() {
        guard slideshowState.hasSelection else { return }

        // Prefer the last clicked index if available; otherwise use first selected in slideshow order.
        if let idx = lastSelectedIndex, idx < slideshowState.photos.count {
            openViewer(for: slideshowState.photos[idx].id)
            return
        }

        if let firstSelected = slideshowState.photos.first(where: { slideshowState.selectedPhotoIDs.contains($0.id) }) {
            openViewer(for: firstSelected.id)
        }
    }
    
    // MARK: - Save/Open

    /// Opens a recent slideshow from the recents menu
    private func openRecentSlideshow(recent: RecentSlideshow) {
        // Try to resolve the security-scoped bookmark first
        let accessURL: URL
        if let resolvedURL = recent.resolveBookmark() {
            accessURL = resolvedURL
        } else {
            // Fallback to stored URL (may fail in sandbox)
            accessURL = recent.url
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: accessURL.path) else {
            missingFilename = accessURL.deletingPathExtension().lastPathComponent
            showMissingFileAlert = true
            return
        }

        // If we have existing photos, show warning dialog
        if !slideshowState.isEmpty {
            pendingOpenURL = accessURL
            showOpenWarning = true
        } else {
            loadSlideshow(from: accessURL)
        }
    }

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
            let photos = document.loadMediaItems()

            // Hydrate face cache from document (trusted; no re-detection for these entries)
            Task.detached(priority: .utility) {
                await FaceDetectionCache.shared.ingest(faceRectsByPath: document.faceRectsByPath)
            }
            
            // Replace current photos
            slideshowState.replacePhotos(with: photos)
            
            // Apply settings from loaded document (overrides app settings)
            settings.applyFromDocument(document.settings)
            
            // Opening a document sets a clean baseline.
            session.markClean()

            // Add to recents after successful load
            recentsManager.addOrUpdate(url: url)

            // Face detection prefetch (open-time only; never during playback)
            Task.detached(priority: .utility) {
                await FaceDetectionCache.shared.prefetch(items: photos)
            }
            
        } catch {
            print("Error loading slideshow: \(error.localizedDescription)")
        }
    }

    // MARK: - Photos Library

    @MainActor
    private func handlePhotosLibrarySelection(_ assets: [PHAsset]) {
        let mediaItems = PhotosLibraryManager.shared.createMediaItems(from: assets)
        slideshowState.addPhotos(mediaItems)
        session.markDirty()
        isImportingFromPhotos = false

        // Face detection prefetch for Photos Library items
        Task.detached(priority: .utility) {
            await FaceDetectionCache.shared.prefetch(items: mediaItems)
        }
    }

    // MARK: - Save

    @MainActor
    private func beginSave() {
        guard !slideshowState.isEmpty else { return }

        let photos = slideshowState.photos
        let docSettings = settings.toDocumentSettings()

        Task { @MainActor in
            // Snapshot any cached face rects we already have (do NOT run detection here).
            // Uses MediaItem-based method to support both filesystem and Photos Library items.
            let faceRects = await FaceDetectionCache.shared.snapshotFaceRects(for: photos.filter { $0.kind == .photo })

            // Create security-scoped bookmarks for each photo so we can reopen across app launches.
            // This is best-effort; missing bookmarks just mean we may need the user to re-select those files later.
            let photoURLs = photos.map(\.url)
            let bookmarksByPath: [String: String] = await Task.detached(priority: .utility) {
                var result: [String: String] = [:]
                for url in photoURLs {
                    // Bookmark creation does NOT prompt; it only succeeds if we already have access.
                    if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        result[url.path] = data.base64EncodedString()
                    }
                }
                return result
            }.value

            var fileDoc = SlideshowFileDocument(photos: photos, settings: docSettings)
            fileDoc.document.faceRectsByPath = faceRects.isEmpty ? nil : faceRects
            fileDoc.document.bookmarksByPath = bookmarksByPath.isEmpty ? nil : bookmarksByPath
            exportDocument = fileDoc

            isSaving = true
        }
    }

    // MARK: - Export

    @MainActor
    private func beginExport() {
        guard !slideshowState.isEmpty else { return }

        // Show save panel to select output location
        let savePanel = NSSavePanel()
        savePanel.title = "Export Video"
        savePanel.nameFieldLabel = "Export As:"
        savePanel.nameFieldStringValue = "My Slideshow"
        savePanel.allowedContentTypes = [.quickTimeMovie]
        savePanel.canCreateDirectories = true

        // Use last export directory if available
        if let lastDir = settings.lastExportDirectory {
            savePanel.directoryURL = lastDir
        }

        savePanel.begin { [self] response in
            guard response == .OK, let outputURL = savePanel.url else { return }

            // Save the directory for next time
            settings.lastExportDirectory = outputURL.deletingLastPathComponent()

            // Reset progress and start export
            exportProgress.reset()
            isExporting = true

            // Start the export process
            Task {
                await performExport(to: outputURL)
            }
        }
    }

    @MainActor
    private func performExport(to outputURL: URL) async {
        let photos = slideshowState.photos

        do {
            // Remove existing file if present (NSSavePanel already confirmed overwrite)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }

            let coordinator = ExportCoordinator.create(
                photos: photos,
                settings: settings,
                preset: exportPreset,
                progress: exportProgress
            )

            try await coordinator.export(to: outputURL)

            // Success
            await MainActor.run {
                exportProgress.outputURL = outputURL
                exportProgress.phase = .completed
            }
        } catch {
            if exportProgress.isCancelled {
                exportProgress.phase = .cancelled
                // Clean up partial file
                try? FileManager.default.removeItem(at: outputURL)
            } else {
                // Enhanced error messages for AudioQueue issues
                let errorMessage: String
                let errorDescription = error.localizedDescription

                if errorDescription.contains("AudioQueue") ||
                   errorDescription.contains("reporterIDs") ||
                   errorDescription.contains("AudioObject") {
                    errorMessage = """
                    Audio export failed due to macOS sandbox restrictions with Photos Library videos.

                    To include video audio:
                    1. Open Photos.app
                    2. Select your videos
                    3. File → Export → Export Unmodified Original
                    4. Add the exported videos to your slideshow

                    Or, restart export and choose 'Continue Without Video Audio'.
                    """
                } else {
                    errorMessage = errorDescription
                }

                await MainActor.run {
                    exportProgress.phase = .failed(errorMessage)
                }
            }
        }
    }
}

// MARK: - FileDocument for Save

/// Wrapper for fileExporter compatibility
struct SlideshowFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.softburn] }
    static var writableContentTypes: [UTType] { [.softburn] }
    
    var document: SlideshowDocument
    
    init(photos: [MediaItem], settings: SlideshowDocument.Settings? = nil) {
        self.document = SlideshowDocument(photos: photos)
        if let settings = settings {
            self.document.settings = settings
        }
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

// MARK: - Slideshow Window Controller

/// Manages the full-screen slideshow window
class SlideshowWindowController: NSObject, NSWindowDelegate {
    static let shared = SlideshowWindowController()
    
    var window: NSWindow?
    var onClose: (() -> Void)?
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    
    private override init() {
        super.init()
    }
    
    func present(rootView: AnyView, backgroundColor: NSColor, displayID: PlaybackDisplayID = 0) {
        // Resolve target screen with fallback chain
        let targetScreen: NSScreen
        if displayID == PlaybackDisplaySelection.appDisplayID {
            // Use "app display" - the screen containing the main app window
            targetScreen = PlaybackDisplaySelection.currentAppScreen(excluding: self.window) ?? NSScreen.main ?? NSScreen.screens.first!
        } else {
            // Try to find the selected external display by ID
            if let screen = PlaybackDisplaySelection.screen(for: displayID) {
                targetScreen = screen
            } else {
                // Fallback: selected monitor disconnected, use app display
                targetScreen = PlaybackDisplaySelection.currentAppScreen(excluding: self.window) ?? NSScreen.main ?? NSScreen.screens.first!
            }
        }

        // Prevent the screen saver / display sleep while playing.
        ScreenIdleSleepController.shared.start()

        // Create the window once and reuse it. Avoiding window deallocation has proven far more stable.
        let window: NSWindow = {
            if let existing = self.window { return existing }

            let w = NSWindow(
                contentRect: targetScreen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.isOpaque = true
            w.hasShadow = false
            w.animationBehavior = .none
            w.collectionBehavior = [.canJoinAllSpaces, .stationary]

            // Keep the slideshow above everything.
            w.level = .screenSaver

            // Ensure we can accept key events.
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true

            // Delegate for lifecycle
            w.delegate = self

            self.window = w
            return w
        }()

        // Hide menu bar / dock during playback (restore on close)
        if previousPresentationOptions == nil {
            previousPresentationOptions = NSApp.presentationOptions
        }
        NSApp.presentationOptions = (previousPresentationOptions ?? []).union([.hideDock, .hideMenuBar])

        window.backgroundColor = backgroundColor
        window.setFrame(targetScreen.frame, display: true)
        window.contentView = NSHostingView(rootView: rootView)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    func close() {
        // Always ensure cursor is visible first
        NSCursor.unhide()

        // Re-enable normal macOS idle behavior.
        ScreenIdleSleepController.shared.stop()

        // Restore presentation options (menu bar / dock)
        if let previous = previousPresentationOptions {
            NSApp.presentationOptions = previous
            previousPresentationOptions = nil
        }

        guard let window = window else {
            onClose?()
            return
        }

        // Release SwiftUI tree immediately, but KEEP the NSWindow alive (no close/dealloc).
        window.contentView = nil
        window.orderOut(nil)

        let callback = onClose
        onClose = nil
        callback?()
    }
}

// MARK: - Previews

#Preview("LiquidGlass") {
    ContentView(toolbarStyleOverride: .liquidGlass)
        .environmentObject(AppSessionState.shared)
}

#Preview("Classic Toolbar") {
    ContentView(toolbarStyleOverride: .classic)
        .environmentObject(AppSessionState.shared)
}
