//
//  FileBrowserView.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/12/26.
//

import SwiftUI
import PartyUI
import QuickLook

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

struct FileBrowserView: View {
    @EnvironmentObject var mgr: FilosManager
    @State var path: URL = URL(fileURLWithPath: "/")
    
    @State private var dirFiles: [FileItem] = []
    @State private var unfilteredFiles: [FileItem] = []
    @State private var searchText = ""
    @AppStorage("chosenSort") var chosenSort: FileSortMode = .system
    @AppStorage("filesAscend") var filesAscend: Bool = true
    @AppStorage("listStyle") var listStyle = 1
    
    @State private var showFavs = false
    @State private var showLogs = false
    @State private var showSettings = false
    @State private var showFileImporter = false
    
    var body: some View {
        List {
            ForEach(dirFiles) { file in
                if file.type == .folder {
                    FolderRow(file: file)
                } else {
                    FileRow(file: file)
                }
            }
        }
        .navigationTitle(path.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
        .searchable(text: $searchText)
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
                            Alertinator.shared.prompt(title: "What would you like to call your new file? Make sure you attach an extension at the end.", placeholder: "new.txt", completion: { name in
                                let name = name ?? ""
                                if !name.isEmpty {
                                    do {
                                        let fileURL = path.appendingPathComponent(name)
                                        try Data().write(to: fileURL)
                                        mgr.refreshFiles.toggle()
                                    } catch {
                                        print("(fm) failed to create file: \(error)")
                                        Alertinator.shared.alert(title: "Failed to create file!", body: Errors.checkLogs)
                                    }
                                }
                            })
                        } label: {
                            Label("File", systemImage: "doc")
                        }
                        
                        Button {
                            Alertinator.shared.prompt(title: "What would you like to call your new property list?", placeholder: "Plist Name", completion: { name in
                                let name = name ?? ""
                                if !name.isEmpty {
                                    do {
                                        let fileURL = path.appendingPathComponent(name + ".plist")
                                        let data = try PropertyListSerialization.data(fromPropertyList: NSMutableDictionary(), format: .xml, options: 0)
                                        try data.write(to: fileURL)
                                        mgr.refreshFiles.toggle()
                                    } catch {
                                        print("(fm) failed to create plist: \(error)")
                                        Alertinator.shared.alert(title: "Failed to create property list!", body: Errors.checkLogs)
                                    }
                                }
                            })
                        } label: {
                            Label("Property List", systemImage: "tablecells")
                        }
                        
                        Button {
                            Alertinator.shared.prompt(title: "What would you like to call your new folder?", placeholder: "Folder Name", completion: { name in
                                let name = name ?? ""
                                if !name.isEmpty {
                                    do {
                                        try fm.createDirectoryIfNeeded(at: path.appendingPathComponent(name))
                                        mgr.refreshFiles.toggle()
                                    } catch {
                                        print("(fm) failed to create folder: \(error)")
                                        Alertinator.shared.alert(title: "Failed to create folder!", body: Errors.checkLogs)
                                    }
                                }
                            })
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                        
                        Button {
                            Alertinator.shared.prompt(title: "Where would you like your new symlink to point to?", placeholder: "/path/to/dir", completion: { symPath in
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
                        showFavs.toggle()
                    } label: {
                        Label("Favorites", systemImage: "star")
                    }
                    
                    Button {
                        Alertinator.shared.prompt(title: "Where would you like to go?", text: path.path, completion: { path in
                            let path = generateNavPath(path: path ?? "")
                            
                            if !path.isEmpty {
                                mgr.push(URL(fileURLWithPath: path))
                            }
                        })
                    } label: {
                        Label("Go to Directory...", systemImage: "arrow.right.arrow.left")
                    }
                    
                    Divider()
                    
                    Button {
                        showLogs.toggle()
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
        
        .sheet(isPresented: $showFavs) {
            FavoritesSheet()
        }
        .sheet(isPresented: $showLogs) {
            LogView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
        .refreshable {
            mgr.refreshFiles.toggle()
        }
        .onAppear {
            Task {
                loadFilesFromPath()
            }
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
    }
    
    // MARK: handle files
    private func loadFilesFromPath() {
        do {
            let pathFiles = try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            
            let unsortedFiles = pathFiles.map { fileURL in
                return getFileItem(at: fileURL)
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
            a.hidden && !b.hidden
        }
        return sortedFiles
    }
    
    // MARK: handle import
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let fileURL):
            do {
                let stopAccess = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if stopAccess {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }
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
}

extension View {
    @ViewBuilder
    func customListStyle(_ selection: Int) -> some View {
        switch selection {
        case 2: self.listStyle(.inset)
        case 3: self.listStyle(.grouped)
        default: self.listStyle(.insetGrouped)
        }
    }
    
    @ViewBuilder
    func adaptiveListMargin() -> some View {
        if #available(iOS 26.0, *) {
            self.contentMargins(.top, 0)
        }
    }
}
