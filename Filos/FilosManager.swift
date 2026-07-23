//
//  FilosManager.swift
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
