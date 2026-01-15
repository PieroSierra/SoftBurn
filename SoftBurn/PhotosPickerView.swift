//
//  PhotosPickerView.swift
//  SoftBurn
//
//  Created by Claude Code on 14/01/2026.
//

import SwiftUI
import PhotosUI

/// SwiftUI wrapper for PHPickerViewController to select photos/videos from Photos Library
struct PhotosPickerView: NSViewControllerRepresentable {
    let onSelection: ([PHAsset]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeNSViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 0 // unlimited selection
        config.filter = .any(of: [.images, .videos])

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateNSViewController(_ nsViewController: PHPickerViewController, context: Context) {
        // No updates needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotosPickerView

        init(parent: PhotosPickerView) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            print("📸 Picker finished with \(results.count) results")

            // Convert results to PHAssets
            var assets: [PHAsset] = []

            for result in results {
                // Get the asset identifier
                if let assetIdentifier = result.assetIdentifier {
                    print("📸 Processing asset: \(assetIdentifier)")
                    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
                    if let asset = fetchResult.firstObject {
                        assets.append(asset)
                        print("📸 Successfully fetched asset")
                    } else {
                        print("📸 Failed to fetch asset")
                    }
                } else {
                    print("📸 No asset identifier in result")
                }
            }

            print("📸 Total assets converted: \(assets.count)")

            // Call selection handler
            parent.onSelection(assets)

            // Dismiss picker
            picker.dismiss(nil)
        }
    }
}
