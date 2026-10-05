//
//  FileBrowserView.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/12/26.
//

import SwiftUI

import QuickLook
import UniformTypeIdentifiers

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

enum FileBrowserState {
    case loading, loaded, noPerms, noFiles, unknownError
    
    var description: String {
        switch self {
        case .noFiles: return "This directory is empty."
        case .noPerms: return "You don't have permission to view the files in this directory."
        case .unknownError: return "Unknown error."
        default: return ""
        }
    }
    
    var symbol: String {
        switch self {
        case .noFiles: return "questionmark.folder"
        case .noPerms: return "externaldrive.badge.xmark"
        case .unknownError: return "exclamationmark.triangle"
        default: return ""
        }
    }
}

struct FileBrowserView: View {
    @EnvironmentObject var mgr: FilosManager
    @State var item: FileItem
    
    @State private var dirFiles: [FileItem] = []
    @State private var unfilteredFiles: [FileItem] = []
    @State private var searchText = ""
    @AppStorage("chosenSort") var chosenSort: FileSortMode = .system
    @AppStorage("filesAscend") var filesAscend: Bool = true
    @AppStorage("listStyle") var listStyle = 1
    
    @State private var receivedPreviewer: FBPreviewer?
    @State private var previewer: FBPreviewer?
    @State private var quickLookURL: URL?
    @State private var currentState = FileBrowserState.loading
    @State private var localizedError = ""
    @State private var showFavs = false
    @State private var showLogs = false
    @State private var showSettings = false
    @State private var showFileImporter = false
    
