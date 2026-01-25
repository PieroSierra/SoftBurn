//
//  EffectTuningView.swift
//  SoftBurn
//

import SwiftUI

#if DEBUG

import AppKit

struct EffectTuningView: View {
    @EnvironmentObject private var tuning: PatinaTuningStore

    var body: some View {
        TabView {
            Patina35mmTuningTab(mm35: $tuning.mm35)
                .tabItem { Text("35mm") }

            PatinaAgedFilmTuningTab(aged: $tuning.aged)
                .tabItem { Text("Aged Film") }

            PatinaVHSTuningTab(vhs: $tuning.vhs)
                .tabItem { Text("VHS") }
        }
        .padding(12)
    }
}

// MARK: - Generic slider row

private struct SliderRow: View {
    let title: String
    @Binding var value: Float
    let range: PatinaRange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "%.4f", value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Float($0) }
                ),
                in: Double(range.min)...Double(range.max)
            )
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Clipboard helpers

@MainActor
private func copyToClipboard(_ string: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(string, forType: .string)
}

private func fmt(_ v: Float) -> String { String(format: "%.6g", v) }

private func dump(_ v: Patina35mmTuning) -> String {
    """
    Patina35mmTuning(
        grainFineness: \(fmt(v.grainFineness)),
        grainIntensity: \(fmt(v.grainIntensity)),
        blurRadiusTexels: \(fmt(v.blurRadiusTexels)),
        toneR: \(fmt(v.toneR)),
        toneG: \(fmt(v.toneG)),
        toneB: \(fmt(v.toneB)),
        blackLift: \(fmt(v.blackLift)),
        contrast: \(fmt(v.contrast)),
        rolloffThreshold: \(fmt(v.rolloffThreshold)),
        rolloffSoftness: \(fmt(v.rolloffSoftness)),
        vignetteStrength: \(fmt(v.vignetteStrength)),
        vignetteRadius: \(fmt(v.vignetteRadius))
    )
    """
}

private func dump(_ v: PatinaAgedFilmTuning) -> String {
    """
    PatinaAgedFilmTuning(
        grainFineness: \(fmt(v.grainFineness)),
        grainIntensity: \(fmt(v.grainIntensity)),
        blurRadiusTexels: \(fmt(v.blurRadiusTexels)),
        jitterAmplitudeTexels: \(fmt(v.jitterAmplitudeTexels)),
        driftSpeed: \(fmt(v.driftSpeed)),
        driftIntensity: \(fmt(v.driftIntensity)),
        dimPulseSpeed: \(fmt(v.dimPulseSpeed)),
        dimPulseThreshold: \(fmt(v.dimPulseThreshold)),
        dimPulseIntensity: \(fmt(v.dimPulseIntensity)),
        highlightSoftThreshold: \(fmt(v.highlightSoftThreshold)),
        highlightSoftAmount: \(fmt(v.highlightSoftAmount)),
        shadowLiftThreshold: \(fmt(v.shadowLiftThreshold)),
        shadowLiftAmount: \(fmt(v.shadowLiftAmount)),
        vignetteStrength: \(fmt(v.vignetteStrength)),
        vignetteRadius: \(fmt(v.vignetteRadius)),
        dustRate: \(fmt(v.dustRate)),
        dustIntensity: \(fmt(v.dustIntensity)),
        dustSize: \(fmt(v.dustSize)),
        projectorSpeed: \(fmt(v.projectorSpeed))
    )
    """
}

