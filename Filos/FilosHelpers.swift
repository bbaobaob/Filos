//
//  FilosHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/12/26.
//

import SwiftUI
import Combine
import PartyUI
import UniformTypeIdentifiers

final class FilosManager: ObservableObject {
    static let shared = FilosManager()
    
    @Published var refreshFiles: Bool = false
    @Published var fmNavPath = NavigationPath()
    
    @Published var logOutput = ""
    @Published var tokenVaild = false
    
    init() { }
}

enum FSPaths {
    static var appBundles = "/private/var/containers/Bundle/Application"
    static var appContainers = "/private/var/mobile/Containers/Data/Application"
}

extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws {
        if !self.fileExists(atPath: url.path) {
            try self.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

func makeTemp(_ fileURL: URL) -> URL? {
    do {
        guard fileURL.startAccessingSecurityScopedResource() else {
            throw "failed to access file!"
        }
        defer { fileURL.stopAccessingSecurityScopedResource() }
        
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(fileURL.lastPathComponent)_\(UUID())")
        try fm.copyItem(at: fileURL, to: tempURL)
        return tempURL
    } catch {
        print("[!] failed to make temp: \(error)")
    }
    return nil
}

// MARK: sbx stuff
func sbxConsume(token: String) -> Int64? {
    typealias sbxConsumeFunc = @convention(c) (UnsafePointer<CChar>?) -> Int64
    
    guard let sbxLib = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else {
        return nil
    }
    defer { dlclose(sbxLib) }
    
    guard let sbxConsumeSymbol = dlsym(sbxLib, "sandbox_extension_consume") else {
        return nil
    }
    
    let consume = unsafeBitCast(sbxConsumeSymbol, to: sbxConsumeFunc.self)
    
    let result = consume(token)
    return result
}

// MARK: generate nav url (mainly used in FileBrowserView)
func generateNavPath(path: String) -> String {
    if !path.contains("/") || path.isEmpty {
        return ""
    }
    
    let fileDetails = getFileInfo(URL(fileURLWithPath: path))
    
    if fileDetails.kind == "directory" || fileDetails.isSymlink {
        return path
    }
    
    if fileDetails.kind == "file" {
        let navPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return navPath
    }
    
    return ""
}

// MARK: get file info
func getFileInfo(_ fileURL: URL) -> FileInfoProperties {
    let fm = FileManager.default
    var info: FileInfoProperties = FileInfoProperties()
    
    var isdir = ObjCBool(false)
    let exists = fm.fileExists(atPath: fileURL.path, isDirectory: &isdir)
    if exists {
        info.fileExists = exists
        info.kind = isdir.boolValue ? "directory" : "file"
    }
    
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd-yyyy h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    
    let keys: Set<URLResourceKey> = [.contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isSymbolicLinkKey]
    if let values = try? fileURL.resourceValues(forKeys: keys) {
        if let type = values.contentType {
            info.uttype = type.identifier
        }
        if let size = values.fileSize {
            info.size = size
        }
        if let created = values.creationDate {
            info.created = formatter.string(from: created)
        }
        if let modified = values.contentModificationDate {
            info.modified = formatter.string(from: modified)
        }
        if let sym = values.isSymbolicLink {
            info.isSymlink = sym
        }
    }
    
    if let attrs = try? fm.attributesOfItem(atPath: fileURL.path) {
        if let perms = attrs[.posixPermissions] as? NSNumber {
            info.posixPerms = String(format: "%04o", perms.intValue)
        }
        if let owner = attrs[.ownerAccountName] as? String {
            info.owner = owner
        }
        if let group = attrs[.groupOwnerAccountName] as? String {
            info.group = group
        }
    }
    
    info.readable = fm.isReadableFile(atPath: fileURL.path)
    info.writable = fm.isWritableFile(atPath: fileURL.path)
    info.executable = fm.isExecutableFile(atPath: fileURL.path)
    
    return info
}

// MARK: get dict from file
func getFileDict(_ url: URL) -> [String : Any] {
    if let data = try? Data(contentsOf: url),
       let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any] {
        return dict
    }
    
    return [:]
}

// MARK: get text from file
func getFileText(_ url: URL) -> String {
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

// MARK: get info from folder
enum FolderType {
    case normal, bundle, container
}

func folderLabel(url: URL) -> String {
    let parent = url.deletingLastPathComponent().path
    
    if parent == FSPaths.appBundles {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return url.lastPathComponent }
        
        for item in contents where item.hasSuffix(".app") {
            let infopath = url.path + "/" + item + "/Info.plist"
            guard let plist = NSDictionary(contentsOf: URL(fileURLWithPath: infopath)) else { continue }
            
            return (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? (plist["CFBundleExecutable"] as? String) ?? url.lastPathComponent
        }
    } else if parent == FSPaths.appContainers {
        let path = url.path + "/.com.apple.mobile_container_manager.metadata.plist"
        guard let plist = NSDictionary(contentsOf: URL(fileURLWithPath: path)) else { return url.lastPathComponent }
        return plist["MCMMetadataIdentifier"] as? String ?? url.lastPathComponent
    }
    return url.lastPathComponent
}

func getFolderType(url: URL) -> FolderType {
    let parent = url.deletingLastPathComponent().path
    
    if parent == FSPaths.appBundles {
        return .bundle
    } else if parent == FSPaths.appContainers {
        return .container
    }
    return .normal
}
