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

final class FilosManager: ObservableObject {
    static let shared = FilosManager()
    
    @Published var refreshFiles = false
    @Published var fmNavPath: URL = URL(fileURLWithPath: "/")
    
    @Published var logOutput = ""
    @Published var tokenVaild = false
    
    init() { }
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
