<div align="center">
  <br>
  <a href="https://jailbreak.party/discord"><img src="https://github.com/jailbreakdotparty/Filos/blob/main/PreviewIcon.png?raw=true" alt="App Icon" width="150"></a>
  <br>
  <h1>Filos</h1>
  <p>Modern and open-source file manager for iDevices. Supports iOS 15+.</p>
  <a href="https://github.com/jailbreakdotparty/Filos/releases/latest"><img alt="GitHub Downloads (all assets, all releases)" src="https://img.shields.io/github/downloads/jailbreakdotparty/Filos/total?style=flat-square&color=CF7D46"></a>
  <a href="https://github.com/jailbreakdotparty/Filos/stargazers"> <img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/jailbreakdotparty/filos?style=flat-square&color=%23FFD300"></a> 
  <a href="https://jailbreak.party/discord"><img alt="Discord" src="https://img.shields.io/discord/1349128546072793218?style=flat-square&logo=discord&logoColor=FFFFFF&color=5865F2"></a> 
  <a href="https://jailbreak.party"><img alt="Static Badge" src="https://img.shields.io/badge/jailbreak.party-blue?style=flat-square&label=%20&color=3868DB"></a>
</div>

## Important Information
- Filos is a modern and open-source file manager that's primarily designed for developers. It was written in pure Swift for iOS 15 and later, so it supports a wide range of iOS versions and is great for tinkering or basic file management on jailbroken devices. There's no FTP, package management, or other tools that would be found in file managers like Filza. Filos has all the basic file operations you'd expect, a plist/text editor, and a permissions viewer.
- **Filos does NOT use any exploits or sandbox escapes.** If you're thinking that this project will give you full r/w on iOS 27.x, think again. This file manager has been designed with developers and jailbreakers in mind.
- Since Filos relies on entitlements in order to function, it will be inherently more limited on jailbroken devices than any file manager with a root helper would. I may look into adding one in the future, but no promises.

