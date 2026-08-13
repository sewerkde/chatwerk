import Foundation
import AppKit
import UserNotifications

/// Plays a sound / posts a banner when a running Claude Code session finishes
/// responding and starts waiting for input.
enum Notifier {

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Alert sounds for the ready-chime: whatever the system and the user
    /// actually have installed, with the classic names as a fallback.
    static let availableSounds: [String] = {
        var names = Set<String>()
        for dir in ["/System/Library/Sounds", NSHomeDirectory() + "/Library/Sounds"] {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let url = URL(fileURLWithPath: file)
                if ["aiff", "aif", "m4a", "caf", "wav"].contains(url.pathExtension.lowercased()) {
                    names.insert(url.deletingPathExtension().lastPathComponent)
                }
            }
        }
        guard !names.isEmpty else {
            return ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                    "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
        }
        return names.sorted()
    }()

    static func preview(sound: String) {
        NSSound(named: sound)?.play()
    }

    static func claudeIsReady(sessionTitle: String, sessionUuid: String, soundName: String?, showBanner: Bool) {
        if let soundName {
            NSSound(named: soundName)?.play()
        }
        guard showBanner else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Claude is ready"
        content.body = sessionTitle
        content.userInfo = ["sessionUuid": sessionUuid]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Routes notification clicks back to the session they came from.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let uuid = response.notification.request.content.userInfo["sessionUuid"] as? String
        DispatchQueue.main.async {
            if let uuid {
                AppState.shared?.reveal(sessionUuid: uuid)
            }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
