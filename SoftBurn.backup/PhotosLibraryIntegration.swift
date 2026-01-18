//
//  PhotosLibraryIntegration.swift
//  SoftBurn
//
//  Created by SoftBurn on 14/01/2026.
//

import SwiftUI
import Photos

/// View modifier that adds Photos Library import functionality (sheet only)
/// PHPickerViewController handles its own privacy and permissions
struct PhotosLibraryIntegration: ViewModifier {
    @Binding var isImportingFromPhotos: Bool
    let onSelection: ([PHAsset]) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isImportingFromPhotos) {
                PhotosPickerView(onSelection: onSelection)
                    .frame(minWidth: 800, minHeight: 600)
                    .frame(idealWidth: 1000, idealHeight: 700)
            }
    }
}

extension View {
    func photosLibraryIntegration(
        isImportingFromPhotos: Binding<Bool>,
        onSelection: @escaping ([PHAsset]) -> Void
    ) -> some View {
        modifier(PhotosLibraryIntegration(
            isImportingFromPhotos: isImportingFromPhotos,
            onSelection: onSelection
        ))
    }
}
