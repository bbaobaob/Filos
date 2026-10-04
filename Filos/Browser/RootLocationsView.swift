//
//  RootLocationsView.swift
//  Filos
//
//  Root screen: the Airlift-supported locations. Tapping a row pushes the
//  regular FileBrowser so files inside can be viewed, edited, renamed, etc.
//

import SwiftUI

struct RootLocationsView: View {
    @EnvironmentObject var mgr: FilosManager
    @StateObject private var airlift = AirLiftModel.shared

    @State private var showAirLift = false
    @State private var showLogs = false
    @State private var showSettings = false

    @AppStorage("listStyle") var listStyle = 1

    var body: some View {
        List {
            Section {
                ForEach(AirLiftModel.defaultTargets, id: \.self) { path in
                    Button {
                        mgr.push(URL(fileURLWithPath: path))
                    } label: {
                        NavigationLabel(text: URL(fileURLWithPath: path).lastPathComponent, footer: path, symbol: "folder", showChevron: true)
                    }
                }
            } header: {
                HeaderLabel("Locations", symbol: "folder")
            } footer: {
                Text("Airlift runs automatically on launch, so these directories can be read and edited.")
            }

            Section {
                if !airlift.paired {
                    Button {
                        airlift.startPairing()
                    } label: {
                        ButtonLabel(text: "Pair this device", symbol: "link")
                    }
                }

                if !airlift.launchStatus.isEmpty {
                    CompactAlert(
                        title: "Airlift",
                        symbol: airlift.isRunning ? "ellipsis" : "checkmark.circle",
                        text: airlift.launchStatus,
                        color: airlift.launchFailed ? .red : .accentColor
                    )
                } else {
                    CompactAlert(
                        title: "Airlift",
                        symbol: airlift.paired ? "checkmark.circle" : "exclamationmark.triangle",
                        text: airlift.paired ? "Paired — ready" : "Not paired",
                        color: airlift.paired ? .green : .orange
                    )
                }
            } header: {
                HeaderLabel("Status", symbol: "info.circle")
            }
        }
        .background {
            NavigationLink(
                destination: destView,
                isActive: Binding(get: {
                    mgr.navArray.count > 0
                }, set: { newValue in
                    if !newValue, mgr.navArray.count > 0 {
                        mgr.navArray.removeSubrange(0...)
                    }
                })
            ) {
                EmptyView()
            }
        }
        .navigationTitle(AppInfo.appName)
        .customListStyle(listStyle)
        .adaptiveListMargin()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showAirLift = true
                } label: {
                    Label("Airlift", systemImage: "airplane")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAirLift = true
                    } label: {
                        Label("Airlift", systemImage: "airplane")
                    }

                    Button {
                        showLogs = true
                    } label: {
                        Label("Logs", systemImage: "terminal")
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $showAirLift) {
            AirLiftView()
                .environmentObject(mgr)
        }
        .sheet(isPresented: $showLogs) {
            LogView()
                .environmentObject(mgr)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(mgr)
        }
    }

    // The root list itself isn't a FileBrowserView, so the first pushed URL
    // lives at navArray[0] and the container that shows it has to be level 1.
    private var destView: some View {
        Group {
            if mgr.navArray.count > 0 {
                FileBrowserContainer(level: 1, url: mgr.navArray[0].url)
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
    RootLocationsView()
        .environmentObject(FilosManager.shared)
}
