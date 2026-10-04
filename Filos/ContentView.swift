//
//  ContentView.swift
//  Filos
//
//  Created by lunginspector on 7/12/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mgr: FilosManager
    @State private var showBrowser = false

    var body: some View {
        NavigationView {
            AirLiftView()
                .environmentObject(mgr)
                .navigationTitle("AirLift")
                .background {
                    NavigationLink(
                        destination: FileBrowserContainer(level: 0, url: URL(fileURLWithPath: "/"))
                            .environmentObject(mgr),
                        isActive: $showBrowser
                    ) {
                        EmptyView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showBrowser = true
                        } label: {
                            Label("File Browser", systemImage: "folder")
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

struct FileBrowserContainer: View {
    @EnvironmentObject var mgr: FilosManager
    let level: Int
    let url: URL
    
    var body: some View {
        FileBrowserView(item: getFileItem(at: url))
            .environmentObject(mgr)
            .background {
                NavigationLink(
                    destination: destView,
                    isActive: Binding(get: {
                        mgr.navArray.count > level
                    }, set: { newValue in
                        if !newValue, mgr.navArray.count > level {
                            mgr.navArray.removeSubrange(level...)
                        }
                    })
                ) {
                    EmptyView()
                }
            }
    }
    
    private var destView: some View {
        Group {
            if mgr.navArray.count > level {
                FileBrowserContainer(level: level + 1, url: mgr.navArray[level].url)
            } else {
                VStack {
                    HStack {
                        ProgressView()
                        Text("Loading...")
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
