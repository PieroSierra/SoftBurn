//
//  MediaGridCollectionView.swift
//  SoftBurn
//
//  AppKit-backed thumbnail grid using NSCollectionView for native macOS selection and drag behaviors.
//

import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let softburnMediaID = NSPasteboard.PasteboardType("com.softburn.media-id")
}

// MARK: - NSView Snapshot Helper

private extension NSView {
    /// Creates a snapshot image of the view's current appearance.
    func snapshot() -> NSImage? {
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmapRep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}

/// AppKit-backed thumbnail grid embedded in SwiftUI.
struct MediaGridCollectionView: NSViewRepresentable {
    let photos: [MediaItem]
    @Binding var selectedPhotoIDs: Set<UUID>

    /// Extra top inset so content can scroll under a translucent toolbar.
    var toolbarInset: CGFloat = 0

    /// Current zoom level in points (100, 140, 220, 320, 420, 680)
    var zoomPointSize: CGFloat = 220

    /// Callback when pinch gesture changes zoom level
    var onZoomLevelChange: ((Int) -> Void)?

    /// Called when user clicks an item (used to update "last selected index" anchor in SwiftUI).
    let onUserClickItem: (UUID) -> Void

    /// Double-click action: open viewer.
    let onOpenViewer: (UUID) -> Void

    /// Space/Enter: preview current selection.
    let onPreviewSelection: () -> Void

    /// External file drop (folders/images/movies).
    let onDropFiles: ([URL]) -> Void

    /// Local reorder (Photos.app-style insertion gap).
    let onReorderToIndex: ([UUID], Int) -> Void

    /// Called when a drag begins (used to ensure drag item is selected).
    let onDragStart: (UUID) -> Void

    /// Whitespace click (used to clear selection model).
    let onDeselectAll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MediaGridContainerView {
        let container = MediaGridContainerView()
        container.configure()
        container.toolbarInset = toolbarInset

        container.onPerformExternalDrop = { urls in
            self.onDropFiles(urls)
        }

        // Wire up zoom level change callback for pinch gestures
        container.onZoomLevelChange = { newLevelIndex in
            self.onZoomLevelChange?(newLevelIndex)
        }

        // Collection view callbacks
        container.collectionView.onClickedWhitespace = {
            self.onDeselectAll()
        }
        container.collectionView.onItemSingleClick = { id in
            self.onUserClickItem(id)
        }
        container.collectionView.onItemDoubleClick = { id in
            self.onOpenViewer(id)
        }
        container.collectionView.onPreviewSelection = {
            self.onPreviewSelection()
        }

        // Wire up coordinator
        context.coordinator.attach(to: container.collectionView, container: container)
        return container
    }

