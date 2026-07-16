//
//  ContentView.swift
//  Filos
//
//  Created by lunginspector on 7/12/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mgr: FilosManager
    
    var body: some View {
        NavigationStack(path: $mgr.fmNavPath) {
            FileBrowserView(path: URL(fileURLWithPath: "/"), navigationPath: $mgr.fmNavPath)
                .navigationDestination(for: URL.self) { path in
                    FileBrowserView(path: path, navigationPath: $mgr.fmNavPath)
                }
        }
    }
}

#Preview {
    ContentView()
}
