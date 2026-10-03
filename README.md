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

## Building & Tinkering
- You'll need Xcode 26.2 or later, as well as the iOS 26 SDK (or newer) to build this project or open it in Xcode.
- Included are two scripts: `ipabuild.sh` and `debbuild.sh`:
    - `ipabuild.sh`: By default, will build a jailed .ipa version of Filos. Pass `--debug` for a debug build or `--ts` for a regular TrollStore build.
    - `debbuild.sh`: Will build a jailbroken distribution version of Filos.

## Credits
- [lunginspector](https://github.com/lunginspector): Primary developer and maintainer.
- [skadz108](https://github.com/skadz108): SBX-related stuff and some file browser components.
- [rooootdev](https://github.com/rooootdev): Archive utilities.
