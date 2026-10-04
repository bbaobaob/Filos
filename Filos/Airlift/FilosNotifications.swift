//
//  FilosNotifications.swift
//  Filos
//
//  Local notification plumbing: asks for permission once on launch and pings
//  the user when RPPairing needs a PIN. Used by FilosApp + PairingController.
//

import Foundation
import UserNotifications

enum FilosNotifications {

    static let pairingTitle = "Pairing required"
    static let pairingBody = "Enter the PIN shown by the system to pair with Filos"

    private static let pairingRequestID = "filos.pairing.pin"

    /// Asks for alert/badge/sound permission. Called once early from `FilosApp`.
    /// Safe to call repeatedly: does nothing if the user already answered.
    static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                    if let error {
                        print("[!] notification authorization failed: \(error)")
                    }
                    print("[*] notification authorization granted: \(granted)")
                }
            case .denied:
                print("[!] notifications denied — the pairing PIN will only be shown in-app")
            default:
                break
            }
        }
    }

    /// Posts the "Pairing required" notification. Called from the pairing PIN
    /// callback, since the user is usually inside Settings at that point.
    static func postPairingPrompt(pin: String? = nil) {
        let center = UNUserNotificationCenter.current()

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral else { return }

            let content = UNMutableNotificationContent()
            content.title = pairingTitle
            if let pin, !pin.isEmpty {
                content.body = "Pairing PIN: \(pin) — enter it in Settings › Developer Mode"
            } else {
                content.body = pairingBody
            }
            content.sound = .default

            let request = UNNotificationRequest(identifier: pairingRequestID, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    print("[!] failed to post pairing notification: \(error)")
                }
            }
        }
    }
}
