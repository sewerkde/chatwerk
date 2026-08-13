import Foundation
import AppKit
import UserNotifications

/// Plays a sound / posts a banner when a running Claude Code session finishes
/// responding and starts waiting for input.
enum Notifier {

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// macOS system alert sounds available for the ready-chime.
    static let availableSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    static func preview(sound: String) {
        NSSound(named: sound)?.play()
    }

    static func claudeIsReady(sessionTitle: String, soundName: String?, showBanner: Bool) {
        if let soundName {
            NSSound(named: soundName)?.play()
        }
        guard showBanner else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude is ready"
        content.body = sessionTitle
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
