import Foundation
import UserNotifications

@MainActor
enum NotificationsService {
    private static var didRequestAuthorization = false

    static func requestAuthorizationIfNeeded() async {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            AppLog.notifications.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func postTranscriptionComplete(language: AppLanguage, fileCount: Int, failureCount: Int) {
        Task { await deliver(language: language, fileCount: fileCount, failureCount: failureCount) }
    }

    private static func deliver(language: AppLanguage, fileCount: Int, failureCount: Int) async {
        await requestAuthorizationIfNeeded()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = Copy.text("notification.transcription.title", language: language)
        if failureCount > 0 {
            let template = Copy.text("notification.transcription.partial", language: language)
            content.body = String(format: template, fileCount - failureCount, fileCount)
        } else {
            let template = Copy.text("notification.transcription.success", language: language)
            content.body = String(format: template, fileCount)
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "msub.transcription.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppLog.notifications.error("deliver notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
