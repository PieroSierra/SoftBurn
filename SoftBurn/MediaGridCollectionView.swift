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

/// AppKit-backed thumbnail grid embedded in SwiftUI.
struct MediaGridCollectionView: NSViewRepresentable {
    let photos: [MediaItem]
    @Binding var selectedPhotoIDs: Set<UUID>

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

        container.onPerformExternalDrop = { urls in
            self.onDropFiles(urls)
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
        context.coordinator.attach(to: container.collectionView)
        return container
    }

    func updateNSView(_ nsView: MediaGridContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(photos: photos, to: nsView.collectionView)
        context.coordinator.syncSelection(to: nsView.collectionView, selectedIDs: selectedPhotoIDs)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        var parent: MediaGridCollectionView

        private weak var collectionView: MediaCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<Int, UUID>?

        private var currentPhotos: [MediaItem] = []
        private var itemByID: [UUID: MediaItem] = [:]
        private var idToIndexPath: [UUID: IndexPath] = [:]

        private var isApplyingSelectionFromSwiftUI = false
        private var didPushSelectionToSwiftUI = false
        private var currentlyDraggingIDs: [UUID] = []
        private var lastAppliedIDs: [UUID] = []

        // Drag placeholder (visual gap) support
        private let dropPlaceholderID = UUID()
        private var placeholderInsertionIndex: Int?

        init(parent: MediaGridCollectionView) {
            self.parent = parent
        }

        func attach(to collectionView: MediaCollectionView) {
            self.collectionView = collectionView
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
            if ids == lastAppliedIDs {
                return
            }
            lastAppliedIDs = ids

            currentPhotos = photos
            itemByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
            idToIndexPath = Dictionary(uniqueKeysWithValues: photos.enumerated().map { idx, item in (item.id, IndexPath(item: idx, section: 0)) })

            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(photos.map(\.id), toSection: 0)

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

            if let first = ordered.first {
                parent.onDragStart(first)
            }
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
            currentlyDraggingIDs.removeAll()
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
            hideDropPlaceholder(animated: false)
            parent.onReorderToIndex(idsToMove, insertionIndex)
            return true
        }

        private func showDropPlaceholder(at insertionIndex: Int, animated: Bool) {
            guard let collectionView else { return }
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

    var onPerformExternalDrop: (([URL]) -> Void)?

    func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.registerForDraggedTypes([.fileURL])

        // Ensure we always have whitespace below the last row for deselect + marquee start.
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 120, right: 0)

        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true

        flowLayout.minimumInteritemSpacing = 16
        flowLayout.minimumLineSpacing = 16
        flowLayout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 220, right: 16)
        flowLayout.scrollDirection = .vertical

        collectionView.collectionViewLayout = flowLayout
        collectionView.backgroundColors = [.controlBackgroundColor]
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
    }

    override func layout() {
        super.layout()
        updateItemSizing()
    }

    private func updateItemSizing() {
        guard let contentView = scrollView.contentView as NSClipView? else { return }
        let availableWidth = max(1, contentView.bounds.width - flowLayout.sectionInset.left - flowLayout.sectionInset.right)

        let minW: CGFloat = 180
        let maxW: CGFloat = 220
        let spacing: CGFloat = flowLayout.minimumInteritemSpacing

        let columns = max(1, Int(floor((availableWidth + spacing) / (minW + spacing))))
        let totalSpacing = CGFloat(max(0, columns - 1)) * spacing
        let rawItemW = floor((availableWidth - totalSpacing) / CGFloat(columns))
        let itemW = max(minW, min(maxW, rawItemW))

        let newSize = NSSize(width: itemW, height: itemW)
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

    func apply(_ media: MediaItem) {
        cellView.configure(with: media)
    }

    func applyPlaceholder() {
        cellView.configureAsPlaceholder()
    }
}

@MainActor
final class MediaThumbnailCellView: NSView {
    private let backgroundView = NSView()
    private let imageContainer = NSView()
    private let progress = NSProgressIndicator()
    private let placeholder = NSImageView()

    private let dragIcon = NSImageView()

    private let durationContainer = NSView()
    private let durationEffect = NSVisualEffectView()
    private let durationLabel = NSTextField(labelWithString: "")

    private let selectionOverlay = NSView()
    private let outerSelectionLayer = CAShapeLayer()
    private let innerSelectionLayer = CAShapeLayer()

