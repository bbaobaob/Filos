//
//  LogView.swift
//  dirtyZero
//
//  Created by lunginspector on 4/17/26.
//

import SwiftUI
import PartyUI

struct LogView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var mgr: FilosManager

    var body: some View {
        NavigationStack {
            GeometryReader { _ in
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(mgr.logOutput)
                            .font(.system(size: 10, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Spacer()
                            .id(0)
                    }
                    .onAppear {
                        proxy.scrollTo(0)
                    }
                    .onChange(of: mgr.logOutput) { _ in
                        proxy.scrollTo(0)
                    }
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = mgr.logOutput
                        } label: {
                            Label("Copy Output", systemImage: "doc.on.doc")
                        }
                        
                        Button {
                            do {
                                let formatter = DateFormatter()
                                formatter.dateFormat = "MM-dd-yyyy-HHmmss"
                                let date = formatter.string(from: Date())
                                
                                let tempURL = URL.temporaryDirectory.appendingPathComponent("Filos-Log-\(date)").appendingPathExtension("txt")
                                guard let data = mgr.logOutput.data(using: .utf8) else {
                                    throw "failed to create data from log string"
                                }
                                
                                try data.write(to: tempURL)
                                presentShareSheet(with: tempURL)
                            } catch {
                                print("[*] failed to export logs: \(error)")
                            }
                        } label: {
                            Label("Export Logs", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("Menu", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        CloseSheetLabel()
                    }
                }
            }
        }
    }
}

#Preview {
    LogView()
        .environmentObject(FilosManager.shared)
}
