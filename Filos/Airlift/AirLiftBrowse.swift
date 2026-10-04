//
//  AirLiftBrowse.swift
//  Filos
//
//  Swift wrapper around the al_dir_list / al_file_read / al_file_write /
//  al_file_delete FFI surface. Used by FileBrowserView for the Airlift
//  target paths (/var/mobile, /var/tmp, the 12 default targets) since the
//  sandboxed FileManager cannot see them.
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

final class AirLiftBrowse {

    static let shared = AirLiftBrowse()

    /// Serial queue for every remote call; tunnel opens must not race.
    private let queue = DispatchQueue(label: "filos.airlift.browse", qos: .userInitiated)

    /// Last successful listing per directory path.
    private var listingCache: [String: [RemoteEntry]] = [:]
    /// Small read-through cache for plist/label reads (keyed by file path).
    private var fileCache: [String: Data] = [:]
    private let cacheLock = NSLock()

    private init() {}

    // MARK: - Path predicate

    /// True when `path` lives under one of the Airlift target roots.
    static func isRemotePath(_ path: String) -> Bool {
        let roots = ["/var/mobile", "/var/tmp", "/private/var/mobile", "/private/var/tmp"]
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return AirLiftModel.defaultTargets.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    // MARK: - Listing

    /// List a remote directory. Returns nil when the tunnel fails; callers
    /// should fall back to FileManager and surface the existing error UI.
    @discardableResult
    func listDir(_ path: String) -> [RemoteEntry]? {
        let pairingPath = PairingController.pairingFilePath()
        let json = queue.sync { () -> String? in
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
                print("[airlift] al_dir_list(\(path)) failed rc=\(rc): \(err ?? "?")")
                return nil
            }
            return json
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let entries = try? JSONDecoder().decode([RemoteEntry].self, from: data) else {
            print("[airlift] al_dir_list(\(path)) returned undecodable JSON")
            return nil
        }
        cacheLock.lock()
        listingCache[path] = entries
        cacheLock.unlock()
        return entries
    }

    /// Cached listing for `path`, if a successful fetch happened earlier.
    func cachedListing(for path: String) -> [RemoteEntry]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return listingCache[path]
    }

    // MARK: - Files

    func readFile(_ path: String) -> Data? {
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

    /// Drop the cached listing of `path`'s parent so the next listing reflects
    /// a write/delete. Pass no argument to clear everything.
    func invalidateCache(for path: String? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let path {
            listingCache.removeValue(forKey: path)
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            listingCache.removeValue(forKey: parent)
        } else {
            listingCache.removeAll()
            fileCache.removeAll()
        }
    }

    private func invalidateParentListingLocked(path: String) {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        listingCache.removeValue(forKey: parent)
    }
}
