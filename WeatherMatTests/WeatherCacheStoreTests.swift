// WeatherCacheStoreTests.swift
// Covers the two things this session added to WeatherCacheStore: graceful
// self-healing when stored bytes don't decode, and safety under concurrent
// access from multiple threads/tasks (the real-world shape being the main
// app and a background App Intent touching the store at the same time).
import Foundation
import Testing
@testable import WeatherMat

struct WeatherCacheStoreTests {

    @Test func loadRecoversFromCorruptedCacheEntry() {
        // Random UUID — isolated key, same safety property the existing
        // round-trip test relies on: never touches real app data.
        let id = UUID()
        defer { WeatherCacheStore.remove(for: id) }

        UserDefaults.standard.set(Data("not valid json".utf8), forKey: WeatherCacheStore.cacheKey(for: id))

        #expect(WeatherCacheStore.load(for: id) == nil)
        // Self-healed: the corrupted bytes were discarded rather than left
        // to fail the same decode again on every future load.
        #expect(UserDefaults.standard.data(forKey: WeatherCacheStore.cacheKey(for: id)) == nil)

        // A subsequent save for the same id still works normally — the
        // corrupted entry didn't leave the key in some unusable state.
        WeatherCacheStore.save(.empty, fetchedAt: Date(), for: id)
        #expect(WeatherCacheStore.load(for: id) != nil)
    }

    @Test func loadSavedLocationsRecoversFromCorruptedData() {
        // `loadSavedLocations()` reads a fixed, non-parameterized key that
        // is the user's real saved-location list outside of this test — so
        // this backs up whatever is there, corrupts it, asserts the
        // graceful-empty fallback, and always restores the original value,
        // even if the test fails partway through.
        let defaults = UserDefaults.standard
        let key = "savedLocations_v1"
        let original = defaults.data(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.set(Data("not valid json".utf8), forKey: key)

        #expect(WeatherCacheStore.loadSavedLocations().isEmpty)
    }

    @Test func concurrentSaveLoadRemoveDoesNotCorruptOtherEntries() async {
        let ids = (0..<8).map { _ in UUID() }
        defer { for id in ids { WeatherCacheStore.remove(for: id) } }

        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    for _ in 0..<25 {
                        WeatherCacheStore.save(.empty, fetchedAt: Date(), for: id)
                        _ = WeatherCacheStore.load(for: id)
                    }
                }
            }
            // Exercises `loadSavedLocations()` concurrently too, since it
            // shares the same lock as the per-location entries above.
            group.addTask {
                for _ in 0..<25 {
                    _ = WeatherCacheStore.loadSavedLocations()
                }
            }
        }

        // Every id's last write landed in a valid, independently-decodable
        // state — concurrent access to other keys never tore or corrupted
        // this one.
        for id in ids {
            #expect(WeatherCacheStore.load(for: id) != nil)
        }
    }
}
