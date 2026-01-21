//
//  AboutView.swift
//  SoftBurn
//

import AppKit
import SwiftUI

struct AboutView: View {
    let onAcknowledgements: () -> Void
    
    @ObservedObject private var tipJar = TipJarManager.shared
    @State private var showThankYouAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage: String?

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

            HStack(alignment: .top, spacing: 20) {
                // App icon (uses the icon already included in the bundle).
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                   .shadow(color: Color.black.opacity(0.15), radius: 18, x: 6, y: 6)
        
                VStack(alignment: .leading, spacing: 12) {
                    Text(appName)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(versionLine)\nCopyright © 2026 Piero Sierra. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer().frame(height: 4)
                    
                    // Tip Jar Section
                    TipJarSection(
                        tipJar: tipJar,
                        onPurchaseComplete: {
                            showThankYouAlert = true
                        },
                        onPurchaseError: { message in
                            errorMessage = message
                            showErrorAlert = true
                        }
                    )

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
        .frame(width: 640, height: 400)
        .alert("Thank you!", isPresented: $showThankYouAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your support means a lot ❤️")
        }
        .alert("Purchase not completed", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            } else {
                Text("No worries — thanks for trying SoftBurn!")
            }
        }
    }
}

// MARK: - Tip Jar Section

struct TipJarSection: View {
    @ObservedObject var tipJar: TipJarManager
    let onPurchaseComplete: () -> Void
    let onPurchaseError: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SoftBurn is free. Coffee is not. Buy me a cup?")
            
            Spacer().frame(height: 2)
            
            HStack(spacing: 24) {
                ForEach(TipJarManager.TipTier.allCases, id: \.self) { tier in
                    TipOptionView(
                        tier: tier,
                        tipJar: tipJar,
                        onPurchaseComplete: onPurchaseComplete,
                        onPurchaseError: onPurchaseError
                    )
                }
            }
        }
     //   .padding(10)
    }
}

// MARK: - Tip Option View

struct TipOptionView: View {
    let tier: TipJarManager.TipTier
    @ObservedObject var tipJar: TipJarManager
    let onPurchaseComplete: () -> Void
    let onPurchaseError: (String) -> Void
    
    private var isPurchasing: Bool {
        tipJar.purchasingTier == tier
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Icon
            Image(tier.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            
            // Label
            Text(tier.displayName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            
            // Price Button
            Button {
                Task {
                    await purchaseTip()
                }
            } label: {
                Text(tipJar.price(for: tier))
                    .frame(minWidth: 60)
            }
            .buttonStyle(.bordered)
            .disabled(isPurchasing || !tipJar.isProductAvailable(tier))
        }
        .frame(maxWidth: .infinity)
    }
    
    private func purchaseTip() async {
        let result = await tipJar.purchase(tier)
        
        switch result {
        case .success:
            onPurchaseComplete()
            
        case .failure(let error):
            if let tipError = error as? TipJarError {
                switch tipError {
                case .userCancelled:
                    // Don't show error for user cancellation
                    break
                default:
                    onPurchaseError("No worries — thanks for trying SoftBurn!")
                }
            } else {
                onPurchaseError("No worries — thanks for trying SoftBurn!")
            }
        }
    }
}

#Preview {
    AboutView {
        print("Acknowledgements tapped")
    }
    .frame(width: 640, height: 400)
}
