import Foundation
import UserNotifications

extension Notification.Name {
    static let mytimeOpenLink = Notification.Name("mytime.openLink")
}

/// 通知を押したときに、その予定・タスクの画面を開く（通知の userInfo["link"] の mytime:// を使う）
final class NotificationTapHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationTapHandler()
    private var pending: URL?

    /// 起動直後に1回だけ受け取る（アプリが閉じていたときに押された通知）
    func takePending() -> URL? { defer { pending = nil }; return pending }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["link"] as? String, let u = URL(string: s) else { return }
        await MainActor.run {
            pending = u
            NotificationCenter.default.post(name: .mytimeOpenLink, object: u)
        }
    }

    /// アプリを開いている間も、バナーとして見せる
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
