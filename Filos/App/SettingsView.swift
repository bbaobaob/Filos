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
    @Environment(\.openURL) var openURL
    @Environment(\.dismiss) var dismiss
    
    @AppStorage("sbxToken") var sbxToken = ""
    @AppStorage("consumeOnLaunch") var consumeOnLaunch = false
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        AppInfoCell(build: "Beta 2")
                        HStack {
                            Button {
                                openURL(URL(string: "https://jailbreak.party/discord")!)
                            } label: {
                                ButtonLabel(text: "Discord", icon: "discord", useImage: true)
                            }
                            .buttonStyle(TranslucentButtonStyle(color: .discord))
                            
                            Button {
                                openURL(URL(string: "https://github.com/jailbreakdotparty/PancakeStore")!)
                            } label: {
                                ButtonLabel(text: "GitHub", icon: "github", useImage: true)
                            }
                            .buttonStyle(TranslucentButtonStyle(color: .github))
                        }
                        
                        Button {
                            openURL(URL(string: "https://jailbreak.party/")!)
                        } label: {
                            ButtonLabel(text: "Website", icon: "globe")
                        }
                        .buttonStyle(TranslucentButtonStyle())
                    }
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
                    Toggle("Consume On Launch", isOn: $consumeOnLaunch)
                } header: {
                    HeaderLabel(text: "Sandbox Extension Token", icon: "loupe")
                }
                
                Section {
                    LinkCreditCell(image: Image("lunginspector"), name: "lunginspector", description: "Primary developer.", url: "https://github.com/lunginspector")
                    LinkCreditCell(image: Image("skadz"), name: "Skadz", description: "SBX-related stuff and some file browser things.", url: "https://github.com/skadz108")
                    LinkCreditCell(image: Image("roooot"), name: "roooot", description: "Archiving Utilities.", url: "https://github.com/rooootdev")
                } header: {
                    HeaderLabel(text: "Credits", icon: "star")
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

