//
//  iCloudDownloadManager.swift
//  SoftBurn
//
//  Centralized tracking of iCloud download state for Photos Library items.
//  Monitors network availability via NWPathMonitor and auto-retries failed downloads.
//
//  Download states are transient (in-memory only) — not persisted to .softburn files.
//  Filesystem items are not tracked (macOS handles iCloud Drive sync transparently).
//

import Foundation
import Photos
import Network
import Combine

/// Download state for a Photos Library media item
enum DownloadState: Sendable, Equatable {
    case ready
    case downloading
    case unavailable
}

/// MainActor-published download states for SwiftUI views to observe directly.
/// Eliminates the actor-hop race where state transitions complete before views exist.
/// All access must happen on MainActor (enforced by callers).
@MainActor
final class DownloadStatePublisher: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    static let shared = DownloadStatePublisher()
    private(set) var states: [UUID: DownloadState] = [:]
    private(set) var networkRestoredGeneration: Int = 0

    func notifyNetworkRestored() {
        networkRestoredGeneration += 1
        objectWillChange.send()
    }

    /// Set initial downloading state for Photos Library items synchronously on MainActor.
    /// Call BEFORE addPhotos() so ThumbnailView sees badges on its very first render.
    func register(_ items: [MediaItem]) {
        var changed = false
        for item in items where item.isFromPhotosLibrary {
            if states[item.id] == nil {
                states[item.id] = .downloading
                changed = true
            }
        }
        print("[iCloud][Publisher] register: \(items.filter { $0.isFromPhotosLibrary }.count) Photos items, changed=\(changed), total states=\(states.count)")
        if changed { objectWillChange.send() }
    }

    /// Called by iCloudDownloadManager when state changes on the actor side.
    func update(id: UUID, state: DownloadState) {
        guard states[id] != state else { return }
        let shortID = id.uuidString.prefix(8)
        print("[iCloud][Publisher] update: \(shortID) → \(state)")
        states[id] = state
        objectWillChange.send()
    }
}

