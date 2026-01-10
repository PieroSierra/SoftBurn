//
//  SettingsPopoverView.swift
//  SoftBurn
//
//  Created by Piero Sierra on 04/01/2026.
//

import SwiftUI
import UniformTypeIdentifiers

/// Popover view for global slideshow settings
struct SettingsPopoverView: View {
    @ObservedObject var settings: SlideshowSettings
    @State private var showColorPicker = false
    @State private var showMusicFilePicker = false
    
    private let labelWidth: CGFloat = 100
    
    /// Music selection options for the dropdown
    enum MusicSelectionOption: String, CaseIterable, Identifiable {
        case none = "None"
        case wintersTale = "winters_tale"
        case brighterPlans = "brighter_plans"
        case innovation = "innovation"
        case custom = "custom"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .none: return "None"
            case .wintersTale: return "Winter's Tale"
            case .brighterPlans: return "Brighter Plans"
            case .innovation: return "Innovation"
            case .custom: return "Custom…"
            }
        }
    }
    
    /// Current music selection option based on settings
    private var currentMusicOption: MusicSelectionOption {
        guard let selection = settings.musicSelection else { return .none }
        
        if let url = URL(string: selection), url.isFileURL {
            return .custom
        }
        
        switch selection {
        case "winters_tale": return .wintersTale
        case "brighter_plans": return .brighterPlans
        case "innovation": return .innovation
        default: return .none
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Transition Style
            settingsRow(label: "Transition") {
                Picker("", selection: $settings.transitionStyle) {
                    ForEach(SlideshowDocument.Settings.TransitionStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 150, alignment: .leading)
            }
            
            // Zoom on Faces (only available with Pan & Zoom)
            settingsRow(label: "") {
                Toggle("Zoom on faces", isOn: $settings.zoomOnFaces)
                    .toggleStyle(.checkbox)
                    .disabled(!(settings.transitionStyle == .panAndZoom || settings.transitionStyle == .zoom))
            }
            
            Divider()
                .padding(.vertical, 4)
            
          
            
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
                Toggle("Shuffle slides", isOn: $settings.shuffle)
                    .toggleStyle(.checkbox)
            }
            
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
            
            
            Divider()
                .padding(.vertical, 4)
            
            // Music Selection
            settingsRow(label: "Music") {
                Picker("", selection: Binding(
                    get: { currentMusicOption },
                    set: { option in
                        handleMusicSelectionChange(option)
                    }
                )) {
                    ForEach(MusicSelectionOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 150, alignment: .leading)
            }
            
            // Music Volume (enabled only when music is selected)
            settingsRow(label: "Volume") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(settings.musicVolume) },
                        set: { settings.musicVolume = Int($0) }
                    ), in: 0...100)
                    .frame(width: 100)
                    .disabled(settings.musicSelection == nil)
                    Text("\(settings.musicVolume)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(settings.musicSelection == nil ? .secondary : .primary)
                        .frame(width: 30, alignment: .trailing)
                        .opacity(settings.musicSelection == nil ? 0.5 : 1.0)
                }
            }
            
            settingsRow(label: "Videos") {
                Toggle("Play with sound", isOn: $settings.playVideosWithSound)
                    .toggleStyle(.checkbox)
            }
            
            settingsRow(label: "") {
                Toggle("Play in full", isOn: $settings.playVideosInFull)
                    .toggleStyle(.checkbox)
            }
            
            // File picker for custom music (hidden)
            .fileImporter(
                isPresented: $showMusicFilePicker,
                allowedContentTypes: [
                    UTType(filenameExtension: "mp3") ?? .audio,
                    UTType(filenameExtension: "m4a") ?? .audio,
                    UTType(filenameExtension: "aac") ?? .audio,
                    .audio
                ],
                allowsMultipleSelection: false
            ) { result in
                handleCustomMusicSelection(result: result)
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
    
    // MARK: - Music Selection Handlers
    
    private func handleMusicSelectionChange(_ option: MusicSelectionOption) {
        switch option {
        case .none:
            settings.musicSelection = nil
            settings.customMusicURL = nil
        case .wintersTale:
            settings.musicSelection = "winters_tale"
            settings.customMusicURL = nil
        case .brighterPlans:
            settings.musicSelection = "brighter_plans"
            settings.customMusicURL = nil
        case .innovation:
            settings.musicSelection = "innovation"
            settings.customMusicURL = nil
        case .custom:
            // Show file picker
            showMusicFilePicker = true
        }
    }
    
    private func handleCustomMusicSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            // Start accessing security-scoped resource
            _ = url.startAccessingSecurityScopedResource()
            
            // Verify it's a supported audio format
            let pathExtension = url.pathExtension.lowercased()
            let supportedExtensions = ["mp3", "m4a", "aac"]
            
            guard supportedExtensions.contains(pathExtension) else {
                // Reset to None if unsupported format
                settings.musicSelection = nil
                settings.customMusicURL = nil
                return
            }
            
            // Store the file URL as a string identifier
            settings.musicSelection = url.absoluteString
            settings.customMusicURL = url
        case .failure:
            // On cancel or error, revert to previous selection
            // If current selection is .custom but file picker was cancelled, reset to None
            if currentMusicOption == .custom {
                settings.musicSelection = nil
                settings.customMusicURL = nil
            }
        }
    }
}

// MARK: - Background Color Picker

/// Custom color picker that appears as a popover with preset colors
struct BackgroundColorPickerView: View {
    @Binding var selectedColor: Color
    
    private let presetColors: [(String, Color)] = [
        ("Dark Gray", Color(white: 0.15)),
        ("Black", .black),
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