    func updateNSView(_ nsView: MediaGridContainerView, context: Context) {
        context.coordinator.parent = self
        nsView.toolbarInset = toolbarInset
        nsView.updateZoomLevel(to: zoomPointSize, animated: true)
        context.coordinator.apply(photos: photos, to: nsView.collectionView)
        context.coordinator.syncSelection(to: nsView.collectionView, selectedIDs: selectedPhotoIDs)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        var parent: MediaGridCollectionView

        private weak var collectionView: MediaCollectionView?
        private weak var container: MediaGridContainerView?
        private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>?

        private var currentPhotos: [MediaItem] = []
        private var itemByID: [UUID: MediaItem] = [:]
        private var idToIndexPath: [UUID: IndexPath] = [:]

        private var isApplyingSelectionFromSwiftUI = false
        private var didPushSelectionToSwiftUI = false
        private var currentlyDraggingIDs: [UUID] = []
        private var lastAppliedIDs: [UUID] = []
        private var lastAppliedContentKeys: [UInt64] = []

        // Drag placeholder (visual gap) support
        private let dropPlaceholderID = UUID()
        private var placeholderInsertionIndex: Int?

        init(parent: MediaGridCollectionView) {
            self.parent = parent
        }

        func attach(to collectionView: MediaCollectionView, container: MediaGridContainerView) {
            self.collectionView = collectionView
            self.container = container
            collectionView.delegate = self
            collectionView.onSelectionIndexPathsChanged = { [weak self, weak collectionView] in
                guard let self, let cv = collectionView else { return }
                self.updateSwiftUISelection(from: cv)
            }

            collectionView.register(MediaCollectionViewItem.self,
                                    forItemWithIdentifier: MediaCollectionViewItem.reuseIdentifier)

            let ds = NSCollectionViewDiffableDataSource<Int, UUID>(collectionView: collectionView) { [weak self] cv, indexPath, id in
                guard let self else { return nil }
                let item = cv.makeItem(withIdentifier: MediaCollectionViewItem.reuseIdentifier, for: indexPath)
                guard let mediaItem = item as? MediaCollectionViewItem else { return item }
                if id == self.dropPlaceholderID {
                    mediaItem.applyPlaceholder()
                } else if let model = self.itemByID[id] {
                    mediaItem.apply(model)
                }
                return mediaItem
            }

            self.dataSource = ds
            apply(photos: parent.photos, to: collectionView, animatingDifferences: false)
            syncSelection(to: collectionView, selectedIDs: parent.selectedPhotoIDs)

            // Drag and drop (reorder)
            collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
            collectionView.registerForDraggedTypes([.softburnMediaID, .fileURL])
        }

        func apply(photos: [MediaItem], to collectionView: MediaCollectionView, animatingDifferences: Bool = true) {
            let ids = photos.map(\.id)
            // Content key: if IDs are the same but per-item metadata changes (e.g. rotation),
            // we must still refresh visible cells so thumbnails update immediately.
            let contentKeys: [UInt64] = photos.map { item in
                var hasher = Hasher()
                hasher.combine(item.id)
                hasher.combine(item.url.path)
                hasher.combine(item.kind.rawValue)
                hasher.combine(item.rotationDegrees)
                return UInt64(bitPattern: Int64(hasher.finalize()))
            }

            let idsUnchanged = (ids == lastAppliedIDs)
            let contentUnchanged = (contentKeys == lastAppliedContentKeys)
            lastAppliedIDs = ids
            lastAppliedContentKeys = contentKeys

            if idsUnchanged, contentUnchanged {
                return
            }

            currentPhotos = photos
            itemByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
            idToIndexPath = Dictionary(uniqueKeysWithValues: photos.enumerated().map { idx, item in (item.id, IndexPath(item: idx, section: 0)) })

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(photos.map(\.id), toSection: 0)
            if idsUnchanged, !contentUnchanged {
                // Force NSCollectionViewItem reconfiguration for metadata-only updates.
                snapshot.reloadItems(ids)
            }

            dataSource?.apply(snapshot, animatingDifferences: animatingDifferences)
        }

        func syncSelection(to collectionView: MediaCollectionView, selectedIDs: Set<UUID>) {
            // If the selection change originated from this collection view (marquee/keyboard),
            // don't round-trip it back immediately — it can interfere with live marquee updates.
            if didPushSelectionToSwiftUI {
                didPushSelectionToSwiftUI = false
                return
            }

            isApplyingSelectionFromSwiftUI = true
            defer { isApplyingSelectionFromSwiftUI = false }

            let indexPaths = Set(selectedIDs.compactMap { idToIndexPath[$0] })
            // Avoid redundant selection churn
            if collectionView.selectionIndexPaths != indexPaths {
                collectionView.setSelectionIndexPaths(indexPaths)
            }
        }

        func updateSwiftUISelection(from collectionView: NSCollectionView) {
            guard !isApplyingSelectionFromSwiftUI else { return }
            let ids: Set<UUID> = Set(collectionView.selectionIndexPaths.compactMap { ip -> UUID? in
                guard ip.section == 0, ip.item >= 0, ip.item < currentPhotos.count else { return nil }
                return currentPhotos[ip.item].id
            })
            if parent.selectedPhotoIDs != ids {
                didPushSelectionToSwiftUI = true
                parent.selectedPhotoIDs = ids
            }
        }

        // MARK: NSCollectionViewDelegate (selection)

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            updateSwiftUISelection(from: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            updateSwiftUISelection(from: collectionView)
        }

        // MARK: NSCollectionViewDelegate (drag start)

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            let ordered: [UUID] = indexPaths
                .sorted { $0.item < $1.item }
                .compactMap { ip -> UUID? in
                    guard ip.section == 0, ip.item >= 0, ip.item < currentPhotos.count else { return nil }
                    return currentPhotos[ip.item].id
                }
            currentlyDraggingIDs = ordered
            container?.isDragging = true

            if let first = ordered.first {
                parent.onDragStart(first)
            }
        }

        func collectionView(_ collectionView: NSCollectionView, draggingImageForItemsAt indexPaths: Set<IndexPath>, with event: NSEvent, offset dragImageOffset: NSPointPointer) -> NSImage {
            // Build a Photos-like "pile" drag preview (image-only, no letterbox/background).
            let ordered = indexPaths.sorted { $0.item < $1.item }
            let maxPreviews = min(ordered.count, 3)
            let visible = Array(ordered.prefix(maxPreviews))

            let stackOffset: CGFloat = 12
            let padding: CGFloat = 20
            let maxEdge: CGFloat = 180

            // Extract per-item drag images (best-effort; visible items only).
            // Draw CGImage directly so we never get opaque/white backing from NSImage compositing.
            let images: [(cg: CGImage, size: CGSize)] = visible.compactMap { ip in
                guard let item = collectionView.item(at: ip) as? MediaCollectionViewItem,
                      let r = item.dragPreviewCGImage(maxEdge: maxEdge) else {
                    return nil
                }
                return r
            }

            // Fallback to default system drag image if we can't build anything.
            if images.isEmpty {
                // We can't call "super" here (Coordinator is NSObject). Provide a simple generic fallback.
                let count = max(1, indexPaths.count)
                let baseSize = CGSize(width: 120, height: 90)
                let img = NSImage(size: baseSize, flipped: false) { rect in
                    NSColor.clear.setFill()
                    rect.fill()

                    let r = rect.insetBy(dx: 12, dy: 12)
                    let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
                    NSColor.windowBackgroundColor.withAlphaComponent(0.85).setFill()
                    path.fill()

                    NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
                    path.lineWidth = 1
                    path.stroke()

                    if let icon = NSImage(systemSymbolName: "photo", accessibilityDescription: nil) {
                        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
                        let configured = icon.withSymbolConfiguration(config) ?? icon
                        configured.draw(in: CGRect(x: r.midX - 14, y: r.midY - 14, width: 28, height: 28))
                    }

                    if count > 1 {
                        let badge = "\(count)" as NSString
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                            .foregroundColor: NSColor.white
                        ]
                        let size = badge.size(withAttributes: attrs)
                        let badgeW = size.width + 14
                        let badgeH = size.height + 6
                        let bx = r.maxX - badgeW - 6
                        let by = r.maxY - badgeH - 6
                        let badgeRect = CGRect(x: bx, y: by, width: badgeW, height: badgeH)
                        NSColor.controlAccentColor.setFill()
                        NSBezierPath(roundedRect: badgeRect, xRadius: badgeH / 2, yRadius: badgeH / 2).fill()
                        badge.draw(at: CGPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2), withAttributes: attrs)
                    }

                    return true
                }
                dragImageOffset.pointee = NSPoint(x: -36, y: -36)
                return img
            }

