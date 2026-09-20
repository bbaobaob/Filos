//
//  FolderRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI

import QuickLook
import ZIPFoundation

struct FolderRow: View {
    @EnvironmentObject var mgr: FilosManager
    var item: FileItem
    var parent: FileItem
    @Binding var previewer: FBPreviewer?
    
    @State private var folderType: FolderType = .normal
    
    var body: some View {
        Button {
            mgr.push(item.destURL)
        } label: {
            HStack(spacing: fileRowSpacing) {
                Group {
                    if folderType == .bundle || folderType == .container {
                        Image(systemName: "app")
                            .frame(width: 20, alignment: .center)
                        VStack(alignment: .leading) {
                            Text(folderLabel(url: item.fileURL))
                                .foregroundStyle(item.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.fileURL.path)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "folder")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(item.hidden ? .secondary : .primary)
                        Text(item.name)
                            .lineLimit(1)
                            .foregroundStyle(item.hidden ? .secondary : .primary)
                    }
                }
                
                Spacer()
                
                Button {
                    previewer = FBPreviewer(type: .info, file: item)
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.hidden ? .secondary : .primary)
                
                Chevron()
            }
        }
        .foregroundStyle(Color(.label))
        .contextMenu {
            if item.readable {
                Button {
                    previewer = FBPreviewer(type: .quickLook, file: item)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
                Divider()
            }
            
            Button {
                previewer = FBPreviewer(type: .info, file: item)
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            if parent.writable && item.readable {
                Button {
                    let res = zipFile(item.fileURL)
                    if res {
                        mgr.refreshFiles.toggle()
                    } else {
                        Alertinator.shared.alert(title: "Failed to compress file!", body: Errors.checkLogs)
                    }
                } label: {
                    Label("Compress", systemImage: "archivebox")
                }
            }
            
            Divider()
            if mgr.isFavorited(item) {
                Button {
                    mgr.removeFavorite(item)
                } label: {
                    Label("Unfavorite", systemImage: "star.slash")
                }
            } else {
                Button {
                    mgr.addFavorite(item)
                } label: {
                    Label("Favorite", systemImage: "star")
                }
            }
            
            Button {
                if let url = makeTemp(item.fileURL) {
                    presentShareSheet(with: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            if item.writable {
                Divider()
                Button(role: .destructive) {
                    try? fm.removeItem(at: item.fileURL)
                    mgr.refreshFiles.toggle()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
