//
//  ThumbnailView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// A view that displays a photo thumbnail with async loading
struct ThumbnailView: View {
    let photo: PhotoItem
    let isSelected: Bool
    let onTap: () -> Void
    
    @State private var thumbnail: NSImage?
    @State private var isLoading = true
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(.secondary)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                
                // Drag indicator overlay in upper-left corner
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(6)
                  /*  .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.5))
                    )*/
                    .padding(8)
                
                // Selection outline
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .task {
            await loadThumbnail()
        }
    }
    
    /// The current thumbnail image (exposed for drag preview)
    var currentThumbnail: NSImage? {
        thumbnail
    }
    
    private func loadThumbnail() async {
        isLoading = true
        defer { isLoading = false }
        
        // Check if file exists before loading
        guard FileManager.default.fileExists(atPath: photo.url.path) else {
            return
        }
        
        thumbnail = await ThumbnailCache.shared.thumbnail(for: photo.url)
    }
}