            let widths = images.map(\.size.width)
            let heights = images.map(\.size.height)
            let contentW = (widths.max() ?? maxEdge) + CGFloat(images.count - 1) * stackOffset
            let contentH = (heights.max() ?? maxEdge) + CGFloat(images.count - 1) * stackOffset
            let canvasSize = CGSize(width: contentW + padding * 2, height: contentH + padding * 2)

            let dragImage = Self.makeTransparentDragImage(size: canvasSize) { ctx in
                for (idx, entry) in images.enumerated().reversed() {
                    let x = padding + CGFloat(idx) * stackOffset
                    let y = padding + CGFloat(idx) * stackOffset
                    let r = CGRect(origin: CGPoint(x: x, y: y), size: entry.size)
                    let corner: CGFloat = 12
                    let roundedPath = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)

                    // Use a transparency layer so the shadow applies to the clipped image shape.
                    ctx.saveGState()
                    ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor.black.withAlphaComponent(0.3).cgColor)
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

                    // Draw image clipped to rounded rect inside the transparency layer.
                    ctx.addPath(roundedPath)
                    ctx.clip()
                    ctx.interpolationQuality = .high
                    ctx.draw(entry.cg, in: r)

                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                }
            }

            // Place cursor near the top-left corner of the front (topmost) image.
            // Front image is at (padding, padding), so offset cursor to be just inside that.
            dragImageOffset.pointee = NSPoint(x: -(padding + 20), y: -(padding + 20))
            return dragImage
        }

        private static func makeTransparentDragImage(size: CGSize, draw: (CGContext) -> Void) -> NSImage {
            let w = max(1, Int(ceil(size.width)))
            let h = max(1, Int(ceil(size.height)))

            // Use CGBitmapContext directly for guaranteed transparency handling.
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

            guard let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return NSImage(size: size)
            }

            // Explicitly clear to fully transparent.
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

            draw(ctx)

            guard let cgImage = ctx.makeImage() else {
                return NSImage(size: size)
            }

            return NSImage(cgImage: cgImage, size: size)
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            currentlyDraggingIDs.removeAll()
            container?.isDragging = false
            hideDropPlaceholder(animated: true)
        }

        // MARK: NSCollectionViewDelegate (drag/drop reorder)

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < currentPhotos.count else { return nil }
            let id = currentPhotos[indexPath.item].id

            let pbItem = NSPasteboardItem()
            pbItem.setString(id.uuidString, forType: .softburnMediaID)
            return pbItem
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            let pb = draggingInfo.draggingPasteboard

            // External file drops (folders/images/movies).
            if pb.types?.contains(.fileURL) == true,
               (draggingInfo.draggingSource as? NSCollectionView) !== collectionView {
                proposedDropOperation.pointee = .on
                return .copy
            }

            // Local reorder only.
            guard draggingInfo.draggingSource as? NSCollectionView === collectionView else {
                return []
            }

            if pb.types?.contains(.softburnMediaID) != true {
                return []
            }

            // Use insertion drops; we render our own animated gap by inserting a placeholder item.
            proposedDropOperation.pointee = .before

            // Normalize insertion index to the model (exclude placeholder if it's already present).
            let proposed = proposedDropIndexPath.pointee
            var insertionIndex = max(0, min(proposed.item, currentPhotos.count))
            if let placeholderInsertionIndex,
               // If the placeholder is already inserted before the proposed position in the snapshot,
               // NSCollectionView's proposed index will be shifted by +1.
               proposed.item > placeholderInsertionIndex {
                insertionIndex = max(0, insertionIndex - 1)
            }
            showDropPlaceholder(at: insertionIndex, animated: true)
            return .move
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            let pb = draggingInfo.draggingPasteboard

            // External file drop
            if pb.types?.contains(.fileURL) == true,
               (draggingInfo.draggingSource as? NSCollectionView) !== collectionView {
                if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                   !urls.isEmpty {
                    parent.onDropFiles(urls)
                    return true
                }
                return false
            }

            guard !currentPhotos.isEmpty else { return false }

            let idsToMove: [UUID]
            if !currentlyDraggingIDs.isEmpty {
                idsToMove = currentlyDraggingIDs
            } else {
                // Fallback: read from pasteboard
                let pb = draggingInfo.draggingPasteboard
                let strings = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .softburnMediaID) }
                idsToMove = strings.compactMap(UUID.init(uuidString:))
            }

            guard !idsToMove.isEmpty else { return false }

            // With `.before`, `indexPath.item` is the insertion index (can be == count).
            let insertionIndex = placeholderInsertionIndex ?? max(0, min(indexPath.item, currentPhotos.count))
            // Clear placeholder state but don't apply a snapshot here — let the state change
            // from onReorderToIndex trigger a single animated update to the new order.
            placeholderInsertionIndex = nil
            parent.onReorderToIndex(idsToMove, insertionIndex)
            return true
        }

        private func showDropPlaceholder(at insertionIndex: Int, animated: Bool) {
            guard collectionView != nil else { return }
            let clamped = max(0, min(insertionIndex, currentPhotos.count))
            if placeholderInsertionIndex == clamped { return }
            placeholderInsertionIndex = clamped

            var ids = currentPhotos.map(\.id)
            ids.insert(dropPlaceholderID, at: clamped)

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids, toSection: 0)

            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    self.dataSource?.apply(snapshot, animatingDifferences: true)
                }
            } else {
                dataSource?.apply(snapshot, animatingDifferences: false)
            }
        }

        private func hideDropPlaceholder(animated: Bool) {
            guard placeholderInsertionIndex != nil else { return }
            placeholderInsertionIndex = nil
            guard let _ = collectionView else { return }

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(currentPhotos.map(\.id), toSection: 0)

            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    self.dataSource?.apply(snapshot, animatingDifferences: true)
                }
            } else {
                dataSource?.apply(snapshot, animatingDifferences: false)
            }
        }
    }
}