/// Centralized actor for tracking iCloud download state and retrying failed downloads.
actor iCloudDownloadManager {
    static let shared = iCloudDownloadManager()

    private var states: [UUID: DownloadState] = [:]
    private var retryCounts: [UUID: Int] = [:]
    private var items: [UUID: MediaItem] = [:]
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]

    private let maxRetries = 3
    private let downloadTimeout: TimeInterval = 30
    private var lastNetworkRetryTime: CFAbsoluteTime = 0

    // Network monitoring
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.softburn.networkMonitor")
    private var _isNetworkAvailable = true

    // State change notifications via continuations
    private var continuations: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var streamContinuation: AsyncStream<(UUID, DownloadState)>.Continuation?

    /// Stream of (itemID, newState) changes for observers
    nonisolated let stateChanges: AsyncStream<(UUID, DownloadState)>

    private init() {
        var continuation: AsyncStream<(UUID, DownloadState)>.Continuation!
        stateChanges = AsyncStream { continuation = $0 }
        // Can't assign to self in nonisolated init, so defer to a setup method
        Task { await self.setUp(continuation: continuation) }
    }

    private func setUp(continuation: AsyncStream<(UUID, DownloadState)>.Continuation) {
        self.streamContinuation = continuation
        startNetworkMonitor()
    }

    // MARK: - Public API

    /// Register initial `.downloading` state for all Photos Library items in a single actor hop.
    /// Fast, no I/O. Call BEFORE items appear in the grid so ThumbnailView sees badges immediately.
    func registerItems(_ items: [MediaItem]) {
        let photosItems = items.filter { $0.isFromPhotosLibrary && self.items[$0.id] == nil }
        print("[iCloud] registerItems: \(photosItems.count) new Photos Library items")
        for item in photosItems {
            self.items[item.id] = item
            setState(.downloading, for: item.id)
        }
    }

    /// Begin tracking a Photos Library item. Probes local availability via PHAssetResourceManager,
    /// then starts a full-resolution download if needed.
    func trackItem(_ item: MediaItem) {
        guard item.isFromPhotosLibrary else { return }

        // Register if not already known
        if items[item.id] == nil {
            items[item.id] = item
            setState(.downloading, for: item.id)
        }

        // Only probe/download if still in .downloading state
        guard states[item.id] == .downloading else { return }

        // Probe + download is async, launch as a task
        Task { [weak self] in
            guard let self else { return }
            let isLocal = await self.probeFullSizeLocal(item)
            let shortID = item.id.uuidString.prefix(8)
            print("[iCloud] \(shortID) probe: \(isLocal ? "LOCAL" : "NEEDS_DOWNLOAD")")
            guard await self.states[item.id] == .downloading else { return }
            if isLocal {
                await self.setState(.ready, for: item.id)
            } else {
                await self.startDownload(for: item)
            }
        }
    }

    /// Query the current download state for an item.
    func state(for itemID: UUID) -> DownloadState {
        states[itemID] ?? .ready
    }

    /// Check if network is currently available.
    var isNetworkAvailable: Bool {
        _isNetworkAvailable
    }

    /// Stop monitoring and cancel all in-flight downloads.
    func stop() {
        monitor.cancel()
        for (_, task) in downloadTasks {
            task.cancel()
        }
        downloadTasks.removeAll()
        streamContinuation?.finish()
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task {
                await self.handleNetworkChange(satisfied: path.status == .satisfied)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func handleNetworkChange(satisfied: Bool) {
        let wasUnavailable = !_isNetworkAvailable
        _isNetworkAvailable = satisfied

        // On macOS, non-WiFi interfaces (Thunderbolt Bridge, etc.) can keep the path
        // "satisfied" even when WiFi is off. So rather than requiring a full offline→online
        // transition, retry whenever the path changes to satisfied — with a cooldown to
        // prevent rapid-fire retries when the path flaps.
        guard satisfied else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard wasUnavailable || (now - lastNetworkRetryTime) > 30 else { return }
        lastNetworkRetryTime = now

        retryUnavailableItems()
        Task { @MainActor in
            DownloadStatePublisher.shared.notifyNetworkRestored()
        }
    }

    private func retryUnavailableItems() {
        for (id, state) in states where state == .unavailable {
            guard let item = items[id] else { continue }
            // Reset retry count on network change
            retryCounts[id] = 0
            setState(.downloading, for: id)
            startDownload(for: item)
        }
    }

    // MARK: - Download Execution

    private func startDownload(for item: MediaItem) {
        // Cancel any existing download task for this item
        downloadTasks[item.id]?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.executeDownload(for: item)
        }
        downloadTasks[item.id] = task
    }

    private func executeDownload(for item: MediaItem) async {
        let id = item.id

        // Race: download vs timeout
        let success = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // Attempt the actual download
                return await self.performDownload(for: item)
            }
            group.addTask {
                // Timeout
                try? await Task.sleep(nanoseconds: UInt64(self.downloadTimeout * 1_000_000_000))
                return false
            }

            // First result wins
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        // Check if we were cancelled (e.g., stop() called)
        guard !Task.isCancelled else { return }

        if success {
            setState(.ready, for: id)
            downloadTasks.removeValue(forKey: id)

            // Notify face detection cache to retry pending items
            Task.detached(priority: .utility) {
                await FaceDetectionCache.shared.retryPendingItems(for: item)
            }
        } else {
            let count = (retryCounts[id] ?? 0) + 1
            retryCounts[id] = count

            if count < maxRetries && _isNetworkAvailable {
                // Retry with backoff
                let delay = UInt64(pow(2.0, Double(count))) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                startDownload(for: item)
            } else {
                setState(.unavailable, for: id)
                downloadTasks.removeValue(forKey: id)
            }
        }
    }

    private func performDownload(for item: MediaItem) async -> Bool {
        guard case .photosLibrary(let localID, _) = item.source else { return false }
        let shortID = item.id.uuidString.prefix(8)
        let start = CFAbsoluteTimeGetCurrent()

        switch item.kind {
        case .photo:
            // Request full resolution (PHImageManagerMaximumSize) to trigger actual iCloud download.
            // A small target (e.g. 350x350) is satisfied from the local thumbnail cache even offline,
            // which would falsely report success.
            let image = await PhotosLibraryImageLoader.shared.loadFullResolutionCGImage(
                localIdentifier: localID
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let success = image != nil
            print("[iCloud] \(shortID) performDownload photo: \(success ? "OK" : "FAIL") in \(String(format: "%.1f", elapsed))s" +
                  (image != nil ? " (\(image!.width)x\(image!.height))" : ""))
            return success
        case .video:
            // Trigger iCloud download by requesting the video URL
            let url = await PhotosLibraryImageLoader.shared.getVideoURL(localIdentifier: localID)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let success = url != nil
            print("[iCloud] \(shortID) performDownload video: \(success ? "OK" : "FAIL") in \(String(format: "%.1f", elapsed))s")
            return success
        }
    }

    // MARK: - State Management

    private func setState(_ newState: DownloadState, for id: UUID) {
        let oldState = states[id]
        guard oldState != newState else { return }
        states[id] = newState
        let shortID = id.uuidString.prefix(8)
        print("[iCloud] \(shortID): \(oldState.map { "\($0)" } ?? "nil") → \(newState)")
        streamContinuation?.yield((id, newState))

        // Push to MainActor publisher for SwiftUI views
        Task { @MainActor in
            DownloadStatePublisher.shared.update(id: id, state: newState)
        }
    }

    // MARK: - Local Availability Probe

    /// Check if the full-size resource is truly on disk using PHAssetResourceManager with
    /// isNetworkAccessAllowed=false. This is the only reliable approach:
    /// - PHAssetResource.value(forKey: "locallyAvailable") — undocumented KVC key, defaults to true
    /// - PHAssetResource type checking — resource types exist whether data is local or in iCloud
    /// - PHImageManager with isNetworkAccessAllowed=false — returns optimized/cached proxy versions
    /// - PHImageManager.loadFullResolution / getVideoURL — succeed from local cache even offline
    ///
    /// PHAssetResourceManager.requestData with isNetworkAccessAllowed=false will fail with an error
    /// if the resource data is not on disk. We request just the first chunk and cancel immediately.
    private nonisolated func probeFullSizeLocal(_ item: MediaItem) async -> Bool {
        guard case .photosLibrary(let localID, _) = item.source else { return true }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else {
            return false
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let targetTypes: [PHAssetResourceType] = item.kind == .photo
            ? [.fullSizePhoto, .photo]
            : [.fullSizeVideo, .video]

        guard let resource = resources.first(where: { targetTypes.contains($0.type) }) else {
            return false
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        // Use a class to safely share mutable state across callbacks from any thread
        final class ProbeState: @unchecked Sendable {
            private let lock = NSLock()
            private var _gotData = false
            private var _resumed = false
            private var _continuation: CheckedContinuation<Bool, Never>?

            init(continuation: CheckedContinuation<Bool, Never>) {
                self._continuation = continuation
            }

            func onDataReceived(requestID: PHAssetResourceDataRequestID) {
                lock.lock()
                _gotData = true
                if !_resumed {
                    _resumed = true
                    let cont = _continuation
                    _continuation = nil
                    lock.unlock()
                    PHAssetResourceManager.default().cancelDataRequest(requestID)
                    cont?.resume(returning: true)
                } else {
                    lock.unlock()
                }
            }

            func onCompletion() {
                lock.lock()
                if !_resumed {
                    _resumed = true
                    let cont = _continuation
                    let gotData = _gotData
                    _continuation = nil
                    lock.unlock()
                    cont?.resume(returning: gotData)
                } else {
                    lock.unlock()
                }
            }
        }

        // Wrap requestID so the closure can capture the box before the ID is assigned
        final class RequestIDBox: @unchecked Sendable {
            var value: PHAssetResourceDataRequestID = 0
        }

        return await withCheckedContinuation { continuation in
            let probe = ProbeState(continuation: continuation)
            let box = RequestIDBox()
            box.value = PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { _ in
                    probe.onDataReceived(requestID: box.value)
                },
                completionHandler: { _ in
                    probe.onCompletion()
                }
            )
        }
    }
}
