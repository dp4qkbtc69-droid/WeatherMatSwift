// WatchModels.swift
// Minimal, self-contained models shared between the watch app and the
// complication widget extension. Deliberately not shared with the iOS
// target — the watch fetches its own data via WeatherKit rather than
// mirroring the iPhone's multi-provider ensemble.
import Foundation

struct WatchLocation: Codable, Identifiable, Equatable {
    let id:        String
    var name:      String
    var latitude:  Double
    var longitude: Double
    var isGPS:     Bool

    static let gpsPlaceholder = WatchLocation(
        id: "gps", name: "Aktueller Standort",
        latitude: 0, longitude: 0, isGPS: true
    )
}

struct WatchWeatherSnapshot: Codable, Equatable {
    let locationName:   String
    let currentTemp:    Int
    let highTemp:       Int
    let lowTemp:        Int
    let sfSymbol:       String
    let conditionLabel: String
    let rainSummary:    String
    let rainSFSymbol:   String
    let fetchedAt:      Date
}
