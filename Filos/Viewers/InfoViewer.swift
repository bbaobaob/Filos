//
//  FileInfoSheet.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI
import UniformTypeIdentifiers

struct InfoViewer: View {
    @Environment(\.dismiss) var dismiss
    
    var file: FileItem
    
    init(_ file: FileItem) {
        self.file = file
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(file.name)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = file.name
                        } label: {
                            Label("Copy Name", systemImage: "character.cursor.ibeam")
                        }
                    }
                    HStack {
                        Text("Path")
                        Spacer()
                        Text(file.fileURL.path)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = file.fileURL.path
                        } label: {
                            Label("Copy Path", systemImage: "character.cursor.ibeam")
                        }
                    }
                    if file.type == .symlink {
                        HStack {
                            Text("Destination Path")
                            Spacer()
                            Text(file.destURL.path)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = file.destURL.path
                            } label: {
                                Label("Copy Path", systemImage: "character.cursor.ibeam")
                            }
                        }
                    }
                    if file.type == .file {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section {
                    HStack {
                        Text("UTType")
                        Spacer()
                        Text(file.uttype.identifier)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = file.uttype.identifier
                        } label: {
                            Label("Copy UTType", systemImage: "doc")
                        }
                    }
                    HStack {
                        Text("Creation Date")
                        Spacer()
                        Text(file.creationDateStr)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Last Modified")
                        Spacer()
                        Text(file.modifiedDateStr)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Symlink")
                        Spacer()
                        Image(systemName: file.type == .symlink ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HeaderLabel(text: "File", icon: "doc")
                }
                
                Section {
                    HStack {
                        Text("POSIX Permissions")
                        Spacer()
                        Text(file.posixPerms)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Owner")
                        Spacer()
                        Text(file.owner)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Group")
                        Spacer()
                        Text(file.group)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Readable")
                        Spacer()
                        Image(systemName: file.readable ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Writable")
                        Spacer()
                        Image(systemName: file.writable ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Executable")
                        Spacer()
                        Image(systemName: file.executable ? "checkmark" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HeaderLabel(text: "Permissions", icon: "shield")
                }
            }
            .navigationTitle(file.type == .file ? "File Info" : "Folder Info")
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
        }
        .navigationViewStyle(.stack)
    }
}
