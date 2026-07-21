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
    
    @State private var showFileInfoSheet: Bool = false
    @State private var showFilePlistSheet: Bool = false
    @State private var showTextSheet: Bool = false
    
    var body: some View {
        Button {
            if isPlist() {
                showFilePlistSheet.toggle()
            } else if isText() {
                showTextSheet.toggle()
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
                    showFileInfoSheet.toggle()
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
                showFileInfoSheet.toggle()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            Button {
                previewURL = file.url
            } label: {
                Label("Quick Look", systemImage: "eye")
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
                    } catch {
                        print("(fm) failed to unzip file: \(error)")
                    }
                } label: {
                    Label("Extract Archive", systemImage: "archivebox")
                }
            }
            
            if fileInfo.uttype == "com.apple.property-list" {
                Button {
                    showFilePlistSheet.toggle()
                } label: {
                    Label("Plist Viewer", systemImage: "text.document")
                }
            }
            
            //if isText() {
                Button {
                    showTextSheet.toggle()
                } label: {
                    Label("Text Viewer", systemImage: "doc.plaintext")
                }
            //}
            
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
                presentShareSheet(with: file.url)
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
            fileInfo = getFileInfo(fileURL: file.url)
        }
        .sheet(isPresented: $showFileInfoSheet) {
            FileInfoSheet(file: file)
        }
        .sheet(isPresented: $showFilePlistSheet) {
            FilePlistSheet(name: file.name, path: file.url.path)
        }
        .sheet(isPresented: $showTextSheet) {
            TextViewer(file.url)
        }
        .quickLookPreview($previewURL)
    }
    
    private func isPlist() -> Bool {
        do {
            let data = try Data(contentsOf: file.url)
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
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
