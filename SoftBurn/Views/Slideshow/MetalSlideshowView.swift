//
//  MetalSlideshowView.swift
//  SoftBurn
//
//  Metal-based slideshow renderer used when Patina is enabled.
//  Renders media + geometry into an offscreen texture, then applies Patina post-processing.
//

import SwiftUI
import MetalKit

struct MetalSlideshowView: NSViewRepresentable {
    @ObservedObject var playerState: SlideshowPlayerState
    @ObservedObject var settings: SlideshowSettings

    func makeNSView(context: Context) -> MetalSlideshowMTKView {
        let v = MetalSlideshowMTKView()
        v.update(playerState: playerState, settings: settings)
        return v
    }

    func updateNSView(_ nsView: MetalSlideshowMTKView, context: Context) {
        nsView.update(playerState: playerState, settings: settings)
    }
}

final class MetalSlideshowMTKView: MTKView, MTKViewDelegate {
    private var renderer: MetalSlideshowRenderer?

    private var playerState: SlideshowPlayerState?
    private var settings: SlideshowSettings?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        guard let device else { return }
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self

        // Construct renderer on main actor (matches app isolation defaults)
        renderer = MetalSlideshowRenderer(device: device)
    }

    func update(playerState: SlideshowPlayerState, settings: SlideshowSettings) {
        self.playerState = playerState
        self.settings = settings
        renderer?.update(playerState: playerState, settings: settings, drawableSize: drawableSize)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.drawableSizeWillChange(size: size)
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let renderer,
              let playerState,
              let settings else { return }

        // SwiftUI may not call `updateNSView` for internal @Published mutations on reference-type inputs.
        // Make the renderer "pull" current playback state every frame, but only do GPU uploads when IDs change.
        renderer.update(playerState: playerState, settings: settings, drawableSize: drawableSize)
        renderer.draw(drawable: drawable, renderPassDescriptor: rpd, playerState: playerState, settings: settings)
    }
}

