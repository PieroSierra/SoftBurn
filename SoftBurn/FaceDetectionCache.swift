//
//  FaceDetectionCache.swift
//  SoftBurn
//
//  Created by SoftBurn on 05/01/2026.
//

import Foundation
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
        cache[url] = faces
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
                    let observations = (request.results as? [VNFaceObservation]) ?? []
                    return observations.map(\.boundingBox)
                } catch {
                    return []
                }
            }
        }.value
    }
}


