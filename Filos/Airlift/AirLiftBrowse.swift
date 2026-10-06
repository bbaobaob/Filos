//
//  AirLiftBrowse.swift
//  Filos
//
//  Swift wrapper around the al_dir_list / al_file_read / al_file_write /
//  al_file_delete / al_list_apps / al_house_* FFI surface. Used by
//  FileBrowserView for the Airlift target paths (/var/mobile, /var/tmp, the 12
//  default targets) since the sandboxed FileManager cannot see them, and for
//  app containers, which are reached through com.apple.mobile.house_arrest
//  instead of AFC.
//
//  All FFI calls are serialized on one queue (tunnel opens are not
//  re-entrant) and the last directory listing is cached per path so rows
//  can be re-rendered and labelled without a fresh tunnel each time.
//

import Foundation
import AirliftFFI

struct RemoteEntry: Decodable, Equatable {
    let name: String
    let is_dir: Bool
    let size: Int

    var isDir: Bool { is_dir }
}

/// One installed app as reported by InstallationProxy (`al_list_apps`).
struct AppEntry: Decodable, Equatable {
    let bundle_id: String
    let name: String
    /// Data container directory, normalized to the `/var/...` spelling.
    let path: String
    /// App Group container directory per group identifier, if any.
    let group_containers: [String: String]?

    var isDir: Bool { true }
}

final class AirLiftBrowse {

    static let shared = AirLiftBrowse()

    /// Serial queue for every remote call; tunnel opens must not race.
    private let queue = DispatchQueue(label: "filos.airlift.browse", qos: .userInitiated)

    /// Last successful listing per directory path.
    private var listingCache: [String: [RemoteEntry]] = [:]
    /// Small read-through cache for plist/label reads (keyed by file path).
    private var fileCache: [String: Data] = [:]
    /// Container-relative listing cache for house_arrest (keyed "bundleId\u{0}path").
    private var houseCache: [String: [RemoteEntry]] = [:]
    /// Last successful InstallationProxy result.
    private var appCache: [AppEntry]?
    /// `Data container path -> app`, built lazily from `appCache`.
    private var appByContainerPath: [String: AppEntry] = [:]
    private let cacheLock = NSLock()

    private init() {}

    // MARK: - Path predicate

