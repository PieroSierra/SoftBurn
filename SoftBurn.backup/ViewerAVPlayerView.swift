//
//  ViewerAVPlayerView.swift
//  SoftBurn
//

import AppKit
import AVKit
import SwiftUI

/// AVPlayerView wrapper for the in-app viewer.
/// Shows native playback controls (on hover) and supports volume/mute via the built-in UI.
struct ViewerAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}


