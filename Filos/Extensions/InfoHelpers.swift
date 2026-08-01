//
//  FilosHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI
import PartyUI

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
