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

struct InfoViewer: View {
    @Environment(\.dismiss) var dismiss
    
    var fileItem: FileItem
    @State private var fileInfo = FileInfoProperties()
    
    init(_ fileItem: FileItem) {
        self.fileItem = fileItem
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(fileItem.name)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = fileItem.name
                        } label: {
                            Label("Copy Name", systemImage: "character.cursor.ibeam")
                        }
                    }
                    HStack {
                        Text("Path")
                        Spacer()
                        Text(fileItem.url.path)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = fileItem.url.path
                        } label: {
                            Label("Copy Path", systemImage: "character.cursor.ibeam")
                        }
                    }
                    if fileItem.type == .file {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(fileItem.size), countStyle: .file))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section {
                    HStack {
                        Text("UTType")
                        Spacer()
                        Text(fileInfo.uttype)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = fileInfo.uttype
                        } label: {
                            Label("Copy UTType", systemImage: "doc")
                        }
                    }
                    HStack {
                        Text("Creation Date")
                        Spacer()
                        Text(fileInfo.created)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Last Modified")
                        Spacer()
                        Text(fileInfo.modified)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Symlink")
                        Spacer()
                        Image(systemName: fileInfo.isSymlink ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HeaderLabel(text: "File", icon: "doc")
                }
                
                Section {
                    HStack {
                        Text("POSIX Permissions")
                        Spacer()
                        Text(fileInfo.posixPerms)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Owner")
                        Spacer()
                        Text(fileInfo.owner)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Group")
                        Spacer()
                        Text(fileInfo.group)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Readable")
                        Spacer()
                        Image(systemName: fileInfo.readable ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Writable")
                        Spacer()
                        Image(systemName: fileInfo.writable ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Executable")
                        Spacer()
                        Image(systemName: fileInfo.executable ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HeaderLabel(text: "Permissions", icon: "shield")
                }
            }
            .navigationTitle(fileItem.type == .file ? "File Info" : "Folder Info")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", icon: "xmark")
                    }
                }
            }
            .onAppear {
                fileInfo = getFileInfo(fileItem.url)
            }
        }
        .navigationViewStyle(.stack)
    }
}
