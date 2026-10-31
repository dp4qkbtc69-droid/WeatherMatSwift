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

        let estimate = rainEventEstimate(for: rain)
        let state = RainRadarActivityAttributes.ContentState(
            statusText: rain.text,
            subText: rain.sub,
            sfSymbol: rain.sfSymbol,
            minutesUntilRain: rain.minutesUntilRain,
            minutesUntilClear: rain.minutesUntilClear,
            rainIntensity: RainIntensity(rawValue: rain.severity.rawValue),
            estimatedDurationMinutes: estimate?.durationMinutes,
            progress: estimate?.progress,
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

    /// How long the current/imminent rain is expected to last and, while
    /// it's still approaching, how close it is — derived purely from
    /// `RainAnalysis.chart` (already computed by `analyzeRain`, no new
    /// data source or persisted state). Pure/stateless and `nonisolated`
    /// so it's directly unit-testable.
    ///
    /// `chart` only looks forward from "now" (`EnsembleService.rainChart`),
    /// so there's no way to know how long an already-ongoing (`.now`) event
    /// has been running — `progress` stays `nil` there rather than faking a
    /// number; `durationMinutes` instead reads as "how much longer".
    // `now` is a parameter (not read internally) so the same instant used to
    // build `rain.chart` can be passed straight through in tests — calling
    // `Date()` again a few ms later here previously caused real, if tiny,
    // clock drift that flipped the truncated minute count by one.
    nonisolated static func rainEventEstimate(for rain: RainAnalysis, now: Date = Date()) -> (durationMinutes: Int, progress: Double?)? {
        switch rain.type {
        case .soon:
            guard let minutesUntilRain = rain.minutesUntilRain, minutesUntilRain > 0 else { return nil }
            let eventStart = now.addingTimeInterval(Double(minutesUntilRain) * 60)
            guard let durationMinutes = minutesUntilClear(in: rain.chart, from: eventStart) else { return nil }
            // Countdown fill: 0 at the edge of analyzeRain's own "soon"
            // lookahead window, 1 right as it starts.
            let progress = min(1, max(0, 1 - Double(minutesUntilRain) / soonLookaheadMinutes))
            return (durationMinutes, progress)
        case .now:
            guard let durationMinutes = minutesUntilClear(in: rain.chart, from: now) else { return nil }
            return (durationMinutes, nil)
        default:
            return nil
        }
    }

    // Matches the 2h lookahead `EnsembleService.analyzeRain` itself searches
    // within for an upcoming event — keep in sync if that window changes.
    // `nonisolated`: a plain constant, and `rainEventEstimate` (which reads
    // it) needs to stay nonisolated to be callable from non-MainActor tests.
    private nonisolated static let soonLookaheadMinutes: Double = 120

    // Thresholds mirror `EnsembleService.analyzeRain`'s own "rain stopping"
    // check — intentionally duplicated rather than shared, so this stays
    // dependency-free of EnsembleService's private helpers.
    private nonisolated static func minutesUntilClear(in chart: [RainChartPoint], from start: Date) -> Int? {
        guard let startIndex = chart.firstIndex(where: { $0.time >= start }) else { return nil }
        let end = chart[startIndex...]
            .first { $0.precipitationRate < 0.08 && $0.probability < 40 }?.time
            ?? chart.last?.time
        guard let end, end > start else { return nil }
        return max(1, Int(end.timeIntervalSince(start) / 60))
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
