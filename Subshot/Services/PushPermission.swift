import UIKit
import UserNotifications

/// 2026-11-24 (audit #7) — ask for push permission when it's needed (opening the notifications or their
/// settings), not at the first start. Devices that already allowed it register at every start as before.
enum PushPermission {
    static func registerIfAlreadyAllowed() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// shows the system question only once (status «not determined»); afterwards just registers if allowed
    static func requestIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    guard granted else { return }
                    DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            default:
                break
            }
        }
    }
}

/// 2026-11-24 (audit #6) — URLs for logs: scheme + host + path, never the query (presigned signatures)
enum LogRedact {
    nonisolated static func url(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return "?" }
        c.query = nil
        c.fragment = nil
        return c.string ?? "?"
    }
}