// MARK: - AppKit container + views

@MainActor
final class MediaGridContainerView: NSView {
    let scrollView = MediaGridScrollView()
    let collectionView = MediaCollectionView()

    private let flowLayout = NSCollectionViewFlowLayout()

    /// Current zoom point size (100, 140, 220, 320, 420, 680)
    private var currentZoomPointSize: CGFloat = 220

    /// Magnification gesture accumulator for debounced snapping
    private var magnificationAccumulator: CGFloat = 0
    private var debounceWorkItem: DispatchWorkItem?

    /// Flag to defer zoom during drag operations
    var isDragging: Bool = false

    /// Callback to update zoom state (set by coordinator)
    var onZoomLevelChange: ((Int) -> Void)?

    /// Extra top inset so content scrolls under the toolbar but starts below it.
    var toolbarInset: CGFloat = 0 {
        didSet { updateContentInsets() }
    }

    var onPerformExternalDrop: (([URL]) -> Void)?

    func configure() {
        wantsLayer = true
        // Transparent background so content shows through translucent toolbar
        layer?.backgroundColor = NSColor.clear.cgColor

        // Transparent scroll view background
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.registerForDraggedTypes([.fileURL])

        updateContentInsets()

        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true

        flowLayout.minimumInteritemSpacing = 16
        flowLayout.minimumLineSpacing = 16
        flowLayout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        flowLayout.scrollDirection = .vertical

        collectionView.collectionViewLayout = flowLayout
        // Transparent collection view background
        collectionView.backgroundColors = [.clear]
        collectionView.registerForDraggedTypes([.softburnMediaID, .fileURL])

        scrollView.documentView = collectionView
        addSubview(scrollView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        scrollView.onPerformExternalDrop = { [weak self] urls in
            self?.onPerformExternalDrop?(urls)
        }

        // Wire up magnification gesture for pinch-to-zoom
        collectionView.onMagnify = { [weak self] delta in
            self?.handleMagnification(delta)
        }
    }

    /// Handle trackpad magnification gesture (pinch-to-zoom)
    func handleMagnification(_ delta: CGFloat) {
        // Defer zoom during drag operations
        guard !isDragging else { return }

        // Accumulate magnification deltas
        magnificationAccumulator += delta

        // Debounce: schedule snap after gesture settles
        debounceWorkItem?.cancel()
        debounceWorkItem = DispatchWorkItem { [weak self] in
            self?.snapToNearestZoomLevel()
        }
        if let workItem = debounceWorkItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }

    /// Snap to the nearest discrete zoom level based on accumulated magnification
    private func snapToNearestZoomLevel() {
        let accumulated = magnificationAccumulator
        magnificationAccumulator = 0

        // Ignore tiny movements
        guard abs(accumulated) > 0.05 else { return }

        // Calculate proposed size based on current size and accumulated magnification
        let proposedSize = currentZoomPointSize * (1 + accumulated)

        // Find nearest zoom level
        let nearest = ZoomLevel.nearest(to: proposedSize)

        // Only update if it's a different level
        if nearest.pointSize != currentZoomPointSize {
            onZoomLevelChange?(nearest.id)
        }
    }
    
    private func updateContentInsets() {
        // Top inset accounts for toolbar; bottom gives whitespace for deselect + marquee.
        scrollView.contentInsets = NSEdgeInsets(top: toolbarInset, left: 0, bottom: 16, right: 0)
        // Auto-scroll to top of content when inset changes (prevents jump).
        scrollView.automaticallyAdjustsContentInsets = false
    }

    override func layout() {
        super.layout()
        updateItemSizingForCurrentZoom()
    }

    /// Overlay view used during zoom animations (snapshot of previous state)
    private var animationOverlayView: NSView?

    /// Updates the zoom level with optional animation
    /// - Parameters:
    ///   - pointSize: Target thumbnail size in points (100, 140, 220, 320, 420, 680)
    ///   - animated: Whether to animate the transition
    func updateZoomLevel(to pointSize: CGFloat, animated: Bool = true) {
        guard pointSize != currentZoomPointSize else { return }
        let oldSize = currentZoomPointSize
        currentZoomPointSize = pointSize

        let newSize = NSSize(width: pointSize, height: pointSize)
        guard flowLayout.itemSize != newSize else { return }

        if animated {
            performZoomCrossFadeAnimation(from: oldSize, to: pointSize)
        } else {
            flowLayout.itemSize = newSize
            flowLayout.invalidateLayout()
        }
    }

    /// Performs a cross-fade zoom animation where the old view scales and fades out
    /// while the new layout fades in.
    private func performZoomCrossFadeAnimation(from oldSize: CGFloat, to newSize: CGFloat) {
        // Cancel any in-progress animation
        if let existingOverlay = animationOverlayView {
            existingOverlay.layer?.removeAllAnimations()
            existingOverlay.removeFromSuperview()
            animationOverlayView = nil
        }

        // 1. Capture scroll position
        let savedScrollPosition = captureScrollPosition()

        // 2. Create snapshot
        guard let snapshotImage = scrollView.snapshot() else {
            flowLayout.itemSize = NSSize(width: newSize, height: newSize)
            flowLayout.invalidateLayout()
            return
        }

        // 3. Create overlay using a raw CALayer for direct animation control
        let overlay = NSView(frame: scrollView.frame)
        overlay.wantsLayer = true
        overlay.layer?.contents = snapshotImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        overlay.layer?.contentsGravity = .resizeAspectFill
        addSubview(overlay, positioned: .above, relativeTo: scrollView)
        animationOverlayView = overlay

        guard overlay.layer != nil else {
            flowLayout.itemSize = NSSize(width: newSize, height: newSize)
            flowLayout.invalidateLayout()
            return
        }

        // 4. Update layout while overlay covers it
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        collectionView.alphaValue = 0.0
        flowLayout.itemSize = NSSize(width: newSize, height: newSize)
        flowLayout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        restoreScrollPosition(savedScrollPosition)
        CATransaction.commit()

        // 5. Calculate animation parameters - animate the frame to scale from center
        let duration: TimeInterval = 0.25
        let scaleFactor = newSize / oldSize
        let currentFrame = overlay.frame
        let newWidth = currentFrame.width * scaleFactor
        let newHeight = currentFrame.height * scaleFactor
        let newX = currentFrame.origin.x - (newWidth - currentFrame.width) / 2
        let newY = currentFrame.origin.y - (newHeight - currentFrame.height) / 2
        let targetFrame = CGRect(x: newX, y: newY, width: newWidth, height: newHeight)

        // 6. Animate using NSView frame animation (which animator() supports)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            overlay.animator().frame = targetFrame
            overlay.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            guard let self else { return }
            overlay.removeFromSuperview()
            MainActor.assumeIsolated {
                self.animationOverlayView = nil
            }

            // Fade in new layout
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.collectionView.animator().alphaValue = 1.0
            }
        }
    }

    /// Capture scroll position as the first visible item and offset from top
    private func captureScrollPosition() -> (indexPath: IndexPath?, offsetFromTop: CGFloat) {
        let clipView = scrollView.contentView

        let visibleItems = collectionView.visibleItems()
        guard let firstVisibleItem = visibleItems.first,
              let indexPath = collectionView.indexPath(for: firstVisibleItem) else {
            return (nil, clipView.bounds.origin.y)
        }

        let itemFrame = firstVisibleItem.view.frame
        let offsetFromTop = clipView.bounds.origin.y - itemFrame.origin.y
        return (indexPath, offsetFromTop)
    }

    /// Restore scroll position after layout change
    private func restoreScrollPosition(_ savedPosition: (indexPath: IndexPath?, offsetFromTop: CGFloat)) {
        let clipView = scrollView.contentView

        if let indexPath = savedPosition.indexPath,
           let item = collectionView.item(at: indexPath) {
            let itemFrame = item.view.frame
            let newScrollY = itemFrame.origin.y + savedPosition.offsetFromTop

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var bounds = clipView.bounds
            bounds.origin.y = max(0, newScrollY)
            clipView.bounds = bounds
            scrollView.reflectScrolledClipView(clipView)
            CATransaction.commit()
        }
    }

    private func updateItemSizingForCurrentZoom() {
        // Use the current zoom point size directly as the item size
        let newSize = NSSize(width: currentZoomPointSize, height: currentZoomPointSize)
        if flowLayout.itemSize != newSize {
            flowLayout.itemSize = newSize
            flowLayout.invalidateLayout()
        }
    }
}

