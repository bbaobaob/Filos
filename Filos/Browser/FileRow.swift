//
//  FileRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI
import QuickLook
import ZIPFoundation

struct FileRow: View {
    @EnvironmentObject var mgr: FilosManager
    @AppStorage("favList") var favList: [FavoriteItem] = []
    @AppStorage("hideFavs") var hideFavs = false
    
    var file: FileItem
    
    @State private var previewURL: URL?
    @State private var fileInfo: FileInfoProperties = FileInfoProperties(fileExists: false, kind: "", uttype: "", size: 0, created: "", modified: "", isSymlink: false, posixPerms: "", owner: "", group: "", readable: false, writable: false, executable: false)
    
    @State private var conformsText = false
    @State private var conformsPlist = false
    @State private var conformsZip = false
    
    @State private var showInfo = false
    @State private var showPlistViewer = false
    @State private var showTextViewer = false
    
    var body: some View {
        Group {
            if file.type == .file {
                Button {
                    if conformsZip {
                        let res = unzipFile(file.url)
                        if res {
                            mgr.refreshFiles.toggle()
                        } else {
                            Haptic.shared.play(.heavy)
                        }
                    } else {
                        if conformsPlist {
                            showPlistViewer.toggle()
                        } else if conformsText {
                            showTextViewer.toggle()
                        } else {
                            previewURL = file.url
                        }
                    }
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Image(systemName: "doc")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
                        
                        VStack(alignment: .leading) {
                            Text(file.name)
                                .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !fileInfo.modified.isEmpty && file.type == .file {
                                Text(fileInfo.modified)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if file.type == .file {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, !fileInfo.modified.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
                }
            } else {
                Button {
                    mgr.push(file.symURL)
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Image(systemName: "arrow.up.right.circle")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
                        
                        Text(file.name)
                            .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        
                        Chevron()
                    }
                }
            }
        }
        .foregroundStyle(Color(.label))
        .onAppear {
            fileInfo = getFileInfo(file.url)
            conformsText = conformsToTextViewer(file.url)
            conformsPlist = conformsToPlistViewer(file.url)
            if let type = UTType(fileInfo.uttype), type.conforms(to: .zip) {
                conformsZip = true
            }
        }
        .sheet(isPresented: $showInfo) {
            InfoViewer(file)
        }
        .sheet(isPresented: $showPlistViewer) {
            PlistViewer(file.url)
        }
        .sheet(isPresented: $showTextViewer) {
            TextViewer(file.url)
        }
        .quickLookPreview($previewURL)
        // MARK: cell actions
        .contextMenu {
            if conformsText || conformsPlist {
                Menu {
                    Button {
                        previewURL = file.url
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    
                    if conformsPlist {
                        Button {
                            showPlistViewer.toggle()
                        } label: {
                            Label("Plist Viewer", systemImage: "tablecells")
                        }
                    }
                    
                    if conformsText {
                        Button {
                            showTextViewer.toggle()
                        } label: {
                            Label("Text Viewer", systemImage: "doc.plaintext")
                        }
                    }
                } label: {
                    Label("View In...", systemImage: "doc.text.magnifyingglass")
                }
            } else {
                Button {
                    previewURL = file.url
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }
            
            Divider()
            
            Button {
                showInfo.toggle()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            if file.type == .file {
                Button {
                    Alertinator.shared.prompt(title: "What would you like to call this file?", placeholder: file.name, completion: { result in
                        if let name = result {
                            let res = renameFile(file.url, to: name)
                            if res {
                                mgr.refreshFiles.toggle()
                            } else {
                                Alertinator.shared.alert(title: "Failed to rename file!", body: Errors.checkLogs)
                            }
                        }
                    })
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            
            if file.type == .file {
                if conformsZip {
                    Button {
                        let res = unzipFile(file.url)
                        if res {
                            mgr.refreshFiles.toggle()
                        } else {
                            Alertinator.shared.alert(title: "Failed to uncompress file!", body: Errors.checkLogs)
                        }
                    } label: {
                        Label("Uncompress", systemImage: "archivebox")
                    }
                } else {
                    Button {
                        let res = zipFile(file.url)
                        if res {
                            mgr.refreshFiles.toggle()
                        } else {
                            Alertinator.shared.alert(title: "Failed to compress file!", body: Errors.checkLogs)
                        }
                    } label: {
                        Label("Compress", systemImage: "archivebox")
                    }
                }
            }
            
            if file.type == .file {
                Button {
                    let res = duplicateFile(file.url)
                    if res {
                        mgr.refreshFiles.toggle()
                    } else {
                        Alertinator.shared.alert(title: "Failed to duplicate file!", body: Errors.checkLogs)
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
            
            if !hideFavs {
                Divider()
                
                if let index = favList.firstIndex(where: { $0.path == file.url.path }) {
                    Button {
                        favList.remove(at: index)
                    } label: {
                        Label("Remove Favorite", systemImage: "star.slash")
                    }
                } else {
                    Button {
                        favList.append(FavoriteItem(label: file.name, path: file.url.path))
                    } label: {
                        Label("Favorite", systemImage: "star")
                    }
                }
            }
            
            Divider()
            
            Button {
                let res = copyFileToClipboard(file.url)
                if !res {
                    Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            
            Button {
                if let url = makeTemp(file.url) {
                    presentShareSheet(with: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Divider()
            
            Button(role: .destructive) {
                do {
                    try fm.removeItem(at: file.url)
                    mgr.refreshFiles.toggle()
                } catch {
                    print("[!] failed to delete file: \(error)")
                    Alertinator.shared.alert(title: "Failed to delete file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
