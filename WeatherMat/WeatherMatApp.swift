// WeatherMatApp.swift
import SwiftUI
import BackgroundTasks
import os

/// Bridges UIKit remote-notification callbacks (device token) into SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private static let logger = Logger(subsystem: "de.praxishartlep.weathermat", category: "Push")

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            PushRegistrationService.shared.updateDeviceToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Self.logger.warning("remote notification registration failed: \(String(describing: error), privacy: .public)")
    }
}

@main
struct WeatherMatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm = WeatherViewModel()
    @AppStorage("appTheme") private var themeName: String = AppTheme.system.rawValue

    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .system }

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 80 * 1024 * 1024,
            diskCapacity: 350 * 1024 * 1024,
            diskPath: "WeatherMatURLCache"
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(vm)
                .preferredColorScheme(theme.colorScheme)
                .tint(Color(hex: "#0ea5e9"))
                .task {
                    await NotificationService.shared.requestAuthorization()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didEnterBackgroundNotification
                    )
                ) { _ in
                    scheduleBackgroundRefresh()
                }
        }
        // SwiftUI background task handler (iOS 16+)
        .backgroundTask(.appRefresh("de.praxishartlep.weathermat.refresh")) {
            await performBackgroundRefresh()
        }
    }

    // MARK: - Background refresh
    @Sendable
    private func performBackgroundRefresh() async {
        guard let loc = vm.activeLocation else { return }
        await vm.loadWeather(for: loc, force: true)
        scheduleBackgroundRefresh()
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: "de.praxishartlep.weathermat.refresh"
        )
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