    /// True when `path` lives under one of the Airlift target roots.
    static func isRemotePath(_ path: String) -> Bool {
        let roots = ["/var/mobile", "/var/tmp", "/private/var/mobile", "/private/var/tmp"]
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return AirLiftModel.defaultTargets.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    // MARK: - App container paths

    /// Data-container root in the `/var` spelling. InstallationProxy answers
    /// with `/private/var/...`, which normalises onto this.
    static let appContainerRoot = "/var/mobile/Containers/Data/Application"

    /// `/private/var/…` and `/var/…` name the same place; use the `/var` spelling.
    static func normalizeDevicePath(_ path: String) -> String {
        if path.hasPrefix("/private/var/") { return String(path.dropFirst("/private".count)) }
        if path == "/private/var" { return "/var" }
        return path
    }

    /// True when `path` is the Data-container root itself (either spelling).
    static func isAppContainerRoot(_ path: String) -> Bool {
        let normalized = normalizeDevicePath(path)
        return normalized == appContainerRoot || normalized == appContainerRoot + "/"
    }

    /// True when `path` is somewhere below the Data-container root — the
    /// container itself or anything inside it.
    static func isInsideAppContainerRoot(_ path: String) -> Bool {
        let normalized = normalizeDevicePath(path)
        return normalized.hasPrefix(appContainerRoot + "/")
    }

    /// Bundle id + container-relative path for a device path inside an app's
    /// Data container, or nil when `path` is not inside one.
    ///
    /// `/var/mobile/Containers/Data/Application/<UUID>/Documents` maps to
    /// `("com.example.app", "/Documents")`; the container root itself maps to
    /// `("com.example.app", "/")`. Requires `listApps()` to have run (see
    /// `app(forContainerPath:)`).
    func containerInfo(forDevicePath path: String) -> (bundleId: String, relativePath: String)? {
        let normalized = AirLiftBrowse.normalizeDevicePath(path)
        let prefix = AirLiftBrowse.appContainerRoot + "/"
        guard normalized.hasPrefix(prefix) else { return nil }

        let rest = String(normalized.dropFirst(prefix.count))
        let components = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard let containerId = components.first, !containerId.isEmpty else { return nil }
        guard let entry = app(forContainerPath: "\(AirLiftBrowse.appContainerRoot)/\(containerId)") else { return nil }

        let relative = components.count > 1
            ? "/" + components.dropFirst().joined(separator: "/")
            : "/"
        return (entry.bundle_id, relative)
    }

    /// App owning the Data container at `path`, from the InstallationProxy
    /// listing (built lazily on first use).
    func app(forContainerPath path: String) -> AppEntry? {
        let wanted = AirLiftBrowse.normalizeDevicePath(path)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if appByContainerPath.isEmpty, let cached = appCache {
            appByContainerPath = Self.containerPathIndex(cached)
        }
        return appByContainerPath[wanted]
    }

    /// App owning the App Group container at `path`, from the InstallationProxy
    /// listing (built lazily on first use).
    func app(forAppGroupPath path: String) -> AppEntry? {
        let wanted = AirLiftBrowse.normalizeDevicePath(path)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if appByGroupContainerPath.isEmpty, let cached = appCache {
            appByGroupContainerPath = Self.groupContainerPathIndex(cached)
        }
        return appByGroupContainerPath[wanted]
    }

    private var appByGroupContainerPath: [String: AppEntry] = [:]

    private static func groupContainerPathIndex(_ apps: [AppEntry]) -> [String: AppEntry] {
        var index: [String: AppEntry] = [:]
        for app in apps {
            if let groups = app.group_containers?.values {
                for path in groups where !path.isEmpty {
                    index[normalizeDevicePath(path)] = app
                }
            }
        }
        return index
    }

    private static func containerPathIndex(_ apps: [AppEntry]) -> [String: AppEntry] {
        var index: [String: AppEntry] = [:]
        index.reserveCapacity(apps.count)
        for app in apps where !app.path.isEmpty {
            index[normalizeDevicePath(app.path)] = app
        }
        return index
    }

    // MARK: - Installed apps (InstallationProxy)

    /// List every installed app with its Data container path.
    ///
    /// This is what makes `/var/mobile/Containers/Data/Application` browsable
    /// over AFC: InstallationProxy returns the mapping directly instead of us
    /// guessing UUID directory names from a listing.
    func listApps() -> Result<[AppEntry], String> {
        let pairingPath = PairingController.pairingFilePath()
        let raw = queue.sync { () -> Result<String, String> in
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                al_list_apps(pairC, airLiftLogCallback, nil, &outJSON, &outError)
            }
            let json = outJSON.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outJSON { al_string_free(p) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_list_apps returned \(rc) with no error string"
                print("[airlift] al_list_apps failed rc=\(rc): \(message)")
                return .failure(message)
            }
            guard let json else {
                let message = "al_list_apps succeeded but returned no JSON"
                print("[airlift] \(message)")
                return .failure(message)
            }
            return .success(json)
        }

        let json: String
        switch raw {
        case .success(let value): json = value
        case .failure(let message): return .failure(message)
        }

        guard let data = json.data(using: .utf8) else {
            return .failure("al_list_apps returned text that is not valid UTF-8")
        }
        guard let apps = try? JSONDecoder().decode([AppEntry].self, from: data) else {
            let message = "al_list_apps returned JSON that could not be decoded"
            print("[airlift] \(message)")
            return .failure(message)
        }
        cacheLock.lock()
        appCache = apps
        appByContainerPath = Self.containerPathIndex(apps)
        cacheLock.unlock()
        return .success(apps)
    }