    private var currentID: UUID?
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
        backgroundView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.10).cgColor
        backgroundView.layer?.shadowOpacity = 1
        backgroundView.layer?.shadowRadius = 2
        backgroundView.layer?.shadowOffset = CGSize(width: 0, height: -1)

        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = 8
        imageContainer.layer?.masksToBounds = true
        imageContainer.layer?.contentsGravity = .resizeAspectFill

        placeholder.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        placeholder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        placeholder.contentTintColor = .secondaryLabelColor

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        dragIcon.image = NSImage(systemSymbolName: "circle.grid.2x2.fill", accessibilityDescription: nil)
        dragIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        dragIcon.contentTintColor = .white

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
        addSubview(dragIcon)
        addSubview(durationContainer)
        addSubview(selectionOverlay)

        durationContainer.addSubview(durationEffect)
        durationEffect.addSubview(durationLabel)

        // Selection layers
        outerSelectionLayer.fillColor = nil
        outerSelectionLayer.strokeColor = NSColor.controlAccentColor.cgColor
        outerSelectionLayer.lineWidth = 3

        innerSelectionLayer.fillColor = nil
        innerSelectionLayer.strokeColor = NSColor.white.cgColor
        innerSelectionLayer.lineWidth = 2

        // Draw selection ABOVE the thumbnail image, without clipping so the blue stroke can sit around the tile.
        selectionOverlay.layer?.addSublayer(outerSelectionLayer)
        selectionOverlay.layer?.addSublayer(innerSelectionLayer)

        outerSelectionLayer.isHidden = true
        innerSelectionLayer.isHidden = true

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        dragIcon.translatesAutoresizingMaskIntoConstraints = false
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

            dragIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dragIcon.topAnchor.constraint(equalTo: topAnchor, constant: 14)
        ])

        NSLayoutConstraint.activate([
            selectionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func layout() {
        super.layout()
        backgroundView.layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
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

        // Make the white border sit immediately inside the blue stroke (no visible gap).
        let outerLW = outerSelectionLayer.lineWidth
        let innerLW = innerSelectionLayer.lineWidth
        let innerInset = (outerLW / 2.0) + (innerLW / 2.0)

        outerSelectionLayer.frame = outerRect
        innerSelectionLayer.frame = outerRect

        // Outer path is the full bounds so half the stroke renders outside the tile (looks "around" it).
        outerSelectionLayer.path = CGPath(roundedRect: outerRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        innerSelectionLayer.path = CGPath(
            roundedRect: outerRect.insetBy(dx: innerInset, dy: innerInset),
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
        let pillW = labelSize.width + paddingX * 2
        let pillH = labelSize.height + paddingY * 2

        let origin = CGPoint(
            x: bounds.maxX - inset - pillW,
            y: inset
        )

        durationContainer.frame = CGRect(origin: origin, size: CGSize(width: pillW, height: pillH))
        durationEffect.frame = durationContainer.bounds
        durationLabel.frame = CGRect(x: paddingX, y: paddingY, width: labelSize.width, height: labelSize.height)
        durationEffect.layer?.cornerRadius = pillH / 2
    }

    func configure(with media: MediaItem) {
        // Ensure placeholder state is cleared.
        setPlaceholderUI(isPlaceholder: false)
        currentID = media.id

        // Reset UI
        imageContainer.layer?.contents = nil
        progress.startAnimation(nil)
        placeholder.isHidden = true
        durationContainer.isHidden = true
        durationLabel.stringValue = ""

        thumbnailTask?.cancel()
        durationTask?.cancel()

        let url = media.url
        let id = media.id
        thumbnailTask = Task {
            let thumb = await ThumbnailCache.shared.thumbnail(for: url)
            await MainActor.run { [weak self] in
                guard let self, self.currentID == id else { return }
                self.progress.stopAnimation(nil)
                if let thumb, let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    self.imageContainer.layer?.contents = cg
                    self.placeholder.isHidden = true
                } else {
                    self.imageContainer.layer?.contents = nil
                    self.placeholder.isHidden = false
                }
            }
        }

        if media.kind == .video {
            durationTask = Task {
                let text = await VideoMetadataCache.shared.durationString(for: url)
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
        setPlaceholderUI(isPlaceholder: true)
    }

    private func setPlaceholderUI(isPlaceholder: Bool) {
        backgroundView.isHidden = isPlaceholder
        imageContainer.isHidden = isPlaceholder
        progress.isHidden = isPlaceholder
        placeholder.isHidden = true
        dragIcon.isHidden = isPlaceholder
        durationContainer.isHidden = true
        outerSelectionLayer.isHidden = true
        innerSelectionLayer.isHidden = true
        if isPlaceholder {
            imageContainer.layer?.contents = nil
            progress.stopAnimation(nil)
        }
    }
}


