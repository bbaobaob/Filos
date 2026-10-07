//
//  ResearchView.swift
//  Filos
//
//  RESEARCH ONLY. A one-row-at-a-time harness for the two research FFI entry
//  points in `AirLiftBrowse` (`al_research_list_dir`,
//  `al_research_list_dir_any_path`). Those exist to measure how far
//  `com.apple.atc` (the Books AirTraffic daemon) will move a filesystem object
//  when a host names it with an `AssetID` — Apple's sandbox boundary is not
//  enforced on that path, which is an unfixed Apple bug, not a feature. See
//  RESEARCH.md for the matrix this feeds.
//
//  Nothing here is part of browsing. The screen cannot navigate into a
//  directory, does not touch any cache, and deliberately presents its result as
//  raw JSON: for a research row the payload plus the STEP B / AssetManifest
//  diagnostics are the measurement, and a decoded row list would hide them.
//
//  The Rust guard (`research_checked_path`) is the authority on what may be
//  probed. `problemWith(path:)` below is a UX-only copy of it that exists to
//  fail in a sentence instead of after a five-second blocking round trip; if
//  the two ever disagree, Rust wins and this is a bug in the message, not a
//  hole in the guard.
//

import SwiftUI

struct ResearchView: View {

    /// Absolute device path of the directory to pull. Verbatim — no
    /// normalisation, no expansion, no `..`.
    @State private var path = "/var/mobile/Library"
    /// AirTraffic dataclass to put on the wire. Empty means `Book`, the only
    /// dataclass known to work on device as of 2026-10-07.
    @State private var dataclass = "Book"
    /// That dataclass's AFC-relative sync directory (`Music/Sync`). Only read by
    /// `al_research_list_dir_any_path`; empty means the `Book` root `Books/Sync`.
    @State private var syncRootDir = ""