    /// Cached app listing, if `listApps()` succeeded earlier.
    func cachedApps() -> [AppEntry]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return appCache
    }

    // MARK: - Listing

    /// List a remote directory.
    ///
    /// - Throws: the FFI error string when the tunnel or the AFC listing
    ///   failed. Callers must surface it rather than fall back to
    ///   `FileManager` — the sandboxed `FileManager` cannot see these paths at
    ///   all, so its failure (code 257) is meaningless and its "no permission"
    ///   copy actively misleads.
    func listDir(_ path: String) -> Result<[RemoteEntry], String> {
        let pairingPath = PairingController.pairingFilePath()
        let raw = queue.sync { () -> Result<String, String> in
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                path.withCString { pathC in
                    al_dir_list(pairC, pathC, airLiftLogCallback, nil, &outJSON, &outError)
                }
            }
            let json = outJSON.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outJSON { al_string_free(p) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_dir_list returned \(rc) with no error string"
                print("[airlift] al_dir_list(\(path)) failed rc=\(rc): \(message)")
                return .failure(message)
            }
            guard let json else {
                let message = "al_dir_list(\(path)) succeeded but returned no JSON"
                print("[airlift] \(message)")
                return .failure(message)
            }
            return .success(json)
        }

        let json: String
        switch raw {
        case .success(let value): json = value
        case .failure(let message): return .failure(message)
        }

        guard let data = json.data(using: .utf8) else {
            return .failure("al_dir_list(\(path)) returned text that is not valid UTF-8")
        }
        guard let entries = try? JSONDecoder().decode([RemoteEntry].self, from: data) else {
            let message = "al_dir_list(\(path)) returned JSON that could not be decoded"
            print("[airlift] \(message)")
            return .failure(message)
        }
        cacheLock.lock()
        listingCache[path] = entries
        cacheLock.unlock()
        return .success(entries)
    }

    /// Cached listing for `path`, if a successful fetch happened earlier.
    func cachedListing(for path: String) -> [RemoteEntry]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return listingCache[path]
    }

    // MARK: - Files

    func readFile(_ path: String) -> Data? {
        // Files inside an app container are served by house_arrest, not AFC —
        // AFC is rooted at /var/mobile/Media and cannot resolve them.
        if let (bundleId, relativePath) = containerInfo(forDevicePath: path) {
            let key = houseKey(bundleId: bundleId, path: relativePath)
            cacheLock.lock()
            let cached = fileCache[key]
            cacheLock.unlock()
            if let cached { return cached }
            return try? houseRead(bundleId: bundleId, path: relativePath).get()
        }

        cacheLock.lock()
        let cached = fileCache[path]
        cacheLock.unlock()
        if let cached { return cached }

        let pairingPath = PairingController.pairingFilePath()
        let b64 = queue.sync { () -> String? in
            var outB64: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                path.withCString { pathC in
                    al_file_read(pairC, pathC, &outB64, &outError)
                }
            }
            let b64 = outB64.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outB64 { al_string_free(p) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                print("[airlift] al_file_read(\(path)) failed rc=\(rc): \(err ?? "?")")
                return nil
            }
            return b64
        }
        guard let b64, let data = Data(base64Encoded: b64) else { return nil }
        cacheLock.lock()
        if fileCache.count < 256 { fileCache[path] = data }
        cacheLock.unlock()
        return data
    }

    func writeFile(_ path: String, data: Data) -> Bool {
        if let (bundleId, relativePath) = containerInfo(forDevicePath: path) {
            return (try? houseWrite(bundleId: bundleId, path: relativePath, data: data).get()) != nil
        }

        let pairingPath = PairingController.pairingFilePath()
        let b64 = data.base64EncodedString()
        let ok = queue.sync { () -> Bool in
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                path.withCString { pathC in
                    b64.withCString { b64C in
                        al_file_write(pairC, pathC, b64C, &outError)
                    }
                }
            }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                print("[airlift] al_file_write(\(path)) failed rc=\(rc): \(err ?? "?")")
                return false
            }
            return true
        }
        if ok {
            cacheLock.lock()
            fileCache[path] = data
            invalidateParentListingLocked(path: path)
            cacheLock.unlock()
        }
        return ok
    }

    func delete(_ path: String) -> Bool {
        if let (bundleId, relativePath) = containerInfo(forDevicePath: path) {
            return (try? houseDelete(bundleId: bundleId, path: relativePath).get()) != nil
        }

        let pairingPath = PairingController.pairingFilePath()
        let ok = queue.sync { () -> Bool in
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                path.withCString { pathC in
                    al_file_delete(pairC, pathC, &outError)
                }
            }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                print("[airlift] al_file_delete(\(path)) failed rc=\(rc): \(err ?? "?")")
                return false
            }
            return true
        }
        if ok {
            cacheLock.lock()
            fileCache.removeValue(forKey: path)
            invalidateParentListingLocked(path: path)
            cacheLock.unlock()
        }
        return ok
    }

    // MARK: - House arrest (app containers)

    /// List a directory inside one app's Data container.
    ///
    /// `path` is container-relative: `"/"` is the container root.
    /// - Throws: the FFI error string, verbatim. Apps installed without a
    ///   developer profile can answer `PermDenied` — that is the truth here and
    ///   the UI shows it as-is.
    func houseList(bundleId: String, path: String) -> Result<[RemoteEntry], String> {
        let key = houseKey(bundleId: bundleId, path: path)
        cacheLock.lock()
        let cached = houseCache[key]
        cacheLock.unlock()
        if let cached { return .success(cached) }

        let pairingPath = PairingController.pairingFilePath()
        let raw = queue.sync { () -> Result<String, String> in
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                bundleId.withCString { bundleC in
                    path.withCString { pathC in
                        al_house_list(pairC, bundleC, pathC, airLiftLogCallback, nil, &outJSON, &outError)
                    }
                }
            }
            let json = outJSON.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outJSON { al_string_free(p) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_house_list returned \(rc) with no error string"
                print("[airlift] al_house_list(\(bundleId)\(path)) failed rc=\(rc): \(message)")
                return .failure(message)
            }
            guard let json else {
                let message = "al_house_list(\(bundleId)\(path)) succeeded but returned no JSON"
                print("[airlift] \(message)")
                return .failure(message)
            }
            return .success(json)
        }

        let json: String
        switch raw {
        case .success(let value): json = value
        case .failure(let message): return .failure(message)
        }

        guard let data = json.data(using: .utf8) else {
            return .failure("al_house_list(\(bundleId)\(path)) returned text that is not valid UTF-8")
        }
        guard let entries = try? JSONDecoder().decode([RemoteEntry].self, from: data) else {
            let message = "al_house_list(\(bundleId)\(path)) returned JSON that could not be decoded"
            print("[airlift] \(message)")
            return .failure(message)
        }
        cacheLock.lock()
        houseCache[key] = entries
        cacheLock.unlock()
        return .success(entries)
    }

    /// Read one file from inside an app's Data container.
    func houseRead(bundleId: String, path: String) -> Result<Data, String> {
        let pairingPath = PairingController.pairingFilePath()
        let result = queue.sync { () -> Result<Data, String> in
            var outB64: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                bundleId.withCString { bundleC in
                    path.withCString { pathC in
                        al_house_files(pairC, bundleC, pathC, &outB64, &outError)
                    }
                }
            }
            let b64 = outB64.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outB64 { al_string_free(p) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_house_files returned \(rc) with no error string"
                print("[airlift] al_house_files(\(bundleId)\(path)) failed rc=\(rc): \(message)")
                return .failure(message)
            }
            guard let b64, let data = Data(base64Encoded: b64) else {
                let message = "al_house_files(\(bundleId)\(path)) returned no usable data"
                print("[airlift] \(message)")
                return .failure(message)
            }
            return .success(data)
        }
        if case .success(let data) = result {
            cacheLock.lock()
            if fileCache.count < 256 { fileCache[houseKey(bundleId: bundleId, path: path)] = data }
            cacheLock.unlock()
        }
        return result
    }

    /// Write/create a file inside an app's Data container.
    func houseWrite(bundleId: String, path: String, data: Data) -> Result<Void, String> {
        let pairingPath = PairingController.pairingFilePath()
        let b64 = data.base64EncodedString()
        let result = queue.sync { () -> Result<Void, String> in
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                bundleId.withCString { bundleC in
                    path.withCString { pathC in
                        b64.withCString { b64C in
                            al_house_write(pairC, bundleC, pathC, b64C, &outError)
                        }
                    }
                }
            }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_house_write returned \(rc) with no error string"
                print("[airlift] al_house_write(\(bundleId)\(path)) failed rc=\(rc): \(message)")
                return .failure(message)
            }
            return .success(())
        }
        if case .success = result {
            cacheLock.lock()
            fileCache[houseKey(bundleId: bundleId, path: path)] = data
            houseCache.removeValue(forKey: houseKey(bundleId: bundleId, path: Self.containerParent(path)))
            cacheLock.unlock()
        }
        return result
    }

    /// Delete a file/directory inside an app's Data container.
    func houseDelete(bundleId: String, path: String) -> Result<Void, String> {
        let pairingPath = PairingController.pairingFilePath()
        let result = queue.sync { () -> Result<Void, String> in
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                bundleId.withCString { bundleC in
                    path.withCString { pathC in
                        al_house_delete(pairC, bundleC, pathC, &outError)
                    }
                }
            }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_house_delete returned \(rc) with no error string"
                print("[airlift] al_house_delete(\(bundleId)\(path)) failed rc=\(rc): \(message)")
                return .failure(message)
            }
            return .success(())
        }
        if case .success = result {
            cacheLock.lock()
            fileCache.removeValue(forKey: houseKey(bundleId: bundleId, path: path))
            houseCache.removeValue(forKey: houseKey(bundleId: bundleId, path: Self.containerParent(path)))
            cacheLock.unlock()
        }
        return result
    }

    /// Container-relative parent of `path` (`/Library/Preferences` -> `/Library`).
    private static func containerParent(_ path: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.isEmpty { return "/" }
        components.removeLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private func houseKey(bundleId: String, path: String) -> String {
        "\(bundleId)\u{0}\(path)"
    }

    /// Drop the cached listing of `path`'s parent so the next listing reflects
    /// a write/delete. Pass no argument to clear everything.
    func invalidateCache(for path: String? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let path {
            listingCache.removeValue(forKey: path)
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            listingCache.removeValue(forKey: parent)
            // A change inside an app container invalidates that container's
            // cached listing too.
            if let (bundleId, relativePath) = Self.containerInfoUncached(forDevicePath: path, index: appByContainerPath) {
                houseCache.removeValue(forKey: houseKey(bundleId: bundleId, path: relativePath))
                houseCache.removeValue(forKey: houseKey(bundleId: bundleId, path: Self.containerParent(relativePath)))
            }
        } else {
            listingCache.removeAll()
            houseCache.removeAll()
            fileCache.removeAll()
            // Apps come and go (installs, deletions, restores); force the next
            // container listing to ask InstallationProxy again.
            appCache = nil
            appByContainerPath.removeAll()
        }
    }

    /// `containerInfo(forDevicePath:)` without touching the cache lock — the
    /// caller already holds it.
    private static func containerInfoUncached(forDevicePath path: String, index: [String: AppEntry]) -> (bundleId: String, relativePath: String)? {
        let normalized = normalizeDevicePath(path)
        let prefix = appContainerRoot + "/"
        guard normalized.hasPrefix(prefix) else { return nil }
        let components = String(normalized.dropFirst(prefix.count))
            .split(separator: "/", omittingEmptySubsequences: false)
        guard let containerId = components.first, !containerId.isEmpty else { return nil }
        guard let entry = index["\(appContainerRoot)/\(containerId)"] else { return nil }
        let relative = components.count > 1 ? "/" + components.dropFirst().joined(separator: "/") : "/"
        return (entry.bundle_id, relative)
    }

    private func invalidateParentListingLocked(path: String) {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        listingCache.removeValue(forKey: parent)
    }
}
