//
//  FilosApp.swift
//  Filos
//
//  Created by lunginspector on 7/12/26.
//

import SwiftUI
import PartyUI

var weOnADebugBuild: Bool = false
var pipe = Pipe()
var sema = DispatchSemaphore(value: 0)
let fm = FileManager.default

@main
struct FilosApp: App {
    @StateObject private var mgr = FilosManager.shared
    @AppStorage("sbxToken") var sbxToken = ""
    @AppStorage("consumeOnLaunch") var consumeOnLaunch = false
    
    init() {
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        
        #if DEBUG
        weOnADebugBuild = true
        #else
        weOnADebugBuild = false
        #endif
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mgr)
                .onAppear {
                    pipe.fileHandleForReading.readabilityHandler = { fh in
                        let data = fh.availableData
                        
                        if data.isEmpty {
                            fh.readabilityHandler = nil
                            sema.signal()
                            return
                        }
                        
                        guard let text = String(data: data, encoding: .utf8) else {
                            return
                        }
                        
                        DispatchQueue.main.async {
                            mgr.logOutput.append(text)
                        }
                    }
                    
                    print("[*] Filos v0.1 (Release)")
                    print("[*] Running on \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), \(machineName())")
                    
                    if consumeOnLaunch && !sbxToken.isEmpty {
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
        }
    }
}

// make strings compatiable with errors
extension String: @retroactive Error {}

// allows us to put arrays into AppStorage
extension Array: @retroactive RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }
    
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}

func isSolariumUI() -> Bool {
    if #available(iOS 19.0, *) {
        return true
    }
    return false
}

// get machine name
func machineName() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    return machineMirror.children.reduce("") { identifier, element in
        guard let value = element.value as? Int8, value != 0 else { return identifier }
        return identifier + String(UnicodeScalar(UInt8(value)))
    }
}