private func dump(_ v: PatinaVHSTuning) -> String {
    """
    PatinaVHSTuning(
        blurTap1: \(fmt(v.blurTap1)),
        blurTap2: \(fmt(v.blurTap2)),
        blurW0: \(fmt(v.blurW0)),
        blurW1: \(fmt(v.blurW1)),
        blurW2: \(fmt(v.blurW2)),
        chromaOffsetTexels: \(fmt(v.chromaOffsetTexels)),
        chromaMix: \(fmt(v.chromaMix)),
        scanlineBase: \(fmt(v.scanlineBase)),
        scanlineAmp: \(fmt(v.scanlineAmp)),
        scanlinePow: \(fmt(v.scanlinePow)),
        lineFrequencyScale: \(fmt(v.lineFrequencyScale)),
        desat: \(fmt(v.desat)),
        tintR: \(fmt(v.tintR)),
        tintG: \(fmt(v.tintG)),
        tintB: \(fmt(v.tintB)),
        trackingThreshold: \(fmt(v.trackingThreshold)),
        trackingIntensity: \(fmt(v.trackingIntensity)),
        staticIntensity: \(fmt(v.staticIntensity)),
        tearEnabled: \(fmt(v.tearEnabled)),
        tearGateRate: \(fmt(v.tearGateRate)),
        tearGateThreshold: \(fmt(v.tearGateThreshold)),
        tearSpeed: \(fmt(v.tearSpeed)),
        tearBandHeight: \(fmt(v.tearBandHeight)),
        tearOffsetTexels: \(fmt(v.tearOffsetTexels)),
        edgeSoftStrength: \(fmt(v.edgeSoftStrength))
    )
    """
}

// MARK: - 35mm

private struct Patina35mmTuningTab: View {
    @Binding var mm35: Patina35mmTuning

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Button {
                        copyToClipboard(dump(mm35))
                    } label: {
                        Image(systemName: "document.on.document")
                    }
                    .help("Copy 35mm settings to clipboard")
                    .buttonStyle(.plain)
                }

                GroupBox("Grain") {
                    SliderRow(title: "grainFineness", value: $mm35.grainFineness, range: Patina35mmTuning.ranges["grainFineness"]!)
                    SliderRow(title: "grainIntensity", value: $mm35.grainIntensity, range: Patina35mmTuning.ranges["grainIntensity"]!)
                }

                GroupBox("Tone") {
                    SliderRow(title: "toneR", value: $mm35.toneR, range: Patina35mmTuning.ranges["toneR"]!)
                    SliderRow(title: "toneG", value: $mm35.toneG, range: Patina35mmTuning.ranges["toneG"]!)
                    SliderRow(title: "toneB", value: $mm35.toneB, range: Patina35mmTuning.ranges["toneB"]!)
                    SliderRow(title: "blackLift", value: $mm35.blackLift, range: Patina35mmTuning.ranges["blackLift"]!)
                    SliderRow(title: "contrast", value: $mm35.contrast, range: Patina35mmTuning.ranges["contrast"]!)
                }

                GroupBox("Highlights") {
                    SliderRow(title: "rolloffThreshold", value: $mm35.rolloffThreshold, range: Patina35mmTuning.ranges["rolloffThreshold"]!)
                    SliderRow(title: "rolloffSoftness", value: $mm35.rolloffSoftness, range: Patina35mmTuning.ranges["rolloffSoftness"]!)
                }

                GroupBox("Optics") {
                    SliderRow(title: "blurRadiusTexels", value: $mm35.blurRadiusTexels, range: Patina35mmTuning.ranges["blurRadiusTexels"]!)
                    SliderRow(title: "vignetteStrength", value: $mm35.vignetteStrength, range: Patina35mmTuning.ranges["vignetteStrength"]!)
                    SliderRow(title: "vignetteRadius", value: $mm35.vignetteRadius, range: Patina35mmTuning.ranges["vignetteRadius"]!)
                }
            }
        }
    }
}

// MARK: - Aged Film

