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

      //      Text("Placeholder text — put licenses / credits here.")
                .foregroundStyle(.secondary)

        //    Divider()

            ScrollView {
                Text(
                    """
                    **Sample Music Credits**
                    The following music tracks are included as sample audio in this app, used under the **Uppbeat free-for-creators license**. All rights remain with their respective artists.

                    **[Winter’s Tale](https://uppbeat.io/t/roger-gabalda/winters-tale)**  
                    By [Roger Gabaldà](https://uppbeat.io/browse/artist/roger-gabalda)  
                    Music from **#Uppbeat**  
                    **License code:** `VYEOKFQSXCTAGLBM`

                    **[Brighter Plans](https://uppbeat.io/t/iros-young/brighter-plans)**  
                    By [Iros Young](https://uppbeat.io/browse/artist/iros-young)  
                    Music from **#Uppbeat** 
                    **License code:** `MIWVFMOE85RMWVE7`

                    **[Innovation](https://uppbeat.io/t/mountaineer/innovation)**  
                    By [Mountaineer](https://uppbeat.io/browse/artist/mountaineer)  
                    Music from **#Uppbeat** 
                    **License code:** `ANQXTHOVUGLZP3BN`
                    """
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 450)
    }
}


#Preview {
    AcknowledgementsView()
}

