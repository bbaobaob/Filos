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

    /// The Retry button belongs to the ATC-move route only; every other route's
    /// errors have nothing to retry.
    private var canRetryAirliftMove: Bool {
        let path = item.fileURL.path
        return !AirLiftBrowse.isAppContainerRoot(path) && AirLiftBrowse.usesAirliftMove(path)
    }

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
                    // Only on the ATC-move routes: an explicit way to spend
                    // another AirTraffic session after the per-launch guard has
                    // refused or spent this path's one attempt.
                    if canRetryAirliftMove {
                        Button {
                            retryAirliftMove()
                        } label: {
                            ButtonLabel("Retry AirTraffic read", symbol: "arrow.clockwise")
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
            // A fresh navigation arms the ATC move (see
            // `loadRemoteDirFiles`), but it spends at most one session per path
            // per launch, and runs off the main thread regardless because an
            // AirTraffic sync blocks for seconds.
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
            // Pull-to-refresh must never start an AirTraffic session, so the ATC
            // branch is disarmed here: the cached listing is served, or the AFC /
            // house_arrest route runs.
            DispatchQueue.global(qos: .userInitiated).async {
                loadDirFiles(allowAirliftMove: false)
            }
        }
    }
    
    // MARK: handle files
    /// `allowAirliftMove` is false for a pull-to-refresh: a refresh re-lists over
    /// AFC / InstallationProxy / house_arrest and never starts an AirTraffic
    /// session. A fresh navigation sets it, and even then
    /// `AirLiftBrowse.moveListDir(_:)` allows only one ATC session per path per
    /// launch.
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
    ///   * every other ATC path — an app container directory and everything
    ///     under it, plus `/var/mobile/Containers/Shared/AppGroup` and its
    ///     subdirectories — through the Books ATC move
    ///     (`al_airlift_list_dir`). It moves the directory out to
    ///     `Airlock/Read/<token>` and back, and
    ///     `AirLiftBrowse.moveListDir` allows exactly one session per path per
    ///     launch, so a reappearing view cannot loop. `allowAirliftMove == false`
    ///     (pull-to-refresh) serves the cached listing and starts nothing.
    ///   * anything inside a container the ATC move did not cover —
    ///     `com.apple.mobile.house_arrest` (`al_house_list`) vends the container
    ///     as its own AFC channel. Last resort only: on-device testing showed
    ///     house_arrest answering `InstallationLookupFailed` for every bundle,
    ///     third-party and Apple alike, so it cannot be the route for real app
    ///     containers.
    ///   * everything else (`/var/mobile/Library/…`, `/var/tmp`) — plain AFC
    ///     (`al_dir_list`), as before.
    private func loadRemoteDirFiles(path: String, allowAirliftMove: Bool) {
        if AirLiftBrowse.isAppContainerRoot(path) {
            loadAppContainerRoot(path: path)
            return
        }
        if AirLiftBrowse.usesAirliftMove(path) {
            if allowAirliftMove {
                loadAirliftMoveDirectory(path: path)
            } else {
                serveCachedMoveListing(path: path)
            }
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

    /// A pull-to-refresh of an ATC-move path: no session is started, the cached
    /// listing is served when there is one, and otherwise the cached failure (or
    /// a plain explanation) is shown with the Retry button.
    private func serveCachedMoveListing(path: String) {
        if let cached = AirLiftBrowse.shared.cachedListing(for: path) {
            print("[airlift] refresh of \(path) served from the cached listing (no ATC session)")
            applyRemoteListing(cached)
            return
        }
        let message = "Pull-to-refresh does not re-read \(path): reading it means moving the directory out to Airlock/Read and back with the AirTraffic sync. Use \"Retry AirTraffic read\" if you want another attempt on purpose."
        print("[!] \(message)")
        failRemoteListing(message)
    }

    /// An app container, App Group or `/var/mobile/Applications` directory via
    /// the Books ATC move.
    ///
    /// Every outcome is funneled through `handleMoveOutcome(_:path:)`, which never
    /// starts a second session for the same path — see
    /// `AirLiftBrowse.moveListDir(_:)`.
    private func loadAirliftMoveDirectory(path: String) {
        print("[airlift] listing \(path) through al_airlift_list_dir (Books ATC move)")
        handleMoveOutcome(AirLiftBrowse.shared.moveListDir(path), path: path)
    }

    /// Apply whatever the loop-guarded ATC move decided. A refusal or an
    /// already-spent attempt becomes the error state with the Retry button — but
    /// a container root that could not be pulled falls back to synthetic rows
    /// for its standard child folders (see `apiSynthesiseContainerChildren`), so
    /// the screen is still navigable. The Books daemon answers `FileComplete`
    /// but never materialises a moved container root (20 s of `ObjectNotFound`
    /// in `Airlock/Read`), while pulls of plain directories succeed.
    private func handleMoveOutcome(_ outcome: AirLiftBrowse.MoveOutcome, path: String) {
        switch outcome {
        case .listed(let entries):
            applyRemoteListing(entries)
        case .alreadyAttempted(let result):
            switch result {
            case .success(let entries):
                print("[airlift] serving the cached listing for \(path) (no new ATC session)")
                applyRemoteListing(entries)
            case .failure(let message):
                print("[!] ATC read of \(path) is not retried automatically: \(message)")
                if apiSynthesiseContainerChildrenIfPossible(path) == nil {
                    failRemoteListing(message)
                }
            }
        case .refused(let message):
            print("[!] ATC read of \(path) refused: \(message)")
            if apiSynthesiseContainerChildrenIfPossible(path) == nil {
                failRemoteListing(message)
            }
        }
    }

    /// For a path that IS a container root (`Application/<UUID>` or
    /// `AppGroup/<UUID>`) whose ATC pull failed, show the three standard iOS
    /// container folders as rows. Each row carries the REAL subdirectory URL,
    /// so tapping it starts an ATC pull of that directory — and plain
    /// directories are the ones the Books move does materialise (the AppGroup
    /// root and its parent-group pulls work; container roots do not).
    /// Every row still keeps a note in the log. Returns a description of the
    /// fallback it applied, or nil when `path` is not a container root.
    @discardableResult
    private func apiSynthesiseContainerChildrenIfPossible(_ path: String) -> String? {
        guard let children = Self.containerRootChildren(path) else { return nil }
        let note = "Books could not move the container root itself; showing its standard folders"
        print("[airlift] \(note) — \(path) → \(children.map(\.name).joined(separator: ", "))")
        let items = children.map { child in
            remoteFileItem(name: child.name, isDirectory: true, size: 0, url: child.url)
        }
        publishListing(sortFiles(files: items))
        return note
    }

    /// `Documents`, `Library`, `tmp` as real child URLs when `path` is a
    /// container root (`Application/<UUID>` or `AppGroup/<UUID>`), else nil.
    static func containerRootChildren(_ path: String) -> [(name: String, url: URL)]? {
        let normalized = AirLiftBrowse.normalizeDevicePath(path)
        for prefix in ["/var/mobile/Containers/Data/Application/",
                       "/var/mobile/Containers/Shared/AppGroup/"] {
            guard normalized.hasPrefix(prefix) else { continue }
            let rest = String(normalized.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rest.isEmpty && !rest.contains("/") else { return nil }
            return ["Documents", "Library", "tmp"].map { name in
                (name: name, url: URL(fileURLWithPath: "\(path)/\(name)"))
            }
        }
        return nil
    }

    /// Every remote path is enumerated on a background queue (tunnel opens
    /// block). SwiftUI state mutated off the main thread is undefined behaviour
    /// and crashes on navigation, so all of it hops back here.
    private func failRemoteListing(_ message: String) {
        DispatchQueue.main.async {
            localizedError = message
            currentState = .unknownError
        }
    }

    /// Deliberate retry: re-arm this one path and spend one session on it. Never
    /// called automatically.
    private func retryAirliftMove() {
        let path = item.fileURL.path
        AirLiftBrowse.shared.resetMoveAttempt(for: path)
        currentState = .loading
        DispatchQueue.global(qos: .userInitiated).async {
            loadAirliftMoveDirectory(path: path)
        }
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
            failRemoteListing("Could not list installed apps over the Airlift tunnel:\n\(error)")
        }
    }

    /// A directory inside one app's Data container, via house_arrest
    /// (`al_house_list`). Last-resort route only: the ATC move is tried first,
    /// and on-device house_arrest answers `InstallationLookupFailed` for every
    /// bundle.
    private func loadContainerDirectory(path: String, bundleId: String, relativePath: String) {
        switch AirLiftBrowse.shared.houseList(bundleId: bundleId, path: relativePath) {
        case .success(let entries):
            applyRemoteListing(entries)
        case .failure(let error):
            print("[!] house_arrest listing failed for \(bundleId)\(relativePath): \(error)")
            failRemoteListing("Could not open \(bundleId) through house_arrest:\n\(error)")
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
            failRemoteListing("Could not list this directory over the Airlift tunnel:\n\(error)")
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
        publishListing(sortFiles(files: unsorted))
    }

    /// Turn remote AFC entries into rows for the current directory.
    private func applyRemoteListing(_ entries: [RemoteEntry]) {
        let unsorted = entries.map { entry -> FileItem in
            let url = item.fileURL.appendingPathComponent(entry.name)
            return remoteFileItem(name: entry.name, isDirectory: entry.isDir, size: entry.size, url: url)
        }
        let sorted = sortFiles(files: unsorted)
        publishListing(sorted)
    }

    /// Hand a finished listing to SwiftUI on the main thread.
    ///
    /// Every remote enumeration runs on a background queue because the tunnel
    /// FFI blocks for seconds; mutating `@State` from there is undefined
    /// behaviour and was crashing the app the moment a row was tapped and the
    /// next screen's own enumeration wrote its state.
    private func publishListing(_ sorted: [FileItem]) {
        DispatchQueue.main.async {
            dirFiles = sorted
            unfilteredFiles = sorted
            currentState = sorted.isEmpty ? .noFiles : .loaded
        }
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
