//
//  FilosHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI
import PartyUI
import UniformTypeIdentifiers

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

enum FolderType {
    case normal, bundle, container
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
