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

struct ContentView: View {
    @StateObject private var slideshowState = SlideshowState()
    @ObservedObject private var settings = SlideshowSettings.shared
    @EnvironmentObject private var session: AppSessionState
    @State private var isImporting = false
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
    
    /// Height of our custom toolbar (used for content inset on older macOS).
    private let customToolbarHeight: CGFloat = 44
    
    var body: some View {
        ZStack {
            // Background color for the window
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()
            
            // Main content area (fills entire space, scrolls under toolbar)
            contentArea
                .ignoresSafeArea(edges: .top) // Extend under system toolbar on macOS 26
            
            // On older macOS, overlay our custom toolbar + fade gradient
            if #unavailable(macOS 26.0) {
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
            if #available(macOS 26.0, *) {
                // Leading controls - disabled when viewer is open
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: {
                        importMode = .photos
                        isImporting = true
                    }) {
                        Label("Add Media", systemImage: "plus")
                    }
                    .help("Add media")
                    .disabled(isShowingViewer)

                    Button(action: {
                        importMode = .slideshow
                        isImporting = true
                    }) {
                        Label("Open", systemImage: "folder")
                    }
                    .help("Open slideshow")
                    .disabled(isShowingViewer)

                    Button(action: {
                        beginSave()
                    }) {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .help("Save")
                    .disabled(slideshowState.isEmpty || isShowingViewer)
                }

                // Center status
                ToolbarItem(placement: .principal) {
                    if !slideshowState.isEmpty {
                        Text(photoCountText)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .opacity(isShowingViewer ? 0.4 : 1.0) // Dim when viewer is open
                    }
                }

                // Trailing controls - disabled when viewer is open
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
                        Image(systemName: "gearshape")
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
        .softBurnWindowToolbarLiquidGlass()
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
            case .success:
                session.markClean()
                session.performPendingActionAfterSuccessfulSave()
            case .failure(let error):
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
            backgroundColor: NSColor(settings.backgroundColor)
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
            // Left side buttons - disabled when viewer is open
            HStack(spacing: 12) {
                Button(action: {
                    importMode = .photos
                    isImporting = true
                }) {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                    Text("Add Media")
                }
                .help("Add media")
                .disabled(isShowingViewer)
                
                
                Button(action: {
                    importMode = .slideshow
                    isImporting = true
                }) {
                    Image(systemName: "folder")
                        .frame(width: 20, height: 20)
                    Text("Open")
                }
                .help("Open slideshow")
                .disabled(isShowingViewer)

                Button(action: {
                    beginSave()
                }) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 20, height: 20)
                    Text("Save")
                }
                .help("Save")
                .disabled(slideshowState.isEmpty || isShowingViewer)

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
                
                Button(action: {
                    showSettings.toggle()
                }) {
                    Image(systemName: "gearshape")
                        .frame(width: 20, height: 20)
                }
                .help("Slideshow settings")
                .disabled(isShowingViewer)
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopoverView(settings: settings)
                }
                
                Button(action: {
                    startSlideshow()
                }) {
                    Image(systemName: "play.fill")
                        .frame(width: 20, height: 20)
                        .foregroundStyle((slideshowState.isEmpty || isShowingViewer) ? Color.secondary : Color.blue)
                    Text("Play")
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
            return "  \(slideshowState.photoCount) photos  "
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
            await FaceDetectionCache.shared.prefetch(urls: photos.filter { $0.kind == .photo }.map(\.url))
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
            
            // Face detection prefetch (open-time only; never during playback)
            Task.detached(priority: .utility) {
                await FaceDetectionCache.shared.prefetch(urls: photos.filter { $0.kind == .photo }.map(\.url))
            }
            
        } catch {
            print("Error loading slideshow: \(error.localizedDescription)")
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
            let faceRects = await FaceDetectionCache.shared.snapshotFaceRectsByPath(for: photos.filter { $0.kind == .photo }.map(\.url))

            // Create security-scoped bookmarks for each photo so we can reopen across app launches.
            // This is best-effort; missing bookmarks just mean we may need the user to re-select those files later.
            let bookmarksByPath: [String: String] = await Task.detached(priority: .utility) {
                var result: [String: String] = [:]
                for url in photos.map(\.url) {
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
    
    func present(rootView: AnyView, backgroundColor: NSColor) {
        guard let screen = NSScreen.main else { return }

        // Prevent the screen saver / display sleep while playing.
        ScreenIdleSleepController.shared.start()

        // Create the window once and reuse it. Avoiding window deallocation has proven far more stable.
        let window: NSWindow = {
            if let existing = self.window { return existing }

            let w = NSWindow(
                contentRect: screen.frame,
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
        window.setFrame(screen.frame, display: true)
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

#Preview {
    ContentView()
}
