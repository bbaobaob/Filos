//
//  PlistViewer.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI

struct PlistViewer: View {
    @Environment(\.dismiss) var dismiss
    
    var fileURL: URL
    @State private var fileDict: [String : Any] = [:]
    @State private var hierarchy = 0
    
    init(_ fileURL: URL) {
        self.fileURL = fileURL
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(fileDict.keys.sorted(), id: \.self) { key in
                        KeyRow(key: key, value: fileDict[key], hierarchy: hierarchy + 1)
                    }
                }
            }
            .navigationTitle(fileURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
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
                        CloseSheetLabel()
                    }
                }
            }
            .onAppear {
                fileDict = getFileDict(fileURL)
            }
        }
    }
}

// MARK: hierarchy coloring
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
