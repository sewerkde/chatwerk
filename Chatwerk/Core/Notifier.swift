import Foundation
import AppKit
import UserNotifications

/// Plays a sound / posts a banner when a running Claude Code session finishes
/// responding and starts waiting for input.
enum Notifier {

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func claudeIsReady(sessionTitle: String, playSound: Bool, showBanner: Bool) {
        if playSound {
            NSSound(named: "Glass")?.play()
        }
        guard showBanner else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude is ready"
        content.body = sessionTitle
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
