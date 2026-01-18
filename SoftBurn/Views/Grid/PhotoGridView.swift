//
//  PhotoGridView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI

/// Grid view displaying photo thumbnails
struct PhotoGridView: View {
    let photos: [MediaItem]
    @Binding var selectedPhotoIDs: Set<UUID>
    var toolbarInset: CGFloat = 0
    let onUserClickItem: (UUID) -> Void
    let onOpenViewer: (UUID) -> Void
    let onPreviewSelection: () -> Void
    let onDrop: ([URL]) -> Void
    let onReorderToIndex: ([UUID], Int) -> Void // sourceIDs (all selected), destination insertion index
    let onDragStart: (UUID) -> Void // Called when drag starts to select the item
    let onDeselectAll: () -> Void // Called when clicking on whitespace
    
    var body: some View {
        MediaGridCollectionView(
            photos: photos,
            selectedPhotoIDs: $selectedPhotoIDs,
            toolbarInset: toolbarInset,
            onUserClickItem: onUserClickItem,
            onOpenViewer: onOpenViewer,
            onPreviewSelection: onPreviewSelection,
            onDropFiles: onDrop,
            onReorderToIndex: onReorderToIndex,
            onDragStart: onDragStart,
            onDeselectAll: onDeselectAll
        )
    }
}


