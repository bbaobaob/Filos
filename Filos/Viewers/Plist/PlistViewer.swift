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
                ForEach(pmgr.plistArray.sorted(by: { $0.key < $1.key })) { item in
                    ItemRow(item: item, hierarchy: 0)
                        .environmentObject(pmgr)
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .onAppear {
                let res = pmgr.loadPlistItems()
                if !res {
                    Alertinator.shared.alert(title: "Failed to load plist!", body: "Check error logs for more detailed information.")
                }
            }
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
        .navigationViewStyle(.stack)
    }
}

extension UIColor {
    static func hierarchyLevelColor(_ level: Int = 0) -> UIColor {
        UIColor { trait in
            let baseColor = UIColor.secondarySystemBackground.resolvedColor(with: trait)
            
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            
            // get rgba values from base color
            guard baseColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
                return baseColor
            }
            
            // set amount + curve colors
            let curve: CGFloat = 0.04 * CGFloat(level)
            r = min(r + (1 - r) * curve, 1)
            g = min(g + (1 - g) * curve, 1)
            b = min(b + (1 - b) * curve, 1)
            
            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
    }
}
