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

struct FBPreviewer: Identifiable, Equatable {
    let id = UUID()
    var type: FBPreviewTypes
    var file: FileItem
}

enum FBPreviewTypes: Equatable {
    case info, plist, text, quickLook
}

let fileRowSpacing: CGFloat = {
    if isSolariumUI() {
        return 12
    } else {
        return 10
    }
}()

struct FileRow: View {
    @EnvironmentObject var mgr: FilosManager
    @AppStorage("hideFavs") var hideFavs = false
    @AppStorage("hideDates") var hideDates = false
    var file: FileItem
    @Binding var previewer: FBPreviewer?
    
    @State private var conformsText = false
    @State private var conformsPlist = false
    @State private var conformsZip = false
    
    var body: some View {
        Button {
            fileTapAction()
        } label: {
            HStack(spacing: fileRowSpacing) {
                Image(systemName: file.type == .file ? "doc" : "arrow.up.right.circle")
                    .foregroundStyle(file.hidden ? .secondary : .primary)
                
                VStack(alignment: .leading) {
                    Text(file.name)
                        .foregroundStyle(file.hidden ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file {
                        Text(file.modifiedDateStr)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                
                if file.type == .file {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Button {
                    previewer = FBPreviewer(type: .info, file: file)
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                Chevron()
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                do {
                    try fm.removeItem(at: file.fileURL)
                    mgr.refreshFiles.toggle()
                } catch {
                    print("[!] failed to delete file: \(error)")
                    Alertinator.shared.alert(title: "Failed to delete file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
            /*
            if file.type == .file {
                Button {
                    if conformsZip {
                        let res = unzipFile(file.fileURL)
                        if res {
                            mgr.refreshFiles.toggle()
                        } else {
                            Haptic.shared.play(.heavy)
                        }
                    } else {
                        if conformsPlist {
                            //showPlistViewer.toggle()
                            previewer = FBPreviewer(type: .plist, file: file)
                        } else if conformsText {
                            //showTextViewer.toggle()
                            previewer = FBPreviewer(type: .text, file: file)
                        } else {
                            //previewURL = file.fileURL
                            previewer = FBPreviewer(type: .quickLook, file: file)
                        }
                    }
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Image(systemName: "doc")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                        
                        VStack(alignment: .leading) {
                            Text(file.name)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file {
                                Text(file.modifiedDateStr)
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
                            //showInfo.toggle()
                            previewer = FBPreviewer(type: .info, file: file)
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
                }
            } else {
                Button {
                    mgr.push(file.destURL)
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Image(systemName: "arrow.up.right.circle")
                            .frame(width: 20, alignment: .center)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                        
                        Text(file.name)
                            .foregroundStyle(file.hidden ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button {
                            //showInfo.toggle()
                            previewer = FBPreviewer(type: .info, file: file)
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        
                        Chevron()
                    }
                }
            }
             */
        .foregroundStyle(Color(.label))
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                conformsText = conformsToTextViewer(file.fileURL)
                conformsPlist = conformsToPlistViewer(file.fileURL)
                if file.uttype.conforms(to: .zip) {
                    conformsZip = true
                }
            }
        }
        /*
        .sheet(isPresented: $showInfo) {
            InfoViewer(file)
        }
        .sheet(isPresented: $showPlistViewer) {
            PlistViewer(file.fileURL)
        }
        .sheet(isPresented: $showTextViewer) {
            TextViewer(file.fileURL)
        }
        .quickLookPreview($previewURL)
         */
        // MARK: cell actions
        .contextMenu {
            if conformsText || conformsPlist {
                Menu {
                    Button {
                        //previewURL = file.fileURL
                        previewer = FBPreviewer(type: .quickLook, file: file)
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    
                    if conformsPlist {
                        Button {
                            //showPlistViewer.toggle()
                            previewer = FBPreviewer(type: .plist, file: file)
                        } label: {
                            Label("Plist Viewer", systemImage: "tablecells")
                        }
                    }
                    
                    if conformsText {
                        Button {
                            //showTextViewer.toggle()
                            previewer = FBPreviewer(type: .text, file: file)
                        } label: {
                            Label("Text Viewer", systemImage: "doc.plaintext")
                        }
                    }
                } label: {
                    Label("View In...", systemImage: "doc.text.magnifyingglass")
                }
            } else {
                Button {
                    previewer = FBPreviewer(type: .quickLook, file: file)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }
            
            Divider()
            
            Button {
                previewer = FBPreviewer(type: .info, file: file)
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            if file.type == .file {
                Button {
                    Alertinator.shared.prompt(title: "What would you like to call this file?", placeholder: file.name, completion: { result in
                        if let name = result {
                            let res = renameFile(file.fileURL, to: name)
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
                        let res = unzipFile(file.fileURL)
                        if res {
                            mgr.refreshFiles.toggle()
                        } else {
                            Haptic.shared.play(.heavy)
                        }
                    } label: {
                        Label("Uncompress", systemImage: "archivebox")
                    }
                } else {
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
                }
            }
            
            if file.type == .file {
                Button {
                    let res = duplicateFile(file.fileURL)
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
                if isFavorited(item: file) {
                    Button {
                        removeFavorite(item: file)
                    } label: {
                        Label("Remove Favorite", systemImage: "star.slash")
                    }
                } else {
                    Button {
                        addFavorite(item: file)
                    } label: {
                        Label("Favorite", systemImage: "star")
                    }
                }
            }
            
            Divider()
            
            Button {
                let res = copyFileToClipboard(file.fileURL)
                if !res {
                    Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            
            Button {
                if let url = makeTemp(file.fileURL) {
                    presentShareSheet(with: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Divider()
            
            Button(role: .destructive) {
                do {
                    try fm.removeItem(at: file.fileURL)
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
    
    // MARK: functions
    private func fileTapAction() {
        if file.type == .symlink {
            mgr.push(file.destURL)
        } else {
            if conformsZip {
                let res = unzipFile(file.fileURL)
                if res {
                    mgr.refreshFiles.toggle()
                } else {
                    Haptic.shared.play(.heavy)
                }
            } else {
                if conformsPlist {
                    previewer = FBPreviewer(type: .plist, file: file)
                } else if conformsText {
                    previewer = FBPreviewer(type: .text, file: file)
                } else {
                    previewer = FBPreviewer(type: .quickLook, file: file)
                }
            }
        }
    }
}
