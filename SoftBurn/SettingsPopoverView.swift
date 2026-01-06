//
//  SettingsPopoverView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI

/// Popover view for global slideshow settings
struct SettingsPopoverView: View {
    @ObservedObject var settings: SlideshowSettings
    @State private var showColorPicker = false
    
    private let labelWidth: CGFloat = 100
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Transition Style
            settingsRow(label: "Transition") {
                Picker("", selection: $settings.transitionStyle) {
                    ForEach(SlideshowDocument.Settings.TransitionStyle.allCases, id: \.self) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 150, alignment: .leading)
            }
            
            // Zoom on Faces (only available with Pan & Zoom)
            settingsRow(label: "") {
                Toggle("Zoom on faces", isOn: $settings.zoomOnFaces)
                    .toggleStyle(.checkbox)
                    .disabled(settings.transitionStyle != .panAndZoom)
            }
            
            Divider()
                .padding(.vertical, 4)
            
          
            
            // Background Color
            settingsRow(label: "Background") {
                Button(action: { showColorPicker.toggle() }) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(settings.backgroundColor)
                        .frame(width: 40, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.2), lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showColorPicker, arrowEdge: .trailing) {
                    BackgroundColorPickerView(selectedColor: $settings.backgroundColor)
                }
            }
            
            
            // Slide Duration
            settingsRow(label: "Slide duration") {
                HStack(spacing: 8) {
                    Slider(value: slideDurationBinding, in: 1...15)
                        .frame(width: 100)
                    Text(String(format: "%.1fs", settings.slideDuration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            
            // Shuffle
            settingsRow(label: "") {
                Toggle("Shuffle photos", isOn: $settings.shuffle)
                    .toggleStyle(.checkbox)
            }
            
#if DEBUG
            Divider()
                .padding(.vertical, 4)
            
            settingsRow(label: "Debug") {
                Toggle("Show face boxes", isOn: $settings.debugShowFaces)
                    .toggleStyle(.checkbox)
            }
#endif
   
        }
        .padding(16)
        .frame(width: 290)
    }
    
    /// Helper to create consistently aligned settings rows
    @ViewBuilder
    private func settingsRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
    
    // Binding for slide duration with 0.5s snapping (removes tick marks)
    private var slideDurationBinding: Binding<Double> {
        Binding(
            get: { settings.slideDuration },
            set: { newValue in
                // Snap to nearest 0.5
                settings.slideDuration = (newValue * 2).rounded() / 2
            }
        )
    }
}

// MARK: - Background Color Picker

/// Custom color picker that appears as a popover with preset colors
struct BackgroundColorPickerView: View {
    @Binding var selectedColor: Color
    
    private let presetColors: [(String, Color)] = [
        ("Black", .black),
        ("Dark Gray", Color(white: 0.2)),
        ("Gray", .gray),
        ("White", .white),
        ("Navy", Color(red: 0.1, green: 0.1, blue: 0.3)),
        ("Dark Brown", Color(red: 0.2, green: 0.15, blue: 0.1)),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background Color")
                .font(.headline)
            
            // Preset colors grid
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 8) {
                ForEach(presetColors, id: \.0) { name, color in
                    Button(action: { selectedColor = color }) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(color)
                            .frame(width: 40, height: 20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(selectedColor.isClose(to: color) ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selectedColor.isClose(to: color) ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            
            Divider()
            
            // Full color picker for custom colors
            ColorPicker("Custom color:", selection: $selectedColor, supportsOpacity: false)
        }
        .padding(12)
        .frame(width: 180)
    }
}

extension Color {
    /// Check if two colors are approximately equal
    func isClose(to other: Color) -> Bool {
        guard let c1 = NSColor(self).usingColorSpace(.deviceRGB),
              let c2 = NSColor(other).usingColorSpace(.deviceRGB) else { return false }
        
        let threshold: CGFloat = 0.05
        return abs(c1.redComponent - c2.redComponent) < threshold &&
               abs(c1.greenComponent - c2.greenComponent) < threshold &&
               abs(c1.blueComponent - c2.blueComponent) < threshold
    }
}

#Preview {
    SettingsPopoverView(settings: SlideshowSettings.shared)
}

