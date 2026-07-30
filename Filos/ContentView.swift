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
        NavigationView {
            FileBrowserView()
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    ContentView()
}