@MainActor
final class MediaGridScrollView: NSScrollView {
    var onPerformExternalDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if pb.types?.contains(.softburnMediaID) == true {
            return []
        }
        if pb.types?.contains(.fileURL) == true {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if pb.types?.contains(.softburnMediaID) == true {
            return false
        }
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        onPerformExternalDrop?(urls)
        return true
    }
}

@MainActor
final class MediaCollectionView: NSCollectionView {
    var onClickedWhitespace: (() -> Void)?
    var onItemSingleClick: ((UUID) -> Void)?
    var onItemDoubleClick: ((UUID) -> Void)?
    var onPreviewSelection: (() -> Void)?
    var onSelectionIndexPathsChanged: (() -> Void)?
    var onMagnify: ((CGFloat) -> Void)?  // Pinch gesture handler

    private var marqueeStartPoint: NSPoint?
    private var marqueeInitialSelection: Set<IndexPath> = []
    private var marqueeIsCommand: Bool = false

    /// Allows representable to set selection without triggering a scroll.
    func setSelectionIndexPaths(_ indexPaths: Set<IndexPath>) {
        // Important: this should REPLACE selection, not add to it.
        // `selectItems(at:)` only adds; it does not deselect items that are no longer in the set.
        deselectAll(nil)
        if !indexPaths.isEmpty {
            selectItems(at: indexPaths, scrollPosition: [])
        }
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let ip = indexPathForItem(at: point),
           ip.section == 0,
           let ds = dataSource as? NSCollectionViewDiffableDataSource<Int, UUID>,
           let id = ds.itemIdentifier(for: ip) {
            marqueeStartPoint = nil
            if event.clickCount >= 2 {
                onItemDoubleClick?(id)
            } else {
                onItemSingleClick?(id)
            }
            super.mouseDown(with: event)
            return
        }

        // Whitespace click: deselect all and allow marquee selection to begin.
        onClickedWhitespace?()
        marqueeStartPoint = point
        marqueeInitialSelection = selectionIndexPaths
        marqueeIsCommand = event.modifierFlags.contains(.command)
        deselectAll(nil)
        onSelectionIndexPathsChanged?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = marqueeStartPoint {
            let point = convert(event.locationInWindow, from: nil)
            let rect = NSRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )

            // Compute hits among visible items (fast) and update selection continuously (Photos-like).
            let hitIndexPaths: Set<IndexPath> = Set(visibleItems().compactMap { item in
                guard let ip = indexPath(for: item) else { return nil }
                return item.view.frame.intersects(rect) ? ip : nil
            })

            let newSelection: Set<IndexPath> = {
                if marqueeIsCommand {
                    // Toggle selection state for hit items (standard cmd-drag behavior).
                    var s = marqueeInitialSelection
                    for ip in hitIndexPaths {
                        if s.contains(ip) { s.remove(ip) } else { s.insert(ip) }
                    }
                    return s
                } else {
                    return hitIndexPaths
                }
            }()

            if selectionIndexPaths != newSelection {
                setSelectionIndexPaths(newSelection)
                onSelectionIndexPathsChanged?()
            }

            autoscroll(with: event)
            super.mouseDragged(with: event)
            return
        }

        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        marqueeStartPoint = nil
        marqueeInitialSelection = []
        marqueeIsCommand = false
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Space / Return / Enter should preview selection (Finder/Photos-like).
        switch event.keyCode {
        case 49, 36, 76: // space, return, keypad enter
            onPreviewSelection?()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }
}

