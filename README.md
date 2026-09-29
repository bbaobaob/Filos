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

## So what is Filos, anyways?
- Filos is a modern and open-source file manager that's primarily designed for developers. It was written in pure Swift for iOS 15 and later, so it supports a wide range of iOS versions and is great for tinkering, testing exploits, or basic file management on jailbreaks. There's no FTP, jailbreak-related package tools, or other things you'd expect in things like Filza. Just all the file operations you'd need, and a plist/text editor.

## Tinkering
- You'll need Xcode 26.2 or later, as well as the iOS 26 (or newer) SDK to play around with this.
- Also included is the `ipabuild.sh` file, which only requires that you have xcodebuild (obviously).
- If you'd like to build for TrollStore or a jailbreak, you'll need to link the `entitlements.plist` file to the built project with ldid.
