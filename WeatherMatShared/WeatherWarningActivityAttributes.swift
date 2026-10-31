// WeatherWarningActivityAttributes.swift
// Shared between the main app and the WeatherMatWidgets extension. Kept
// self-contained (plain strings/bools, no DWDWarning/WarningSeverity model
// types) so it compiles standalone in the extension target.
import ActivityKit
import Foundation

struct WeatherWarningActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var headline: String
        var eventDescription: String
        var isExtreme: Bool
        var updatedAt: Date
    }

    let locationName: String
}
