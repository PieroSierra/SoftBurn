//
//  PlayerLayerView.swift
//  SoftBurn
//

import AppKit
import AVFoundation
import SwiftUI

/// A lightweight video rendering view with **no playback controls** (unlike AVKit's VideoPlayer).
/// Used for slideshow playback to avoid hover/scrubber UI and "dimmed" overlays.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.setPlayer(player, gravity: videoGravity)
        return v
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        nsView.setPlayer(player, gravity: videoGravity)
    }
}

final class PlayerLayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

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
        if playerLayer.player !== player {
            playerLayer.player = player
        }
        if playerLayer.videoGravity != gravity {
            playerLayer.videoGravity = gravity
        }
    }
}


