//
//  FileHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI
import PartyUI

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

func getFileDict(_ url: URL) -> [String : Any]? {
    if let data = try? Data(contentsOf: url),
       let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any] {
        return dict
    }
    
    return nil
}

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

func makeTemp(_ fileURL: URL) -> URL? {
    do {
        let neededAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if neededAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(fileURL.lastPathComponent)_\(UUID())")
        try fm.copyItem(at: fileURL, to: tempURL)
        return tempURL
    } catch {
        print("[!] failed to make temp: \(error)")
    }
    return nil
}

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
