//
//  PostProcessingEffect.swift
//  SoftBurn
//
//  Created by Piero Sierra on 11/01/2026.
//

import SwiftUI

// MARK: - Post-Processing Effect View Modifier

/// Applies GPU-accelerated post-processing effects to slideshow content.
/// Effects are stateless, lightweight, and designed for 60fps playback.
struct PostProcessingEffectModifier: ViewModifier {
    let effect: SlideshowDocument.Settings.PostProcessingEffect
    
    func body(content: Content) -> some View {
        switch effect {
        case .none:
            content
            
        case .monochrome:
            // Clean, documentary-neutral monochrome
            // Remove all chroma information, preserve luminance evenly
            content
                .saturation(0)
            
        case .silvertone:
            // Subtle tonal depth reminiscent of silver gelatin prints
            // Cool, silvery tint with slightly increased highlight brightness
            content
                .saturation(0)
                .brightness(0.02)
                .colorMultiply(Color(red: 0.94, green: 0.96, blue: 1.0))
            
        case .sepia:
            // Classic, restrained sepia without nostalgia exaggeration
            // Warm brown tonal mapping with gentle highlights
            content
                .saturation(0)
                .colorMultiply(Color(red: 1.0, green: 0.92, blue: 0.78))
        }
    }
}

// MARK: - View Extension

extension View {
    /// Applies a post-processing effect to the view content.
    /// Effects are GPU-accelerated and designed for 60fps playback.
    /// - Parameter effect: The effect to apply (or `.none` for no processing)
    func postProcessingEffect(_ effect: SlideshowDocument.Settings.PostProcessingEffect) -> some View {
        modifier(PostProcessingEffectModifier(effect: effect))
    }
}
