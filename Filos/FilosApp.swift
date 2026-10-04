//
//  FilosApp.swift
//  Filos
//
//  Created by lunginspector on 7/12/26.
//

import SwiftUI
import AirliftFFI

import UniformTypeIdentifiers

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
        
        // fix file picker
        let fixMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.fix_init(forOpeningContentTypes:asCopy:)))!
        let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:)))!
        method_exchangeImplementations(origMethod, fixMethod)

        // Route rust-core / idevice logs into AirLiftLogSink (consumed by AirLiftModel).
        al_log_init({ _, msg in
            guard let msg = msg else { return }
            let line = String(cString: msg)
            DispatchQueue.main.async { AirLiftLogSink.append(line) }
        }, nil)

        // Ensure the Grappa helper symbol is retained and linked into the binary.
        _ = ALGetGrappaToken(0, 0, 0, nil, 0, nil, nil, 0)

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
                        mgr.tokenVaild = sbxConsume(sbxToken)
                        
                        if mgr.tokenVaild {
                            print("[*] consumed=1, token valid!")
                        } else {
                            print("[!] consumed!=2, token invalid?")
                            Alertinator.shared.alert(title: "Failed to consume sandbox extension token!", body: "This token is likely invaild. Generate a new token, and put it in settings.")
                        }
                    }
                }
        }
    }
}

extension UIDocumentPickerViewController {
    @objc func fix_init(forOpeningContentTypes contentTypes: [UTType], asCopy: Bool) -> UIDocumentPickerViewController {
        return fix_init(forOpeningContentTypes: contentTypes, asCopy: true)
    }
}

// MARK: - Grappa helper

// Defined in Filos/Airlift/GrappaHelper.m and dlsym'd by the rust core.
@_silgen_name("ALGetGrappaToken")
func ALGetGrappaToken(
    _ inVersion: UInt32,
    _ inDeviceType: UInt32,
    _ inProtocolVersion: UInt32,
    _ outBuf: UnsafeMutablePointer<UInt8>?,
    _ maxLen: Int,
    _ outLen: UnsafeMutablePointer<Int>?,
    _ errBuf: UnsafeMutablePointer<CChar>?,
    _ errLen: Int
) -> Int32
