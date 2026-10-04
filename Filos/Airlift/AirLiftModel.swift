//
//  AirLiftModel.swift
//  Filos
//
//  Bridges the AirliftFFI rust core (AirCard-iOS) to SwiftUI.
//

import SwiftUI
import Foundation
import Combine
import UIKit
import Darwin
import AirliftFFI

/// Global sink for Rust log lines. Installed in `FilosApp.init()` via
/// `al_log_init`, consumed by `AirLiftModel` (and printed for the Filos log).
enum AirLiftLogSink {
    static var lines: [String] = []
    static var onLine: ((String) -> Void)?

    static func append(_ line: String) {
        lines.append(line)
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
        onLine?(line)
    }
}

@MainActor
final class AirLiftModel: ObservableObject {

    static let shared = AirLiftModel()

    /// LocalDevVPN default peer, same default AirCard uses.
    @Published var deviceIP: String = "10.7.0.1"

    @Published var logs: [String] = []
    @Published var vpnUp: Bool = false
    @Published var vpnDetail: String = ""
    @Published var selectedTarget: String = AirLiftModel.defaultTargets.first!
    @Published var isRunning: Bool = false
    @Published var lastResult: String = ""

    /// Mirror of `PairingController`'s published pairing state.
    @Published var pairingStatus: String = ""
    @Published var pairingPIN: String?

    private var pairingObservation: AnyCancellable?

    /// Absolute iOS directories Airlift can write into.
    static let defaultTargets: [String] = [
        "/var/mobile",
        "/var/mobile/Documents",
        "/var/mobile/Library",
        "/var/mobile/Library/Preferences",
        "/var/mobile/Library/Caches",
        "/var/mobile/Library/SpringBoard",
        "/var/mobile/Library/SMS",
        "/var/mobile/Library/Safari",
        "/var/mobile/Containers",
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Shared/AppGroup",
        "/var/tmp"
    ]

    /// Mirrors the pairing state published by `PairingController`.
    var isPaired: Bool {
        let path = PairingController.pairingFilePath()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return size > 0
    }

    init() {
        AirLiftLogSink.lines.forEach { logs.append($0) }

        AirLiftLogSink.onLine = { [weak self] line in
            Task { @MainActor in
                self?.appendLine(line)
            }
        }

        // Mirror PairingController's status/PIN into this model so the UI updates.
        pairingObservation = PairingController.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshPairing()
            }
        }
        refreshPairing()

        refreshVPN()
    }

    private func refreshPairing() {
        let controller = PairingController.shared
        pairingStatus = controller.pairingStatus
        pairingPIN = controller.pairingPIN
    }

    // MARK: - Network

    func refreshVPN() {
        let ip = deviceIP
        let (vpn, _, detail) = NetworkStatus.summarize(deviceIP: ip)
        vpnUp = vpn
        vpnDetail = detail.isEmpty ? "no IPv4 interfaces" : detail
    }

    func openLocalDevVPN() {
        guard let url = URL(string: "localdevvpn://") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Pairing

    func startPairing() {
        refreshPairing()
        Task {
            do {
                let path = try await PairingController.shared.startAndWait()
                refreshPairing()
                refreshVPN()
                log("Pairing complete: \(path)")
            } catch is CancellationError {
                refreshPairing()
                log("Pairing cancelled.")
            } catch {
                refreshPairing()
                log("Pairing failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelPairing() {
        PairingController.shared.softCancel()
        refreshPairing()
        log("Pairing cancelled.")
    }

    /// Copies an imported pair file somewhere readable, then mirrors it to the
    /// canonical `aircard_pairing.plist` / `airlift_pairing.plist` names.
    func importPairFile(url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else {
                log("Imported pair file was empty.")
                return
            }

            let temp = URL.temporaryDirectory.appendingPathComponent("imported_pairing.plist")
            try data.write(to: temp, options: .atomic)

            let canonical = PairingController.syncCanonicalPairingFile(from: temp.path)
            log("Imported pair file -> \(canonical)")
            try? FileManager.default.removeItem(at: temp)
        } catch {
            log("Failed to import pair file: \(error.localizedDescription)")
        }
    }

    func deletePairingCredentials() {
        PairingController.deleteStoredPairingCredentials()
        refreshPairing()
        log("Deleted pairing credentials.")
    }

    // MARK: - Grappa

    /// Calls `ALGetGrappaToken` (dlsym'd out of the app, same as rust's grappa.rs).
    func generateGrappa() {
        guard let symbol = dlsym(RTLD_DEFAULT, "ALGetGrappaToken") else {
            log("Grappa generate: failed (ALGetGrappaToken symbol not found)")
            return
        }
        typealias GrappaFn = @convention(c) (
            UInt32, UInt32, UInt32,
            UnsafeMutablePointer<UInt8>?, Int,
            UnsafeMutablePointer<Int>?,
            UnsafeMutablePointer<CChar>?, Int
        ) -> Int32

        let fn = unsafeBitCast(symbol, to: GrappaFn.self)

        var buffer = [UInt8](repeating: 0, count: 512)
        var outLength: Int = 0
        var errorBuffer = [CChar](repeating: 0, count: 256)

        let rc = buffer.withUnsafeMutableBufferPointer { outBuf in
            errorBuffer.withUnsafeMutableBufferPointer { errBuf in
                fn(1, 0, 1,
                   outBuf.baseAddress, outBuf.count,
                   &outLength,
                   errBuf.baseAddress, errBuf.count)
            }
        }

        if rc == 0, outLength > 0 {
            log("Grappa generate: ok (\(outLength) bytes)")
        } else {
            let message = errorBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            log("Grappa generate: failed (rc=\(rc)): \(message)")
        }
    }

    // MARK: - Airlift run

    func runAirlift() {
        guard !isRunning else { return }

        let target = selectedTarget
        let pairingPath = PairingController.pairingFilePath()

        isRunning = true
        lastResult = ""
        log("Running airlift on \(target)…")

        let thread = Thread {
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?

            let rc = pairingPath.withCString { pairC in
                target.withCString { targetC in
                    al_exploit_run(
                        pairC,
                        targetC,
                        airLiftLogCallback,
                        nil,
                        &outJSON,
                        &outError
                    )
                }
            }

            let json = outJSON.flatMap { String(validatingUTF8: $0) }
            let err = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outJSON { al_string_free(p) }
            if let p = outError { al_string_free(p) }

            Task { @MainActor in
                let model = AirLiftModel.shared
                model.isRunning = false

                if let json, !json.isEmpty {
                    model.lastResult = json
                    model.log("Airlift result: \(json)")
                }
                if let err, !err.isEmpty {
                    model.lastResult = err
                    model.log("Airlift error: \(err)")
                }
                if rc != 0 {
                    model.log("Airlift exited with rc=\(rc)")
                }
            }
        }
        thread.name = "Filos.AirLift"
        thread.stackSize = 8 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    // MARK: - Log

    private func appendLine(_ line: String) {
        logs.append(line)
        trimLogs()
        print("[airlift] \(line)")
    }

    private func trimLogs() {
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    func log(_ line: String) {
        appendLine(line)
    }
}

/// Forwarded straight into the Rust log line — valid only for the call's duration.
private let airLiftLogCallback: ALLogCallback = { _, msg in
    guard let msg = msg else { return }
    let line = String(cString: msg)
    AirLiftLogSink.append(line)
}