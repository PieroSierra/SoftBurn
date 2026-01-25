//
//  MetalSlideshowRenderer.swift
//  SoftBurn
//
//  Metal renderer for Patina-enabled slideshow playback.
//  Two-pass pipeline:
//   1) Scene pass: clear to background, draw current/next media layers with transforms + Effects mapping
//   2) Patina pass: fullscreen post-processing on the scene texture -> drawable
//

import Foundation
import Metal
import MetalKit
import AppKit
import AVFoundation
import SwiftUI
import Photos

final class MetalSlideshowRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    // Scene pipeline (media layers)
    private let scenePipeline: MTLRenderPipelineState
    private let quadVertexBuffer: MTLBuffer
    private var currentLayerUniformBuffer: MTLBuffer
    private var nextLayerUniformBuffer: MTLBuffer

    // Patina pipeline (post-process)
    private let patinaPipeline: MTLRenderPipelineState
    private var patinaUniformBuffer: MTLBuffer
    private let patinaSeed: Float
    private let startTime: CFTimeInterval

    // Offscreen media texture (RGBA). Background is applied only at present time so Patina never affects it.
    private var sceneTexture: MTLTexture?

    // Cached photo textures (loaded directly from MediaItem URLs; avoids NSImage/HDR conversion issues)
    private struct PhotoKey: Hashable {
        enum Source: Hashable {
            case filesystem(url: URL, rotation: Int)
            case photosLibrary(localIdentifier: String, rotation: Int)
        }
        let source: Source

        var rotationDegrees: Int {
            switch source {
            case .filesystem(_, let rotation):
                return rotation
            case .photosLibrary(_, let rotation):
                return rotation
            }
        }

        // Convenience initializers
        init(url: URL, rotationDegrees: Int) {
            self.source = .filesystem(url: url, rotation: rotationDegrees)
        }

        init(photosLibraryLocalIdentifier: String, rotationDegrees: Int) {
            self.source = .photosLibrary(localIdentifier: photosLibraryLocalIdentifier, rotation: rotationDegrees)
        }

        init(from item: MediaItem) {
            switch item.source {
            case .filesystem(let url):
                self.source = .filesystem(url: url, rotation: item.rotationDegrees)
            case .photosLibrary(let localID, _):
                self.source = .photosLibrary(localIdentifier: localID, rotation: item.rotationDegrees)
            }
        }
    }
    private var currentPhotoTexture: MTLTexture?
    private var nextPhotoTexture: MTLTexture?
    private var currentPhotoKey: PhotoKey?
    private var nextPhotoKey: PhotoKey?

    /*
     * Fallback texture: stores the last successfully rendered "current" texture.
     * Used when the new current media (especially videos) hasn't decoded a frame yet.
     * This prevents the "hot pink flash" when transitioning to a video that's still
     * waiting for its first decoded frame.
     *
     * VIDEO FLASH FIX (January 2026):
     * When a video is promoted from next to current via advanceSlide(), there's a
     * window where currentVideoSource hasn't decoded frames yet. During this window,
     * we use this fallback texture (the last frame of the previous media) to prevent
     * showing the transparent placeholder through to the background.
     */
    private var fallbackCurrentTexture: MTLTexture?

    // Texture cache for Photos Library assets (to avoid reloading)
    private var photosLibraryTextureCache: [String: MTLTexture] = [:]
    private var photosLibraryLoadingSet: Set<String> = []

    /*
     * Video texture sources: Two separate instances for current and next slots.
     *
     * VIDEO FLASH FIX (January 2026):
     * When a video moves from next to current, we create a NEW AVPlayerItemVideoOutput
     * on currentVideoSource. This means currentVideoSource won't have decoded frames
     * immediately. However, nextVideoSource.lastTexture persists even after the player
     * is detached, so we can use it as a temporary fallback. See textureForSlot() for
     * the fallback logic.
     */
    private let currentVideoSource: VideoTextureSource
    private let nextVideoSource: VideoTextureSource
    private var currentVideoPlayerID: ObjectIdentifier?
    private var nextVideoPlayerID: ObjectIdentifier?

    init(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { fatalError("Failed to create MTLCommandQueue") }
        self.queue = q

        // Quad vertices: unit quad in NDC (-1..1), uv bottom-left origin.
        struct V { var p: SIMD2<Float>; var uv: SIMD2<Float> }
        let verts: [V] = [
            V(p: [-1, -1], uv: [0, 1]),
            V(p: [ 1, -1], uv: [1, 1]),
            V(p: [-1,  1], uv: [0, 0]),
            V(p: [ 1,  1], uv: [1, 0]),
        ]
        quadVertexBuffer = device.makeBuffer(bytes: verts, length: MemoryLayout<V>.stride * verts.count, options: [.storageModeShared])!

        // Separate uniform buffers for current and next layers to prevent GPU race conditions
        currentLayerUniformBuffer = device.makeBuffer(length: MemoryLayout<LayerUniforms>.stride, options: [.storageModeShared])!
        nextLayerUniformBuffer = device.makeBuffer(length: MemoryLayout<LayerUniforms>.stride, options: [.storageModeShared])!

        // Patina uniforms match PatinaShaders.metal
        // IMPORTANT: size must match `PatinaUniforms` exactly (it is much larger than 256 bytes).
        patinaUniformBuffer = device.makeBuffer(length: MemoryLayout<PatinaUniforms>.stride, options: [.storageModeShared])!
        patinaSeed = Float.random(in: 0...1000)
        startTime = CACurrentMediaTime()

        let library = device.makeDefaultLibrary()!

        // Scene pipeline
        let sceneDesc = MTLRenderPipelineDescriptor()
        sceneDesc.vertexFunction = library.makeFunction(name: "slideshowVertexShader")
        sceneDesc.fragmentFunction = library.makeFunction(name: "slideshowFragmentShader")
        sceneDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        sceneDesc.colorAttachments[0].isBlendingEnabled = true
        sceneDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        sceneDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        sceneDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        sceneDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        scenePipeline = try! device.makeRenderPipelineState(descriptor: sceneDesc)

        // Patina pipeline (fullscreen triangle from PatinaShaders.metal)
        let patinaDesc = MTLRenderPipelineDescriptor()
        patinaDesc.vertexFunction = library.makeFunction(name: "patinaVertexShader")
        patinaDesc.fragmentFunction = library.makeFunction(name: "patinaFragmentShader")
        patinaDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // No blending: Patina operates on the final composed scene (including background).
        patinaDesc.colorAttachments[0].isBlendingEnabled = false
        patinaPipeline = try! device.makeRenderPipelineState(descriptor: patinaDesc)

        currentVideoSource = VideoTextureSource(device: device)
        nextVideoSource = VideoTextureSource(device: device)
    }

    func drawableSizeWillChange(size: CGSize) {
        rebuildSceneTextureIfNeeded(drawableSize: size)
    }

    func update(playerState: SlideshowPlayerState, settings: SlideshowSettings, drawableSize: CGSize) {
        rebuildSceneTextureIfNeeded(drawableSize: drawableSize)

        // Update cached photo textures from MediaItem URLs (GPU path; no intermediate bitmaps).
        if !playerState.photos.isEmpty {
            let currentItem = playerState.photos[playerState.currentIndex]
            let nextIndex = (playerState.currentIndex + 1) % playerState.photos.count
            let nextItem = playerState.photos[nextIndex]

            // Handle current photo texture
            if currentItem.kind == .photo {
                let key = PhotoKey(from: currentItem)
                if currentPhotoKey != key || currentPhotoTexture == nil {
                    // Check if we can promote nextPhotoTexture (slide just advanced)
                    if nextPhotoKey == key, let tex = nextPhotoTexture {
                        // Promote: next becomes current (avoid flash by reusing already-loaded texture)
                        currentPhotoTexture = tex
                        currentPhotoKey = key
                    } else {
                        // Load fresh
                        currentPhotoTexture = loadPhotoTexture(from: key)
                        currentPhotoKey = currentPhotoTexture == nil ? nil : key
                    }
                }
            } else {
                currentPhotoTexture = nil
                currentPhotoKey = nil
            }

            // Handle next photo texture
            if nextItem.kind == .photo {
                let key = PhotoKey(from: nextItem)
                if nextPhotoKey != key || nextPhotoTexture == nil {
                    // Check if we can demote currentPhotoTexture (if looping back)
                    if currentPhotoKey == key, let tex = currentPhotoTexture {
                        nextPhotoTexture = tex
                        nextPhotoKey = key
                    } else {
                        nextPhotoTexture = loadPhotoTexture(from: key)
                        nextPhotoKey = nextPhotoTexture == nil ? nil : key
                    }
                }
            } else {
                nextPhotoTexture = nil
                nextPhotoKey = nil
            }
        } else {
            currentPhotoTexture = nil
            nextPhotoTexture = nil
            currentPhotoKey = nil
            nextPhotoKey = nil
        }

        // Wire video outputs if the players changed.
        if let pooledPlayer = playerState.currentVideo {
            let id = ObjectIdentifier(pooledPlayer)
            if currentVideoPlayerID != id {
                currentVideoPlayerID = id
                currentVideoSource.setPooledPlayer(pooledPlayer)
            }
        } else {
            currentVideoPlayerID = nil
            currentVideoSource.setPooledPlayer(nil)
        }

        if let pooledPlayer = playerState.nextVideo {
            let id = ObjectIdentifier(pooledPlayer)
            if nextVideoPlayerID != id {
                nextVideoPlayerID = id
                nextVideoSource.setPooledPlayer(pooledPlayer)
            }
        } else {
            nextVideoPlayerID = nil
            nextVideoSource.setPooledPlayer(nil)
        }
    }

    func draw(
        drawable: CAMetalDrawable,
        renderPassDescriptor: MTLRenderPassDescriptor,
        playerState: SlideshowPlayerState,
        settings: SlideshowSettings
    ) {
        guard let sceneTexture else { return }
        guard let cb = queue.makeCommandBuffer() else { return }

        // 1) Scene pass: clear to background + draw media layers into offscreen texture
        let sceneRPD = MTLRenderPassDescriptor()
        sceneRPD.colorAttachments[0].texture = sceneTexture
        sceneRPD.colorAttachments[0].loadAction = .clear
        sceneRPD.colorAttachments[0].storeAction = .store
        // Projector model: Patina affects the entire composed frame, including background.
        sceneRPD.colorAttachments[0].clearColor = settings.backgroundColor.metalClearColor

        if let enc = cb.makeRenderCommandEncoder(descriptor: sceneRPD) {
            enc.setRenderPipelineState(scenePipeline)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

            /*
             * SCENE COMPOSITION: Draw current and next media layers with crossfade.
             *
             * Timeline for a single slide cycle (e.g., 5s hold + 2s transition = 7s total):
             *
             *   animationProgress:  0.0 -------- 0.71 -------- 1.0
             *                       |            |             |
             *                       hold phase   transition    advanceSlide()
             *                                    begins        called
             *
             * RACE CONDITION FIX (January 2026):
             * There's a brief window when animationProgress reaches 1.0 but advanceSlide()
             * hasn't yet promoted the texture slots. During this window:
             *   - Current photo: drawn at 0% opacity (faded out)
             *   - Next photo: MUST be drawn at 100% opacity (fully visible)
             *
             * Without this fix, both photos would be invisible, causing a background flash.
             * The opacity calculation in makeLayerUniforms() handles this case explicitly.
             *
             * VIDEO DECODER DELAY FIX (January 2026):
             * When transitioning to a video, the decoder may not have produced a frame yet
             * even after advanceSlide() promotes the video to current. In this case, we
             * use a fallback texture (the last good current frame) to prevent showing
             * the transparent placeholder through to the background.
             */

            /*
             * Check if textures are ready BEFORE drawing either layer.
             * These values are used to adjust opacity and enable fallback rendering.
             */
            let nextTextureReady = nextSlotHasRealTexture(kind: playerState.nextKind)
            let currentTextureReady = currentSlotHasRealTexture(kind: playerState.currentKind)

            /*
             * Get the current texture, with fallback support for videos.
             * If current is a video with no decoded frames yet, use the fallback texture
             * (which contains the last good frame from the previous current media).
             */
            var currentTexture = textureForSlot(kind: playerState.currentKind, slot: .current)
            let usingFallback: Bool
            if playerState.currentKind == .video && !currentTextureReady {
                // Video has no decoded frame - use fallback if available
                if let fallback = fallbackCurrentTexture {
                    currentTexture = fallback
                    usingFallback = true
                } else {
                    usingFallback = false
                }
            } else {
                usingFallback = false
                // Current texture is valid - save it as fallback for future use
                if let tex = currentTexture, !usingFallback {
                    fallbackCurrentTexture = tex
                }
            }

            // Draw current (outgoing during transition, or sole photo during hold)
            if let tex = currentTexture {
                let u = makeLayerUniforms(
                    mediaTexture: tex,
                    drawableSize: CGSize(width: sceneTexture.width, height: sceneTexture.height),
                    playerState: playerState,
                    settings: settings,
                    slot: .current,
                    nextTextureReady: nextTextureReady
                )
                writeLayerUniforms(u, to: currentLayerUniformBuffer)
                enc.setVertexBuffer(currentLayerUniformBuffer, offset: 0, index: 1)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentBuffer(currentLayerUniformBuffer, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            /*
             * Draw next photo when animationProgress >= transitionStart.
             *
             * IMPORTANT: Do NOT add an upper bound check (animationProgress < 1.0) here!
             * The next photo must continue to be drawn even after progress reaches 1.0,
             * because advanceSlide() runs asynchronously and there's a race window where
             * the current photo is at 0% opacity but slots haven't been promoted yet.
             *
             * The opacity calculation ensures:
             *   - During transition (transitionStart <= progress < 1.0): crossfade
             *   - After transition (progress >= 1.0): next at 100%, current at 0%
             */
            let transitionStart = playerState.currentHoldDuration / playerState.totalSlideDuration
            let shouldDrawNext = playerState.transitionStyle != .plain &&
                                playerState.animationProgress >= transitionStart
            if shouldDrawNext,
               let tex = textureForSlot(kind: playerState.nextKind, slot: .next) {
                let u = makeLayerUniforms(
                    mediaTexture: tex,
                    drawableSize: CGSize(width: sceneTexture.width, height: sceneTexture.height),
                    playerState: playerState,
                    settings: settings,
                    slot: .next,
                    nextTextureReady: nextTextureReady
                )
                writeLayerUniforms(u, to: nextLayerUniformBuffer)
                enc.setVertexBuffer(nextLayerUniformBuffer, offset: 0, index: 1)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentBuffer(nextLayerUniformBuffer, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            enc.endEncoding()
        }

        // 2) Patina pass (or direct copy when Patina is .none)
        // When Patina is disabled, we copy the scene texture directly to the drawable.
        // This unified Metal path eliminates the need for the SwiftUI rendering path.
        if settings.patina == .none {
            // Direct blit from scene texture to drawable (no post-processing)
            blitSceneToDrawable(cb: cb, sceneTexture: sceneTexture, drawable: drawable)
        } else {
            // Patina post-processing pass: fullscreen effect on composed sceneTexture -> drawable
            // Clear black only as a safety default; we overwrite the entire drawable via fullscreen triangle.
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            if let enc = cb.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                enc.setRenderPipelineState(patinaPipeline)
                enc.setFragmentTexture(sceneTexture, index: 0)

                // Get current media rotation for VHS effects
                // During transition, use the current (outgoing) media's rotation
                let currentRotation: Int
                if playerState.currentKind == .video {
                    currentRotation = currentVideoSource.currentRotationDegrees
                } else if let key = currentPhotoKey {
                    currentRotation = key.rotationDegrees
                } else {
                    currentRotation = 0
                }

                writePatinaUniforms(effect: settings.patina, drawableTexture: drawable.texture, currentRotation: currentRotation)
                enc.setFragmentBuffer(patinaUniformBuffer, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }

        cb.present(drawable)
        cb.commit()
    }

    /// Direct blit from scene texture to drawable when Patina is disabled.
    /// This avoids the Patina post-processing pass for better performance.
    private func blitSceneToDrawable(cb: MTLCommandBuffer, sceneTexture: MTLTexture, drawable: CAMetalDrawable) {
        guard let blitEncoder = cb.makeBlitCommandEncoder() else { return }

        let origin = MTLOrigin(x: 0, y: 0, z: 0)
        let size = MTLSize(width: min(sceneTexture.width, drawable.texture.width),
                           height: min(sceneTexture.height, drawable.texture.height),
                           depth: 1)

        blitEncoder.copy(from: sceneTexture, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: origin, sourceSize: size,
                         to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: origin)
        blitEncoder.endEncoding()
    }

    // MARK: - Textures

    private func rebuildSceneTextureIfNeeded(drawableSize: CGSize) {
        let w = max(1, Int(drawableSize.width))
        let h = max(1, Int(drawableSize.height))
        guard sceneTexture?.width != w || sceneTexture?.height != h else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        sceneTexture = device.makeTexture(descriptor: desc)
    }

    private func loadPhotoTexture(from key: PhotoKey) -> MTLTexture? {
        switch key.source {
        case .filesystem(let url, _):
            return loadTextureFromFilesystem(url: url)
        case .photosLibrary(let localID, _):
            return loadTextureFromPhotosLibrary(localIdentifier: localID)
        }
    }

    private func loadTextureFromFilesystem(url: URL) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        return try? loader.newTexture(URL: url, options: [
            MTKTextureLoader.Option.SRGB: false,
            MTKTextureLoader.Option.origin: MTKTextureLoader.Origin.topLeft,
            MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
    }

    private func loadTextureFromPhotosLibrary(localIdentifier: String) -> MTLTexture? {
        // Check cache first
        if let cached = photosLibraryTextureCache[localIdentifier] {
            return cached
        }

        // If already loading, return nil (will be available next frame)
        if photosLibraryLoadingSet.contains(localIdentifier) {
            return nil
        }

        // Mark as loading
        photosLibraryLoadingSet.insert(localIdentifier)

        // Start async load (don't block!)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            if let cgImage = await PhotosLibraryImageLoader.shared.loadFullResolutionCGImage(localIdentifier: localIdentifier) {

                let loader = MTKTextureLoader(device: self.device)
                do {
                    let texture = try await loader.newTexture(cgImage: cgImage, options: [
                        MTKTextureLoader.Option.SRGB: false,
                        MTKTextureLoader.Option.origin: MTKTextureLoader.Origin.topLeft,
                        MTKTextureLoader.Option.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        MTKTextureLoader.Option.textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                    ])


                    // Store in cache (must be on main thread to avoid race conditions)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.photosLibraryTextureCache[localIdentifier] = texture
                        self.photosLibraryLoadingSet.remove(localIdentifier)
                    }
                } catch {
                    _ = await MainActor.run { [weak self] in
                        self?.photosLibraryLoadingSet.remove(localIdentifier)
                    }
                }
            } else {
                _ = await MainActor.run { [weak self] in
                    self?.photosLibraryLoadingSet.remove(localIdentifier)
                }
            }
        }

        // Return nil immediately - texture will be available next frame
        return nil
    }

    private func needsRedraw() {
        // Trigger a redraw (implementation depends on how the view is set up)
        // This might already happen automatically via the display link
    }

    /*
     * VIDEO FLASH FIX (January 2026): Texture selection with fallback support.
     *
     * For videos, there's a critical timing issue when a video is promoted from
     * "next" to "current" via advanceSlide():
     *
     * 1. During transition: Video B plays in nextVideoSource, decodes frames
     * 2. advanceSlide(): Video B promoted to current, nextVideo = nil
     * 3. update(): currentVideoSource.setPooledPlayer(videoB) creates NEW output
     * 4. update(): nextVideoSource.setPooledPlayer(nil) detaches player
     * 5. draw(): currentVideoSource has no decoded frames yet!
     *
     * Solution: We always call currentVideoSource.currentTexture() first to give
     * it a chance to decode frames. If it hasn't decoded any yet, we fall back
     * to nextVideoSource which may still have frames from before promotion.
     *
     * Key insight: nextVideoSource.lastTexture persists even after the player is
     * detached, so we can use it as a bridge until currentVideoSource catches up.
     */
    private func textureForSlot(kind: MediaItem.Kind, slot: Slot) -> MTLTexture? {
        switch kind {
        case .photo:
            return (slot == .current) ? currentPhotoTexture : nextPhotoTexture
        case .video:
            if slot == .current {
                /*
                 * IMPORTANT: Always call currentTexture() first to give the source
                 * a chance to decode frames. hasRealTexture() only returns true
                 * AFTER currentTexture() has successfully decoded at least one frame.
                 *
                 * If we checked hasRealTexture() first (without calling currentTexture()),
                 * we'd never give currentVideoSource a chance to decode, and the video
                 * would freeze on nextVideoSource.lastTexture forever.
                 */
                let currentTex = currentVideoSource.currentTexture()

                // If currentVideoSource has decoded a real frame, use it
                if currentVideoSource.hasRealTexture() {
                    return currentTex
                }

                // Fallback: use nextVideoSource if it has a real frame
                // (this happens during the brief window after video promotion
                // before currentVideoSource decodes its first frame)
                if nextVideoSource.hasRealTexture() {
                    return nextVideoSource.currentTexture()
                }

                // Last resort: use whatever currentVideoSource returned (might be placeholder)
                return currentTex
            } else {
                return nextVideoSource.currentTexture()
            }
        }
    }

    /*
     * Check if the next media slot has a real texture ready (not just a placeholder).
     * For photos: checks if nextPhotoTexture is loaded
     * For videos: checks if the video has decoded at least one frame
     *
     * Used in the opacity calculation to prevent fading out the current media
     * before the next media is ready to be displayed.
     */
    private func nextSlotHasRealTexture(kind: MediaItem.Kind) -> Bool {
        switch kind {
        case .photo:
            return nextPhotoTexture != nil
        case .video:
            return nextVideoSource.hasRealTexture()
        }
    }

    /*
     * Check if the current media slot has a real texture ready.
     * For videos: if the decoder hasn't produced a frame yet, we should not
     * draw the video at all (to avoid showing transparent placeholder).
     *
     * IMPORTANT: When a video moves from "next" to "current" via advanceSlide(),
     * currentVideoSource creates a NEW output and hasn't decoded frames yet.
     * But nextVideoSource might still have decoded frames from when the video
     * was in the next slot! We check BOTH sources to handle this transition window.
     *
     * Note: nextVideoSource.lastTexture persists even after the player is detached,
     * so we can use it as a fallback until currentVideoSource decodes its own frames.
     */
    private func currentSlotHasRealTexture(kind: MediaItem.Kind) -> Bool {
        switch kind {
        case .photo:
            return currentPhotoTexture != nil
        case .video:
            // Check if EITHER source has decoded frames
            // (nextVideoSource might still have frames from before promotion)
            return currentVideoSource.hasRealTexture() || nextVideoSource.hasRealTexture()
        }
    }

    // MARK: - Uniforms

    private enum Slot { case current, next }

    private struct LayerUniforms {
        var scale: SIMD2<Float>
        var translate: SIMD2<Float>
        var opacity: Float
        var effectMode: Int32
        var rotationDegrees: Int32  // 0, 90, 180, or 270 (counterclockwise)
        var debugShowFaces: Int32   // 1 to show face boxes, 0 otherwise
        var faceBoxCount: Int32     // number of valid face boxes (0-8)
        var isVideoTexture: Int32   // 1 for video (bottom-left origin), 0 for photo (top-left origin)
        var faceBoxes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
            (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }

    private func writeLayerUniforms(_ u: LayerUniforms, to buffer: MTLBuffer) {
        var uu = u
        _ = withUnsafeBytes(of: &uu) { bytes in
            memcpy(buffer.contents(), bytes.baseAddress!, MemoryLayout<LayerUniforms>.stride)
        }
    }

    private func makeLayerUniforms(
        mediaTexture: MTLTexture,
        drawableSize: CGSize,
        playerState: SlideshowPlayerState,
        settings: SlideshowSettings,
        slot: Slot,
        nextTextureReady: Bool
    ) -> LayerUniforms {
        // Compute fitted aspect scale (like .aspectRatio(.fit) into full frame)
        let viewW = max(1.0, Double(drawableSize.width))
        let viewH = max(1.0, Double(drawableSize.height))

        // Get rotation: photos from PhotoKey, videos from VideoTextureSource
        let rotation: Int
        if slot == .current {
            if playerState.currentKind == .video {
                rotation = currentVideoSource.currentRotationDegrees
            } else if let key = currentPhotoKey {
                rotation = key.rotationDegrees
            } else {
                rotation = 0
            }
        } else { // .next
            if playerState.nextKind == .video {
                rotation = nextVideoSource.currentRotationDegrees
            } else if let key = nextPhotoKey {
                rotation = key.rotationDegrees
            } else {
                rotation = 0
            }
        }

        // Swap texture dimensions for 90° and 270° rotations (portrait <-> landscape)
        let texW: Double
        let texH: Double
        if rotation == 90 || rotation == 270 {
            texW = max(1.0, Double(mediaTexture.height))  // swapped
            texH = max(1.0, Double(mediaTexture.width))   // swapped
        } else {
            texW = max(1.0, Double(mediaTexture.width))
            texH = max(1.0, Double(mediaTexture.height))
        }

        let viewAspect = viewW / viewH
        let texAspect = texW / texH

        let fittedW: Double
        let fittedH: Double
        if texAspect > viewAspect {
            fittedW = viewW
            fittedH = viewW / texAspect
        } else {
            fittedH = viewH
            fittedW = viewH * texAspect
        }

        // Base scale converts unit quad (-1..1) to fitted size in NDC.
        let baseScaleX = Float(fittedW / viewW)
        let baseScaleY = Float(fittedH / viewH)

        // Ken Burns parameters
        let startScale: Double = 1.0
        let endScale: Double = 1.4

        // Reuse the same progress math as SwiftUI.
        let transitionStart = playerState.currentHoldDuration / playerState.totalSlideDuration
        let transitionProgress: Double = {
            guard playerState.animationProgress >= transitionStart else { return 0.0 }
            let duration = (1.0 - transitionStart)
            if duration <= 0 { return 1.0 }
            return min(1.0, (playerState.animationProgress - transitionStart) / duration)
        }()

        /*
         * OPACITY CALCULATION - Critical for smooth crossfade transitions.
         *
         * This calculation must handle three phases:
         *
         * 1. HOLD PHASE (animationProgress < transitionStart):
         *    - Current: 100% opacity (fully visible)
         *    - Next: 0% opacity (not drawn, see draw condition above)
         *
         * 2. TRANSITION PHASE (transitionStart <= animationProgress < 1.0):
         *    - Current: fades from 100% → 0% as transitionProgress goes 0 → 1
         *    - Next: fades from 0% → 100% as transitionProgress goes 0 → 1
         *
         * 3. POST-TRANSITION RACE WINDOW (animationProgress >= 1.0):
         *    - Current: 0% opacity (must be invisible)
         *    - Next: 100% opacity (must be fully visible!)
         *
         *    This phase exists because advanceSlide() is async. There's a brief window
         *    where the animation timer has reached 1.0 but the slot promotion hasn't
         *    completed yet. During this window, "next" must remain fully visible to
         *    prevent a background flash.
         *
         * VIDEO READINESS CHECK (January 2026):
         * For videos, the decoder may not have produced a frame yet when the transition
         * starts or during the race window. In this case, we keep the current media
         * visible (at some opacity) to prevent showing the background through the
         * transparent video placeholder texture.
         *
         * HISTORICAL NOTE (January 2026):
         * A bug caused both current and next to be 0% opacity when progress >= 1.0,
         * resulting in a "hot pink flash" (background color showing through).
         * The fix ensures next is explicitly set to 100% in phase 3.
         */
        let opacity: Double = {
            if playerState.transitionStyle == .plain { return 1.0 }

            /*
             * Phase 3: Post-transition race window - next must stay fully visible.
             * BUT: If next texture isn't ready (video still decoding), keep current visible
             * to prevent background flash through transparent placeholder.
             */
            if playerState.animationProgress >= 1.0 {
                if slot == .current {
                    // Keep current visible if next isn't ready yet
                    return nextTextureReady ? 0.0 : 1.0
                } else {
                    return 1.0
                }
            }

            /*
             * Calculate transition state from animationProgress directly.
             * Do NOT use playerState.isTransitioning flag here - it's set asynchronously
             * by the animation timer and can be out of sync with animationProgress.
             */
            let isInTransition = playerState.animationProgress >= transitionStart

            /* Phase 1: Hold phase - only current is visible */
            if !isInTransition {
                return slot == .current ? 1.0 : 0.0
            }

            /*
             * Phase 2: Transition phase - crossfade based on progress.
             * If next texture isn't ready, clamp current's minimum opacity to prevent
             * it from fading out completely while next shows transparent placeholder.
             */
            switch slot {
            case .current:
                let baseOpacity = 1.0 - transitionProgress
                if !nextTextureReady {
                    // Don't let current fade below 50% if next isn't ready
                    return max(0.5, baseOpacity)
                }
                return baseOpacity
            case .next:
                return transitionProgress
            }
        }()

        let scale: Double
        let offset: CGSize
        if playerState.transitionStyle == .panAndZoom || playerState.transitionStyle == .zoom {
            let cycleElapsed = playerState.animationProgress * playerState.totalSlideDuration
            let motionTotal = playerState.currentHoldDuration + (2.0 * SlideshowPlayerState.transitionDuration)
            let currentMotionElapsed = cycleElapsed + SlideshowPlayerState.transitionDuration
            let nextMotionElapsed = max(0.0, cycleElapsed - playerState.currentHoldDuration)

            let motionElapsed = (slot == .current) ? currentMotionElapsed : nextMotionElapsed
            let progress = motionTotal > 0 ? min(1.0, max(0.0, motionElapsed / motionTotal)) : 1.0

            scale = startScale + ((endScale - startScale) * progress)

            let startOffset = (slot == .current) ? playerState.currentStartOffset : playerState.nextStartOffset
            let endOffset = (slot == .current) ? playerState.currentEndOffset : playerState.nextEndOffset

            // Same rule as SwiftUI: use face target iff enabled; otherwise endOffset is zero.
            let effectiveEnd = settings.zoomOnFaces ? endOffset : .zero
            offset = CGSize(
                width: (startOffset.width * (1.0 - progress)) + (effectiveEnd.width * progress),
                height: (startOffset.height * (1.0 - progress)) + (effectiveEnd.height * progress)
            )
        } else {
            scale = 1.0
            offset = .zero
        }

        // Translation: offsets are normalized relative to view size, so convert to NDC.
        // Note: NDC Y-axis points UP (+Y = up), but SwiftUI Y-axis points DOWN (+Y = down).
        // We negate Y to match SwiftUI's offset convention used in faceTargetOffset().
        let tx = Float(offset.width) * 2.0
        let ty = Float(-offset.height) * 2.0

        let effectMode: Int32 = {
            switch settings.effect {
            case .none: return 0
            case .monochrome: return 1
            case .silvertone: return 2
            case .sepia: return 3
            }
        }()

        // Face boxes for debug visualization
        let faceBoxes: [CGRect] = (slot == .current) ? playerState.currentFaceBoxes : playerState.nextFaceBoxes
        let faceBoxCount = min(8, faceBoxes.count)

        // Convert CGRect array to tuple of SIMD4<Float> (minX, minY, width, height)
        var boxes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
            (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)

        for i in 0..<faceBoxCount {
            let r = faceBoxes[i]
            let v = SIMD4<Float>(Float(r.origin.x), Float(r.origin.y), Float(r.size.width), Float(r.size.height))
            switch i {
            case 0: boxes.0 = v
            case 1: boxes.1 = v
            case 2: boxes.2 = v
            case 3: boxes.3 = v
            case 4: boxes.4 = v
            case 5: boxes.5 = v
            case 6: boxes.6 = v
            case 7: boxes.7 = v
            default: break
            }
        }

        // Determine if this is a video texture (bottom-left origin) vs photo (top-left origin)
        let isVideo: Bool
        if slot == .current {
            isVideo = playerState.currentKind == .video
        } else {
            isVideo = playerState.nextKind == .video
        }

        return LayerUniforms(
            scale: SIMD2<Float>(baseScaleX * Float(scale), baseScaleY * Float(scale)),
            translate: SIMD2<Float>(tx, ty),
            opacity: Float(opacity),
            effectMode: effectMode,
            rotationDegrees: Int32(rotation),
            debugShowFaces: settings.debugShowFaces ? 1 : 0,
            faceBoxCount: Int32(faceBoxCount),
            isVideoTexture: isVideo ? 1 : 0,
            faceBoxes: boxes
        )
    }

    // MARK: - Patina uniforms

    private struct PatinaParams35mm {
        var grainFineness: Float
        var grainIntensity: Float
        var blurRadiusTexels: Float
        var toneMultiplyRGBA: SIMD4<Float>
        var blackLift: Float
        var contrast: Float
        var rolloffThreshold: Float
        var rolloffSoftness: Float
        var vignetteStrength: Float
        var vignetteRadius: Float
        var _pad0: SIMD2<Float> = .zero
    }

    private struct PatinaParamsAgedFilm {
        var grainFineness: Float
        var grainIntensity: Float
        var blurRadiusTexels: Float
        var jitterAmplitudeTexels: Float
        var driftSpeed: Float
        var driftIntensity: Float
        var dimPulseSpeed: Float
        var dimPulseThreshold: Float
        var dimPulseIntensity: Float
        var highlightSoftThreshold: Float
        var highlightSoftAmount: Float
        var shadowLiftThreshold: Float
        var shadowLiftAmount: Float
        var vignetteStrength: Float
        var vignetteRadius: Float
        var dustRate: Float
        var dustIntensity: Float
        var dustSize: Float
        var projectorSpeed: Float  // Simulated fps (0 = disabled, 18 = classic film)
        var _pad0: Float = 0
    }

    private struct PatinaParamsVHS {
        var blurTap1: Float
        var blurTap2: Float
        var blurW0: Float
        var blurW1: Float
        var blurW2: Float
        var chromaOffsetTexels: Float
        var chromaMix: Float
        var scanlineBase: Float
        var scanlineAmp: Float
        var scanlinePow: Float
        var lineFrequencyScale: Float
        var desat: Float
        var tintMultiplyRGBA: SIMD4<Float>
        var trackingThreshold: Float
        var trackingIntensity: Float
        var staticIntensity: Float
        var tearEnabled: Float
        var tearGateRate: Float
        var tearGateThreshold: Float
        var tearSpeed: Float
        var tearBandHeight: Float
        var tearOffsetTexels: Float
        var edgeSoftStrength: Float
        var scanlineBandWidth: Float
        var blackLift: Float
    }

    private struct PatinaUniforms {
        var mode: Int32
        var time: Float
        var resolution: SIMD2<Float>
        var seed: Float
        var currentRotation: Int32  // Current media rotation: 0, 90, 180, 270
        var p35: PatinaParams35mm
        var aged: PatinaParamsAgedFilm
        var vhs: PatinaParamsVHS
    }

    private func writePatinaUniforms(effect: SlideshowDocument.Settings.PatinaEffect, drawableTexture: MTLTexture, currentRotation: Int) {
        let mode: Int32
        switch effect {
        case .none: mode = 0
        case .mm35: mode = 1
        case .agedFilm: mode = 2
        case .vhs: mode = 3
        }
        let t = Float(CACurrentMediaTime() - startTime)
        let tuning = PatinaTuningStore.shared

        let p35 = PatinaParams35mm(
            grainFineness: tuning.mm35.grainFineness,
            grainIntensity: tuning.mm35.grainIntensity,
            blurRadiusTexels: tuning.mm35.blurRadiusTexels,
            toneMultiplyRGBA: SIMD4<Float>(tuning.mm35.toneR, tuning.mm35.toneG, tuning.mm35.toneB, 1),
            blackLift: tuning.mm35.blackLift,
            contrast: tuning.mm35.contrast,
            rolloffThreshold: tuning.mm35.rolloffThreshold,
            rolloffSoftness: tuning.mm35.rolloffSoftness,
            vignetteStrength: tuning.mm35.vignetteStrength,
            vignetteRadius: tuning.mm35.vignetteRadius
        )

        let aged = PatinaParamsAgedFilm(
            grainFineness: tuning.aged.grainFineness,
            grainIntensity: tuning.aged.grainIntensity,
            blurRadiusTexels: tuning.aged.blurRadiusTexels,
            jitterAmplitudeTexels: tuning.aged.jitterAmplitudeTexels,
            driftSpeed: tuning.aged.driftSpeed,
            driftIntensity: tuning.aged.driftIntensity,
            dimPulseSpeed: tuning.aged.dimPulseSpeed,
            dimPulseThreshold: tuning.aged.dimPulseThreshold,
            dimPulseIntensity: tuning.aged.dimPulseIntensity,
            highlightSoftThreshold: tuning.aged.highlightSoftThreshold,
            highlightSoftAmount: tuning.aged.highlightSoftAmount,
            shadowLiftThreshold: tuning.aged.shadowLiftThreshold,
            shadowLiftAmount: tuning.aged.shadowLiftAmount,
            vignetteStrength: tuning.aged.vignetteStrength,
            vignetteRadius: tuning.aged.vignetteRadius,
            dustRate: tuning.aged.dustRate,
            dustIntensity: tuning.aged.dustIntensity,
            dustSize: tuning.aged.dustSize,
            projectorSpeed: tuning.aged.projectorSpeed
        )

        let vhs = PatinaParamsVHS(
            blurTap1: tuning.vhs.blurTap1,
            blurTap2: tuning.vhs.blurTap2,
            blurW0: tuning.vhs.blurW0,
            blurW1: tuning.vhs.blurW1,
            blurW2: tuning.vhs.blurW2,
            chromaOffsetTexels: tuning.vhs.chromaOffsetTexels,
            chromaMix: tuning.vhs.chromaMix,
            scanlineBase: tuning.vhs.scanlineBase,
            scanlineAmp: tuning.vhs.scanlineAmp,
            scanlinePow: tuning.vhs.scanlinePow,
            lineFrequencyScale: tuning.vhs.lineFrequencyScale,
            desat: tuning.vhs.desat,
            tintMultiplyRGBA: SIMD4<Float>(tuning.vhs.tintR, tuning.vhs.tintG, tuning.vhs.tintB, 1),
            trackingThreshold: tuning.vhs.trackingThreshold,
            trackingIntensity: tuning.vhs.trackingIntensity,
            staticIntensity: tuning.vhs.staticIntensity,
            tearEnabled: tuning.vhs.tearEnabled,
            tearGateRate: tuning.vhs.tearGateRate,
            tearGateThreshold: tuning.vhs.tearGateThreshold,
            tearSpeed: tuning.vhs.tearSpeed,
            tearBandHeight: tuning.vhs.tearBandHeight,
            tearOffsetTexels: tuning.vhs.tearOffsetTexels,
            edgeSoftStrength: tuning.vhs.edgeSoftStrength,
            scanlineBandWidth: tuning.vhs.scanlineBandWidth,
            blackLift: tuning.vhs.blackLift
        )

        let u = PatinaUniforms(
            mode: mode,
            time: t,
            resolution: SIMD2<Float>(Float(drawableTexture.width), Float(drawableTexture.height)),
            seed: patinaSeed,
            currentRotation: Int32(currentRotation),
            p35: p35,
            aged: aged,
            vhs: vhs
        )
        var uu = u
        _ = withUnsafeBytes(of: &uu) { bytes in
            memcpy(patinaUniformBuffer.contents(), bytes.baseAddress!, MemoryLayout<PatinaUniforms>.stride)
        }
    }
}

private extension Color {
    var metalClearColor: MTLClearColor {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.black
        return MTLClearColor(
            red: Double(ns.redComponent),
            green: Double(ns.greenComponent),
            blue: Double(ns.blueComponent),
            alpha: Double(ns.alphaComponent)
        )
    }
}

// MARK: - Video sampling (GPU)

/// Samples decoded video frames from an AVPlayer using AVPlayerItemVideoOutput,
/// creating Metal textures via CVMetalTextureCache (no CPU readback).
private final class VideoTextureSource {
    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var output: AVPlayerItemVideoOutput?
    private weak var player: AVPlayer?
    private weak var playerItem: AVPlayerItem?

    private var lastTexture: MTLTexture?
    private var lastItemTime: CMTime = .invalid

    /// 1x1 transparent placeholder texture to avoid black flashes when no frame is available yet
    private let placeholderTexture: MTLTexture?

    /// Rotation degrees extracted from video's preferredTransform (0, 90, 180, 270)
    private(set) var currentRotationDegrees: Int = 0

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        // Create 1x1 transparent placeholder to prevent black flashes
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        placeholderTexture = device.makeTexture(descriptor: desc)
        if let tex = placeholderTexture {
            var pixel: UInt32 = 0x00000000  // Fully transparent black
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                       withBytes: &pixel, bytesPerRow: 4)
        }
    }

    func setPlayer(_ videoPlayer: SoftBurnVideoPlayer?) {
        // Detach from old item
        if let item = playerItem, let output {
            item.remove(output)
        }

        self.player = videoPlayer?.player
        self.playerItem = videoPlayer?.playerItem
        currentRotationDegrees = videoPlayer?.rotationDegrees ?? 0

        guard let item = videoPlayer?.playerItem else {
            output = nil
            /*
             * VIDEO FLASH FIX (January 2026): Do NOT clear lastTexture here!
             * See setPooledPlayer() for detailed explanation.
             */
            lastItemTime = .invalid
            return
        }

        configureOutput(for: item)
    }

    func setPooledPlayer(_ videoPlayer: PooledVideoPlayer?) {
        // Detach from old item
        if let item = playerItem, let output {
            item.remove(output)
        }

        self.player = videoPlayer?.player
        self.playerItem = videoPlayer?.playerItem
        currentRotationDegrees = videoPlayer?.rotationDegrees ?? 0

        // Debug: log the rotation being used
        if let vp = videoPlayer {
            print("[Video] VideoTextureSource: setPooledPlayer rotation=\(currentRotationDegrees)° (from PooledVideoPlayer.rotationDegrees=\(vp.rotationDegrees))")
        }

        guard let item = videoPlayer?.playerItem else {
            output = nil
            /*
             * VIDEO FLASH FIX (January 2026): Do NOT clear lastTexture here!
             *
             * When a video is promoted from next to current via advanceSlide():
             * 1. advanceSlide() sets nextVideo = nil (before loading new next)
             * 2. update() calls nextVideoSource.setPooledPlayer(nil)
             * 3. If we cleared lastTexture here, we'd lose the decoded frames!
             * 4. But currentVideoSource hasn't decoded frames yet...
             * 5. Result: Flash because no valid texture available
             *
             * By preserving lastTexture, nextVideoSource can provide fallback frames
             * until currentVideoSource decodes its own. The Metal texture remains
             * valid in GPU memory even after the AVPlayer is detached.
             */
            lastItemTime = .invalid
            return
        }

        configureOutput(for: item)
    }

    private func configureOutput(for item: AVPlayerItem) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        out.suppressesPlayerRendering = true
        item.add(out)
        output = out
        /*
         * Clear lastTexture when attaching a NEW video (different from previous).
         * This ensures we don't show stale frames from a completely different video.
         * Note: This is different from the nil case above where we preserve lastTexture.
         */
        lastTexture = nil
        lastItemTime = .invalid
    }

    func currentTexture() -> MTLTexture? {
        guard let output else {
            // No output attached - return last texture or placeholder
            return lastTexture ?? placeholderTexture
        }

        guard let item = playerItem, item.status == .readyToPlay else {
            // Player not ready - return last texture or placeholder
            return lastTexture ?? placeholderTexture
        }

        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)

        // Try to get a new pixel buffer even if hasNewPixelBuffer is false
        // This helps avoid black flashes at video start
        guard let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            // No pixel buffer available - return last texture or placeholder
            return lastTexture ?? placeholderTexture
        }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard w > 0, h > 0 else { return lastTexture ?? placeholderTexture }

        guard let cache = textureCache else { return lastTexture ?? placeholderTexture }
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pb,
            nil,
            .bgra8Unorm,
            w,
            h,
            0,
            &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            return lastTexture ?? placeholderTexture
        }

        lastTexture = tex
        lastItemTime = itemTime
        return tex
    }

    /*
     * VIDEO FLASH FIX (January 2026): Check if video has produced a real frame.
     *
     * Returns true if the video has produced at least one real frame (lastTexture != nil).
     * This is used in multiple places to prevent flashes:
     *
     * 1. In textureForSlot(): To decide whether to use currentVideoSource or fall back
     *    to nextVideoSource during the video promotion window.
     *
     * 2. In currentSlotHasRealTexture(): To determine if fallback texture is needed.
     *
     * IMPORTANT: lastTexture persists even after the player is detached via
     * setPooledPlayer(nil). This is intentional - it allows nextVideoSource to
     * provide fallback frames after a video is promoted to currentVideoSource.
     * The texture remains valid in GPU memory even without an active player.
     */
    func hasRealTexture() -> Bool {
        return lastTexture != nil
    }
}


