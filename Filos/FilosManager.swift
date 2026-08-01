//
//  FilosManager.swift
//  Filos
//
//  Created by lunginspector on 7/12/26.
//

import SwiftUI
import UIKit
import Combine
import PartyUI
import UniformTypeIdentifiers

enum Errors {
    static var checkLogs = "Check error logs for more detailed information."
}

struct NavItem {
    let id = UUID()
    let url: URL
}

final class FilosManager: ObservableObject {
    static let shared = FilosManager()
    
    @Published var refreshFiles = false
    
    @Published var logOutput = ""
    @Published var tokenVaild = false
    
    @Published var navArray: [NavItem] = []
    
    init() { }
    
    func push(_ url: URL) {
        navArray.append(NavItem(url: url))
    }
}

// ios 15 surprise!
extension URL {
    static var temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    static var documentsDirectory: URL {
        do {
            let url = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            return url
        } catch {
            return URL(string: "")!
        }
    }
}
