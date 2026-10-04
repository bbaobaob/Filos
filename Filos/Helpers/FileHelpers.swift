//
//  FileHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI

import ZIPFoundation
import UniformTypeIdentifiers

enum FSPaths {
    static var appBundles = "/private/var/containers/Bundle/Application"
    static var appContainers = "/private/var/mobile/Containers/Data/Application"
    static var appGroups = "/private/var/mobile/Containers/Shared/AppGroup"
}

extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws {
        if !self.fileExists(atPath: url.path) {
            try self.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

func getFileDict(_ url: URL) -> [String : Any]? {
    if AirLiftBrowse.isRemotePath(url.path) {
        guard let data = AirLiftBrowse.shared.readFile(url.path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any]
    }
    if let data = try? Data(contentsOf: url),
       let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any] {
        return dict
    }

    return nil
}

func getFileText(_ url: URL) -> String {
    if AirLiftBrowse.isRemotePath(url.path) {
        guard let data = AirLiftBrowse.shared.readFile(url.path) else {
            print("(fm) remote read failed for \(url.path)")
            return ""
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }
    do {
        let data = try Data(contentsOf: url)

        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(decoding: data, as: UTF8.self)
    } catch {
        print("(fm) failed to get text! path: \(error)")
        return ""
    }
}

func makeTemp(_ fileURL: URL) -> URL? {
    do {
        let neededAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if neededAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(fileURL.lastPathComponent)")
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: fileURL, to: tempURL)
        return tempURL
    } catch {
        print("[!] failed to make temp: \(error)")
    }

    // Remote fallback: fetch over the tunnel and stage in a temp file.
    if AirLiftBrowse.isRemotePath(fileURL.path), let data = AirLiftBrowse.shared.readFile(fileURL.path) {
        let tempURL = URL.temporaryDirectory.appendingPathComponent(fileURL.lastPathComponent)
        try? fm.removeItem(at: tempURL)
        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            print("[!] failed to stage remote file: \(error)")
        }
    }
    return nil
}

/// Delete regardless of whether the path is local or remote.
@discardableResult
func removeItemAnywhere(at url: URL) -> Bool {
    if AirLiftBrowse.isRemotePath(url.path) {
        return AirLiftBrowse.shared.delete(url.path)
    }
    do {
        try fm.removeItem(at: url)
        return true
    } catch {
        print("[!] failed to delete \(url.path): \(error)")
        return false
    }
}

func generateNavPath(path: String) -> String {
    if !path.contains("/") || path.isEmpty {
        return ""
    }
    
    let file = getFileItem(at: URL(fileURLWithPath: path))
    
    if file.type == .folder || file.type == .symlink {
        return path
    }
    
    if file.type == .file {
        let navPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return navPath
    }
    return ""
}

func renameFile(_ url: URL, to newName: String) -> Bool {
    do {
        let data = try Data(contentsOf: url)
        try fm.removeItem(at: url)
        let targetURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try data.write(to: targetURL)
        return true
    } catch {
        print("[!] failed to rename file: \(error)")
    }
    return false
}

func zipFile(_ url: URL) -> Bool {
    do {
        let zipDest = url
            .deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".zip")
        try FileManager.default.zipItem(at: url, to: zipDest, shouldKeepParent: true)
        return true
    } catch {
        print("[!] failed to zip file: \(error)")
    }
    return false
}

func unzipFile(_ url: URL) -> Bool {
    do {
        let unzipDest = url.deletingLastPathComponent()
        try fm.createDirectory(at: unzipDest, withIntermediateDirectories: true)
        try fm.unzipItem(at: url, to: unzipDest)
        return true
    } catch {
        print("[!] failed to uncompress file: \(error)")
    }
    return false
}

func duplicateFile(_ url: URL) -> Bool {
    do {
        let targetURL = {
            if url.pathExtension == "" {
                return url
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy")
            }
            return url
                .deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy.\(url.pathExtension)")
        }()
        let data = try Data(contentsOf: url)
        try data.write(to: targetURL)
        return true
    } catch {
        print("[!] failed to duplicate file: \(error)")
    }
    return false
}

func copyFileToClipboard(_ url: URL) -> Bool {
    do {
        guard let tempURL = makeTemp(url) else {
            throw "failed to make temp!"
        }
        let data = try Data(contentsOf: tempURL)
        let utType = UTType(filenameExtension: tempURL.pathExtension) ?? .data
        
        UIPasteboard.general.setData(data, forPasteboardType: utType.identifier)
        return true
    } catch {
        print("[!] failed to copy file: \(error)")
    }
    return false
}

func conformsToPlistViewer(_ url: URL) -> Bool {
    if AirLiftBrowse.isRemotePath(url.path) {
        // Cache-only heuristic — never pull the whole file over the tunnel just
        // to render a row badge. If the extension lies, the plist viewer will
        // fail loudly when the user taps; a failed probe must not spawn an
        // al_house_files / al_file_read per row.
        let ext = url.pathExtension.lowercased()
        return ext == "plist" || (UTType(filenameExtension: ext)?.conforms(to: .propertyList) == true)
    }
    do {
        guard let data = try? Data(contentsOf: url) else { return false }
        let _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any]
        return true
    } catch {
        return false
    }
}

func conformsToTextViewer(_ url: URL) -> Bool {
    if AirLiftBrowse.isRemotePath(url.path) {
        // Cache-only heuristic — never pull the whole file over the tunnel just
        // to render a row badge.
        let type = UTType(filenameExtension: url.pathExtension)
        if type == nil, url.pathExtension.isEmpty {
            // Extensionless files: fall back to a conservative "is text" check
            // on the *name* only — no network probe.
            return false
        }
        return type?.conforms(to: .text) == true || type?.conforms(to: .plainText) == true
    }
    do {
        let _ = try String(contentsOf: url, encoding: .utf8)
        return true
    } catch {
        return false
    }
}
