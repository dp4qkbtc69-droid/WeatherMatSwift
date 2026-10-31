// RainRadarActivityAttributes.swift
// Shared between the main app (starts/updates/ends the Activity from
// LiveActivityController) and the WeatherMatWidgets extension (renders it).
// This file lives in a folder synchronized into BOTH targets — keep it
// dependency-free from the rest of the app so it compiles standalone in the
// extension.
import ActivityKit
import Foundation

struct RainRadarActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var statusText: String
        var subText: String
        var sfSymbol: String
        var minutesUntilRain: Int?
        var minutesUntilClear: Int?
        var updatedAt: Date
    }

    let locationName: String
}
