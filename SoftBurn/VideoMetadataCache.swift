//
//  VideoMetadataCache.swift
//  SoftBurn
//

import AVFoundation
import Foundation
import CoreGraphics

/// Caches video metadata needed for UI (duration).
actor VideoMetadataCache {
    static let shared = VideoMetadataCache()

    private var durationByURL: [URL: Double] = [:]

    private init() {}

    func durationSeconds(for url: URL) async -> Double? {
        if let cached = durationByURL[url] {
            return cached
        }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return nil
        }

        guard duration.isNumeric else { return nil }
        let seconds = max(0, CMTimeGetSeconds(duration))

        durationByURL[url] = seconds

        return seconds
    }

    func presentationSize(for url: URL) async -> CGSize? {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            return nil
        }
        guard let track = tracks.first else { return nil }

        let natural: CGSize
        let t: CGAffineTransform
        do {
            natural = try await track.load(.naturalSize)
            t = try await track.load(.preferredTransform)
        } catch {
            return nil
        }

        // Apply preferred transform to get the displayed size.
        let rect = CGRect(origin: .zero, size: natural).applying(t)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    func durationString(for url: URL) async -> String? {
        guard let seconds = await durationSeconds(for: url) else { return nil }
        return Self.format(seconds: seconds)
    }

    nonisolated static func format(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}


