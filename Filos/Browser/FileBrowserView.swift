//
//  FileBrowserView.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/12/26.
//

import SwiftUI
import PartyUI
import QuickLook

enum FileType {
    case file, folder, symlink
    
    var sortOrder: Int {
        switch self {
        case .file: return 0
        case .symlink: return 1
        case .folder: return 2
        }
    }
}

// system - load from filesystem completely normally (just don't sort)
enum FileSortMode: String, CaseIterable, Codable, Hashable {
    case system, name, date, type, size
    
    var id: String { label }
    
    var label: String {
        switch self {
        case .system: return "Default"
        case .name: return "Name"
        case .date: return "Date"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

struct FileItem: Identifiable {
    var id: String
    let name: String
    let type: FileType
    let size: Int
    let modifiedDate: Date
    let url: URL
}

struct FileBrowserView: View {
    @EnvironmentObject var mgr: FilosManager
    
    @State var path: URL
    @Binding var navigationPath: NavigationPath
    @State private var dirFiles: [FileItem] = []
    @State private var unfilteredFiles: [FileItem] = []
    @State private var showFavoritesSheet: Bool = false
    @State private var showLogsSheet = false
    @State private var showSettings = false
    @State private var showFileImporter: Bool = false
    @State private var searchText = ""
    
    @AppStorage("chosenSort") var chosenSort: FileSortMode = .system
    @AppStorage("filesAscend") var filesAscend: Bool = true
    
    var body: some View {
        List {
            ForEach(dirFiles) { file in
                if file.type == .folder || file.type == .symlink {
                    NavigationLink(value: file.url) {
                        FolderRow(file: file)
                    }
                } else {
                    FileRow(file: file)
                }
            }
        }
        .navigationTitle(path.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(FileSortMode.allCases, id: \.self) { option in
                        Button {
                            chosenSort = option
                        } label: {
                            if chosenSort == option {
                                Label(option.label, systemImage: "checkmark")
                                    .tag(option)
                            } else {
                                Text(option.label)
                                    .tag(option)
                            }
                        }
                    }
                    Divider()
                    Button {
                        filesAscend.toggle()
                    } label: {
                        if filesAscend {
                            Label("Ascending", systemImage: "chevron.up")
                        } else {
                            Label("Descending", systemImage: "chevron.down")
                        }
                    }
                    .disabled(chosenSort == .system)
                } label: {
                    Label("Sort", systemImage: "line.3.horizontal.decrease")
                }
                .labelStyle(.iconOnly)
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        Button {
                            createFile()
                        } label: {
                            Label("File", systemImage: "doc")
                        }
                        
                        Button {
                            createFolder()
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                        
                        Button {
                            createSymlink()
                        } label: {
                            Label("Symlink", systemImage: "arrow.up.right.circle")
                        }
                    } label: {
                        Label("New...", systemImage: "plus")
                    }
                    
                    Button {
                        showFileImporter.toggle()
                    } label: {
                        Label("Import File", systemImage: "arrow.down.doc")
                    }
                    
                    Divider()
                    
                    Button {
                        Alertinator.shared.prompt(title: "Enter a path (case-sensitive!)", placeholder: "/", completion: { path in
                            let path = generateNavPath(path: path ?? "")
                            
                            if !path.isEmpty {
                                navigationPath.append(URL(fileURLWithPath: path))
                            }
                        })
                    } label: {
                        Label("Go to Directory...", systemImage: "arrow.right.arrow.left")
                    }
                    
                    Button {
                        showFavoritesSheet.toggle()
                    } label: {
                        Label("Favorites", systemImage: "star")
                    }
                    
                    Divider()
                    
                    Button {
                        showLogsSheet.toggle()
                    } label: {
                        Label("Logs", systemImage: "terminal")
                    }
                    
                    Button {
                        showSettings.toggle()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
            }
        }
        .searchable(text: $searchText)
        .sheet(isPresented: $showFavoritesSheet) {
            FavoritesSheet(navPath: $navigationPath)
        }
        .sheet(isPresented: $showLogsSheet) {
            LogView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
        .onAppear {
            loadFilesFromPath()
        }
        .onChange(of: searchText) { newSearch in
            if newSearch.isEmpty {
                dirFiles = unfilteredFiles
            } else {
                dirFiles = unfilteredFiles.filter { $0.name.localizedCaseInsensitiveContains(newSearch) }
            }
        }
        .onChange(of: chosenSort) { _ in
            loadFilesFromPath()
        }
        .onChange(of: filesAscend) { _ in
            loadFilesFromPath()
        }
        .onChange(of: mgr.refreshFiles) { _ in
            loadFilesFromPath()
        }
        .refreshable {
            mgr.refreshFiles.toggle()
        }
    }
    
    private func createFile() {
        Alertinator.shared.prompt(title: "Enter both the name and the extension you'd like to use to create this file.", placeholder: "new.txt", completion: { name in
            let name = name ?? ""
            if !name.isEmpty {
                do {
                    let fileURL = path.appendingPathComponent(name)
                    try Data().write(to: fileURL)
                    mgr.refreshFiles.toggle()
                } catch {
                    print("(fm) failed to create file: \(error)")
                    Alertinator.shared.alert(title: "Failed to create file!", body: "\(error)")
                }
            }
        })
    }
    
    private func createFolder() {
        Alertinator.shared.prompt(title: "Enter a name for your new folder.", placeholder: "", completion: { name in
            let name = name ?? ""
            if !name.isEmpty {
                do {
                    try fm.createDirectoryIfNeeded(at: path.appendingPathComponent(name))
                    mgr.refreshFiles.toggle()
                } catch {
                    print("(fm) failed to create folder: \(error)")
                    Alertinator.shared.alert(title: "Failed to create directory!", body: "\(error)")
                }
            }
        })
    }
    
    private func createSymlink() {
        Alertinator.shared.prompt(title: "Enter the path you'd like your new symlink to point to.", placeholder: "/path/to/dir", completion: { symPath in
            let symPath = symPath ?? ""
            if !symPath.isEmpty {
                do {
                    try fm.createSymbolicLink(atPath: path.appendingPathComponent(URL(fileURLWithPath: symPath).lastPathComponent).path, withDestinationPath: symPath)
                    mgr.refreshFiles.toggle()
                } catch {
                    print("(fm) failed to create symlink: \(error)")
                    Alertinator.shared.alert(title: "Failed to create symlink!", body: "\(error)")
                }
            }
        })
    }
    
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let fileURL):
            do {
                guard fileURL.startAccessingSecurityScopedResource() else {
                    throw "failed to access file!"
                }
                defer { fileURL.stopAccessingSecurityScopedResource() }
                
                let data = try Data(contentsOf: fileURL)
                
                let newURL = path.appendingPathComponent(fileURL.lastPathComponent)
                try? fm.removeItem(at: newURL)
                
                try data.write(to: newURL)
                mgr.refreshFiles.toggle()
            } catch {
                print("(fm) failed to import file: \(error)")
                Alertinator.shared.alert(title: "Failed to import file!", body: "\(error)")
            }
        case .failure(let error):
            print("(fm) failed to import file: \(error)")
            Alertinator.shared.alert(title: "Failed to import file!", body: "\(error)")
        }
    }
    
