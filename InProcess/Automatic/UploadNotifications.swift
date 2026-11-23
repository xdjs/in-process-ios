import UserNotifications
import CryptoKit

@MainActor struct UploadNotifications: UploadNotifying {
    func authorizationStatus() async -> NotificationAccessStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized: .allowed
        case .provisional: .quiet
        case .ephemeral: .temporary
        case .denied: .denied
        case .notDetermined: .notRequested
        @unknown default: .unknown
        }
    }
    func requestPermission() async {
        let span = DevelopmentLog.shared.begin(.notification, .app, [.reason: .tag(.permissionRequest)])
        do { let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); span.end(.succeeded, [.authorized: .flag(allowed)]) }
        catch { span.fail(error) }
    }
    func notify(id: String, message: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { DevelopmentLog.shared.emit(.notification, .app, [.reason: .tag(.notificationSuppressed)]); return }
        let content = UNMutableNotificationContent()
        content.title = "In Process uploads"; content.body = message; content.sound = .default
        content.userInfo = ["uploadStatus": true]
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        let span = DevelopmentLog.shared.begin(.notification, .app)
        do { try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil)); span.end(.succeeded) }
        catch { span.fail(error) }
    }
}
