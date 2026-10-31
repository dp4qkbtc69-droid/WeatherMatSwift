// SavedLocationEntity.swift
// Makes saved locations pickable as an App Intents parameter (e.g. so Siri
// can be told which location to search around in FindGoodWeatherIntent,
// instead of always defaulting to GPS/first saved location).
import AppIntents
import Foundation

struct SavedLocationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Ort" }
    static var defaultQuery: SavedLocationEntityQuery { SavedLocationEntityQuery() }

    let id: UUID
    let name: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: subtitle.isEmpty ? nil : "\(subtitle)")
    }

    init(_ location: SavedLocation) {
        id = location.id
        name = location.name
        subtitle = location.subtitle
    }
}

/// Cross-device identity: `SavedLocation.id` is a UUID generated once and
/// synced verbatim to the Watch via `WatchConnectivityService`/`LocationSyncReceiver`
/// — already stable across the user's devices, so `SyncableEntity` needs no
/// extra work beyond the conformance itself (per Apple's iOS 27 guidance).
@available(iOS 27.0, *)
extension SavedLocationEntity: SyncableEntity {}

struct SavedLocationEntityQuery: EntityQuery {
    func entities(for identifiers: [SavedLocationEntity.ID]) async throws -> [SavedLocationEntity] {
        WeatherCacheStore.loadSavedLocations()
            .filter { identifiers.contains($0.id) }
            .map(SavedLocationEntity.init)
    }

    func suggestedEntities() async throws -> [SavedLocationEntity] {
        WeatherCacheStore.loadSavedLocations().map(SavedLocationEntity.init)
    }
}
