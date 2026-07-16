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
    var fileExists: Bool
    var kind: String
    var uttype: String
    var size: Int
    var created: String
    var modified: String
    var isSymlink: Bool
    var posixPerms: String
    var owner: String
    var group: String
    var readable: Bool
    var writable: Bool
    var executable: Bool
}

struct FileInfoSheet: View {
    @Environment(\.dismiss) var dismiss
    
    var file: FileItem
    @State private var fileInfo: FileInfoProperties = FileInfoProperties(fileExists: false, kind: "", uttype: "", size: 0, created: "", modified: "", isSymlink: false, posixPerms: "", owner: "", group: "", readable: false, writable: false, executable: false)
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Name") {
                        Text(file.name)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = file.name
                        } label: {
                            Label("Copy Name", systemImage: "character.cursor.ibeam")
                        }
                    }
                    LabeledContent("Path") {
                        Text(file.url.path)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = file.url.path
                        } label: {
                            Label("Copy Path", systemImage: "character.cursor.ibeam")
                        }
                    }
                    if file.type == .file {
                        LabeledContent("Size") {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
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
            .navigationTitle(file.type == .file ? "File Info" : "Folder Info")
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
                fileInfo = getFileInfo(fileURL: file.url)
            }
        }
    }
}
