//
//  AcknowledgementsView.swift
//  SoftBurn
//

import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements")
                .font(.title2.weight(.semibold))

            Text("Placeholder text — put licenses / credits here.")
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                Text(
                    """
                    - SoftBurn
                    - Placeholder acknowledgements

                    Replace this text with your real acknowledgements. You can also load from a bundled file later (RTF/Markdown/TXT).
                    """
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
    }
}

