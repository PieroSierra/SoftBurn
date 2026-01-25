//
//  PatinaTuning.swift
//  SoftBurn
//
//  Central place to tweak Patina parameters (defaults + debug live tuning).
//

import Foundation
import SwiftUI
import Combine

// MARK: - Shared tuning store (DEBUG UI binds here)

@MainActor
final class PatinaTuningStore: ObservableObject {
    static let shared = PatinaTuningStore()

    @Published var mm35 = Patina35mmTuning()
    @Published var aged = PatinaAgedFilmTuning()
    @Published var vhs = PatinaVHSTuning()

    private init() {}
}

// MARK: - Range helpers

struct PatinaRange {
    let min: Float
    let max: Float
    let step: Float
}

// MARK: - 35mm

struct Patina35mmTuning: Codable {
    // **grainFineness**: lower = bigger grain (typical: 400–1200)
    var grainFineness: Float = 815.965
    // **grainIntensity**: 0..0.10
    var grainIntensity: Float = 0.049984
    // **blurRadiusTexels**: 0..2
    var blurRadiusTexels: Float = 0.617781

    // **toneMultiplyRGB**: subtle film-stock bias
    var toneR: Float = 1.02
    var toneG: Float = 1.00
    var toneB: Float = 0.985

    // **blackLift**: 0..0.05
    var blackLift: Float = 0.02
    // **contrast**: 0.85..1.0 (lower = flatter/matte)
    var contrast: Float = 0.988194

    // **highlight rolloff**
    var rolloffThreshold: Float = 0.78  // 0.7..0.9
    var rolloffSoftness: Float = 3.2    // 1..6

    // **vignette**
    var vignetteStrength: Float = 0.0668097  // 0..0.30
    var vignetteRadius: Float = 0.911445     // 0.80..0.95

    static let ranges: [String: PatinaRange] = [
        "grainFineness": .init(min: 300, max: 1400, step: 1),
        "grainIntensity": .init(min: 0.00, max: 0.10, step: 0.001),
        "blurRadiusTexels": .init(min: 0.00, max: 2.00, step: 0.01),
        "toneR": .init(min: 0.90, max: 1.10, step: 0.001),
        "toneG": .init(min: 0.90, max: 1.10, step: 0.001),
        "toneB": .init(min: 0.90, max: 1.10, step: 0.001),
        "blackLift": .init(min: 0.00, max: 0.05, step: 0.001),
        "contrast": .init(min: 0.85, max: 1.00, step: 0.001),
        "rolloffThreshold": .init(min: 0.70, max: 0.90, step: 0.001),
        "rolloffSoftness": .init(min: 1.0, max: 6.0, step: 0.01),
        "vignetteStrength": .init(min: 0.00, max: 0.30, step: 0.001),
        "vignetteRadius": .init(min: 0.80, max: 0.95, step: 0.001),
    ]
}

// MARK: - Aged Film

struct PatinaAgedFilmTuning: Codable {
    var grainFineness: Float = 250         // 250..1000
    var grainIntensity: Float = 0.0737154  // 0..0.12
    var blurRadiusTexels: Float = 3.0      // 0..3

    // Jitter/weave (sub-pixel), in texels
    var jitterAmplitudeTexels: Float = 2.16752 // 0..3

    // Drift / breathing
    var driftSpeed: Float = 0.976296       // 0..1
    var driftIntensity: Float = 0.0121638  // 0..0.05

    // Occasional dim pulse
    var dimPulseSpeed: Float = 0.907862        // 0..1
    var dimPulseThreshold: Float = 0.988496    // 0.90..0.999
    var dimPulseIntensity: Float = -0.031574   // -0.06..0

    // Highlight/shadow shaping
    var highlightSoftThreshold: Float = 0.75 // 0.6..0.9
    var highlightSoftAmount: Float = 0.15    // 0..0.4
    var shadowLiftThreshold: Float = 0.15    // 0..0.3
    var shadowLiftAmount: Float = 0.193644   // 0..0.3

    // Vignette
    var vignetteStrength: Float = 0.2104   // 0..0.40
    var vignetteRadius: Float = 0.75       // 0.75..0.95

    // Dust
    var dustRate: Float = 0.00306438       // 0..0.01
    var dustIntensity: Float = 0.133389    // 0..0.6
    var dustSize: Float = 18.8924          // 1..20 (larger = thicker/more varied dust lines)

    static let ranges: [String: PatinaRange] = [
        "grainFineness": .init(min: 250, max: 1000, step: 1),
        "grainIntensity": .init(min: 0.00, max: 0.12, step: 0.001),
        "blurRadiusTexels": .init(min: 0.00, max: 3.00, step: 0.01),
        "jitterAmplitudeTexels": .init(min: 0.00, max: 3.00, step: 0.01),
        "driftSpeed": .init(min: 0.00, max: 1.00, step: 0.01),
        "driftIntensity": .init(min: 0.00, max: 0.05, step: 0.001),
        "dimPulseSpeed": .init(min: 0.00, max: 1.00, step: 0.01),
        "dimPulseThreshold": .init(min: 0.90, max: 0.999, step: 0.001),
        "dimPulseIntensity": .init(min: -0.06, max: 0.0, step: 0.001),
        "highlightSoftThreshold": .init(min: 0.60, max: 0.90, step: 0.001),
        "highlightSoftAmount": .init(min: 0.00, max: 0.40, step: 0.001),
        "shadowLiftThreshold": .init(min: 0.00, max: 0.30, step: 0.001),
        "shadowLiftAmount": .init(min: 0.00, max: 0.30, step: 0.001),
        "vignetteStrength": .init(min: 0.00, max: 0.40, step: 0.001),
        "vignetteRadius": .init(min: 0.75, max: 0.95, step: 0.001),
        "dustRate": .init(min: 0.0, max: 0.01, step: 0.0001),
        "dustIntensity": .init(min: 0.00, max: 0.60, step: 0.01),
        "dustSize": .init(min: 1.0, max: 20.0, step: 0.1),
    ]
}

