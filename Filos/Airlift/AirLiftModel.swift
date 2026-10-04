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

    /// Compact one-liner shown on the root screen (result of the launch run).
    @Published var launchStatus: String = ""
    @Published var launchFailed: Bool = false

    /// Mirror of `PairingController`'s published pairing state.
    @Published var pairingStatus: String = ""
    @Published var pairingPIN: String?
    /// Published mirror of `isPaired` so views re-render after pairing.
    @Published private(set) var paired: Bool = false

    private var pairingObservation: AnyCancellable?
    private var didRunOnLaunch = false

    /// Lets us nag about pairing exactly once per install.
    private static let pairPromptShownKey = "airliftPairPromptShown"

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
        paired = isPaired
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
                // Credentials are stored now, so make the target dirs usable right away.
                warmBrowseCache()
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
        // Allow the one-time pairing prompt to appear again on the next launch.
        UserDefaults.standard.set(false, forKey: Self.pairPromptShownKey)
        refreshPairing()
        log("Deleted pairing credentials.")
    }

    // MARK: - Grappa

    /// Calls `ALGetGrappaToken` (dlsym'd out of the app, same as rust's grappa.rs).
    func generateGrappa() {
        let mainHandle = dlopen(nil, RTLD_NOW)
        guard let symbol = dlsym(mainHandle, "ALGetGrappaToken") else {
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

    /// Called once from `FilosApp.onAppear`.
    ///
    /// Launch is deliberately *browse-ready* only: it checks that a pairing
    /// file exists, drops the cached listings and warms the InstallationProxy
    /// app list so the Application root opens immediately. It never runs
    /// `al_exploit_run`.
    ///
    /// Reason: the AirTraffic exploit moves data between the device and the
    /// Books sync zone (`Books.plist`, `Airlock/`, `OutstandingAssets` sqlite).
    /// Interrupting that transfer leaves those files dirty and the device can
    /// then sign apps out or show update/password prompts. Listing files has no
    /// business touching that machinery, so it never does — the exploit is only
    /// reachable from the explicit self-test button (`runExploitOnce()`).
    func runOnLaunch() {
        guard !didRunOnLaunch else { return }
        didRunOnLaunch = true

        refreshPairing()

        let pairingPath = PairingController.pairingFilePath()
        let size = (try? FileManager.default.attributesOfItem(atPath: pairingPath)[.size] as? Int) ?? 0

        if size > 0 {
            log("Launch: reusing pairing file \(pairingPath)")
            warmBrowseCache()
        } else {
            log("Launch: no pairing file at \(pairingPath)")
            promptPairingOnce()
        }
    }

    /// Clears stale listings and pulls the installed-app list off the main
    /// thread. HouseArrest/AFC only — no AirTraffic sync, no Books mutation.
    private func warmBrowseCache() {
        paired = true
        AirLiftBrowse.shared.invalidateCache()

        let browse = AirLiftBrowse.shared
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let count = (try? browse.listApps().count) ?? 0
            Task { @MainActor in
                guard let self else { return }
                self.launchStatus = "ready"
                self.launchFailed = false
                self.log("launch: browse-ready mode (exploit not run automatically)")
                if count > 0 {
                    self.log("launch: warmed \(count) app containers")
                }
                // Any browser already on screen may have listed files against a
                // stale cache — reload it.
                FilosManager.shared.refreshFiles.toggle()
            }
        }
    }

    /// Manual, single-shot self-test: runs the AirTraffic canary write exactly
    /// once, on explicit user request only. Never called from the browsing path.
    @discardableResult
    func runExploitOnce(target targetPath: String? = nil) -> Bool {
        let target = targetPath ?? (selectedTarget.isEmpty ? (Self.defaultTargets.first ?? "/var/mobile") : selectedTarget)

        log("Self-test: running Airlift exploit on \(target) (AirTraffic canary write, manual only)")
        launchStatus = "Running Airlift self-test on \(target)…"
        launchFailed = false

        let started = runAirlift(target: target) { [weak self] success, detail in
            guard let self else { return }
            if success {
                self.launchStatus = "Self-test ok: \(target)"
                self.log("Self-test ok")
            } else {
                self.launchStatus = "Self-test failed: \(detail)"
                self.launchFailed = true
                self.log("Self-test failed: \(detail)")
            }
            self.logBooksRestoreCheck()
            FilosManager.shared.refreshFiles.toggle()
        }

        if !started {
            launchStatus = "Airlift already running"
        }
        return started
    }

    /// Read-only sanity check after a self-test run: confirms the pairing file
    /// is still intact. Purely local logging, no device filesystem mutation.
    private func logBooksRestoreCheck() {
        let path = PairingController.pairingFilePath()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > 0 {
            log("Books restore check: pairing file intact (\(size) bytes)")
        } else {
            log("Books restore check: pairing file missing at \(path) — re-pair before browsing")
            launchFailed = true
        }
    }

    /// One-time "you have to pair first" prompt. Pairing only happens if the
    /// user taps Pair, and the resulting file is reused on every later launch.
    private func promptPairingOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.pairPromptShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.pairPromptShownKey)

        launchStatus = "Not paired yet"

        Alertinator.shared.alert(
            title: FilosNotifications.pairingTitle,
            body: "Filos has to be paired once before it can read /var/mobile and the other Airlift locations. Tap Pair, then approve the request in Settings › Developer Mode.",
            actionLabel: "Pair"
        ) {
            AirLiftModel.shared.startPairing()
        }
    }

    /// Runs the FFI entry point off the main thread. `completion` is always
    /// invoked on the main actor with (success, summary).
    /// Returns false when a run is already in flight.
    @discardableResult
    func runAirlift(target targetPath: String? = nil, completion: ((Bool, String) -> Void)? = nil) -> Bool {
        guard !isRunning else { return false }

        let target = targetPath ?? selectedTarget
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

                let success = rc == 0 && (err?.isEmpty ?? true)
                let summary = (err?.isEmpty == false ? err! : (json?.isEmpty == false ? json! : "rc=\(rc)"))
                completion?(success, summary)
            }
        }
        thread.name = "Filos.AirLift"
        thread.stackSize = 8 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()

        return true
    }

    // MARK: - Log

    /// `print` here lands in the stdout pipe that `FilosApp` drains into
    /// `FilosManager.logOutput`, so every airlift line shows up in LogView.
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
/// Shared with AirLiftBrowse (same module, different file).
let airLiftLogCallback: ALLogCallback = { _, msg in
    guard let msg = msg else { return }
    let line = String(cString: msg)
    AirLiftLogSink.append(line)
}