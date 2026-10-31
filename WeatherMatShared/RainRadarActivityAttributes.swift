// RainRadarActivityAttributes.swift
// Shared between the main app (starts/updates/ends the Activity from
// LiveActivityController) and the WeatherMatWidgets extension (renders it).
// This file lives in a folder synchronized into BOTH targets — keep it
// dependency-free from the rest of the app so it compiles standalone in the
// extension.
import ActivityKit
import Foundation

// Mirrors the main app's `PrecipSeverity` by case name/rawValue, but kept
// as its own type (not imported) so this file stays dependency-free and
// compiles standalone in the widget extension — see the file header.
enum RainIntensity: String, Codable, Hashable {
    case light, moderate, heavy

    var label: String {
        switch self {
        case .light: "Leicht"
        case .moderate: "Kräftig"
        case .heavy: "Stark"
        }
    }
}

struct RainRadarActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        var subText: String
        var sfSymbol: String
        var minutesUntilRain: Int?
        var minutesUntilClear: Int?
        var rainIntensity: RainIntensity?
        // "How much longer" once rain is under way, or "how long once it
        // starts" while it's still approaching — never a true elapsed-since-
        // start duration, since the forecast chart only looks forward from
        // "now" (see `LiveActivityController.rainEventEstimate`).
        var estimatedDurationMinutes: Int?
        // Countdown fill (0...1) toward rain *starting*, while it's still
        // approaching. nil once rain is already under way — there's no way
        // to know the true elapsed fraction from a forward-only forecast
        // chart, so this intentionally doesn't fake one.
        var progress: Double?
        var updatedAt: Date
    }

    let locationName: String
}
