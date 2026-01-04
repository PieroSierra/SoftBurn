//
//  SlideshowState.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import Foundation
import SwiftUI
import Combine

/// Manages the state of the slideshow
@MainActor
class SlideshowState: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var selectedPhotoIDs: Set<UUID> = []
    
    /// Total number of photos
    var photoCount: Int {
        photos.count
    }
    
    /// Number of selected photos
    var selectedCount: Int {
        selectedPhotoIDs.count
    }
    
    /// Whether any photos are selected
    var hasSelection: Bool {
        !selectedPhotoIDs.isEmpty
    }
    
    /// Whether the slideshow is empty
    var isEmpty: Bool {
        photos.isEmpty
    }
    
    /// Add photos to the slideshow
    func addPhotos(_ newPhotos: [PhotoItem]) {
        photos.append(contentsOf: newPhotos)
    }
    
    /// Remove selected photos from the slideshow
    /// Note: This never deletes the original files
    func removeSelectedPhotos() {
        photos.removeAll { selectedPhotoIDs.contains($0.id) }
        selectedPhotoIDs.removeAll()
    }
    
    /// Toggle selection for a photo
    func toggleSelection(for photoID: UUID) {
        if selectedPhotoIDs.contains(photoID) {
            selectedPhotoIDs.remove(photoID)
        } else {
            selectedPhotoIDs.insert(photoID)
        }
    }
    
    /// Select a range of photos (for shift+click)
    func selectRange(from startID: UUID, to endID: UUID) {
        guard let startIndex = photos.firstIndex(where: { $0.id == startID }),
              let endIndex = photos.firstIndex(where: { $0.id == endID }) else {
            return
        }
        
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        for index in range {
            selectedPhotoIDs.insert(photos[index].id)
        }
    }
    
    /// Get the last selected photo ID (for range selection)
    var lastSelectedID: UUID? {
        // Simple implementation: return the first selected ID
        // In a more sophisticated implementation, we'd track the last clicked item
        selectedPhotoIDs.first
    }
    
    /// Select all photos
    func selectAll() {
        selectedPhotoIDs = Set(photos.map { $0.id })
    }
    
    /// Deselect all photos
    func deselectAll() {
        selectedPhotoIDs.removeAll()
    }
    
    /// Check if a photo is selected
    func isSelected(_ photoID: UUID) -> Bool {
        selectedPhotoIDs.contains(photoID)
    }
    
    /// Move a photo from one index to another
    func movePhoto(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < photos.count,
              destinationIndex >= 0, destinationIndex <= photos.count else {
            return
        }
        
        let photo = photos.remove(at: sourceIndex)
        let adjustedDestination = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        photos.insert(photo, at: min(adjustedDestination, photos.count))
    }
    
    /// Move a photo by ID to a new position (before the target photo)
    func movePhoto(withID sourceID: UUID, toPositionOf targetID: UUID) {
        guard let sourceIndex = photos.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = photos.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else {
            return
        }
        
        let photo = photos.remove(at: sourceIndex)
        let adjustedTarget = targetIndex > sourceIndex ? targetIndex : targetIndex
        photos.insert(photo, at: adjustedTarget)
    }
}

