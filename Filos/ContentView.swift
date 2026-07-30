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
                .background {
                    NavigationLink(
                        destination: FileBrowserView(path: mgr.fmNavPath ?? URL(fileURLWithPath: "/")),
                        tag: mgr.fmNavPath ?? URL(fileURLWithPath: "/"),
                        selection: $mgr.fmNavPath
                    ) {
                        EmptyView()
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    ContentView()
}