## AirLift integration
This fork integrates the **Airlift** capability from [Mak5er/AirCard-iOS](https://github.com/Mak5er/AirCard-iOS): the Rust `airlift_ffi` core plus the Swift pairing/VPN helpers.

- `rust-core/` — vendored Rust FFI crate (RPPairing host, AirTraffic exploit, syslog stream, Grappa token helper).
- `AirliftFFI.xcframework` — prebuilt arm64 (device + simulator) static library wrapper. CI rebuilds it from `rust-core/` on every push, and the copy checked into git can lag behind `rust-core/` — if a local `xcodebuild` fails to link `al_*` symbols that are present in `rust-core/include/airlift.h`, run `./build-ios.sh` first to repackage it.
- `Filos/Airlift/` — Swift side: `AirLiftModel.swift` (FFI bridge + launch bootstrap), `AirLiftView.swift` (panel UI), `PairingController.swift`, `FilosNotifications.swift` (pairing PIN notification), `NetworkStatus.swift`, `Utilities.swift`, `GrappaHelper.m`.
- `build-ios.sh` — builds the Rust core for `aarch64-apple-ios` / `aarch64-apple-ios-sim` and repackages `AirliftFFI.xcframework`.

**Root screen is the location list.** On launch Filos shows the Airlift-supported locations listed below; tapping one opens the regular file browser at that path, so everything inside can be viewed, edited, renamed, copied, zipped, shared or deleted as usual. The AirLift panel is one tap away behind the "Airlift" toolbar button (leading) or the ellipsis menu, and from Settings › Airlift; the log view is behind "Logs" in the ellipsis menu or in a file browser's Actions menu. The AirLift panel sections are: LocalDevVPN status, pairing (self-pair over RPPairing, import pair file, delete credentials), Grappa token generation, target path picker, run, result, and log.

**Airlift runs itself on launch.** `FilosApp.onAppear` asks `PairingController.pairingFilePath()` for the persisted credentials in `Documents/aircard_pairing.plist`. If a non-empty pairing file exists, Filos calls `al_exploit_run(pairing, "/var/mobile")` off the main thread and streams the log into `FilosManager.logOutput` (visible in Logs). A brief success/failure line shows on the root screen. Filos never pairs automatically: if no pairing file exists yet, a one-time prompt offers to pair, and the resulting file is reused on every later launch. Pairing again only happens when you tap Pair in the AirLift panel, or after deleting the stored credentials.

**Notifications.** Authorization for alerts, badges and sounds is requested early, and when RPPairing needs a PIN a local notification titled "Pairing required" is posted (the user is normally inside Settings at that point).

**Target paths listed on the root screen:**

```
/var/mobile
/var/mobile/Documents
/var/mobile/Library
/var/mobile/Library/Preferences
/var/mobile/Library/Caches
/var/mobile/Library/SpringBoard
/var/mobile/Library/SMS
/var/mobile/Library/Safari
/var/mobile/Containers
/var/mobile/Containers/Data/Application
/var/mobile/Containers/Shared/AppGroup
/var/tmp
```

### Browsing app containers without HouseArrest

`/var/mobile/Containers/Data/Application`, `/var/mobile/Containers/Shared/AppGroup` and `/var/mobile/Applications` sit outside the `/var/mobile/Media` root that AFC is jailed to, so plain AFC (`al_dir_list`) cannot list them and `com.apple.mobile.house_arrest` only vends containers for apps carrying a developer profile (`PermDenied` for most installed apps). Those paths are therefore read with the **AirManager trick**, exposed as `al_airlift_list_dir`: the Apple Books sync engine (`com.apple.atc` + `com.apple.streaming_zip_conduit`) is used as a "move any object anywhere" primitive. One AirTraffic sync moves the directory out to `Airlock/Read/<token>`, where ordinary AFC lists it (the row you see is `{"name","is_dir","size"}`, the same shape as every other remote listing), and a second AirTraffic sync moves it straight back through a symlink that points at its real parent — directories move as a unit, so the container is left byte-identical. The container root itself is still enumerated with InstallationProxy (`al_list_apps`) so the app rows keep their names; every other root on the list above stays on plain AFC and keeps showing its honest error when AFC cannot see it.

Two safety nets come with that sequence, both implemented in `rust-core/src/airlift_dir.rs`: `Books/Sync/Books.plist` and `OutstandingAssets_4.sqlite` are snapshotted (in memory and in a temp file) before the first sync and restored after every step, so a failed run cannot leave Books signed out or stuck on an update screen; and the pulled directory is only deleted once AFC confirms it is back at its original location. An interrupted run leaves the directory parked at `Airlock/Read/<token>` with a `<token>.json` recovery record beside it, the error text says `kept at Airlock/Read/<token>`, and **Settings › Airlift › "Recover staged copies"** (`al_airlift_recover`) replays the restore step for each such record. The sync is never started automatically: it only runs when you tap into a directory that needs it (pull-to-refresh deliberately serves the cached listing instead of moving anything), and every ATC sync is serialized behind one process-wide mutex.

### Building with AirLift

The Xcode project is now generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`, so it's not checked in.

```bash
# 1. Build the Rust core and repackage the xcframework (needs rustup + Xcode)
./build-ios.sh

# 2. Generate the project (needs xcodegen; both build scripts do this for you)
xcodegen generate

# 3. Build
./ipabuild.sh          # jailed .ipa (--debug / --ts also supported)
./debbuild.sh          # jailbroken .deb
```

`ipabuild.sh` and `debbuild.sh` run `xcodegen generate` automatically when `xcodegen` is on `PATH`, then build `-project Filos.xcodeproj` as before.

### CI

`.github/workflows/build.yml` runs on every push: it installs the Rust toolchain, builds `rust-core` into `AirliftFFI.xcframework`, generates the Xcode project with XcodeGen, builds an unsigned Release for `generic/platform=iOS`, and uploads `Filos-airlift.ipa` as a workflow artifact.

## Credits
- [lunginspector](https://github.com/lunginspector): Primary developer and maintainer.
- [skadz108](https://github.com/skadz108): SBX-related stuff and some file browser components.
- [rooootdev](https://github.com/rooootdev): Archive utilities.
