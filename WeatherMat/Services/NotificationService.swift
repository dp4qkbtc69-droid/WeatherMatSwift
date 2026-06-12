// NotificationService.swift
import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject {

    static let shared = NotificationService()
    private let seenKey = "seenWarningIDs_v1"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    // MARK: - Check for new DWD warnings
    func checkWarnings(_ warnings: [DWDWarning]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let seenIDs = Set((UserDefaults.standard.array(forKey: seenKey) as? [String]) ?? [])
        var newSeen = seenIDs
        let newSevereCount = warnings.filter { $0.severity >= .severe && !seenIDs.contains($0.id) }.count

        for warning in warnings {
            guard !seenIDs.contains(warning.id) else { continue }
            newSeen.insert(warning.id)

            let content            = UNMutableNotificationContent()
            content.title          = dwdTitle(warning.severity)
            content.body           = warning.headlineDe
            content.subtitle       = warning.eventDe
            content.sound          = warning.severity >= .severe ? .defaultCritical : .default
            content.interruptionLevel = warning.severity >= .severe ? .critical : .active

            // Badge: number of active severe/extreme warnings
            if newSevereCount > 0 { content.badge = NSNumber(value: newSevereCount) }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "dwd-\(warning.id)",
                content:    content,
                trigger:    trigger
            )
            try? await center.add(request)
        }

        // Clear badge if no active warnings
        if warnings.isEmpty {
            try? await center.setBadgeCount(0)
        }

        UserDefaults.standard.set(Array(newSeen), forKey: seenKey)
    }

    // MARK: - Clear seen IDs older than 24h (run on app launch)
    func pruneSeenIDs(keepingFrom warnings: [DWDWarning]) {
        let activeIDs = Set(warnings.map(\.id))
        let seen = (UserDefaults.standard.array(forKey: seenKey) as? [String]) ?? []
        // Only keep IDs that are still active (don't re-notify dismissed ones)
        let pruned = seen.filter { activeIDs.contains($0) }
        UserDefaults.standard.set(pruned, forKey: seenKey)
    }

    private func dwdTitle(_ severity: WarningSeverity) -> String {
        switch severity {
        case .minor:    return "DWD Wetterhinweis"
        case .moderate: return "DWD Wetterwarnung"
        case .severe:   return "⚠️ DWD Unwetterwarnung"
        case .extreme:  return "🚨 DWD Extreme Unwetterwarnung"
        }
    }
}

// MARK: - Foreground notification display
extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
