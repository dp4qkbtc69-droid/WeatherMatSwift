// WeatherCacheStore.swift
// Shared read/write contract for the on-disk weather cache (UserDefaults).
// `WeatherViewModel` and background-executing App Intents (e.g.
// `RefreshWeatherIntent`, which can run concurrently with the foreground app
// or the app's own BGTaskScheduler refresh — same process, different
// threads/tasks) both need to read/write the exact same cache entries — this
// keeps the JSON shape and key format defined exactly once so the two call
// sites can never drift apart.
//
// `UserDefaults` itself already serializes individual get/set calls, so a
// single read or write can never be torn or corrupted. The lock here exists
// for a narrower reason: it makes each *logical* operation — including
// "read, and if the bytes don't decode, drop them" in `load(for:)` — atomic
// as a whole. Without it, a load that fails to decode and a concurrent save
// of fresh data for the same key could interleave so the load's cleanup
// deletes the save's work instead of the stale bytes it meant to discard.
import Foundation
import os

enum WeatherCacheStore {

    struct Entry: Codable {
        let data: EnsembleWeatherData
        let fetchedAt: Date
    }

    private static let logger = Logger(subsystem: "de.praxishartlep.weathermat", category: "WeatherCacheStore")
    private static let lock = NSLock()
    private static let savedLocationsKey = "savedLocations_v1"

    static func cacheKey(for locationID: UUID) -> String {
        "weatherCache_\(locationID.uuidString)"
    }

    static func save(_ data: EnsembleWeatherData, fetchedAt: Date, for locationID: UUID) {
        guard let encoded = try? JSONEncoder().encode(Entry(data: data, fetchedAt: fetchedAt)) else {
            // Codable encode failures are effectively unreachable for a plain
            // data model like this, but logging rather than silently
            // dropping the write makes a future regression (e.g. a NaN
            // slipping into a Double field) visible instead of just "the
            // cache never updates".
            logger.error("Failed to encode weather cache entry for location \(locationID.uuidString, privacy: .public)")
            return
        }
        let key = cacheKey(for: locationID)
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.set(encoded, forKey: key)
    }

    static func load(for locationID: UUID) -> Entry? {
        let key = cacheKey(for: locationID)
        lock.lock()
        defer { lock.unlock() }
        guard let raw = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(Entry.self, from: raw)
        } catch {
            // Corrupted bytes (e.g. an interrupted write) or a stale shape
            // from an older app version that no longer decodes into the
            // current model — either way, the caller just falls back to a
            // fresh network fetch, so self-heal by dropping the entry here
            // instead of re-failing this same decode on every future launch
            // or intent run. Still inside the lock above: this removal and
            // any concurrent `save(...)` for the same key can't interleave.
            logger.error("Discarding unreadable weather cache entry for location \(locationID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
    }

    static func remove(for locationID: UUID) {
        let key = cacheKey(for: locationID)
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Saved locations, sorted the same way `WeatherViewModel` shows them.
    /// App Intents run outside the view model's lifecycle, so they read this
    /// directly from UserDefaults instead of holding a reference to it.
    static func loadSavedLocations() -> [SavedLocation] {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = UserDefaults.standard.data(forKey: savedLocationsKey) else { return [] }
        do {
            let locations = try JSONDecoder().decode([SavedLocation].self, from: raw)
            return locations.sorted { $0.sortOrder < $1.sortOrder }
        } catch {
            // Unlike a per-location weather cache entry, this list is the
            // user's actual data, not a recomputable cache — log and fall
            // back to an empty list, but don't delete the raw bytes; a
            // decode failure here is likely schema drift that a fix-forward
            // app update could still read, not corruption worth discarding.
            logger.error("Failed to decode saved locations: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
