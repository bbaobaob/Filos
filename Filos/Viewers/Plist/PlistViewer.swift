//
//  PlistViewer.swift
//  Filos
//
//  Created by lunginspector on 7/25/26.
//

import SwiftUI
import PartyUI

struct PlistViewer: View {
    @StateObject private var pmgr = PlistManager.shared
    @Environment(\.dismiss) var dismiss
    
    var fileURL: URL
    
    init(_ fileURL: URL) {
        self.fileURL = fileURL
        pmgr.url = fileURL
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(pmgr.plistArray) { item in
                    ItemRow(item: item, hierarchy: 0)
                        .environmentObject(pmgr)
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.inset)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let url = makeTemp(fileURL) {
                            presentShareSheet(with: url)
                        }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", icon: "xmark")
                    }
                }
            }
        }
        .onAppear {
            let res = pmgr.loadPlistItems()
            if !res {
                Alertinator.shared.alert(title: "Failed to load plist!", body: "Check error logs for more detailed information.")
            }
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    PlistViewer(URL(fileURLWithPath: "/Users/liquidglass/Desktop/com.apple.MobileGestalt.plist"))
        .environmentObject(PlistManager())
}

// no comment.
extension UIColor {
    static func hierarchyLevelColor(_ level: Int = 0) -> UIColor {
        UIColor { trait in
            let isDark = (trait.userInterfaceStyle == .dark)
            let baseColor = isDark ? UIColor.secondarySystemBackground.resolvedColor(with: trait) : UIColor.white.resolvedColor(with: trait)
            
            let clampedLevel = max(0, level)
            var factor = max(0, 1 - 0.03 * CGFloat(clampedLevel))
            if isDark {
                factor = max(0, 1 + 0.24 * CGFloat(clampedLevel))
            }

            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0

            if baseColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
                let newBrightness = max(0, min(1, b * factor))
                return UIColor(hue: h, saturation: s, brightness: newBrightness, alpha: a)
            }

            var r: CGFloat = 0
            var g: CGFloat = 0
            var bl: CGFloat = 0

            guard baseColor.getRed(&r, green: &g, blue: &bl, alpha: &a) else {
                return baseColor
            }

            return UIColor(red: max(0, r * factor), green: max(0, g * factor), blue: max(0, bl * factor), alpha: a)
        }
    }
}