// MARK: - VHS

struct PatinaVHSTuning: Codable {
    // Horizontal blur taps/weights
    var blurTap1: Float = 2.0          // 0..8
    var blurTap2: Float = 4.0          // 0..12
    var blurW0: Float = 0.45           // 0.2..0.8
    var blurW1: Float = 0.22           // 0..0.4
    var blurW2: Float = 0.0848369      // 0..0.2

    // Chroma bleed / aberration
    var chromaOffsetTexels: Float = 3.60274 // 0..10
    var chromaMix: Float = 0.194751         // 0..0.30

    // Lines
    var scanlineBase: Float = 0.96         // 0.7..1.0
    var scanlineAmp: Float = 0.180328      // 0..0.20
    var scanlinePow: Float = 1.18387       // 0.1..2
    var lineFrequencyScale: Float = 0.874821 // 0.4..1.0 (lower = thicker lines)
    var scanlineBandWidth: Float = 0.65    // 0.5..0.8 (ratio of bright band)
    var blackLift: Float = 0.08            // 0..0.20 (minimum black level)

    // Color/tone
    var desat: Float = 0.80                // 0..1
    var tintR: Float = 0.97                // 0.8..1.2
    var tintG: Float = 1.00
    var tintB: Float = 1.03

    // Tracking/static
    var trackingThreshold: Float = 0.995   // 0.9..1.0
    var trackingIntensity: Float = 0.12    // 0..0.5
    var staticIntensity: Float = 0.025     // 0..0.10

    // Tear line (scan tear)
    var tearEnabled: Float = 1.0              // 0/1 slider (debug convenience)
    var tearGateRate: Float = 1.7349          // 0..2 (how often to re-roll)
    var tearGateThreshold: Float = 0.551752   // 0.5..0.99 (higher = rarer)
    var tearSpeed: Float = 0.0637713          // 0..2 (downward scan speed)
    var tearBandHeight: Float = 0.0411877     // 0.001..0.05 (UV)
    var tearOffsetTexels: Float = 8.76785     // 0..10 (horizontal offset)

    // Edge softness
    var edgeSoftStrength: Float = 0.0427662  // 0..0.10

    static let ranges: [String: PatinaRange] = [
        "blurTap1": .init(min: 0, max: 8, step: 0.1),
        "blurTap2": .init(min: 0, max: 12, step: 0.1),
        "blurW0": .init(min: 0.2, max: 0.8, step: 0.001),
        "blurW1": .init(min: 0.0, max: 0.4, step: 0.001),
        "blurW2": .init(min: 0.0, max: 0.2, step: 0.001),
        "chromaOffsetTexels": .init(min: 0.0, max: 10.0, step: 0.1),
        "chromaMix": .init(min: 0.0, max: 0.30, step: 0.001),
        "scanlineBase": .init(min: 0.70, max: 1.0, step: 0.001),
        "scanlineAmp": .init(min: 0.0, max: 0.20, step: 0.001),
        "scanlinePow": .init(min: 0.10, max: 2.0, step: 0.01),
        "lineFrequencyScale": .init(min: 0.40, max: 1.0, step: 0.01),
        "scanlineBandWidth": .init(min: 0.50, max: 0.80, step: 0.01),
        "blackLift": .init(min: 0.0, max: 0.20, step: 0.005),
        "desat": .init(min: 0.0, max: 1.0, step: 0.001),
        "tintR": .init(min: 0.80, max: 1.20, step: 0.001),
        "tintG": .init(min: 0.80, max: 1.20, step: 0.001),
        "tintB": .init(min: 0.80, max: 1.20, step: 0.001),
        "trackingThreshold": .init(min: 0.90, max: 1.0, step: 0.001),
        "trackingIntensity": .init(min: 0.0, max: 0.50, step: 0.001),
        "staticIntensity": .init(min: 0.0, max: 0.10, step: 0.001),
        "tearEnabled": .init(min: 0.0, max: 1.0, step: 1.0),
        "tearGateRate": .init(min: 0.0, max: 2.0, step: 0.01),
        "tearGateThreshold": .init(min: 0.50, max: 0.99, step: 0.001),
        "tearSpeed": .init(min: 0.0, max: 2.0, step: 0.01),
        "tearBandHeight": .init(min: 0.001, max: 0.05, step: 0.001),
        "tearOffsetTexels": .init(min: 0.0, max: 10.0, step: 0.1),
        "edgeSoftStrength": .init(min: 0.0, max: 0.10, step: 0.001),
    ]
}

