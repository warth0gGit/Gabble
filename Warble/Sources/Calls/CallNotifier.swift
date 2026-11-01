import AppKit
import UserNotifications

/// Posts a normal Mac notification when a call transcript is saved, so you
/// still see it if you were away from the screen. It stays in Notification
/// Center, and clicking it opens the note.
final class CallNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CallNotifier()

    private static let urlKey = "url"

    /// Call once at launch, so clicks on notifications reach Warble.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks permission the first time, then posts. Does nothing if notifications are off.
    func transcriptSaved(title: String, body: String, url: URL) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [Self.urlKey: url.path]
            let request = UNNotificationRequest(identifier: "call-saved-\(url.lastPathComponent)",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    // Show the banner even when Warble is the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    // Clicking the notification opens the note (wherever it has been filed since).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo[Self.urlKey] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            }
        }
        completionHandler()
    }
}
