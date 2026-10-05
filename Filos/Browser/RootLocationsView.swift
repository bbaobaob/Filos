//
//  RootLocationsView.swift
//  Filos
//
//  Root screen: the 12 Airlift-supported locations, as a static list. Tapping a
//  row pushes the regular FileBrowser so files inside can be viewed, edited,
//  renamed, etc.
//
//  This view does no directory loading of its own. It renders one static row per
//  `AirLiftModel.defaultTargets` entry and nothing else — no listing, no
//  AirLiftModel observation, no ATC trigger — so it cannot re-enter a listing
//  while a pushed screen is still working. The enumeration happens once, inside
//  the pushed `FileBrowserView` (AFC / InstallationProxy / house_arrest).
//

import SwiftUI

struct RootLocationsView: View {
    @EnvironmentObject var mgr: FilosManager

    @State private var showAirLift = false
    @State private var showLogs = false
    @State private var showSettings = false

    @AppStorage("listStyle") var listStyle = 1

    /// Row model, built once. `AirLiftModel.defaultTargets` is a static `let`,
    /// so this never changes while the view lives — no state to mutate, nothing
    /// to re-render on.
    private struct RootRow: Identifiable {
        let path: String
        let name: String
        var id: String { path }
    }

    private let rows: [RootRow] = AirLiftModel.defaultTargets.map {
        RootRow(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent)
    }

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    NavigationLink {
                        FileBrowserContainer(level: 1, url: URL(fileURLWithPath: row.path))
                    } label: {
                        NavigationLabel(text: row.name, symbol: "folder", footer: row.path, showChevron: true)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        // The pushed FileBrowser reads `navArray[0]`, so record the
                        // navigation here too. The link itself does the pushing;
                        // this only keeps the deep-link stack in sync.
                        if mgr.navArray.isEmpty {
                            mgr.push(URL(fileURLWithPath: row.path))
                        }
                    })
                }
            } header: {
                HeaderLabel("Locations", symbol: "folder")
            } footer: {
                Text("Airlift runs automatically on launch, so these directories can be read and edited.")
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
}

#Preview {
    RootLocationsView()
        .environmentObject(FilosManager.shared)
}