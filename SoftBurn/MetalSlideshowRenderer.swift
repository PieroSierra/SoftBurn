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

    // Texture cache for Photos Library assets (to avoid reloading)
    private var photosLibraryTextureCache: [String: MTLTexture] = [:]
    private var photosLibraryLoadingSet: Set<String> = []

    // Video texture sources (GPU sampling via AVPlayerItemVideoOutput)
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

            if currentItem.kind == .photo {
                let key = PhotoKey(from: currentItem)
                if currentPhotoKey != key || currentPhotoTexture == nil {
                    currentPhotoTexture = loadPhotoTexture(from: key)
                    currentPhotoKey = currentPhotoTexture == nil ? nil : key
                }
            } else {
                currentPhotoTexture = nil
                currentPhotoKey = nil
            }

            if nextItem.kind == .photo {
                let key = PhotoKey(from: nextItem)
                if nextPhotoKey != key || nextPhotoTexture == nil {
                    nextPhotoTexture = loadPhotoTexture(from: key)
                    nextPhotoKey = nextPhotoTexture == nil ? nil : key
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
        if let loopingPlayer = playerState.currentVideo {
            let id = ObjectIdentifier(loopingPlayer)
            if currentVideoPlayerID != id {
                currentVideoPlayerID = id
                currentVideoSource.setPlayer(loopingPlayer)
            }
        } else {
            currentVideoPlayerID = nil
            currentVideoSource.setPlayer(nil)
        }

        if let loopingPlayer = playerState.nextVideo {
            let id = ObjectIdentifier(loopingPlayer)
            if nextVideoPlayerID != id {
                nextVideoPlayerID = id
                nextVideoSource.setPlayer(loopingPlayer)
            }
        } else {
            nextVideoPlayerID = nil
            nextVideoSource.setPlayer(nil)
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

            // Draw current
            if let tex = textureForSlot(kind: playerState.currentKind, slot: .current) {
                let u = makeLayerUniforms(
                    mediaTexture: tex,
                    drawableSize: CGSize(width: sceneTexture.width, height: sceneTexture.height),
                    playerState: playerState,
                    settings: settings,
                    slot: .current
                )
                writeLayerUniforms(u, to: currentLayerUniformBuffer)
                enc.setVertexBuffer(currentLayerUniformBuffer, offset: 0, index: 1)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentBuffer(currentLayerUniformBuffer, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            // Draw next (during and after transition, until advanceSlide completes)
            let transitionStart = playerState.currentHoldDuration / playerState.totalSlideDuration
            if playerState.animationProgress >= transitionStart,
               let tex = textureForSlot(kind: playerState.nextKind, slot: .next) {
                let u = makeLayerUniforms(
                    mediaTexture: tex,
                    drawableSize: CGSize(width: sceneTexture.width, height: sceneTexture.height),
                    playerState: playerState,
                    settings: settings,
                    slot: .next
                )
                writeLayerUniforms(u, to: nextLayerUniformBuffer)
                enc.setVertexBuffer(nextLayerUniformBuffer, offset: 0, index: 1)
                enc.setFragmentTexture(tex, index: 0)
                enc.setFragmentBuffer(nextLayerUniformBuffer, offset: 0, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            enc.endEncoding()
        }

        // 2) Patina pass: post-process composed sceneTexture -> drawable
        // Clear black only as a safety default; we overwrite the entire drawable via fullscreen triangle.
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let enc = cb.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            enc.setRenderPipelineState(patinaPipeline)
            enc.setFragmentTexture(sceneTexture, index: 0)
            writePatinaUniforms(effect: settings.patina, drawableTexture: drawable.texture)
            enc.setFragmentBuffer(patinaUniformBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
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
                    await MainActor.run { [weak self] in
                        self?.photosLibraryLoadingSet.remove(localIdentifier)
                    }
                }
            } else {
                await MainActor.run { [weak self] in
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

    private func textureForSlot(kind: MediaItem.Kind, slot: Slot) -> MTLTexture? {
        switch kind {
        case .photo:
            return (slot == .current) ? currentPhotoTexture : nextPhotoTexture
        case .video:
            return (slot == .current) ? currentVideoSource.currentTexture() : nextVideoSource.currentTexture()
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
        withUnsafeBytes(of: &uu) { bytes in
            memcpy(buffer.contents(), bytes.baseAddress!, MemoryLayout<LayerUniforms>.stride)
        }
    }

    private func makeLayerUniforms(
        mediaTexture: MTLTexture,
        drawableSize: CGSize,
        playerState: SlideshowPlayerState,
        settings: SlideshowSettings,
        slot: Slot
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

        let opacity: Double = {
            if playerState.transitionStyle == .plain { return 1.0 }

            // Prevent flash: keep current at 0 opacity when animationProgress reaches 1.0
            if slot == .current && playerState.animationProgress >= 1.0 {
                return 0.0
            }

            if !playerState.isTransitioning { return 1.0 }
            switch slot {
            case .current: return 1.0 - transitionProgress
            case .next: return transitionProgress
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
        var _pad0: SIMD3<Float> = .zero
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
        var _pad0: Float = 0
    }

    private struct PatinaUniforms {
        var mode: Int32
        var time: Float
        var resolution: SIMD2<Float>
        var seed: Float
        var _pad0: Float = 0
        var p35: PatinaParams35mm
        var aged: PatinaParamsAgedFilm
        var vhs: PatinaParamsVHS
    }

    private func writePatinaUniforms(effect: SlideshowDocument.Settings.PatinaEffect, drawableTexture: MTLTexture) {
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
            dustIntensity: tuning.aged.dustIntensity
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
            edgeSoftStrength: tuning.vhs.edgeSoftStrength
        )

        let u = PatinaUniforms(
            mode: mode,
            time: t,
            resolution: SIMD2<Float>(Float(drawableTexture.width), Float(drawableTexture.height)),
            seed: patinaSeed,
            p35: p35,
            aged: aged,
            vhs: vhs
        )
        var uu = u
        withUnsafeBytes(of: &uu) { bytes in
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
            lastTexture = nil
            lastItemTime = .invalid
            return
        }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        out.suppressesPlayerRendering = true
        item.add(out)
        output = out
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
}