// MARK: - Collection view item + cell view

@MainActor
final class MediaCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MediaCollectionViewItem")

    private let cellView = MediaThumbnailCellView()

    override func loadView() {
        view = cellView
    }

    override var isSelected: Bool {
        didSet {
            cellView.setSelected(isSelected)
        }
    }

    // Override to provide a clean drag image without the cell's background view.
    // Returns a rounded-rect clipped image at a reasonable drag preview size.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        let maxEdge: CGFloat = 160
        let corner: CGFloat = 10
        
        guard let (cg, size) = cellView.dragPreviewCGImage(maxEdge: maxEdge) else {
            return []
        }
        
        // Create a rounded-rect clipped version of the image.
        let w = Int(ceil(size.width))
        let h = Int(ceil(size.height))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            return []
        }
        
        let rect = CGRect(origin: .zero, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: rect)
        
        guard let clippedCG = ctx.makeImage() else {
            return []
        }
        
        let image = NSImage(cgImage: clippedCG, size: size)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = CGRect(origin: .zero, size: size)
        return [component]
    }

    func apply(_ media: MediaItem) {
        cellView.configure(with: media)
    }

    func applyPlaceholder() {
        cellView.configureAsPlaceholder()
    }

    func dragPreviewImage(maxEdge: CGFloat) -> NSImage? {
        cellView.dragPreviewImage(maxEdge: maxEdge)
    }

    func dragPreviewCGImage(maxEdge: CGFloat) -> (CGImage, CGSize)? {
        cellView.dragPreviewCGImage(maxEdge: maxEdge)
    }
}

