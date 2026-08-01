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
    @AppStorage("hideFavs") var hideFavs = false
    
    var file: FileItem
    
    @State private var previewURL: URL?
    @State private var folderType: FolderType = .normal
    
    @State private var showInfo = false
    
    var body: some View {
        Button {
            mgr.push(file.destURL)
        } label: {
            HStack(spacing: isSolariumUI() ? 12 : 10) {
                Group {
                    if folderType == .bundle || folderType == .container {
                        Image(systemName: "app")
                            .frame(width: 20, alignment: .center)
                        VStack(alignment: .leading) {
                            Text(folderLabel(url: file.fileURL))
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(file.fileURL.path)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "folder")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                        Text(file.name)
                            .lineLimit(1)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                    }
                }
                
                Spacer()
                
                Button {
                    showInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(file.hidden ? .secondary : .primary)
                
                Chevron()
            }
        }
        .foregroundStyle(Color(.label))
        .onAppear {
            folderType = getFolderType(url: file.fileURL)
        }
        .sheet(isPresented: $showInfo) {
            InfoViewer(file)
        }
        .quickLookPreview($previewURL)
        .contextMenu {
            Button {
                previewURL = file.fileURL
            } label: {
                Label("Quick Look", systemImage: "eye")
            }
            
            Divider()
            
            Button {
                showInfo.toggle()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            Button {
                let res = zipFile(file.fileURL)
                if res {
                    mgr.refreshFiles.toggle()
                } else {
                    Alertinator.shared.alert(title: "Failed to compress file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Compress", systemImage: "archivebox")
            }
            
            if !hideFavs {
                if let index = favList.firstIndex(where: { $0.path == file.fileURL.path }) {
                    Button {
                        favList.remove(at: index)
                    } label: {
                        Label("Remove Favorite", systemImage: "star.slash")
                    }
                } else {
                    Button {
                        favList.append(FavoriteItem(label: file.name, path: file.fileURL.path))
                    } label: {
                        Label("Favorite", systemImage: "star")
                    }
                }
            }
            
            Divider()
            
            Button {
                if let url = makeTemp(file.fileURL) {
                    presentShareSheet(with: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Divider()
            
            Button(role: .destructive) {
                try? fm.removeItem(at: file.fileURL)
                mgr.refreshFiles.toggle()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