private struct PatinaAgedFilmTuningTab: View {
    @Binding var aged: PatinaAgedFilmTuning

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Button {
                        copyToClipboard(dump(aged))
                    } label: {
                        Image(systemName: "document.on.document")
                    }
                    .help("Copy Aged Film settings to clipboard")
                    .buttonStyle(.plain)
                }

                GroupBox("Grain") {
                    SliderRow(title: "grainFineness", value: $aged.grainFineness, range: PatinaAgedFilmTuning.ranges["grainFineness"]!)
                    SliderRow(title: "grainIntensity", value: $aged.grainIntensity, range: PatinaAgedFilmTuning.ranges["grainIntensity"]!)
                }

                GroupBox("Optics") {
                    SliderRow(title: "blurRadiusTexels", value: $aged.blurRadiusTexels, range: PatinaAgedFilmTuning.ranges["blurRadiusTexels"]!)
                    SliderRow(title: "jitterAmplitudeTexels", value: $aged.jitterAmplitudeTexels, range: PatinaAgedFilmTuning.ranges["jitterAmplitudeTexels"]!)
                    SliderRow(title: "vignetteStrength", value: $aged.vignetteStrength, range: PatinaAgedFilmTuning.ranges["vignetteStrength"]!)
                    SliderRow(title: "vignetteRadius", value: $aged.vignetteRadius, range: PatinaAgedFilmTuning.ranges["vignetteRadius"]!)
                }

                GroupBox("Breathing") {
                    SliderRow(title: "driftSpeed", value: $aged.driftSpeed, range: PatinaAgedFilmTuning.ranges["driftSpeed"]!)
                    SliderRow(title: "driftIntensity", value: $aged.driftIntensity, range: PatinaAgedFilmTuning.ranges["driftIntensity"]!)
                    SliderRow(title: "dimPulseSpeed", value: $aged.dimPulseSpeed, range: PatinaAgedFilmTuning.ranges["dimPulseSpeed"]!)
                    SliderRow(title: "dimPulseThreshold", value: $aged.dimPulseThreshold, range: PatinaAgedFilmTuning.ranges["dimPulseThreshold"]!)
                    SliderRow(title: "dimPulseIntensity", value: $aged.dimPulseIntensity, range: PatinaAgedFilmTuning.ranges["dimPulseIntensity"]!)
                }

                GroupBox("Highlights/Shadows") {
                    SliderRow(title: "highlightSoftThreshold", value: $aged.highlightSoftThreshold, range: PatinaAgedFilmTuning.ranges["highlightSoftThreshold"]!)
                    SliderRow(title: "highlightSoftAmount", value: $aged.highlightSoftAmount, range: PatinaAgedFilmTuning.ranges["highlightSoftAmount"]!)
                    SliderRow(title: "shadowLiftThreshold", value: $aged.shadowLiftThreshold, range: PatinaAgedFilmTuning.ranges["shadowLiftThreshold"]!)
                    SliderRow(title: "shadowLiftAmount", value: $aged.shadowLiftAmount, range: PatinaAgedFilmTuning.ranges["shadowLiftAmount"]!)
                }

                GroupBox("Dust") {
                    SliderRow(title: "dustRate", value: $aged.dustRate, range: PatinaAgedFilmTuning.ranges["dustRate"]!)
                    SliderRow(title: "dustIntensity", value: $aged.dustIntensity, range: PatinaAgedFilmTuning.ranges["dustIntensity"]!)
                    SliderRow(title: "dustSize", value: $aged.dustSize, range: PatinaAgedFilmTuning.ranges["dustSize"]!)
                }

                GroupBox("Projector") {
                    SliderRow(title: "projectorSpeed", value: $aged.projectorSpeed, range: PatinaAgedFilmTuning.ranges["projectorSpeed"]!)
                }
            }
        }
    }
}

// MARK: - VHS

