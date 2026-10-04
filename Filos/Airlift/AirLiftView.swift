//
//  AirLiftView.swift
//  Filos
//
//  Airlift panel: LocalDevVPN + pairing + Airlift target paths.
//  Reached from the root screen toolbar / Settings.
//

import SwiftUI
import UniformTypeIdentifiers

struct AirLiftView: View {
    @StateObject private var airlift = AirLiftModel.shared

    @State private var showImporter = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: "airplane")
                        Text("AirLift")
                            .font(.title2.weight(.semibold))
                    }
                    Text("Filos pairs with this device over RPPairing and runs Airlift automatically on launch. Use this panel to re-pair, pick a different target, or inspect the log.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            // MARK: LocalDevVPN
            Section {
                HStack {
                    Image(systemName: airlift.vpnUp ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(airlift.vpnUp ? .green : .secondary)
                    Text(airlift.vpnUp ? "LocalDevVPN up" : "LocalDevVPN down")
                }
                if !airlift.vpnDetail.isEmpty {
                    Text(airlift.vpnDetail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button {
                    airlift.openLocalDevVPN()
                } label: {
                    Label("Bật LocalDevVPN", systemImage: "network")
                }
                Button {
                    airlift.refreshVPN()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } header: {
                HeaderLabel("LocalDevVPN", symbol: "network")
            }

            // MARK: Pairing
            Section {
                Text(airlift.pairingStatus.isEmpty
                     ? (airlift.isPaired ? "Paired" : "Not paired")
                     : airlift.pairingStatus)
                    .font(.callout)
                if let pin = airlift.pairingPIN {
                    HStack {
                        Text("PIN")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(pin)
                            .font(.system(size: 14, design: .monospaced))
                    }
                }
                Button {
                    airlift.startPairing()
                } label: {
                    Label("Pair with this device", systemImage: "link")
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import pair file", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    airlift.deletePairingCredentials()
                } label: {
                    Label("Delete pairing credentials", systemImage: "trash")
                }
            } header: {
                HeaderLabel("Pairing", symbol: "link")
            }

            // MARK: Grappa
            Section {
                Button {
                    airlift.generateGrappa()
                } label: {
                    Label("Generate Grappa token", systemImage: "key")
                }
            } header: {
                HeaderLabel("Grappa", symbol: "key")
            }

            // MARK: Target paths
            Section {
                ForEach(AirLiftModel.defaultTargets, id: \.self) { path in
                    Button {
                        airlift.selectedTarget = path
                    } label: {
                        HStack {
                            Text(path)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.primary)
                            Spacer()
                            if airlift.selectedTarget == path {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }
            } header: {
                HeaderLabel("Target paths", symbol: "folder")
            } footer: {
                Text("Selected: \(airlift.selectedTarget)")
                    .font(.system(size: 11, design: .monospaced))
            }

            // MARK: Run
            Section {
                Button {
                    airlift.runAirlift()
                } label: {
                    HStack {
                        if airlift.isRunning {
                            ProgressView()
                        }
                        Text(airlift.isRunning ? "Running…" : "Run Airlift")
                    }
                }
                .disabled(airlift.isRunning)
            }

            // MARK: Result
            Section {
                if airlift.lastResult.isEmpty {
                    Text("No result yet")
                        .foregroundStyle(.secondary)
                } else {
                    Text(airlift.lastResult)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                HeaderLabel("Result", symbol: "checkmark.seal")
            }

            // MARK: Log
            Section {
                if airlift.logs.isEmpty {
                    Text("Log is empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(airlift.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                HeaderLabel("Log", symbol: "terminal")
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.propertyList],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first {
                    airlift.importPairFile(url: url)
                }
            case let .failure(error):
                airlift.log("Pair file import cancelled: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    AirLiftView()
}