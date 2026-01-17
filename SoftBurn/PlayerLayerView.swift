//
//  PlayerLayerView.swift
//  SoftBurn
//

import AppKit
import AVFoundation
import SwiftUI

/// A lightweight video rendering view with **no playback controls** (unlike AVKit's VideoPlayer).
/// Used for slideshow playback to avoid hover/scrubber UI and "dimmed" overlays.
///
/// IMPORTANT: This view uses identity-based caching to prevent the AVPlayerLayer from being
/// repeatedly reassigned during SwiftUI view updates. Without this, the 60fps animation timer
/// would trigger 120+ player reassignments during a 2-second transition, corrupting the
/// AVPlayer's internal render pipeline and causing video cutout.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        VideoDebugLogger.log("PlayerLayerView makeNSView: creating new view, player=\(ObjectIdentifier(player))")
        v.setPlayer(player, gravity: videoGravity)
        v.currentPlayerID = ObjectIdentifier(player)
        return v
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        // Use identity-based check to prevent redundant player assignments.
        // SwiftUI calls updateNSView on every frame (~60fps) during animated transitions,
        // but the underlying AVPlayer object may be the same. Only call setPlayer when
        // the actual player instance changes.
        let playerID = ObjectIdentifier(player)
        let currentPlayerID = nsView.currentPlayerID

        VideoDebugLogger.log("PlayerLayerView updateNSView: player=\(playerID), cached=\(String(describing: currentPlayerID)), same=\(playerID == currentPlayerID)")

        if nsView.currentPlayerID != playerID {
            VideoDebugLogger.log("PlayerLayerView: ASSIGNING new player")
            nsView.setPlayer(player, gravity: videoGravity)
            nsView.currentPlayerID = playerID
        } else if nsView.playerLayer.videoGravity != videoGravity {
            // Player is same but gravity changed
            nsView.playerLayer.videoGravity = videoGravity
        }

        // Log AVPlayer status
        VideoDebugLogger.log("PlayerLayerView: player.status=\(player.status.rawValue), rate=\(player.rate), error=\(player.error?.localizedDescription ?? "none")")

        // Log AVPlayerLayer status
        VideoDebugLogger.log("PlayerLayerView: layer.isReadyForDisplay=\(nsView.playerLayer.isReadyForDisplay)")
    }
}

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    /// Cached player identity to prevent redundant assignments during SwiftUI view updates.
    /// This is the key fix for the video cutout bug - see comment on PlayerLayerView.
    var currentPlayerID: ObjectIdentifier?

    /// KVO observer for isReadyForDisplay changes
    private var displayReadyObserver: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func setPlayer(_ player: AVPlayer, gravity: AVLayerVideoGravity) {
        let willChange = playerLayer.player !== player
        VideoDebugLogger.log("PlayerLayerNSView.setPlayer: willChange=\(willChange), player.status=\(player.status.rawValue)")

        if willChange {
            playerLayer.player = player
        }
        if playerLayer.videoGravity != gravity {
            playerLayer.videoGravity = gravity
        }

        VideoDebugLogger.log("PlayerLayerNSView.setPlayer: layer.isReadyForDisplay=\(playerLayer.isReadyForDisplay)")

        // Observe isReadyForDisplay changes to catch when the layer stops rendering
        displayReadyObserver?.invalidate()
        displayReadyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.new, .old]) { layer, change in
            VideoDebugLogger.log("PlayerLayerNSView: isReadyForDisplay changed from \(change.oldValue ?? false) to \(change.newValue ?? false)")
        }
    }

    deinit {
        displayReadyObserver?.invalidate()
        VideoDebugLogger.log("PlayerLayerNSView deinit: view deallocated")
    }
}