private struct PatinaVHSTuningTab: View {
    @Binding var vhs: PatinaVHSTuning

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Button {
                        copyToClipboard(dump(vhs))
                    } label: {
                        Image(systemName: "document.on.document")
                    }
                    .help("Copy VHS settings to clipboard")
                    .buttonStyle(.plain)
                }

                GroupBox("Blur") {
                    SliderRow(title: "blurTap1", value: $vhs.blurTap1, range: PatinaVHSTuning.ranges["blurTap1"]!)
                    SliderRow(title: "blurTap2", value: $vhs.blurTap2, range: PatinaVHSTuning.ranges["blurTap2"]!)
                    SliderRow(title: "blurW0", value: $vhs.blurW0, range: PatinaVHSTuning.ranges["blurW0"]!)
                    SliderRow(title: "blurW1", value: $vhs.blurW1, range: PatinaVHSTuning.ranges["blurW1"]!)
                    SliderRow(title: "blurW2", value: $vhs.blurW2, range: PatinaVHSTuning.ranges["blurW2"]!)
                }

                GroupBox("Chroma") {
                    SliderRow(title: "chromaOffsetTexels", value: $vhs.chromaOffsetTexels, range: PatinaVHSTuning.ranges["chromaOffsetTexels"]!)
                    SliderRow(title: "chromaMix", value: $vhs.chromaMix, range: PatinaVHSTuning.ranges["chromaMix"]!)
                }

                GroupBox("Lines") {
                    SliderRow(title: "scanlineBase", value: $vhs.scanlineBase, range: PatinaVHSTuning.ranges["scanlineBase"]!)
                    SliderRow(title: "scanlineAmp", value: $vhs.scanlineAmp, range: PatinaVHSTuning.ranges["scanlineAmp"]!)
                    SliderRow(title: "scanlinePow", value: $vhs.scanlinePow, range: PatinaVHSTuning.ranges["scanlinePow"]!)
                    SliderRow(title: "lineFrequencyScale", value: $vhs.lineFrequencyScale, range: PatinaVHSTuning.ranges["lineFrequencyScale"]!)
                }

                GroupBox("Tone") {
                    SliderRow(title: "desat", value: $vhs.desat, range: PatinaVHSTuning.ranges["desat"]!)
                    SliderRow(title: "tintR", value: $vhs.tintR, range: PatinaVHSTuning.ranges["tintR"]!)
                    SliderRow(title: "tintG", value: $vhs.tintG, range: PatinaVHSTuning.ranges["tintG"]!)
                    SliderRow(title: "tintB", value: $vhs.tintB, range: PatinaVHSTuning.ranges["tintB"]!)
                }

                GroupBox("Tracking / Static") {
                    SliderRow(title: "trackingThreshold", value: $vhs.trackingThreshold, range: PatinaVHSTuning.ranges["trackingThreshold"]!)
                    SliderRow(title: "trackingIntensity", value: $vhs.trackingIntensity, range: PatinaVHSTuning.ranges["trackingIntensity"]!)
                    SliderRow(title: "staticIntensity", value: $vhs.staticIntensity, range: PatinaVHSTuning.ranges["staticIntensity"]!)
                }

                GroupBox("Tear line") {
                    SliderRow(title: "tearEnabled", value: $vhs.tearEnabled, range: PatinaVHSTuning.ranges["tearEnabled"]!)
                    SliderRow(title: "tearGateRate", value: $vhs.tearGateRate, range: PatinaVHSTuning.ranges["tearGateRate"]!)
                    SliderRow(title: "tearGateThreshold", value: $vhs.tearGateThreshold, range: PatinaVHSTuning.ranges["tearGateThreshold"]!)
                    SliderRow(title: "tearSpeed", value: $vhs.tearSpeed, range: PatinaVHSTuning.ranges["tearSpeed"]!)
                    SliderRow(title: "tearBandHeight", value: $vhs.tearBandHeight, range: PatinaVHSTuning.ranges["tearBandHeight"]!)
                    SliderRow(title: "tearOffsetTexels", value: $vhs.tearOffsetTexels, range: PatinaVHSTuning.ranges["tearOffsetTexels"]!)
                }

                GroupBox("Edges") {
                    SliderRow(title: "edgeSoftStrength", value: $vhs.edgeSoftStrength, range: PatinaVHSTuning.ranges["edgeSoftStrength"]!)
                }
            }
        }
    }
}

#endif

