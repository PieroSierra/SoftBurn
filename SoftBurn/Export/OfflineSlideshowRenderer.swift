//
//  OfflineSlideshowRenderer.swift
//  SoftBurn
//
//  Offline Metal renderer for video export.
//  Reuses the same shader pipelines as MetalSlideshowRenderer but renders
//  to offscreen textures at the target export resolution.
//

import Foundation
import Metal
import MetalKit
import AVFoundation
import CoreVideo
import SwiftUI
import Photos

/// Offline renderer for export - renders frames to CVPixelBuffer for AVAssetWriter
final class OfflineSlideshowRenderer {
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

    // Offscreen textures
    private let sceneTexture: MTLTexture
    private let outputTexture: MTLTexture

    // CVPixelBuffer pool for efficient buffer reuse
    private var pixelBufferPool: CVPixelBufferPool?

    // Export settings
    let preset: ExportPreset
    let settings: SlideshowSettings

    // Texture loader
    private let textureLoader: MTKTextureLoader

    // Time tracking for patina effects
    private var exportStartTime: Double = 0

    init(device: MTLDevice, preset: ExportPreset, settings: SlideshowSettings) throws {
        self.device = device
        self.preset = preset
        self.settings = settings

        guard let q = device.makeCommandQueue() else {
            throw ExportError.metalInitializationFailed("Failed to create command queue")
        }
        self.queue = q

        // Create texture loader
        self.textureLoader = MTKTextureLoader(device: device)

        // Quad vertices: unit quad in NDC (-1..1), uv bottom-left origin.
        struct V { var p: SIMD2<Float>; var uv: SIMD2<Float> }
        let verts: [V] = [
            V(p: [-1, -1], uv: [0, 1]),
            V(p: [ 1, -1], uv: [1, 1]),
            V(p: [-1,  1], uv: [0, 0]),
            V(p: [ 1,  1], uv: [1, 0]),
        ]
        guard let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<V>.stride * verts.count, options: .storageModeShared) else {
            throw ExportError.metalInitializationFailed("Failed to create vertex buffer")
        }
        quadVertexBuffer = vb

        // Uniform buffers - separate buffers for current and next to avoid GPU race conditions
        guard let club = device.makeBuffer(length: MemoryLayout<LayerUniforms>.stride, options: .storageModeShared) else {
            throw ExportError.metalInitializationFailed("Failed to create current layer uniform buffer")
        }
        currentLayerUniformBuffer = club

        guard let nlub = device.makeBuffer(length: MemoryLayout<LayerUniforms>.stride, options: .storageModeShared) else {
            throw ExportError.metalInitializationFailed("Failed to create next layer uniform buffer")
        }
        nextLayerUniformBuffer = nlub

        guard let pub = device.makeBuffer(length: MemoryLayout<PatinaUniforms>.stride, options: .storageModeShared) else {
            throw ExportError.metalInitializationFailed("Failed to create patina uniform buffer")
        }
        patinaUniformBuffer = pub
        patinaSeed = Float.random(in: 0...1000)

        // Load shaders
        guard let library = device.makeDefaultLibrary() else {
            throw ExportError.metalInitializationFailed("Failed to load Metal library")
        }

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
        scenePipeline = try device.makeRenderPipelineState(descriptor: sceneDesc)

        // Patina pipeline
        let patinaDesc = MTLRenderPipelineDescriptor()
        patinaDesc.vertexFunction = library.makeFunction(name: "patinaVertexShader")
        patinaDesc.fragmentFunction = library.makeFunction(name: "patinaFragmentShader")
        patinaDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        patinaDesc.colorAttachments[0].isBlendingEnabled = false
        patinaPipeline = try device.makeRenderPipelineState(descriptor: patinaDesc)

        // Create offscreen textures at export resolution
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: preset.width,
            height: preset.height,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .private

        guard let st = device.makeTexture(descriptor: texDesc) else {
            throw ExportError.metalInitializationFailed("Failed to create scene texture")
        }
        sceneTexture = st

        guard let ot = device.makeTexture(descriptor: texDesc) else {
            throw ExportError.metalInitializationFailed("Failed to create output texture")
        }
        outputTexture = ot