@MainActor
final class MediaThumbnailCellView: NSView {
    private let backgroundView = NSView()
    private let imageContainer = NSView()
    private let imageLayer = CALayer()
    private let progress = NSProgressIndicator()
    private let placeholder = NSImageView()

    private let durationContainer = NSView()
    private let durationEffect = NSVisualEffectView()
    private let durationLabel = NSTextField(labelWithString: "")

    private let selectionOverlay = NSView()
    private let outerSelectionLayer = CAShapeLayer()
    private let innerSelectionLayer = CAShapeLayer()

    private var currentID: UUID?
    private var currentImagePixelSize: CGSize?
    private var currentImageRect: CGRect = .zero
    private var thumbnailTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    deinit {
        thumbnailTask?.cancel()
        durationTask?.cancel()
    }

    private func build() {
        wantsLayer = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        backgroundView.layer?.shadowOpacity = 1
        backgroundView.layer?.shadowRadius = 2
        backgroundView.layer?.shadowOffset = CGSize(width: 0, height: -1)

        imageContainer.wantsLayer = true
        imageContainer.layer?.backgroundColor = NSColor.clear.cgColor
        imageContainer.layer?.masksToBounds = false

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        imageLayer.cornerRadius = 8
        imageLayer.backgroundColor = NSColor.clear.cgColor
        imageLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "cornerRadius": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull()
        ]
        imageContainer.layer?.addSublayer(imageLayer)

        placeholder.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        placeholder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        placeholder.contentTintColor = .secondaryLabelColor

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        durationEffect.material = .hudWindow
        durationEffect.blendingMode = .withinWindow
        durationEffect.state = .active
        durationEffect.wantsLayer = true
        durationEffect.layer?.cornerRadius = 999
        durationEffect.layer?.masksToBounds = true

        durationLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white

        durationContainer.wantsLayer = true
        durationContainer.isHidden = true

        selectionOverlay.wantsLayer = true
        selectionOverlay.layer?.backgroundColor = NSColor.clear.cgColor
        selectionOverlay.layer?.masksToBounds = false

        addSubview(backgroundView)
        addSubview(imageContainer)
        addSubview(progress)
        addSubview(placeholder)
        addSubview(durationContainer)
        addSubview(selectionOverlay)

        durationContainer.addSubview(durationEffect)
        durationEffect.addSubview(durationLabel)

        // Selection layers
        outerSelectionLayer.fillColor = nil
        outerSelectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        outerSelectionLayer.lineWidth = 3

        innerSelectionLayer.fillColor = nil
        innerSelectionLayer.lineWidth = 2

