//
//  FaceDetectionCache.swift
//  SoftBurn
//
//  Created by SoftBurn on 05/01/2026.
//

import Foundation
import CoreGraphics
import Vision

/// In-memory cache of Vision face detection results.
/// - Important: Detection is intended to run during import/open only (never during playback).
actor FaceDetectionCache {
    static let shared = FaceDetectionCache()

    /// Normalized bounding boxes in Vision coordinate space (origin bottom-left).
    private var cache: [URL: [CGRect]] = [:]
    private var inFlight: Set<URL> = []

    private let maxParallelDetections: Int = 3

    private init() {}

    /// Returns cached faces if available (no detection is performed).
    func cachedFaces(for url: URL) -> [CGRect]? {
        cache[url]
    }

    /// Ingest face data loaded from a saved document.
    /// - Important: This is trusted as authoritative and will not be re-detected.
    func ingest(faceRectsByPath: [String: [SlideshowDocument.FaceRect]]?) {
        guard let faceRectsByPath else { return }
        for (path, rects) in faceRectsByPath {
            let url = URL(fileURLWithPath: path)
            // Avoid keypaths here to satisfy Swift 6 strict concurrency/isolation checks.
            cache[url] = rects.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        }
    }

    /// Snapshot currently-cached face rects for the provided URLs (keyed by `url.path`).
    /// - Note: URLs that have no cached entry are omitted (so they can be detected later and saved next time).
    func snapshotFaceRectsByPath(for urls: [URL]) async -> [String: [SlideshowDocument.FaceRect]] {
        var result: [String: [SlideshowDocument.FaceRect]] = [:]
        for url in urls {
            guard let rects = cache[url] else { continue }
            // If your project uses "Default actor = MainActor", value-type initializers may become MainActor-isolated.
            // Construct these on the main actor to avoid Swift 6 isolation warnings.
            let faceRects = await MainActor.run {
                rects.map { SlideshowDocument.FaceRect(x: $0.origin.x, y: $0.origin.y, width: $0.size.width, height: $0.size.height) }
            }
            result[url.path] = faceRects
        }
        return result
    }

    /// Prefetch face detection for URLs that aren't cached yet.
    /// This should be called from import/open flows, not from playback.
    func prefetch(urls: [URL]) async {
        let unique = Array(Set(urls))
        let toDetect = unique.filter { cache[$0] == nil && !inFlight.contains($0) }
        guard !toDetect.isEmpty else { return }

        for url in toDetect {
            inFlight.insert(url)
        }

        // Limit concurrency to keep large imports responsive.
        await withTaskGroup(of: Void.self) { group in
            var iterator = toDetect.makeIterator()

            func enqueueNext() {
                guard let next = iterator.next() else { return }
                group.addTask { [weak self] in
                    guard let self else { return }
                    let faces = await self.detectFaces(url: next)
                    await self.store(url: next, faces: faces)
                    await self.markDone(url: next)
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

    private func store(url: URL, faces: [CGRect]) {
        let wasMissing = (cache[url] == nil)
        cache[url] = faces

        // Face metadata changed (import-time only) → mark document dirty so it can be persisted on next save.
        if wasMissing {
            Task { @MainActor in
                AppSessionState.shared.markDirty()
            }
        }
    }

    private func markDone(url: URL) {
        inFlight.remove(url)
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
}


