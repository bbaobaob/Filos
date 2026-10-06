//
//  SettingsView.swift
//  Filos
//
//  Created by lunginspector on 7/13/26.
//

import SwiftUI


struct SettingsView: View {
    @EnvironmentObject var mgr: FilosManager
    @Environment(\.dismiss) var dismiss
    
    @AppStorage("sbxToken") var sbxToken = ""
    @AppStorage("consumeOnLaunch") var consumeOnLaunch = false
    
    @AppStorage("listStyle") var listStyle = 1
    @AppStorage("hideFavs") var hideFavs = false
    @AppStorage("hideDates") var hideDates = false
    @AppStorage("textViewerSize") var textViewerSize = 10
    @AppStorage("useMonospaced") var useMonospaced = true

    /// Result of the last `recoverStagedCopies()` run, shown inline.
    @State private var recoverResult = ""
    @State private var recoverFailed = false
    @State private var recoverBusy = false

    /// Ask the Rust side (`al_airlift_recover`) to finish every directory that a
    /// previous `al_airlift_list_dir` left parked in `Airlock/Read`.
    ///
    /// This reports; it never lists. Browsing arms the ATC move again
    /// (`AirLiftBrowse.moveListDir(_:)`), but only under the per-path /
    /// per-launch cap, so a stranded copy is the tail case this button exists
    /// for. Off the main thread: each record replays an AirTraffic sync, so this
    /// blocks for seconds. The JSON comes back as
    /// `[{"target":…,"token":…,"status":…}, …]` and is summarised here rather
    /// than swallowed — "0 restored" is the answer people actually need.
    private func recoverStagedCopies() {
        guard !recoverBusy else { return }
        recoverBusy = true
        recoverResult = ""
        recoverFailed = false

        DispatchQueue.global(qos: .userInitiated).async {
            let result = AirLiftBrowse.shared.recoverStaging()
            let summary: String
            var failed = false
            switch result {
            case .success(let json):
                summary = Self.describeRecovery(json)
                failed = false
            case .failure(let error):
                summary = error
                failed = true
            }
            DispatchQueue.main.async {
                recoverResult = summary
                recoverFailed = failed
                recoverBusy = false
            }
        }
    }