    /// Raw JSON of the last run, or the error it failed with.
    @State private var result = ""
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        List {
            Section {
                Text("RESEARCH ONLY. This screen probes how far Apple's Books AirTraffic daemon will move a directory it has no business touching — a sandbox escape that Apple has not fixed and this app does not pretend to have fixed. Run it only on a device you own, one row at a time, and expect it to fail for most targets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Device path")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("/var/mobile/Library", text: $path)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onLongPressGesture {
                            UIPasteboard.general.string = path
                        }
                }
                HStack {
                    Text("Dataclass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("Book", text: $dataclass)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                HStack {
                    Text("Sync root dir")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextField("Books/Sync", text: $syncRootDir)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                HeaderLabel("Row", symbol: "scope")
            } footer: {
                Text("Leave the sync root empty for the Book root (Books/Sync). Anything else is a guess about a dataclass nobody has observed syncing. The path must survive exactly as typed — autocorrect and auto-capitalisation are off, and a long press copies it back for pasting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    runSweep()
                } label: {
                    ButtonLabel(busy ? "Running…" : "Run sweep", symbol: busy ? "showMeProgressPlease" : "scope")
                }
                .disabled(busy)

                if !result.isEmpty {
                    CompactAlert(
                        title: failed ? "Sweep failed" : "Ran — raw result",
                        symbol: failed ? "exclamationmark.triangle" : "checkmark.seal",
                        text: result,
                        color: failed ? .red : .green
                    )
                }
            } header: {
                HeaderLabel("Sweep", symbol: "play.circle")
            } footer: {
                Text("The call blocks for seconds (two AirTraffic syncs) — that is why the button shows a spinner and why a second tap is ignored.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("• One row at a time, sequentially, never concurrently. Each sweep is a full AirTraffic sync and the Books daemon's outstanding-asset journal is shared between sessions, so two sweeps at once measure neither. Let one finish before starting the next.")
                Text("• Each sweep blocks for seconds: the directory is moved out to Airlock/Read/<token> and pushed back through a restore symlink. The app stays responsive only because the FFI call runs off the main thread.")
                Text("• Book is the only dataclass known to work on device as of 2026-10-07. Every other name — Music, App, Podcast — is an experiment, and the point of this screen is to find out what com.apple.atc does with it.")
                Text("• A non-Book dataclass's sync root is a derived guess, not a known fact: Music ⇒ Music/Sync, with Music/Sync/Music.plist as its catalog at depth 5. Wrong directory, wrong depth or wrong plist name makes the run inconclusive rather than wrong.")
                Text("• Recovery depends on the target. For a /var/mobile target, Settings → Recover staged copies finishes the job. For a target outside /var/mobile the recovery record is refused by the shipping guard, so a result of kept at Airlock/Read/<token> has to be cleaned up by hand.")
                Text("• The result above is the raw payload, unordered, and not the measurement. The real signal is the AssetManifest contents and the STEP B diagnostics — Settings → Airlift → Log, or the root screen Actions → Logs.")
            } header: {
                HeaderLabel("Before you run this", symbol: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Research sweep")
        .navigationBarTitleDisplayMode(.inline)
        // Required: without this a pull-to-refresh on this List would trigger the
        // normal listing load, and the research screen must never do that.
        .noRefreshable()
    }

    /// Run one research row, off the main thread, and show what came back.
    ///
    /// Three guards matter here, and all three are load-bearing:
    ///
    /// * `guard !busy` — the FFI call blocks for seconds (two AirTraffic syncs).
    ///   Without this a second tap would start a *concurrent* sweep, and the
    ///   outstanding-asset journal the two share would be corrupted, so neither
    ///   measurement would mean anything. The `.disabled(busy)` on the button is
    ///   the visible half of the same rule; this is the half that survives a
    ///   double-tap racing the state update.
    /// * the path check — a UX mirror of the Rust guard, so a typo costs a
    ///   sentence instead of a blocking round trip. It is NOT the authority:
    ///   `research_checked_path` runs regardless, on every call, and refuses
    ///   anything this lets through. Do not let this become the thing that
    ///   decides what is safe to probe.
    /// * the entry-point choice — a `/var/mobile` target goes through
    ///   `researchListDir(path:dataclass:)`, the entry point every verified
    ///   result came from. Anything else has to go through
    ///   `researchListDirAnyPath(path:dataclass:syncRootDir:)`, because the
    ///   other one still derives its `AssetID` relative to `/var/mobile` and
    ///   would refuse an out-of-`/var/mobile` target *before* STEP A — measuring
    ///   our own guard instead of the daemon.
    private func runSweep() {
        guard !busy else { return }

        if let problem = Self.problemWith(path: path) {
            result = problem
            failed = true
            return
        }

        busy = true
        result = ""
        failed = false

        // Snapshot the fields: @State must not be read off the main thread.
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let wireDataclass = dataclass.trimmingCharacters(in: .whitespacesAndNewlines)
        let wireSyncRoot = syncRootDir.trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.needsAnyPath(target)
                ? AirLiftBrowse.shared.researchListDirAnyPath(path: target, dataclass: wireDataclass, syncRootDir: wireSyncRoot)
                : AirLiftBrowse.shared.researchListDir(path: target, dataclass: wireDataclass)
            DispatchQueue.main.async {
                switch outcome {
                case .success(let json):
                    result = json
                    failed = false
                case .failure(let error):
                    result = error
                    failed = true
                }
                busy = false
            }
        }
    }

    /// True when `path` is not under `/var/mobile`, i.e. the only case the
    /// root-relative entry point can answer. `/private/var/...` is the same
    /// place, so it normalises first.
    private static func needsAnyPath(_ path: String) -> Bool {
        let normalized = AirLiftBrowse.normalizeDevicePath(path)
        return !(normalized == "/var/mobile" || normalized.hasPrefix("/var/mobile/"))
    }

    /// UX-only copy of the Rust guard `research_checked_path`
    /// (`rust-core/src/airlift_dir.rs`): non-empty, absolute, no `..`, no
    /// `Airlock` / `Books.plist` component, at least three components.
    ///
    /// Rust enforces all five regardless of what this says — this only decides
    /// whether the user gets a fast sentence or a slow one. Keep it a copy; a
    /// divergence costs a worse message, never a hole.
    private static func problemWith(path raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Enter an absolute device path first."
        }
        if !trimmed.hasPrefix("/") {
            return "A device path is absolute and starts with '/', got '\(trimmed)'."
        }

        var components: [String] = []
        for component in trimmed.split(separator: "/") {
            let text = String(component)
            if text.isEmpty { continue }
            if text == ".." {
                return "A device path must not contain '..', got '\(trimmed)'."
            }
            if text == "Airlock" || text == "Books.plist" {
                return "'\(text)' is reserved by Airlift — it is this sweep's own staging zone / sync manifest, and pulling it would destroy the scaffolding the run depends on."
            }
            components.append(text)
        }

        // `/private/var/…` and `/var/…` name the same directory on device, so the
        // `private` component goes away before the depth floor is counted.
        if components.first == "private" && components.dropFirst().first == "var" {
            components.removeFirst()
        }
        if components.count < 3 {
            return "A target needs at least three components (e.g. /var/mobile/Library), got '\(trimmed)'."
        }
        return nil
    }
}