        // Create pixel buffer pool
        try createPixelBufferPool()
    }

    private func createPixelBufferPool() throws {
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: preset.width,
            kCVPixelBufferHeightKey as String: preset.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )

        guard status == kCVReturnSuccess, let pool = pool else {
            throw ExportError.metalInitializationFailed("Failed to create pixel buffer pool")
        }

        pixelBufferPool = pool
    }

    /// Set the export start time for patina effect timing
    func setExportStartTime(_ time: Double) {
        exportStartTime = time
    }

    /// Render a single frame to a CVPixelBuffer
    func renderFrame(
        currentTexture: MTLTexture?,
        nextTexture: MTLTexture?,
        currentTransform: MediaTransform,
        nextTransform: MediaTransform?,
        animationProgress: Double,
        transitionStart: Double,
        frameTime: Double
    ) throws -> CVPixelBuffer {
        guard let cb = queue.makeCommandBuffer() else {
            throw ExportError.renderFailed("Failed to create command buffer")
        }

        // Pass 1: Render scene to sceneTexture
        let sceneRPD = MTLRenderPassDescriptor()
        sceneRPD.colorAttachments[0].texture = sceneTexture
        sceneRPD.colorAttachments[0].loadAction = .clear
        sceneRPD.colorAttachments[0].storeAction = .store
        sceneRPD.colorAttachments[0].clearColor = settings.backgroundColor.metalClearColor

        guard let enc = cb.makeRenderCommandEncoder(descriptor: sceneRPD) else {
            throw ExportError.renderFailed("Failed to create scene render encoder")
        }

        enc.setRenderPipelineState(scenePipeline)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

        // Calculate transition progress
        let transitionProgress: Double
        if animationProgress >= transitionStart {
            let duration = 1.0 - transitionStart
            transitionProgress = duration > 0 ? min(1.0, (animationProgress - transitionStart) / duration) : 1.0
        } else {
            transitionProgress = 0.0
        }

        let isTransitioning = animationProgress >= transitionStart

        // Draw current media (fades out during transition)
        if let tex = currentTexture {
            let opacity = isTransitioning ? (1.0 - transitionProgress) : 1.0
            let uniforms = makeLayerUniforms(
                texture: tex,
                transform: currentTransform,
                opacity: opacity,
                animationProgress: animationProgress,
                isTransitioning: isTransitioning
            )
            writeLayerUniforms(uniforms, to: currentLayerUniformBuffer)
            enc.setVertexBuffer(currentLayerUniformBuffer, offset: 0, index: 1)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentBuffer(currentLayerUniformBuffer, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Draw next media (fades in during transition)
        if isTransitioning, let tex = nextTexture, let nextXform = nextTransform {
            let opacity = transitionProgress
            let uniforms = makeLayerUniforms(
                texture: tex,
                transform: nextXform,
                opacity: opacity,
                animationProgress: animationProgress,
                isTransitioning: true
            )
            writeLayerUniforms(uniforms, to: nextLayerUniformBuffer)
            enc.setVertexBuffer(nextLayerUniformBuffer, offset: 0, index: 1)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentBuffer(nextLayerUniformBuffer, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        enc.endEncoding()

        // Pass 2: Apply patina (or direct copy)
        if settings.patina == .none {
            // Direct blit
            guard let blitEnc = cb.makeBlitCommandEncoder() else {
                throw ExportError.renderFailed("Failed to create blit encoder")
            }
            let origin = MTLOrigin(x: 0, y: 0, z: 0)
            let size = MTLSize(width: preset.width, height: preset.height, depth: 1)
            blitEnc.copy(
                from: sceneTexture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: origin, sourceSize: size,
                to: outputTexture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: origin
            )
            blitEnc.endEncoding()
        } else {
            // Patina pass
            let patinaRPD = MTLRenderPassDescriptor()
            patinaRPD.colorAttachments[0].texture = outputTexture
            patinaRPD.colorAttachments[0].loadAction = .dontCare
            patinaRPD.colorAttachments[0].storeAction = .store

            guard let pEnc = cb.makeRenderCommandEncoder(descriptor: patinaRPD) else {
                throw ExportError.renderFailed("Failed to create patina encoder")
            }

            pEnc.setRenderPipelineState(patinaPipeline)
            pEnc.setFragmentTexture(sceneTexture, index: 0)

            writePatinaUniforms(
                effect: settings.patina,
                time: Float(frameTime - exportStartTime),
                currentRotation: currentTransform.rotationDegrees
            )
            pEnc.setFragmentBuffer(patinaUniformBuffer, offset: 0, index: 0)
            pEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            pEnc.endEncoding()
        }

        // Create pixel buffer
        guard let pool = pixelBufferPool else {
            throw ExportError.renderFailed("Pixel buffer pool not available")
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            throw ExportError.renderFailed("Failed to create pixel buffer")
        }

        // Copy output texture to pixel buffer (commits and waits internally)
        try copyTextureToPixelBuffer(cb: cb, texture: outputTexture, pixelBuffer: pb)

        return pb
    }

    private func copyTextureToPixelBuffer(cb: MTLCommandBuffer, texture: MTLTexture, pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExportError.renderFailed("Failed to get pixel buffer base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Create a staging texture for readback (shared storage)
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: preset.width,
            height: preset.height,
            mipmapped: false
        )
        stagingDesc.usage = .shaderRead
        stagingDesc.storageMode = .shared

        guard let staging = device.makeTexture(descriptor: stagingDesc) else {
            throw ExportError.renderFailed("Failed to create staging texture")
        }

        // Blit from private to shared
        guard let blitEnc = cb.makeBlitCommandEncoder() else {
            throw ExportError.renderFailed("Failed to create blit encoder for copy")
        }
        let origin = MTLOrigin(x: 0, y: 0, z: 0)
        let size = MTLSize(width: preset.width, height: preset.height, depth: 1)
        blitEnc.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: origin, sourceSize: size,
            to: staging, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: origin
        )
        // Note: synchronize() is only needed for managed storage mode (Intel Macs with discrete GPUs).
        // On Apple Silicon (unified memory), shared storage textures don't need synchronization.
        // waitUntilCompleted() below ensures the GPU has finished before CPU reads.
        blitEnc.endEncoding()

        cb.commit()
        cb.waitUntilCompleted()

        // Copy from staging texture to pixel buffer
        staging.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, preset.width, preset.height),
            mipmapLevel: 0
        )
    }

    /// Load a texture from a MediaItem (handles both filesystem and Photos Library)
    func loadTexture(from item: MediaItem) async -> MTLTexture? {
        switch item.source {
        case .filesystem(let url):
            return loadTextureFromFilesystem(url: url)
        case .photosLibrary(let localID, _):
            return await loadTextureFromPhotosLibrary(localIdentifier: localID)
        }
    }

    /// Legacy method for backward compatibility with URL-based loading
    func loadTexture(from url: URL, rotationDegrees: Int) -> MTLTexture? {
        return loadTextureFromFilesystem(url: url)
    }

    private func loadTextureFromFilesystem(url: URL) -> MTLTexture? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        return try? textureLoader.newTexture(URL: url, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
        ])
    }

    private func loadTextureFromPhotosLibrary(localIdentifier: String) async -> MTLTexture? {
        guard let cgImage = await PhotosLibraryImageLoader.shared.loadFullResolutionCGImage(localIdentifier: localIdentifier) else {
            return nil
        }

        return try? await textureLoader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
        ])
    }

    // MARK: - Uniform Types (must match shader definitions)

    private struct LayerUniforms {
        var scale: SIMD2<Float>
        var translate: SIMD2<Float>
        var opacity: Float
        var effectMode: Int32
        var rotationDegrees: Int32
        var debugShowFaces: Int32
        var faceBoxCount: Int32
        var isVideoTexture: Int32
        var faceBoxes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
            (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }

    private func makeLayerUniforms(
        texture: MTLTexture,
        transform: MediaTransform,
        opacity: Double,
        animationProgress: Double,
        isTransitioning: Bool
    ) -> LayerUniforms {
        let viewW = Double(preset.width)
        let viewH = Double(preset.height)

        // Handle rotation for dimensions
        let texW: Double
        let texH: Double
        if transform.rotationDegrees == 90 || transform.rotationDegrees == 270 {
            texW = Double(texture.height)
            texH = Double(texture.width)
        } else {
            texW = Double(texture.width)
            texH = Double(texture.height)
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

        let baseScaleX = Float(fittedW / viewW)
        let baseScaleY = Float(fittedH / viewH)

        // Apply Ken Burns scale and offset
        let scale = transform.scale
        let tx = Float(transform.offset.width) * 2.0
        let ty = Float(-transform.offset.height) * 2.0

        let effectMode: Int32 = {
            switch settings.effect {
            case .none: return 0
            case .monochrome: return 1
            case .silvertone: return 2
            case .sepia: return 3
            case .budapestRose: return 4
            case .fantasticMrYellow: return 5
            case .darjeelingMint: return 6
            }
        }()

        // Convert face boxes
        var boxes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
            (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)

        let faceCount = min(8, transform.faceBoxes.count)
        for i in 0..<faceCount {
            let r = transform.faceBoxes[i]
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

        return LayerUniforms(
            scale: SIMD2<Float>(baseScaleX * Float(scale), baseScaleY * Float(scale)),
            translate: SIMD2<Float>(tx, ty),
            opacity: Float(opacity),
            effectMode: effectMode,
            rotationDegrees: Int32(transform.rotationDegrees),
            debugShowFaces: 0, // Never show debug faces in export
            faceBoxCount: Int32(faceCount),
            isVideoTexture: transform.isVideo ? 1 : 0,
            faceBoxes: boxes
        )
    }

    private func writeLayerUniforms(_ u: LayerUniforms, to buffer: MTLBuffer) {
        var uu = u
        _ = withUnsafeBytes(of: &uu) { bytes in
            memcpy(buffer.contents(), bytes.baseAddress!, MemoryLayout<LayerUniforms>.stride)
        }
    }

    // MARK: - Patina Uniforms (must match PatinaShaders.metal)

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
        var scanlineBandWidth: Float
        var blackLift: Float
    }

    private struct PatinaUniforms {
        var mode: Int32
        var time: Float
        var resolution: SIMD2<Float>
        var seed: Float
        var currentRotation: Int32
        var p35: PatinaParams35mm
        var aged: PatinaParamsAgedFilm
        var vhs: PatinaParamsVHS
    }

    private func writePatinaUniforms(effect: SlideshowDocument.Settings.PatinaEffect, time: Float, currentRotation: Int) {
        let mode: Int32
        switch effect {
        case .none: mode = 0
        case .mm35: mode = 1
        case .agedFilm: mode = 2
        case .vhs: mode = 3
        }

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
            edgeSoftStrength: tuning.vhs.edgeSoftStrength,
            scanlineBandWidth: tuning.vhs.scanlineBandWidth,
            blackLift: tuning.vhs.blackLift
        )

        let u = PatinaUniforms(
            mode: mode,
            time: time,
            resolution: SIMD2<Float>(Float(preset.width), Float(preset.height)),
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

// MARK: - Supporting Types

/// Transform data for a media item during rendering
struct MediaTransform: Sendable {
    let rotationDegrees: Int
    let scale: Double
    let offset: CGSize
    let faceBoxes: [CGRect]
    let isVideo: Bool

    nonisolated init(
        rotationDegrees: Int = 0,
        scale: Double = 1.0,
        offset: CGSize = .zero,
        faceBoxes: [CGRect] = [],
        isVideo: Bool = false
    ) {
        self.rotationDegrees = rotationDegrees
        self.scale = scale
        self.offset = offset
        self.faceBoxes = faceBoxes
        self.isVideo = isVideo
    }
}

/// Errors during export
enum ExportError: LocalizedError {
    case metalInitializationFailed(String)
    case renderFailed(String)
    case videoWriterFailed(String)
    case audioCompositionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .metalInitializationFailed(let msg):
            return "Metal initialization failed: \(msg)"
        case .renderFailed(let msg):
            return "Render failed: \(msg)"
        case .videoWriterFailed(let msg):
            return "Video writer failed: \(msg)"
        case .audioCompositionFailed(let msg):
            return "Audio composition failed: \(msg)"
        case .cancelled:
            return "Export was cancelled"
        }
    }
}

// MARK: - Color Extension

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
