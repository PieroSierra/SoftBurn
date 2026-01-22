//
//  RecentSlideshowsManager.swift
//  SoftBurn
//
//  Created by Claude on 22/01/2026.
//

import Combine
import Foundation
import SwiftUI

/// Manages the list of recently opened slideshows
@MainActor
final class RecentSlideshowsManager: ObservableObject {
    static let shared = RecentSlideshowsManager()

    private static let maxItems = 5
    private static let storageKey = "recents.list"

    @AppStorage(storageKey) private var storedJSON: String = "[]"
    @Published private(set) var recentSlideshows: [RecentSlideshow] = []

    private init() {
        loadFromStorage()
    }

    /// Add or update a slideshow in the recents list
    func addOrUpdate(url: URL) {
        var list = recentSlideshows.filter { $0.url != url }
        let entry = RecentSlideshow(url: url)
        list.insert(entry, at: 0)
        if list.count > Self.maxItems {
            list = Array(list.prefix(Self.maxItems))
        }
        recentSlideshows = list
        saveToStorage()
    }

    /// Clear all recent entries
    func clearAll() {
        recentSlideshows = []
        saveToStorage()
    }

    /// Whether the list has any entries
    var isEmpty: Bool {
        recentSlideshows.isEmpty
    }

    // MARK: - Persistence

    private func loadFromStorage() {
        guard let data = storedJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentSlideshow].self, from: data) else {
            recentSlideshows = []
            return
        }
        recentSlideshows = decoded
    }

    private func saveToStorage() {
        guard let data = try? JSONEncoder().encode(recentSlideshows),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        storedJSON = json
    }
}
