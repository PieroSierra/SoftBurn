//
//  FaceDetectionCache.swift
//  SoftBurn
//
//  Created by SoftBurn on 05/01/2026.
//

import Foundation
import CoreGraphics
import Vision
import Photos

/// In-memory cache of Vision face detection results.
/// - Important: Detection is intended to run during import/open only (never during playback).
actor FaceDetectionCache {
    static let shared = FaceDetectionCache()

    /// Normalized bounding boxes in Vision coordinate space (origin bottom-left).
    /// Cache key format: "file://path" for filesystem, "photos://localID" for Photos Library
    private var cache: [String: [CGRect]] = [:]
    private var inFlight: Set<String> = []

    private let maxParallelDetections: Int = 3

    private init() {}

    /// Generate cache key from MediaItem
    private func cacheKey(for item: MediaItem) -> String {
        switch item.source {
        case .filesystem(let url):
            return url.path
        case .photosLibrary(let localID, _):
            return "photos://\(localID)"
        }
    }

    /// Returns cached faces if available (no detection is performed).
    func cachedFaces(for item: MediaItem) -> [CGRect]? {
        cache[cacheKey(for: item)]
    }

    /// Legacy method for URL-based access
    func cachedFaces(for url: URL) -> [CGRect]? {
        cache[url.path]
    }

    /// Ingest face data loaded from a saved document.
    /// - Important: This is trusted as authoritative and will not be re-detected.
    func ingest(faceRectsByPath: [String: [SlideshowDocument.FaceRect]]?) {
        guard let faceRectsByPath else { return }
        for (key, rects) in faceRectsByPath {
            // Keys can be either file paths or "photos://localID"
            cache[key] = rects.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        }
    }

    /// Snapshot currently-cached face rects for the provided MediaItems (keyed by cache key).
    /// - Note: Items that have no cached entry are omitted (so they can be detected later and saved next time).
    func snapshotFaceRects(for items: [MediaItem]) async -> [String: [SlideshowDocument.FaceRect]] {
        var result: [String: [SlideshowDocument.FaceRect]] = [:]
        for item in items {
            let key = cacheKey(for: item)
            guard let rects = cache[key] else { continue }
            let faceRects = await MainActor.run {
                rects.map { SlideshowDocument.FaceRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
            }
            result[key] = faceRects
        }
        return result
    }

    /// Legacy snapshot method for URL-based access
    func snapshotFaceRectsByPath(for urls: [URL]) async -> [String: [SlideshowDocument.FaceRect]] {
        var result: [String: [SlideshowDocument.FaceRect]] = [:]
        for url in urls {
            guard let rects = cache[url.path] else { continue }
            let faceRects = await MainActor.run {
                rects.map { SlideshowDocument.FaceRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
            }
            result[url.path] = faceRects
        }
        return result
    }

    /// Prefetch face detection for URLs that aren't cached yet.
    /// This should be called from import/open flows, not from playback.
    /// - Note: This only works for filesystem URLs. Use `prefetch(items:)` for Photos Library support.
    func prefetch(urls: [URL]) async {
        let unique = Array(Set(urls))
        let toDetect = unique.filter { cache[$0.path] == nil && !inFlight.contains($0.path) }
        guard !toDetect.isEmpty else { return }

        for url in toDetect {
            inFlight.insert(url.path)
        }

        // Limit concurrency to keep large imports responsive.
        await withTaskGroup(of: Void.self) { group in
            var iterator = toDetect.makeIterator()

            func enqueueNext() {
                guard let next = iterator.next() else { return }
                group.addTask { [weak self] in
                    guard let self else { return }
                    let faces = await self.detectFaces(url: next)
                    await self.store(key: next.path, faces: faces)
                    await self.markDone(key: next.path)
                }
            }

            for _ in 0..<min(maxParallelDetections, toDetect.count) {
                enqueueNext()
            }

            while await group.next() != nil {
                enqueueNext()
            }
        }
    }

    /// Prefetch face detection for MediaItems that aren't cached yet.
    /// Supports both filesystem and Photos Library items.
    /// This should be called from import/open flows, not from playback.
    func prefetch(items: [MediaItem]) async {
        // Filter to photos only (no face detection on videos) and uncached items
        let photoItems = items.filter { $0.kind == .photo }
        let toDetect = photoItems.filter {
            let key = cacheKey(for: $0)
            return cache[key] == nil && !inFlight.contains(key)
        }
        guard !toDetect.isEmpty else { return }

        for item in toDetect {
            inFlight.insert(cacheKey(for: item))
        }

        // Limit concurrency to keep large imports responsive.
        await withTaskGroup(of: Void.self) { group in
            var iterator = toDetect.makeIterator()

            func enqueueNext() {
                guard let next = iterator.next() else { return }
                let key = cacheKey(for: next)
                group.addTask { [weak self] in
                    guard let self else { return }
                    let faces = await self.detectFaces(item: next)
                    await self.store(key: key, faces: faces)
                    await self.markDone(key: key)
                }
            }

            for _ in 0..<min(maxParallelDetections, toDetect.count) {
                enqueueNext()
            }

            while await group.next() != nil {
                enqueueNext()
            }
        }
    }

    /// Clears the cache (useful for memory pressure handling later).
    func clear() {
        cache.removeAll()
        inFlight.removeAll()
    }

    // MARK: - Internals

    private func store(key: String, faces: [CGRect]) {
        let wasMissing = (cache[key] == nil)
        cache[key] = faces

        // Face metadata changed (import-time only) → mark document dirty so it can be persisted on next save.
        if wasMissing {
            Task { @MainActor in
                AppSessionState.shared.markDirty()
            }
        }
    }

    private func markDone(key: String) {
        inFlight.remove(key)
    }

    private func detectFaces(url: URL) async -> [CGRect] {
        // Never throw; face detection is best-effort and should be silent on failure.
        await Task.detached(priority: .utility) {
            autoreleasepool {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(url: url, options: [:])

                do {
                    try handler.perform([request])
                    // VNDetectFaceRectanglesRequest.results is already [VNFaceObservation]? on modern SDKs.
                    let observations = request.results ?? []
                    return observations.map(\.boundingBox)
                } catch {
                    return []
                }
            }
        }.value
    }

    /// Detect faces from a MediaItem (supports both filesystem and Photos Library)
    private func detectFaces(item: MediaItem) async -> [CGRect] {
        switch item.source {
        case .filesystem(let url):
            return await detectFaces(url: url)
        case .photosLibrary(let localID, _):
            return await detectFaces(photosLibraryLocalID: localID)
        }
    }

    /// Detect faces from a Photos Library asset using CGImage
    private func detectFaces(photosLibraryLocalID: String) async -> [CGRect] {
        // Load CGImage from Photos Library
        guard let cgImage = await PhotosLibraryImageLoader.shared.loadFullResolutionCGImage(localIdentifier: photosLibraryLocalID) else {
            return []
        }

        // Run face detection on the CGImage
        return await Task.detached(priority: .utility) {
            autoreleasepool {
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    return observations.map(\.boundingBox)
                } catch {
                    return []
                }
            }
        }.value
    }
}