    // MARK: file handling functions
    private func loadFilesFromPath() {
        do {
            let pathFiles = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            
            let unsortedFiles = try pathFiles.map { fileURL in
                let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                let isDirectory = values.isDirectory ?? false
                let isSymlink = values.isSymbolicLink ?? false
                let modifiedDate = values.contentModificationDate ?? Date()
                let fileSize = values.fileSize ?? 0
                let fileType: FileType = isSymlink ? .symlink : isDirectory ? .folder : .file
                
                return FileItem(id: fileURL.path, name: fileURL.lastPathComponent, type: fileType, size: fileSize, modifiedDate: modifiedDate, url: fileURL)
            }
            dirFiles = sortFiles(files: unsortedFiles)
            unfilteredFiles = sortFiles(files: unsortedFiles)
        } catch {
            print("[!] failed to load files from \(path): \(error)")
            Alertinator.shared.alert(title: "Failed to load files from \(path)!", body: "\(error)")
        }
    }
    
    private func sortFiles(files: [FileItem]) -> [FileItem] {
        var sortedFiles: [FileItem]
        
        switch chosenSort {
        case .system:
            sortedFiles = files
        case .name:
            sortedFiles = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            sortedFiles = files.sorted { $0.modifiedDate > $1.modifiedDate }
        case .type:
            sortedFiles = files.sorted { $0.type.sortOrder < $1.type.sortOrder }
        case .size:
            sortedFiles = files.sorted { $0.size < $1.size }
        }

        sortedFiles = filesAscend ? sortedFiles : sortedFiles.reversed()
        
        sortedFiles = sortedFiles.sorted { a, b in
            a.name.hasPrefix(".") && !b.name.hasPrefix(".")
        }
        
        return sortedFiles
    }
}