    var body: some View {
        Group {
            if currentState == .loading {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(1.25)
                    Text("Loading Files...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else if currentState == .loaded {
                List {
                    ForEach(dirFiles) { file in
                        if file.type == .folder {
                            FolderRow(item: file, parent: item, previewer: $receivedPreviewer)
                        } else {
                            FileRow(item: file, parent: item, previewer: $receivedPreviewer)
                        }
                    }
                }
                .searchable(text: $searchText)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: currentState.symbol)
                        .font(.largeTitle)
                    if currentState == .noFiles {
                        Text(currentState.description)
                    } else {
                        VStack {
                            Text("Failed to load files from path!")
                            Text(currentState == .unknownError ? localizedError : currentState.description)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(item.fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
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
                        .labelStyle(.iconOnly)
                }
                .labelStyle(.iconOnly)
                .disabled(currentState != .loaded)
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if item.writable {
                        Menu {
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new file? Make sure you attach an extension at the end.", placeholder: "new.txt", completion: { name in
                                    let name = name ?? ""
                                    if !name.isEmpty {
                                        do {
                                            let fileURL = item.fileURL.appendingPathComponent(name)
                                            try Data().write(to: fileURL)
                                            mgr.refreshFiles.toggle()
                                        } catch {
                                            print("(fm) failed to create file: \(error)")
                                            
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
                                            let fileURL = item.fileURL.appendingPathComponent(name + ".plist")
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
                                            try fm.createDirectoryIfNeeded(at: item.fileURL.appendingPathComponent(name))
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
                                            try fm.createSymbolicLink(atPath: item.fileURL.appendingPathComponent(URL(fileURLWithPath: symPath).lastPathComponent).path, withDestinationPath: symPath)
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
                        .disabled(currentState != .loaded && currentState != .noFiles)
                        
                        Button {
                            showFileImporter.toggle()
                        } label: {
                            Label("Import File", systemImage: "arrow.down.doc")
                        }
                        .disabled(currentState != .loaded && currentState != .noFiles)
                        
                        Divider()
                    }
                    
                    Button {
                        showFavs.toggle()
                    } label: {
                        Label("Favorites", systemImage: "star")
                    }
                    
                    Button {
                        Alertinator.shared.prompt(title: "Where would you like to go?", text: item.fileURL.path, completion: { path in
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
        .onChange(of: receivedPreviewer) { receivedPrev in
            if receivedPrev?.type == .quickLook {
                quickLookURL = receivedPrev?.file.fileURL
            } else {
                previewer = receivedPrev
            }
        }
        .sheet(item: $previewer) { newPrev in
            switch newPrev.type {
            case .info: InfoViewer(newPrev.file)
            case .plist: PlistViewer(newPrev.file.fileURL)
            case .text: TextViewer(newPrev.file.fileURL)
            default: EmptyView()
            }
        }
        .quickLookPreview($quickLookURL)
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
            // Enumeration goes through AFC / InstallationProxy / house_arrest
            // only — the ATC move is disabled, so this blocks no longer than a
            // plain tunnel listing and stays off the main thread regardless.
            DispatchQueue.global(qos: .userInitiated).async {
                loadDirFiles(allowAirliftMove: true)
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
            dirFiles = sortFiles(files: dirFiles)
        }
        .onChange(of: filesAscend) { _ in
            dirFiles = sortFiles(files: dirFiles)
        }
        .onChange(of: mgr.refreshFiles) { _ in
            // Pull-to-refresh re-runs the same AFC / InstallationProxy /
            // house_arrest listing as a navigation. No ATC sync either way.
            DispatchQueue.global(qos: .userInitiated).async {
                loadDirFiles(allowAirliftMove: false)
            }
        }
    }
    
    // MARK: handle files
    /// `allowAirliftMove` is accepted and ignored: the ATC move is disabled
    /// (`AirLiftBrowse.usesAirliftMove(_:)` is always `false`), so a reload and a
    /// fresh navigation take the same AFC/InstallationProxy route.
    private func loadDirFiles(allowAirliftMove: Bool = true) {
        let path = item.fileURL.path

        // Airlift target paths (/var/mobile, /var/tmp, the 12 defaults) are not
        // visible to the sandboxed FileManager — enumerate them over the tunnel.
        if AirLiftBrowse.isRemotePath(path) {
            currentState = .loading
            loadRemoteDirFiles(path: path, allowAirliftMove: allowAirliftMove)
            return
        }

        loadLocalDirFiles()
    }

    /// Remote enumeration, routed by what the path actually is.
    ///
    ///   * `/var/mobile/Containers/Data/Application` — InstallationProxy knows
    ///     every installed app's container directory, so the listing comes from
    ///     `al_list_apps` instead of a UUID-directory AFC guess.
    ///   * anything inside one of those containers —
    ///     `com.apple.mobile.house_arrest` (`al_house_list`) vends the
    ///     container as its own AFC channel, which is the only thing that can
    ///     open it.
    ///   * everything else (`/var/mobile/Library/…`, AppGroup, `/var/tmp`) —
    ///     plain AFC (`al_dir_list`), as before.
    ///
    /// The Books ATC move (`al_airlift_list_dir`) is not reachable from here
    /// at all: `usesAirliftMove(_:)` is `false` for every path, and `allowAirliftMove`
    /// no longer arms anything.
    private func loadRemoteDirFiles(path: String, allowAirliftMove: Bool) {
        if AirLiftBrowse.isAppContainerRoot(path) {
            loadAppContainerRoot(path: path)
            return
        }
        if AirLiftBrowse.isInsideAppContainerRoot(path) {
            // Resolving a container to a bundle id needs the app index. Populate
            // it on a cold start (deep link straight into a container), then
            // re-resolve.
            if AirLiftBrowse.shared.cachedApps() == nil {
                _ = AirLiftBrowse.shared.listApps()
            }
            if let info = AirLiftBrowse.shared.containerInfo(forDevicePath: path) {
                loadContainerDirectory(path: path, bundleId: info.bundleId, relativePath: info.relativePath)
                return
            }
            // Under the container root but not one of the known containers: a
            // container that was deleted underneath us, or an app hidden from
            // InstallationProxy. House arrest cannot address it — say so rather
            // than blaming AFC.
            let message = "No installed app owns \(path). The container may have been deleted, or its app is hidden from InstallationProxy."
            print("[!] \(message)")
            localizedError = message
            currentState = .unknownError
            return
        }
        loadAFCDirectory(path: path)
    }

    /// `/var/mobile/Containers/Data/Application` — one row per installed app,
    /// labelled from InstallationProxy (display name + bundle id) instead of a
    /// metadata plist read through AFC.
    private func loadAppContainerRoot(path: String) {
        switch AirLiftBrowse.shared.listApps() {
        case .success(let apps):
            applyAppListing(apps)
        case .failure(let error):
            print("[!] al_list_apps failed for \(path): \(error)")
            localizedError = "Could not list installed apps over the Airlift tunnel:\n\(error)"
            currentState = .unknownError
        }
    }

    /// A directory inside one app's Data container, via house_arrest
    /// (`al_house_list`).
    private func loadContainerDirectory(path: String, bundleId: String, relativePath: String) {
        switch AirLiftBrowse.shared.houseList(bundleId: bundleId, path: relativePath) {
        case .success(let entries):
            applyRemoteListing(entries)
        case .failure(let error):
            print("[!] house_arrest listing failed for \(bundleId)\(relativePath): \(error)")
            localizedError = "Could not open \(bundleId) through house_arrest:\n\(error)"
            currentState = .unknownError
        }
    }

    /// Every other remote path — plain AFC (`al_dir_list`) over the same tunnel.
    private func loadAFCDirectory(path: String) {
        handleRemoteListing(path: path, result: AirLiftBrowse.shared.listDir(path))
    }

    /// Success/error handling for the AFC listing route. Never falls back to
    /// `FileManager`: it cannot see these paths, and its sandbox error would be
    /// a misleading "no permission".
    private func handleRemoteListing(path: String, result: Result<[RemoteEntry], String>) {
        switch result {
        case .success(let entries):
            applyRemoteListing(entries)
            return
        case .failure(let error):
            // Fresh tunnel failed — serve the cached listing if there is one.
            if let cached = AirLiftBrowse.shared.cachedListing(for: path) {
                print("[!] remote listing failed for \(path) (\(error)); serving cached entries")
                applyRemoteListing(cached)
                return
            }
            // No cache, and FileManager cannot see this path anyway: its
            // error would be a sandbox code 257 dressed up as "no
            // permission", which is never the truth here. Show the real
            // FFI failure instead.
            print("[!] remote listing failed for \(path): \(error)")
            localizedError = "Could not list this directory over the Airlift tunnel:\n\(error)"
            currentState = .unknownError
            return
        }
    }

    /// Turn installed apps into container rows. Each row's URL is the real
    /// container directory (`…/Application/<UUID>`) so tapping it navigates into
    /// the container, and the name/bundle-id labelling from `appRowLabels`
    /// keeps working.
    private func applyAppListing(_ apps: [AppEntry]) {
        let unsorted = apps.compactMap { app -> FileItem? in
            guard !app.path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: app.path)
            return remoteFileItem(name: app.name.isEmpty ? app.bundle_id : app.name, isDirectory: true, size: 0, url: url)
        }
        let sorted = sortFiles(files: unsorted)
        dirFiles = sorted
        unfilteredFiles = sorted
        currentState = sorted.isEmpty ? .noFiles : .loaded
    }

    /// Turn remote AFC entries into rows for the current directory.
    private func applyRemoteListing(_ entries: [RemoteEntry]) {
        let unsorted = entries.map { entry -> FileItem in
            let url = item.fileURL.appendingPathComponent(entry.name)
            return remoteFileItem(name: entry.name, isDirectory: entry.isDir, size: entry.size, url: url)
        }
        let sorted = sortFiles(files: unsorted)
        dirFiles = sorted
        unfilteredFiles = sorted
        currentState = sorted.isEmpty ? .noFiles : .loaded
    }

    /// Original sandboxed-FileManager enumeration, used for every non-Airlift
    /// path and as the fallback when the remote listing fails.
    private func loadLocalDirFiles() {
        do {
            currentState = .loading
            let pathFiles = try fm.contentsOfDirectory(at: item.fileURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])

            let unsortedFiles = pathFiles.map { fileURL in
                return getFileItem(at: fileURL)
            }
            dirFiles = sortFiles(files: unsortedFiles)
            unfilteredFiles = sortFiles(files: unsortedFiles)
            if dirFiles.isEmpty {
                currentState = .noFiles
            } else {
                currentState = .loaded
            }
        } catch {
            let nserror = error as NSError
            print("[!] failed to load files from \(item.fileURL.path): \(nserror.localizedDescription) (code \(nserror.code))")
            if nserror.code == NSFileReadNoPermissionError {
                currentState = .noPerms
            } else {
                localizedError = nserror.localizedDescription
                currentState = .unknownError
            }
        }
    }

    /// Build a FileItem for a remote entry — no URLResourceValues (the
    /// sandboxed FileManager cannot stat these), so fill what we know and
    /// mark readable/writable so viewers and the edit paths engage.
    private func remoteFileItem(name: String, isDirectory: Bool, size: Int, url: URL) -> FileItem {
        var item = FileItem(name: name, fileURL: url, destURL: url, type: isDirectory ? .folder : .file, uttype: isDirectory ? .folder : .data, size: size, creationDate: Date(), modifiedDate: Date(), creationDateStr: "", modifiedDateStr: "", hidden: name.hasPrefix("."), posixPerms: "", owner: "", group: "", readable: true, writable: true, executable: false)
        if !isDirectory, let uti = UTType(filenameExtension: url.pathExtension) {
            item.uttype = uti
        }
        return item
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
                
                let newURL = item.fileURL.appendingPathComponent(fileURL.lastPathComponent)
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
