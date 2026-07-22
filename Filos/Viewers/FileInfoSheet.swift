//
//  FileInfoSheet.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI
import UniformTypeIdentifiers

struct FileInfoProperties {
    var id = UUID()
    var fileExists = false
    var kind = ""
    var uttype = ""
    var size = 0
    var created = ""
    var modified = ""
    var isSymlink = false
    var posixPerms = ""
    var owner = ""
    var group = ""
    var readable = false
    var writable = false
    var executable = false
}

struct FileInfoSheet: View {
    @Environment(\.dismiss) var dismiss
    
    var fileItem: FileItem
    @State private var fileInfo = FileInfoProperties()
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name") {
                        Text(fileItem.name)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = fileItem.name
                        } label: {
                            Label("Copy Name", systemImage: "character.cursor.ibeam")
                        }
                    }
                    LabeledContent("Path") {
                        Text(fileItem.url.path)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = fileItem.url.path
                        } label: {
                            Label("Copy Path", systemImage: "character.cursor.ibeam")
                        }
                    }
                    if fileItem.type == .file {
                        LabeledContent("Size") {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(fileItem.size), countStyle: .file))")
                        }
                    }
                }
                
                Section {
                    LabeledContent("UTType") {
                        Text(fileInfo.uttype)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = fileInfo.uttype
                        } label: {
                            Label("Copy UTType", systemImage: "doc")
                        }
                    }
                    LabeledContent("Creation Date") {
                        Text(fileInfo.created)
                    }
                    LabeledContent("Last Modified") {
                        Text(fileInfo.modified)
                    }
                    LabeledContent("Symlink") {
                        Image(systemName: fileInfo.isSymlink ? "checkmark" : "xmark")
                    }
                } header: {
                    HeaderLabel(text: "File", icon: "doc")
                }
                
                Section {
                    LabeledContent("POSIX Permissions") {
                        Text(fileInfo.posixPerms)
                    }
                    LabeledContent("Owner") {
                        Text(fileInfo.owner)
                    }
                    LabeledContent("Group") {
                        Text(fileInfo.group)
                    }
                    LabeledContent("Readable") {
                        Image(systemName: fileInfo.readable ? "checkmark" : "xmark")
                    }
                    LabeledContent("Writable") {
                        Image(systemName: fileInfo.writable ? "checkmark" : "xmark")
                    }
                    LabeledContent("Executable") {
                        Image(systemName: fileInfo.executable ? "checkmark" : "xmark")
                    }
                } header: {
                    HeaderLabel(text: "Permissions", icon: "shield")
                }
            }
            .navigationTitle(fileItem.type == .file ? "File Info" : "Folder Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        CloseSheetLabel()
                    }
                    .contentShape(.rect)
                }
            }
            .onAppear {
                fileInfo = getFileInfo(fileItem.url)
            }
        }
    }
}
