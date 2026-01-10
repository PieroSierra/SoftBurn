//
//  AboutView.swift
//  SoftBurn
//

import AppKit
import SwiftUI

struct AboutView: View {
    let onAcknowledgements: () -> Void

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "SoftBurn"
    }

    private var versionLine: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, build) {
        case let (.some(v), .some(b)):
            return "Version \(v) (\(b))"
        case let (.some(v), .none):
            return "Version \(v)"
        case let (.none, .some(b)):
            return "Build \(b)"
        default:
            return "Version —"
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 32) {
                // App icon (uses the icon already included in the bundle).
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                   .shadow(color: Color.black.opacity(0.15), radius: 18, x: 6, y: 6)
        

                VStack(alignment: .leading, spacing: 12) {
                    Text(appName)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(versionLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    Spacer().frame(height: 14)

                    Text("Copyright © 2026 Piero Sierra. All rights reserved.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Placeholder text — you can replace this with whatever you want.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    HStack {
                        Spacer()
                        Button("Acknowledgements") {
                            onAcknowledgements()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .frame(minWidth: 600, minHeight: 200)
    }
}

#Preview {
    AboutView {
        print("Acknowledgements tapped")
    }
    .frame(width: 600, height: 290)
}
