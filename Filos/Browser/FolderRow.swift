//
//  FolderRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI
import QuickLook
import ZIPFoundation

struct FolderRow: View {
    @EnvironmentObject var mgr: FilosManager
    @AppStorage("favList") var favList: [FavoriteItem] = []
    
    var file: FileItem
    
    @State private var previewURL: URL?
    @State private var fileInfo: FileInfoProperties = FileInfoProperties(fileExists: false, kind: "", uttype: "", size: 0, created: "", modified: "", isSymlink: false, posixPerms: "", owner: "", group: "", readable: false, writable: false, executable: false)
    @State private var folderType: FolderType = .normal
    
    @State private var showFileInfoSheet: Bool = false
    
    var body: some View {
        HStack(spacing: isSolariumUI() ? 12 : 10) {
            Group {
                if folderType == .bundle || folderType == .container {
                    Image(systemName: "app")
                        .frame(width: 20, alignment: .center)
                    VStack(alignment: .leading) {
                        Text(folderLabel(url: file.url))
                            .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.url.path)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: file.type == .symlink ? "arrow.up.right.circle" : "folder")
                        .frame(width: 20, alignment: .center)
                        .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
                    Text(file.name)
                        .lineLimit(1)
                        .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
                }
            }
            
            Spacer()
            
            Button {
                showFileInfoSheet.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(file.name.starts(with: ".") ? .secondary : .primary)
        }
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
                    print("Failed to zip: \(error)")
                }
            } label: {
                Label("Compress", systemImage: "archivebox")
            }
            
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
                presentShareSheet(with: file.url)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Divider()
            
            Button(role: .destructive) {
                try? fm.removeItem(at: file.url)
                mgr.refreshFiles.toggle()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onAppear {
            folderType = getFolderType(url: file.url)
            fileInfo = getFileInfo(fileURL: file.url)
        }
        .sheet(isPresented: $showFileInfoSheet) {
            FileInfoSheet(file: file)
        }
        .quickLookPreview($previewURL)
    }
}
