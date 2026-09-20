import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class VaultBridgeNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = VaultBridgeNotificationRouter()
    var repoID: UUID?
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.content.userInfo["vaultID"] as? String
        Task { @MainActor in
            self.repoID = identifier.flatMap(UUID.init(uuidString:))
        }
        completionHandler()
    }
}
