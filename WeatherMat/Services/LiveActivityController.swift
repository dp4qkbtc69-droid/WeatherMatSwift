// LiveActivityController.swift
// Starts, updates, and ends the two Live Activities (rain-radar countdown,
// active weather warning). Local/app-driven only — no APNs push updates, so
// content is only as fresh as the app's own refresh cadence (foreground
// ~2 min via WeatherViewModel.refreshOnForeground, background ~30 min via
// the BGAppRefreshTask in WeatherMatApp). Safe to call from any refresh
// path; each function no-ops when there's nothing worth showing.
// ActivityKit isn't fully Sendable-audited yet, so `Activity<Attributes>`
// triggers Swift 6 "sending risks a data race" diagnostics on ordinary
// `await activity.update(...)`/`.end(...)` calls even though everything here
// runs on MainActor. `@preconcurrency` tells the checker to trust our own
// MainActor isolation instead of ActivityKit's (lack of) annotations.
@preconcurrency import ActivityKit
import Foundation

@MainActor
enum LiveActivityController {

    // MARK: - Rain radar

    // `nonisolated(unsafe)`: ActivityKit isn't Swift 6 concurrency-audited,
    // which makes the region-based isolation checker flag ordinary
    // `await activity.update(...)`/`.end(...)` calls on values read from a
    // MainActor-isolated static var ("Sending risks causing data races"),
    // even though every access to this property already goes through this
    // @MainActor-isolated enum. We take responsibility for that manually.
    nonisolated(unsafe) private static var rainActivity: Activity<RainRadarActivityAttributes>?

    static func updateRain(_ rain: RainAnalysis, locationName: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Only worth a Live Activity when rain is imminent/active, or has
        // just stopped (so the user sees the "all clear" before it expires).
        guard rain.type == .now || rain.type == .soon || rain.minutesUntilClear != nil else {
            await endRain()
            return
        }

        let state = RainRadarActivityAttributes.ContentState(
            statusText: rain.text,
            subText: rain.sub,
            sfSymbol: rain.sfSymbol,
            minutesUntilRain: rain.minutesUntilRain,
            minutesUntilClear: rain.minutesUntilClear,
            updatedAt: Date()
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(35 * 60))

        if let activity = rainActivity {
            await activity.update(content)
        } else {
            let attributes = RainRadarActivityAttributes(locationName: locationName)
            rainActivity = try? Activity.request(attributes: attributes, content: content)
        }
    }

    static func endRain() async {
        guard let activity = rainActivity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        rainActivity = nil
    }

    // MARK: - Weather warnings

    nonisolated(unsafe) private static var warningActivity: Activity<WeatherWarningActivityAttributes>?

    static func updateWarning(_ warnings: [DWDWarning], locationName: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard let worst = warnings
            .filter({ $0.severity >= .severe })
            .max(by: { $0.severity < $1.severity })
        else {
            await endWarning()
            return
        }

        let state = WeatherWarningActivityAttributes.ContentState(
            title: worst.severity == .extreme ? "Extreme Unwetterwarnung" : "Unwetterwarnung",
            headline: worst.headlineDe,
            eventDescription: worst.eventDe,
            isExtreme: worst.severity == .extreme,
            updatedAt: Date()
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60))

        if let activity = warningActivity {
            await activity.update(content)
        } else {
            let attributes = WeatherWarningActivityAttributes(locationName: locationName)
            warningActivity = try? Activity.request(attributes: attributes, content: content)
        }
    }

    static func endWarning() async {
        guard let activity = warningActivity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        warningActivity = nil
    }
}
