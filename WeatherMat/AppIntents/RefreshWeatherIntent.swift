// RefreshWeatherIntent.swift
// Siri/Shortcuts entry point that refreshes every saved location in the
// background. Adopts iOS 27's `LongRunningIntent`, which lets the intent run
// past the system's ~30 s background limit (the ensemble fetch — WeatherKit +
// Open-Meteo + ECMWF + DWD warnings + air quality + station data — can take
// several seconds per location, more with several saved locations).
//
// `LongRunningIntent` refines `ProgressReportingIntent`: reporting `progress`
// regularly is what keeps the runtime extension alive, and in return the
// system renders that progress as a Live Activity automatically — no custom
// ActivityKit UI/extension needed on our side.
//
// NOTE: `LongRunningIntent` / `performBackgroundTask(options:operation:)` are
// iOS 27.0 beta APIs (confirmed against Apple's iOS/iPadOS 27 beta framework
// reference as of beta 5). Exact requirements may still shift before GA —
// verify against the installed SDK on first build and adjust if Xcode flags
// a signature mismatch.
import AppIntents
import CoreLocation

@available(iOS 27.0, *)
struct RefreshWeatherIntent: LongRunningIntent {
    static var title: LocalizedStringResource { "Wetter aktualisieren" }
    static var description: IntentDescription {
        IntentDescription("Aktualisiert die Vorhersage für alle in WeatherMat gespeicherten Orte im Hintergrund.")
    }

    /// Required by `ProgressReportingIntent`. Updated from inside
    /// `performBackgroundTask` below; the system reads it to keep the
    /// extended background runtime alive and to drive the automatic
    /// Live Activity progress bar.
    let progress = Progress()

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let locations = WeatherCacheStore.loadSavedLocations()
        guard !locations.isEmpty else {
            return .result(dialog: "Keine gespeicherten Orte in WeatherMat gefunden.")
        }

        let refreshedCount = try await performBackgroundTask(options: []) { () async -> Int in
            var count = 0
            for (index, loc) in locations.enumerated() {
                let clLoc = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
                let result = await EnsembleService.shared.fetch(for: clLoc)
                if !result.activeModels.isEmpty {
                    WeatherCacheStore.save(result, fetchedAt: Date(), for: loc.id)
                    count += 1
                }
                progress.completedUnitCount = Int64(index + 1)
                progress.totalUnitCount = Int64(locations.count)
            }
            return count
        }

        return .result(
            dialog: "Wetter für \(refreshedCount) von \(locations.count) Orten aktualisiert."
        )
    }
}
