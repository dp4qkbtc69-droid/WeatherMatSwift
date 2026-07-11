// WatchSharedStore.swift
// App-Group backed storage shared on-device between the watch app process
// and the complication widget-extension process.
import Foundation

enum WatchSharedStore {
    static let suiteName = "group.de.praxishartlep.weathermat.watch"

    private static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    private static let locationsKey          = "watch_locations_v1"
    private static let selectedLocationIDKey = "watch_selectedLocationID_v1"
    private static func snapshotKey(for locationID: String) -> String { "watch_snapshot_\(locationID)" }

    static var locations: [WatchLocation] {
        get {
            guard let data = defaults.data(forKey: locationsKey),
                  let decoded = try? JSONDecoder().decode([WatchLocation].self, from: data)
            else { return [.gpsPlaceholder] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: locationsKey)
            }
        }
    }

    static var selectedLocationID: String? {
        get { defaults.string(forKey: selectedLocationIDKey) }
        set { defaults.set(newValue, forKey: selectedLocationIDKey) }
    }

    static func snapshot(for locationID: String) -> WatchWeatherSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey(for: locationID)),
              let decoded = try? JSONDecoder().decode(WatchWeatherSnapshot.self, from: data)
        else { return nil }
        return decoded
    }

    static func saveSnapshot(_ snapshot: WatchWeatherSnapshot, for locationID: String) {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey(for: locationID))
        }
    }
}
