//
//  SettingsView.swift
//  Filos
//
//  Created by lunginspector on 7/13/26.
//

import SwiftUI
import PartyUI

struct SettingsView: View {
    @EnvironmentObject var mgr: FilosManager
    @Environment(\.dismiss) var dismiss
    
    @AppStorage("sbxToken") var sbxToken = ""
    @AppStorage("consumeOnLaunch") var consumeOnLaunch = false
    @AppStorage("plainList") var plainList = false
    @AppStorage("hideFavs") var hideFavs = false
    @AppStorage("hideDates") var hideDates = false
    
    @AppStorage("textViewerSize") var textViewerSize = 10
    @AppStorage("useMonospaced") var useMonospaced = true
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    AppInfoCell(build: "Beta 3")
                    NavigationLink("Credits") {
                        List {
                            LinkCreditCell(image: Image("lunginspector"), name: "lunginspector", description: "Primary developer.", url: "https://github.com/lunginspector")
                            LinkCreditCell(image: Image("skadz"), name: "Skadz", description: "SBX-related stuff and some file browser things.", url: "https://github.com/skadz108")
                            LinkCreditCell(image: Image("roooot"), name: "roooot", description: "Archiving Utilities.", url: "https://github.com/rooootdev")
                        }
                        .navigationTitle("Credits")
                    }
                } header: {
                    HeaderLabel(text: "About", icon: "info.circle")
                } footer: {
                    Text("Made with love by [lunginspector](https://github.com/lunginspector) under the [jailbreak.party](https://jailbreak.party) team.\nJoin our [discord](https://jailbreak.party/discord)!")
                }
                
                Section {
                    TextField("Token", text: $sbxToken)
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
                                    let res = sbxConsume(token: sbxToken)!
                                    
                                    if res >= 1 {
                                        print("[*] consumed=1, token valid!")
                                        mgr.tokenVaild = true
                                    } else {
                                        print("[!] consumed!=2, token invalid?")
                                        mgr.tokenVaild = false
                                        Alertinator.shared.alert(title: "Failed to consume sandbox extension token!", body: "This token is likely invaild. Generate a new token, and put it in settings.")
                                    }
                                }
                            }
                        } else {
                            Button("Eject", role: .destructive) {
                                sbxToken = ""
                                mgr.tokenVaild = false
                            }
                        }
                    }
                    Toggle("Consume on launch", isOn: $consumeOnLaunch)
                } header: {
                    HeaderLabel(text: "Sandbox Extension Token", icon: "loupe")
                }
                
                Section {
                    Toggle("Plain list style", isOn: $plainList)
                    Toggle("Hide \"Favorite\" button", isOn: $hideFavs)
                    Toggle("Hide dates in listed items", isOn: $hideDates)
                } header: {
                    HeaderLabel(text: "View Options", icon: "eye")
                }
                
                Section {
                    Stepper(value: $textViewerSize) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text(textViewerSize.description)
                        }
                    }
                    Toggle("Use monospaced font", isOn: $useMonospaced)
                } header: {
                    HeaderLabel(text: "Text Viewer", icon: "doc.plaintext")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", icon: "xmark")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