    /// One-line summary of the `al_airlift_recover` JSON.
    private static func describeRecovery(_ json: String) -> String {
        // Every key is optional on purpose: an unreadable record comes back as
        // {"record": …, "status": "unreadable"} with no `target` at all, and one
        // such entry must not make the whole summary unreadable.
        struct Entry: Decodable {
            let target: String?
            let record: String?
            let status: String?
            let error: String?
        }
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return "Recovery returned an unexpected payload: \(json)"
        }
        if entries.isEmpty {
            return "Nothing to recover — no directory is staged in Airlock/Read."
        }
        var lines: [String] = []
        for entry in entries {
            let path = entry.target ?? entry.record ?? "<unknown path>"
            let name = (path as NSString).lastPathComponent
            let status = entry.status ?? "unknown result"
            let detail = entry.error.map { " — \($0)" } ?? ""
            lines.append("• \(name): \(status)\(detail)")
        }
        let noun = entries.count == 1 ? "directory" : "directories"
        return "\(entries.count) staged \(noun)\n" + lines.joined(separator: "\n")
    }
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    TextField("Token", text: $sbxToken)
                        .onLongPressGesture {
                            UIPasteboard.general.string = sbxToken
                        }
                    HStack {
                        HStack {
                            Image(systemName: mgr.tokenVaild ? "checkmark.circle" : "xmark.circle")
                            Text(mgr.tokenVaild ? "Valid" : "Invalid")
                        }
                        .foregroundStyle(mgr.tokenVaild ? .green : .red)
                        Spacer()
                        if !mgr.tokenVaild {
                            Button("Consume") {
                                if !sbxToken.isEmpty {
                                    mgr.tokenVaild = sbxConsume(sbxToken)
                                    
                                    if mgr.tokenVaild {
                                        print("[*] consumed=1, token valid!")
                                    } else {
                                        print("[!] consumed!=2, token invalid?")
                                        Haptic.shared.play(.heavy)
                                    }
                                }
                            }
                        } else {
                            Button("Eject", role: .destructive) {
                                sbxToken = ""
                                mgr.tokenVaild = false
                                Alertinator.shared.alert(title: "Token Ejected", body: "To reset file permissions, you'll have to restart the app. Would you like to exit now?", actionLabel: "Confirm", action: { exitinator() })
                            }
                        }
                    }
                    Toggle("Consume on Launch", isOn: $consumeOnLaunch)
                } header: {
                    HeaderLabel("Sandbox Extension Token", symbol: "loupe")
                }
                
                Section {
                    Picker("List Style", selection: $listStyle) {
                        Text("Default").tag(1)
                        Text("Plain").tag(2)
                        Text("Grouped").tag(3)
                    }
                    Toggle("Hide \"Favorite\" Button", isOn: $hideFavs)
                    Toggle("Hide Dates", isOn: $hideDates)
                } header: {
                    HeaderLabel("View Options", symbol: "eye")
                }
                
                Section {
                    Stepper(value: $textViewerSize) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text(textViewerSize.description)
                        }
                    }
                    Toggle("Monospaced Font", isOn: $useMonospaced)
                } header: {
                    HeaderLabel("Text Viewer", symbol: "doc.plaintext")
                }
                
                Section {
                    NavigationLink {
                        AirLiftView()
                    } label: {
                        ButtonLabel("Airlift", symbol: "airplane")
                    }

                    // Browsing an app container / AppGroup / Applications
                    // directory uses the Books AirTraffic sync (pull the
                    // directory to Airlock/Read, list it, push it back), capped
                    // at one session per path and a fixed number per launch
                    // (`AirLiftBrowse.maxMoveSessionsPerLaunch`). If such a
                    // sequence is interrupted — app killed, device asleep,
                    // connection dropped — the directory is still parked in
                    // Airlock/Read with a recovery record beside it, and this
                    // button finishes the job. It never lists anything itself,
                    // and never runs automatically: only when tapped here.
                    Button {
                        recoverStagedCopies()
                    } label: {
                        ButtonLabel(recoverBusy ? "Recovering…" : "Recover staged copies", symbol: recoverBusy ? "showMeProgressPlease" : "arrow.trianglehead.counterclockwise")
                    }
                    .disabled(recoverBusy)

                    if !recoverResult.isEmpty {
                        CompactAlert(
                            title: recoverFailed ? "Recovery failed" : "Recovery",
                            symbol: recoverFailed ? "exclamationmark.triangle" : "checkmark.circle",
                            text: recoverResult,
                            color: recoverFailed ? .red : .green
                        )
                    }
                } header: {
                    HeaderLabel("Airlift", symbol: "airplane")
                } footer: {
                    Text("Airlift runs automatically on launch using the stored pairing file. Pairing only happens when you tap Pair here. \"Recover staged copies\" only matters if an AirTraffic directory listing was interrupted — the per-path details it prints are the safest thing to send in a bug report.")
                }

                Section {
                    AppInfoCell(build: "Release")
                    NavigationLink("Credits") {
                        List {
                            LinkCreditCell(image: Image("lunginspector"), name: "lunginspector", description: "Primary developer.", url: "https://github.com/lunginspector")
                            LinkCreditCell(image: Image("skadz"), name: "Skadz", description: "SBX-related stuff and some file browser things.", url: "https://github.com/skadz108")
                            LinkCreditCell(image: Image("roooot"), name: "roooot", description: "Archiving utilities.", url: "https://github.com/rooootdev")
                        }
                        .navigationTitle("Credits")
                    }
                } header: {
                    HeaderLabel("About", symbol: "info.circle")
                } footer: {
                    Text("Made with love by [jailbreak.party](https://jailbreak.party) team.\nNeed support? Join our [Discord server!](https://jailbreak.party/discord)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .noRefreshable()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", symbol: "xmark")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

