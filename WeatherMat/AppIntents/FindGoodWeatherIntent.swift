// FindGoodWeatherIntent.swift
// Exposes Where2GoService ("Wohin?") to Siri and Shortcuts, so the best
// nearby weather can be asked for without opening the app.
import AppIntents
import SwiftUI

/// AppIntents-visible mirror of `Where2GoWindow` — `@Parameter` needs an
/// `AppEnum` (with display metadata for the Siri/Shortcuts picker), which the
/// plain model enum intentionally doesn't carry.
enum Where2GoWindowAppEnum: String, AppEnum {
    case tomorrow
    case nextWeekend

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Zeitraum" }
    static var caseDisplayRepresentations: [Where2GoWindowAppEnum: DisplayRepresentation] {
        [
            .tomorrow: "Morgen",
            .nextWeekend: "Nächstes Wochenende"
        ]
    }

    var modelValue: Where2GoWindow {
        switch self {
        case .tomorrow:    return .tomorrow
        case .nextWeekend: return .nextWeekend
        }
    }
}

struct FindGoodWeatherIntent: AppIntent {
    static var title: LocalizedStringResource { "Wo ist gutes Wetter?" }
    static var description: IntentDescription {
        IntentDescription("Findet den Ort mit dem besten Wetter in der Nähe deines gespeicherten Standorts.")
    }

    @Parameter(title: "Zeitraum", default: .tomorrow)
    var window: Where2GoWindowAppEnum

    @Parameter(title: "Radius (km)", default: 150)
    var radiusKm: Int

    @Parameter(title: "Ort", description: "Standardmäßig dein GPS-Standort.")
    var location: SavedLocationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Wo ist gutes Wetter \(\.$window) im Umkreis von \(\.$radiusKm) km ab \(\.$location)?")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let locations = WeatherCacheStore.loadSavedLocations()
        let selected = location.flatMap { picked in locations.first { $0.id == picked.id } }
        guard let origin = selected ?? locations.first(where: { $0.isGPS }) ?? locations.first else {
            return .result(
                dialog: "Kein gespeicherter Ort in WeatherMat gefunden. Bitte zuerst einen Ort speichern."
            )
        }

        let spots = await Where2GoService.shared.findSpots(
            from: origin,
            radiusKm: max(50, min(300, radiusKm)),
            window: window.modelValue,
            sortMode: .best
        )

        guard let best = spots.first else {
            return .result(dialog: "Keine Orte mit gutem Wetter im Umkreis gefunden.")
        }

        let dialog: IntentDialog = """
        Bestes Wetter (\(best.dateLabel)): \(best.name) – \(best.temperature)°, \
        \(Int(best.sunshineHours)) Std. Sonne, \(best.precipitationProbability)% Regenwahrscheinlichkeit.
        """
        return .result(dialog: dialog, view: GoodWeatherSnippetView(spot: best))
    }
}

/// Compact result card shown in Shortcuts/Spotlight when the intent runs.
private struct GoodWeatherSnippetView: View {
    let spot: Where2GoSpot

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: spot.condition.sfSymbol)
                .font(.system(size: 34))
                .symbolRenderingMode(.multicolor)

            VStack(alignment: .leading, spacing: 4) {
                Text(spot.name)
                    .font(.headline)
                Text(spot.dateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label("\(spot.temperature)°", systemImage: "thermometer.medium")
                    Label("\(Int(spot.sunshineHours)) h", systemImage: "sun.max")
                    Label("\(spot.precipitationProbability)%", systemImage: "cloud.rain")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}
