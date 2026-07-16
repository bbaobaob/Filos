//
//  FileTextSheet.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI

struct FileTextSheet: View {
    var name: String
    var path: String
    @State private var text: String = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptic.shared.play(.soft)
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .contentShape(.rect)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        dismiss()
                    }) {
                        CloseSheetLabel()
                    }
                    .contentShape(.rect)
                }
            }
            .onAppear {
                text = getFileText(path: path)
            }
        }
    }
}
