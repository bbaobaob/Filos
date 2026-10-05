//
//  FilosHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI


enum FolderType {
    case normal, bundle, container, appGroup
}

/// Normalize "/private/var/…" to "/var/…" so prefix checks hit either spelling.
private func normalizedFSPath(_ path: String) -> String {
    if path.hasPrefix("/private/var/") {
        return String(path.dropFirst("/private".count))
    }
    return path
}

func getFolderType(url: URL) -> FolderType {
    let parent = normalizedFSPath(url.deletingLastPathComponent().path)

    if parent == normalizedFSPath(FSPaths.appBundles) {
        return .bundle
    } else if parent == normalizedFSPath(FSPaths.appContainers) {
        return .container
    } else if parent == normalizedFSPath(FSPaths.appGroups) {
        return .appGroup
    }
    return .normal
}

/// Owning bundle id for an Application/Shared/AppGroup container row: the
/// MCMMetadataIdentifier from the device-local metadata plist, or nil when the
/// plist is missing/corrupt. Never force-unwraps.
///
/// For remote paths this returns nil without touching the tunnel — HouseArrest
/// cannot serve `…/.com.apple.mobile_container_manager.metadata.plist`, and
/// probing it once per container row hangs the listing. The label comes from
/// the cached InstallationProxy entry instead (see `appRowLabels`).
func getBIDFromMCM(_ url: URL) -> String? {
    let path = url.path + "/.com.apple.mobile_container_manager.metadata.plist"
    if AirLiftBrowse.isRemotePath(url.path) {
        return nil
    }
    guard let plist = NSDictionary(contentsOf: URL(fileURLWithPath: path)) else { return url.lastPathComponent }
    return plist["MCMMetadataIdentifier"] as? String
}

/// Display name for the row of an Application (Data) container or .app bundle:
/// CFBundleDisplayName/CFBundleName from the first *.app's Info.plist.
/// Falls back to CFBundleExecutable, then to the MCMMetadataIdentifier bundle
/// id, then nil. Tolerates missing/corrupt plists.
func getNameFromInfP(_ url: URL) -> String? {
    // Remote rows are labelled purely from the cached InstallationProxy data
    // (`appRowLabels` / `folderLabel`). Reading the container's Info.plist over
    // the tunnel during row rendering is what made every container row spawn a
    // HouseArrest tunnel, stalling the listing.
    guard !AirLiftBrowse.isRemotePath(url.path) else { return nil }

    // Collect candidate .app directories.
    var apps: [String] = []
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
    apps = contents.filter { $0.hasSuffix(".app") }

    for item in apps {
        let infopath = url.path + "/" + item + "/Info.plist"
        let plist = NSDictionary(contentsOf: URL(fileURLWithPath: infopath))
        guard let plist else { continue }
        if let name = plist["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = plist["CFBundleName"] as? String, !name.isEmpty { return name }
        if let exec = plist["CFBundleExecutable"] as? String, !exec.isEmpty { return exec }
    }

    // Fallback tier the spec asks for: owning bundle id from the metadata plist.
    if let bid = getBIDFromMCM(url), !bid.isEmpty { return bid }
    return nil
}

/// Row title with subtitle for Application (Data) containers and Shared/AppGroup
/// containers:
///   * container / bundle — display name, bundle id underneath.
///   * appGroup — owning app display name, bundle id underneath (the bare
///     container UUID is never the title when the owner is known).
///
/// The App Group listing comes back from the pulled directory as bare UUID
/// folder names, so the owner has to come from the InstallationProxy cache
/// (`AirLiftBrowse.app(forAppGroupPath:)`) — the same data source the
/// Application container rows use. Nothing here probes the device: a plist read
/// per row stalls the whole listing.
func appRowLabels(url: URL) -> (title: String, subtitle: String?) {
    switch getFolderType(url: url) {
    case .appGroup:
        if AirLiftBrowse.isRemotePath(url.path) {
            // Cached InstallationProxy entry only — no plist probe on render.
            if let hit = AirLiftBrowse.shared.app(forAppGroupPath: url.path) {
                return (title: hit.app.name.isEmpty ? hit.app.bundle_id : hit.app.name, subtitle: hit.app.bundle_id)
            }
            return (title: url.lastPathComponent, subtitle: "bundle id unavailable")
        }
        // AppGroup leads with the owning bundle id; the UUID is the fallback.
        let bundleID = getBIDFromMCM(url) ?? url.lastPathComponent
        return (title: bundleID, subtitle: url.lastPathComponent)
    case .container, .bundle:
        if AirLiftBrowse.isRemotePath(url.path) {
            // InstallationProxy already knows both halves of the label for a Data
            // container (display name + bundle id) — no tunnel round trip needed.
            if let app = AirLiftBrowse.shared.app(forContainerPath: url.path) {
                return (title: app.name.isEmpty ? app.bundle_id : app.name, subtitle: app.bundle_id)
            }
            // Unknown to the cache: honest fallback, never a probe per row.
            return (title: url.lastPathComponent, subtitle: "bundle id unavailable")
        }
        let bundleID = getBIDFromMCM(url) ?? url.lastPathComponent
        let name = getNameFromInfP(url) ?? bundleID
        return (title: name, subtitle: bundleID)
    case .normal:
        return (title: url.lastPathComponent, subtitle: nil)
    }
}

func folderLabel(url: URL) -> String {
    let parent = normalizedFSPath(url.deletingLastPathComponent().path)

    if parent == normalizedFSPath(FSPaths.appBundles) {
        if AirLiftBrowse.isRemotePath(url.path) {
            return AirLiftBrowse.shared.app(forContainerPath: url.path)?.name.nonEmpty ?? url.lastPathComponent
        }
        return getNameFromInfP(url) ?? url.lastPathComponent
    } else if parent == normalizedFSPath(FSPaths.appContainers) || parent == normalizedFSPath(FSPaths.appGroups) {
        if AirLiftBrowse.isRemotePath(url.path) {
            // App Group directories are indexed by their own container path, not
            // by a Data container path — see `app(forAppGroupPath:)`.
            if parent == normalizedFSPath(FSPaths.appGroups),
               let hit = AirLiftBrowse.shared.app(forAppGroupPath: url.path) {
                return hit.app.bundle_id
            }
            return AirLiftBrowse.shared.app(forContainerPath: url.path)?.bundle_id ?? url.lastPathComponent
        }
        return getBIDFromMCM(url) ?? url.lastPathComponent
    }
    return url.lastPathComponent
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
