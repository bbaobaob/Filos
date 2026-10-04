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
func getBIDFromMCM(_ url: URL) -> String? {
    let path = url.path + "/.com.apple.mobile_container_manager.metadata.plist"
    if AirLiftBrowse.isRemotePath(url.path) {
        guard let data = AirLiftBrowse.shared.readFile(path) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        return plist["MCMMetadataIdentifier"] as? String
    }
    guard let plist = NSDictionary(contentsOf: URL(fileURLWithPath: path)) else { return url.lastPathComponent }
    return plist["MCMMetadataIdentifier"] as? String
}

/// Display name for the row of an Application (Data) container or .app bundle:
/// CFBundleDisplayName/CFBundleName from the first *.app's Info.plist.
/// Falls back to CFBundleExecutable, then to the MCMMetadataIdentifier bundle
/// id, then nil. Tolerates missing/corrupt plists.
func getNameFromInfP(_ url: URL) -> String? {
    let isRemote = AirLiftBrowse.isRemotePath(url.path)

    // Collect candidate .app directories.
    var apps: [String] = []
    if isRemote {
        apps = ((try? AirLiftBrowse.shared.listDir(url.path).get()) ?? [])
            .filter { $0.name.hasSuffix(".app") }
            .map { $0.name }
    } else {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        apps = contents.filter { $0.hasSuffix(".app") }
    }

    for item in apps {
        let infopath = url.path + "/" + item + "/Info.plist"
        var plist: NSDictionary?
        if isRemote {
            if let data = AirLiftBrowse.shared.readFile(infopath) {
                plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSDictionary
            }
        } else {
            plist = NSDictionary(contentsOf: URL(fileURLWithPath: infopath))
        }
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
///   * appGroup — owning bundle id first, container UUID underneath.
func appRowLabels(url: URL) -> (title: String, subtitle: String?) {
    let bundleID = getBIDFromMCM(url) ?? url.lastPathComponent
    switch getFolderType(url: url) {
    case .appGroup:
        // AppGroup leads with the owning bundle id; the UUID is the fallback.
        return (title: bundleID, subtitle: url.lastPathComponent)
    case .container, .bundle:
        // InstallationProxy already knows both halves of the label for a Data
        // container (display name + bundle id) — no plist round trip needed.
        if let app = AirLiftBrowse.shared.app(forContainerPath: url.path) {
            return (title: app.name.isEmpty ? app.bundle_id : app.name, subtitle: app.bundle_id)
        }
        let name = getNameFromInfP(url) ?? bundleID
        return (title: name, subtitle: bundleID)
    case .normal:
        return (title: url.lastPathComponent, subtitle: nil)
    }
}

func folderLabel(url: URL) -> String {
    let parent = normalizedFSPath(url.deletingLastPathComponent().path)

    if parent == normalizedFSPath(FSPaths.appBundles) {
        return getNameFromInfP(url) ?? url.lastPathComponent
    } else if parent == normalizedFSPath(FSPaths.appContainers) || parent == normalizedFSPath(FSPaths.appGroups) {
        return getBIDFromMCM(url) ?? url.lastPathComponent
    }
    return url.lastPathComponent
}
