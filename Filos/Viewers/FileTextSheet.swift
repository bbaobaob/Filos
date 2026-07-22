//
//  TextViewer.swift
//  Filos
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI

struct TextViewer: View {
    @EnvironmentObject var mgr: FilosManager
    @Environment(\.dismiss) var dismiss
    
    var fileURL: URL
    @State private var fileText = ""
    @State private var editText = ""
    @State private var isEditing = false
    
    init(_ fileURL: URL) {
        self.fileURL = fileURL
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    if isEditing {
                        TextEditor(text: $editText)
                            .font(.system(size: 10, design: .monospaced))
                    } else {
                        Text(fileText)
                            .font(.system(size: 10, design: .monospaced))
                            .padding(5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(fileURL.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            isEditing = false
                            editText = fileText
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .adaptiveConfirm) {
                            let res = writeTextIntoFile(fileURL, string: editText)
                            if res {
                                isEditing = false
                                fileText = getFileText(fileURL)
                            }
                        } label: {
                            Label("Confirm", systemImage: "checkmark")
                                .labelStyle(.iconOnly)
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if !isEditing {
                                Button {
                                    isEditing = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                            }
                            
                            Button {
                                Haptic.shared.play(.soft)
                                UIPasteboard.general.string = fileText
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            
                            Button {
                                if let url = makeTemp(fileURL) {
                                    presentShareSheet(with: url)
                                }
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        } label: {
                            Label("Menu", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                        }
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                            mgr.refreshFiles.toggle()
                        } label: {
                            CloseSheetLabel()
                        }
                    }
                }
            }
            .onAppear {
                let text = getFileText(fileURL)
                fileText = text
                editText = text
            }
            .onChange(of: isEditing) { editing in
                if editing && fileText.isEmpty {
                    editText = "add text here..."
                }
            }
        }
    }
    
    private func writeTextIntoFile(_ url: URL, string: String) -> Bool {
        do {
            let data = Data(string.utf8)
            try data.write(to: url)
            return true
        } catch {
            print("[!] failed to write data: \(error)")
        }
        return false
    }
}