        // Draw selection ABOVE the thumbnail image, without clipping so the blue stroke can sit around the tile.
        selectionOverlay.layer?.addSublayer(outerSelectionLayer)
        selectionOverlay.layer?.addSublayer(innerSelectionLayer)
        outerSelectionLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        innerSelectionLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]

        outerSelectionLayer.isHidden = true
        innerSelectionLayer.isHidden = true

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        // Duration pill is laid out manually (avoid Auto Layout collapsing the container).
        durationContainer.translatesAutoresizingMaskIntoConstraints = true
        durationEffect.translatesAutoresizingMaskIntoConstraints = true
        durationLabel.translatesAutoresizingMaskIntoConstraints = true
        selectionOverlay.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageContainer.topAnchor.constraint(equalTo: topAnchor),
            imageContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),

            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Drag icon is positioned manually relative to the aspect-fit image rect.
        ])

        NSLayoutConstraint.activate([
            selectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        backgroundView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        innerSelectionLayer.strokeColor = NSColor.textBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        backgroundView.layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        layoutImageLayer()
        updateSelectionPaths()
        layoutDurationPill()
    }

    func setSelected(_ isSelected: Bool) {
        outerSelectionLayer.isHidden = !isSelected
        innerSelectionLayer.isHidden = !isSelected
    }

    private func updateSelectionPaths() {
        let corner: CGFloat = 8
        let outerRect = selectionOverlay.bounds

        // Make the inner border sit immediately inside the blue stroke (no visible gap).
        let outerLW = outerSelectionLayer.lineWidth
        let innerLW = innerSelectionLayer.lineWidth
        let innerInset = (outerLW / 2.0) + (innerLW / 2.0)

        outerSelectionLayer.frame = outerRect
        innerSelectionLayer.frame = outerRect

        // Selection follows the displayed image rect (portrait/landscape), not the square cell.
        let r = currentImageRect.isEmpty ? outerRect : currentImageRect
        outerSelectionLayer.path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
        innerSelectionLayer.path = CGPath(
            roundedRect: r.insetBy(dx: innerInset, dy: innerInset),
            cornerWidth: max(0, corner - innerInset),
            cornerHeight: max(0, corner - innerInset),
            transform: nil
        )
    }

    private func layoutDurationPill() {
        guard !durationContainer.isHidden else { return }

        let inset: CGFloat = 8
        let paddingX: CGFloat = 8
        let paddingY: CGFloat = 4

        let labelSize = durationLabel.intrinsicContentSize
        let labelWidth = ceil(labelSize.width) + 2  // Add small buffer to prevent clipping
        let pillW = labelWidth + paddingX * 2
        let pillH = labelSize.height + paddingY * 2

        let anchorRect = currentImageRect.isEmpty ? bounds : currentImageRect
        let origin = CGPoint(x: anchorRect.maxX - inset - pillW, y: anchorRect.minY + inset)

        durationContainer.frame = CGRect(origin: origin, size: CGSize(width: pillW, height: pillH))
        durationEffect.frame = durationContainer.bounds
        durationLabel.frame = CGRect(x: paddingX, y: paddingY, width: labelWidth, height: labelSize.height)
        durationEffect.layer?.cornerRadius = pillH / 2
    }

    private func layoutImageLayer() {
        let container = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let px = currentImagePixelSize, px.width > 0, px.height > 0 else {
            currentImageRect = container
            imageLayer.frame = container
            return
        }

        let scale = min(container.width / px.width, container.height / px.height)
        let fitted = CGSize(width: px.width * scale, height: px.height * scale)
        let origin = CGPoint(x: (container.width - fitted.width) / 2.0, y: (container.height - fitted.height) / 2.0)
        let rect = CGRect(origin: origin, size: fitted).integral
        currentImageRect = rect
        imageLayer.frame = rect
        imageLayer.cornerRadius = 8
    }

    func configure(with media: MediaItem) {
        // Ensure placeholder state is cleared.
        setPlaceholderUI(isPlaceholder: false)
        currentID = media.id

        // Reset UI
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
        currentImagePixelSize = nil
        progress.startAnimation(nil)
        placeholder.isHidden = true
        durationContainer.isHidden = true
        durationLabel.stringValue = ""

        thumbnailTask?.cancel()
        durationTask?.cancel()

        let id = media.id
        thumbnailTask = Task {
            // Use MediaItem-based method to support both filesystem and Photos Library
            let thumb = await ThumbnailCache.shared.thumbnail(for: media)
            await MainActor.run { [weak self] in
                guard let self, self.currentID == id else { return }
                self.progress.stopAnimation(nil)
                if let thumb, let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    self.currentImagePixelSize = CGSize(width: cg.width, height: cg.height)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.imageLayer.contents = cg
                    CATransaction.commit()
                    self.placeholder.isHidden = true
                    self.needsLayout = true
                } else {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.imageLayer.contents = nil
                    CATransaction.commit()
                    self.currentImagePixelSize = nil
                    self.placeholder.isHidden = false
                    self.needsLayout = true
                }
            }
        }

        if media.kind == .video {
            durationTask = Task {
                // Use MediaItem-based method to support both filesystem and Photos Library
                let text = await VideoMetadataCache.shared.durationString(for: media)
                await MainActor.run { [weak self] in
                    guard let self, self.currentID == id else { return }
                    if let text {
                        self.durationLabel.stringValue = text
                        self.durationContainer.isHidden = false
                        self.needsLayout = true
                    } else {
                        self.durationContainer.isHidden = true
                    }
                }
            }
        }
    }

    func configureAsPlaceholder() {
        thumbnailTask?.cancel()
        durationTask?.cancel()
        currentID = nil
        currentImagePixelSize = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
        setPlaceholderUI(isPlaceholder: true)
    }

    private func setPlaceholderUI(isPlaceholder: Bool) {
        backgroundView.isHidden = isPlaceholder
        imageContainer.isHidden = isPlaceholder
        progress.isHidden = isPlaceholder
        placeholder.isHidden = true
        durationContainer.isHidden = true
        outerSelectionLayer.isHidden = true
        innerSelectionLayer.isHidden = true
        if isPlaceholder {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = nil
            CATransaction.commit()
            currentImagePixelSize = nil
            progress.stopAnimation(nil)
        }
        needsLayout = true
    }

    func dragPreviewImage(maxEdge: CGFloat) -> NSImage? {
        guard let contents = imageLayer.contents else { return nil }
        let cg = contents as! CGImage
        let px = CGSize(width: cg.width, height: cg.height)
        guard px.width > 0, px.height > 0 else { return nil }

        let scale = min(maxEdge / px.width, maxEdge / px.height)
        let size = CGSize(width: floor(px.width * scale), height: floor(px.height * scale))

        return NSImage(size: size, flipped: false) { rect in
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.clear(rect)
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: rect)
            }
            return true
        }
    }

    func dragPreviewCGImage(maxEdge: CGFloat) -> (CGImage, CGSize)? {
        guard let contents = imageLayer.contents else { return nil }
        let cg = contents as! CGImage
        let px = CGSize(width: cg.width, height: cg.height)
        guard px.width > 0, px.height > 0 else { return nil }

        let scale = min(maxEdge / px.width, maxEdge / px.height)
        let size = CGSize(width: floor(px.width * scale), height: floor(px.height * scale))
        return (cg, size)
    }
}


