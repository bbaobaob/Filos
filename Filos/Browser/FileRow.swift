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
    
    var file: FileItem
    
    @State private var previewURL: URL?
    @State private var fileInfo: FileInfoProperties = FileInfoProperties(fileExists: false, kind: "", uttype: "", size: 0, created: "", modified: "", isSymlink: false, posixPerms: "", owner: "", group: "", readable: false, writable: false, executable: false)
    
    @State private var showInfo = false
    @State private var showPlistViewer = false
    @State private var showTextViewer = false
    
    var body: some View {
        Button {
            if isPlist() {
                showPlistViewer.toggle()
            } else if isText() {
                showTextViewer.toggle()
            } else {
                previewURL = file.url
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
                    if !fileInfo.modified.isEmpty {
                        Text(fileInfo.modified)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, !fileInfo.modified.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
        }
        .foregroundStyle(Color(.label))
        .contextMenu {
            Button {
                previewURL = file.url
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            
            if isPlist() {
                Button {
                    showPlistViewer.toggle()
                } label: {
                    Label("Plist Viewer", systemImage: "text.document")
                }
            }
            
            if isText() || isPlist() {
                Button {
                    showTextViewer.toggle()
                } label: {
                    Label("Text Viewer", systemImage: "doc.plaintext")
                }
            }
            
            Divider()
            
            Button {
                showInfo.toggle()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            Button {
                Alertinator.shared.prompt(title: "What would you like to call this file?", placeholder: file.name, completion: { result in
                    if let name = result {
                        do {
                            let data = try Data(contentsOf: file.url)
                            try fm.removeItem(at: file.url)
                            let targetURL = file.url.deletingLastPathComponent().appendingPathComponent(name)
                            try data.write(to: targetURL)
                            mgr.refreshFiles.toggle()
                        } catch {
                            print("[!] failed to rename file: \(error)")
                            Alertinator.shared.alert(title: "Failed to rename file!", body: "Check error logs for more detailed information.")
                        }
                    }
                })
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            
            
            if let type = UTType(fileInfo.uttype), type.conforms(to: .zip) {
                Button {
                    do {
                        let destination = file.url.deletingPathExtension()

                        try FileManager.default.createDirectory(
                            at: destination,
                            withIntermediateDirectories: true
                        )

                        try FileManager.default.unzipItem(
                            at: file.url,
                            to: destination
                        )
                        
                        mgr.refreshFiles.toggle()
                    } catch {
                        print("[!] failed to uncompress: \(error)")
                        Alertinator.shared.alert(title: "Failed to uncompress file!", body: "Check error logs for more detailed information.")
                    }
                } label: {
                    Label("Uncompress", systemImage: "archivebox")
                }
            } else {
                Button {
                    do {
                        let destination = file.url
                            .deletingLastPathComponent()
                            .appendingPathComponent(file.url.lastPathComponent + ".zip")

                        try FileManager.default.zipItem(
                            at: file.url,
                            to: destination,
                            shouldKeepParent: true
                        )

                        mgr.refreshFiles.toggle()
                    } catch {
                        print("[!] failed to compress: \(error)")
                        Alertinator.shared.alert(title: "Failed to compress file!", body: "Check error logs for more detailed information.")
                    }
                } label: {
                    Label("Compress", systemImage: "archivebox")
                }
            }
            
            Button {
                do {
                    let targetURL = file.url.deletingLastPathComponent().appendingPathComponent("\(file.url.deletingPathExtension().lastPathComponent)_copy.\(file.url.pathExtension)")
                    let data = try Data(contentsOf: file.url)
                    try data.write(to: targetURL)
                    mgr.refreshFiles.toggle()
                } catch {
                    print("[!] failed to duplicate file: \(error)")
                    Alertinator.shared.alert(title: "Failed to duplicate file!", body: "Check error logs for more detailed information.")
                }
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            
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
            
            Divider()
            
            Button {
                do {
                    let data = try Data(contentsOf: file.url)
                    let utType = UTType(filenameExtension: file.url.pathExtension) ?? .data
                    
                    UIPasteboard.general.setData(data, forPasteboardType: utType.identifier)
                    UIPasteboard.general.string = file.url.path
                } catch {
                    print("(fm) failed to copy file: \(error)")
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
                } catch {
                    print("(fm) failed to delete file: \(error)")
                    Alertinator.shared.alert(title: "Failed to delete file!", body: "\(error)")
                }
                mgr.refreshFiles.toggle()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onAppear {
            fileInfo = getFileInfo(file.url)
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
    }
    
    private func isPlist() -> Bool {
        do {
            guard let data = try? Data(contentsOf: file.url) else { return false }
            let _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any]
            return true
        } catch {
            return false
        }
    }
    
    private func isText() -> Bool {
        do {
            let _ = try String(contentsOf: file.url, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
