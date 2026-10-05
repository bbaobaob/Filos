//
//  AirLiftBrowse.swift
//  Filos
//
//  Swift wrapper around the al_dir_list / al_file_read / al_file_write /
//  al_file_delete / al_list_apps / al_airlift_list_dir / al_airlift_recover /
//  al_house_* FFI surface. Used by FileBrowserView for the Airlift target paths
//  (/var/mobile, /var/tmp, the 12 default targets) since the sandboxed
//  FileManager cannot see them.
//
//  App containers are read back through InstallationProxy (`al_list_apps`) for
//  the container root and com.apple.mobile.house_arrest (`al_house_*`) for
//  everything inside one container; AppGroup and every other remote root stay
//  on plain AFC (`al_dir_list`). The Books AirTraffic "move any object
//  anywhere" route (`al_airlift_list_dir`) covers the three roots AFC cannot
//  reach, but it moves the directory to `Airlock/Read` and back, so it is
//  loop-guarded: at most one session per path and
//  `maxMoveSessionsPerLaunch` per launch — see `moveListDir(_:)`.
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
    /// Paths that already spent their one ATC session this launch. A second
    /// visit serves the cache instead of starting another AirTraffic sync — this
    /// is what stops the navigation loop.
    private var moveAttempted: Set<String> = []
    /// Failure message of the one attempt a path made, so a reappearance repeats
    /// the real error instead of a generic "already tried" line.
    private var moveFailures: [String: String] = [:]
    /// ATC sessions started this launch, against `maxMoveSessionsPerLaunch`.
    private var moveSessionCount = 0
    private let cacheLock = NSLock()

    /// Hard cap on ATC-move sessions for the whole app run.
    static let maxMoveSessionsPerLaunch = 3

    private init() {}

    // MARK: - Path predicate

    /// True when `path` lives under one of the Airlift target roots.
    static func isRemotePath(_ path: String) -> Bool {
        let roots = ["/var/mobile", "/var/tmp", "/private/var/mobile", "/private/var/tmp"]
        if roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        return AirLiftModel.defaultTargets.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
    }

    // MARK: - Airlift ATC move (loop-guarded)

    /// Device roots the Books ATC move reads. They sit outside AFC's
    /// `/var/mobile/Media` jail, so `al_dir_list` can never list them; these are
    /// exactly the roots the Rust side accepts (`checked_pull_path`).
    static let airliftMoveRoots: [String] = [
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Shared/AppGroup",
        "/var/mobile/Applications",
    ]

    /// True when `path` is listed through the Books ATC move
    /// (`al_airlift_list_dir`) rather than AFC / InstallationProxy /
    /// house_arrest.
    ///
    /// That call *moves* the directory out to `Airlock/Read/<token>` and back
    /// through a restore symlink, and on-device testing showed two failure
    /// modes: it spun the navigation in a loop (a reappearing entry re-triggered
    /// a pull that re-armed the same entry), and only ever moved once per path
    /// (the Books asset state read as one-shot, so later pulls answered
    /// `ObjectNotFound`). Both are now contained rather than avoided:
    /// [`moveListDir(_:)`] spends at most one ATC session per path and
    /// [`maxMoveSessionsPerLaunch`] caps the whole app run, so the route cannot
    /// loop no matter how often the view reappears. See that method for the
    /// retry contract.
    static func usesAirliftMove(_ path: String) -> Bool {
        let normalized = normalizeDevicePath(path)
        return airliftMoveRoots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
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

    /// List a remote directory over AFC.
    ///
    /// Never starts an ATC session: a refresh reload, a scroll or a reappearance
    /// of the same view all land here. Container directories go through the ATC
    /// move instead, via `moveListDir(_:)`.
    ///
    /// - Throws: the FFI error string when the tunnel or the AFC listing
    ///   failed. Callers must surface it rather than fall back to
    ///   `FileManager` — the sandboxed `FileManager` cannot see these paths at
    ///   all, so its failure (code 257) is meaningless and its "no permission"
    ///   copy actively misleads.
    func listDir(_ path: String) -> Result<[RemoteEntry], String> {
        let api = "al_dir_list"
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
                let message = err ?? "\(api) returned \(rc) with no error string"
                print("[airlift] \(api)(\(path)) failed rc=\(rc): \(message)")
                return .failure(message)
            }
            guard let json else {
                let message = "\(api)(\(path)) succeeded but returned no JSON"
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
            return .failure("\(api)(\(path)) returned text that is not valid UTF-8")
        }
        guard let entries = try? JSONDecoder().decode([RemoteEntry].self, from: data) else {
            let message = "\(api)(\(path)) returned JSON that could not be decoded"
            print("[airlift] \(message)")
            return .failure(message)
        }
        cacheLock.lock()
        listingCache[path] = entries
        cacheLock.unlock()
        return .success(entries)
    }

    // MARK: - Loop-guarded ATC move

    /// What `moveListDir(_:)` decided to do about one ATC-move attempt.
    enum MoveOutcome {
        /// A session ran (or had already run) and produced this listing.
        case listed([RemoteEntry])
        /// No session was started. `reason` is user-facing.
        case refused(String)
        /// No session was started because this path already had its one attempt
        /// this launch; `cached` is whatever the first attempt produced.
        case alreadyAttempted(Result<[RemoteEntry], String>)
    }

    /// ATC sessions started so far this launch, and the cap.
    var moveSessionUsage: (used: Int, cap: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (moveSessionCount, Self.maxMoveSessionsPerLaunch)
    }

    /// List `path` through the Books ATC move, at most once per launch.
    ///
    /// The guard exists because the route is destructive on the device: it moves
    /// the directory to `Airlock/Read/<token>` and back. On-device testing
    /// showed (a) a navigation loop, because a restored row re-entered the view
    /// and re-triggered a pull, and (b) one successful move per path only. So:
    ///
    /// * first visit spends one session, whatever the outcome — success caches
    ///   the listing, failure caches the message;
    /// * every later visit returns `.alreadyAttempted` with that cached result
    ///   and starts no session, which is what makes the loop impossible;
    /// * once `maxMoveSessionsPerLaunch` sessions are gone, every path is
    ///   refused with a static message.
    ///
    /// Callers must offer `resetMoveAttempt(for:)` (a deliberate button press) as
    /// the only way back in. Never call this from a refresh, a scroll or
    /// `.onAppear` of a view that can reappear on its own.
    func moveListDir(_ path: String) -> MoveOutcome {
        // Booking the attempt and the session budget has to be atomic: two views
        // appearing at once must not both start a session for one path.
        cacheLock.lock()
        let alreadyMoved = moveAttempted.contains(path)
        let budgetLeft = moveSessionCount < Self.maxMoveSessionsPerLaunch
        if !alreadyMoved && budgetLeft { moveAttempted.insert(path) }
        if !alreadyMoved && budgetLeft { moveSessionCount += 1 }
        let cached = listingCache[path]
        let priorFailure = moveFailures[path]
        cacheLock.unlock()

        if alreadyMoved {
            print("[airlift] ATC read of \(path) already used its one attempt this launch; serving the cached result (session \(Self.maxMoveSessionsPerLaunch) total)")
            if let cached { return .alreadyAttempted(.success(cached)) }
            let prior = priorFailure ?? Self.alreadyAttemptedMessage(path)
            return .alreadyAttempted(.failure(prior))
        }
        guard budgetLeft else {
            return .refused(Self.budgetExhaustedMessage)
        }

        print("[airlift] ATC read of \(path) starting session (attempt 1 of 1)")
        let result = listDirViaAirliftMove(path)
        switch result {
        case .success(let entries):
            cacheLock.lock()
            moveFailures[path] = nil
            cacheLock.unlock()
            return .listed(entries)
        case .failure(let message):
            // Remember the failure so a reappearance repeats the message instead
            // of starting another session.
            cacheLock.lock()
            moveFailures[path] = message
            cacheLock.unlock()
            return .alreadyAttempted(.failure(message))
        }
    }

    /// Give `path` its one ATC attempt back, so the next `moveListDir(_:)` may
    /// start a session. Only ever called from an explicit user action — the
    /// budget still applies, so this cannot become a loop either.
    func resetMoveAttempt(for path: String) {
        cacheLock.lock()
        moveAttempted.remove(path)
        moveFailures.removeValue(forKey: path)
        cacheLock.unlock()
        print("[airlift] ATC read of \(path) was re-armed for one more attempt")
    }

    /// Message for a path that already spent its attempt and has no cached
    /// listing to show.
    private static func alreadyAttemptedMessage(_ path: String) -> String {
        "This directory was already read once with the AirTraffic sync this session, and that attempt did not produce a listing. Reading it again means moving the directory out to \(AirLiftBrowse.airlockReadDir) and back, which is not repeated automatically.\n\nTap \"Retry AirTraffic read\" to try it once more on purpose, or use Settings → Recover staged copies if a directory is stuck there."
    }

    /// Message once the per-launch session cap is spent.
    private static var budgetExhaustedMessage: String {
        let cap = Self.maxMoveSessionsPerLaunch
        return "This session already used its \(cap) AirTraffic reads. Each one moves a real directory out to \(Self.airlockReadDir) and back, so no more start automatically.\n\nRelaunch Filos to get another \(cap), or use Settings → Recover staged copies if a directory was left there."
    }

    private static let airlockReadDir = "Airlock/Read"

    /// The actual FFI call. Blockingly moves the directory; callers run it off
    /// the main thread and have already booked the attempt.
    private func listDirViaAirliftMove(_ path: String) -> Result<[RemoteEntry], String> {
        let pairingPath = PairingController.pairingFilePath()
        let raw = queue.sync { () -> Result<String, String> in
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                path.withCString { pathC in
                    al_airlift_list_dir(pairC, pathC, airLiftLogCallback, nil, &outJSON, &outError)
                }
            }
            let json = outJSON.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outJSON { al_string_free(p) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_airlift_list_dir returned \(rc) with no error string"
                print("[airlift] al_airlift_list_dir(\(path)) failed rc=\(rc): \(message)")
                return .failure(message)
            }
            guard let json else {
                let message = "al_airlift_list_dir(\(path)) succeeded but returned no JSON"
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
            return .failure("al_airlift_list_dir(\(path)) returned text that is not valid UTF-8")
        }
        guard let entries = try? JSONDecoder().decode([RemoteEntry].self, from: data) else {
            let message = "al_airlift_list_dir(\(path)) returned JSON that could not be decoded"
            print("[airlift] \(message)")
            return .failure(message)
        }
        cacheLock.lock()
        listingCache[path] = entries
        cacheLock.unlock()
        return .success(entries)
    }

    /// Finish every pull that is still parked in `Airlock/Read` — the recovery
    /// half of the ATC move (`al_airlift_recover`).
    ///
    /// The ATC move is armed again but strictly capped (`moveListDir(_:)`), so a
    /// stranded copy is possible in principle: a pull that failed after moving
    /// the directory reports
    /// `kept at Airlock/Read/<token>; retry or call al_airlift_recover`, and
    /// calling this replays the restore step for each such record.
    ///
    /// Returns the raw JSON array of per-path results
    /// (`[{"target":…,"token":…,"status":"restored"|"failed"|"missing"…, …}]`)
    /// so the UI can show exactly what happened; decoding is the caller's job.
    ///
    /// BLOCKS for several seconds per parked directory. Never call it on
    /// launch — only from an explicit user action.
    func recoverStaging() -> Result<String, String> {
        let pairingPath = PairingController.pairingFilePath()
        return queue.sync { () -> Result<String, String> in
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pairC in
                al_airlift_recover(pairC, airLiftLogCallback, nil, &outJSON, &outError)
            }
            let json = outJSON.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outJSON { al_string_free(p) }
            if let p = outError { al_string_free(p) }
            if rc != 0 {
                let message = err ?? "al_airlift_recover returned \(rc) with no error string"
                print("[airlift] al_airlift_recover failed rc=\(rc): \(message)")
                return .failure(message)
            }
            guard let json else {
                let message = "al_airlift_recover succeeded but returned no JSON"
                print("[airlift] \(message)")
                return .failure(message)
            }
            return .success(json)
        }
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
