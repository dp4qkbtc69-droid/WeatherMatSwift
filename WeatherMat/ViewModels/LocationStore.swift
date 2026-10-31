// LocationStore.swift
// Owns the saved-locations list, the active selection, and GPS acquisition —
// extracted from WeatherViewModel so this state/CRUD/hardware logic is
// testable and reasoned about independently of weather loading.
//
// This store knows nothing about weather data or radar: `WeatherViewModel`
// holds a reference to it, reads `activeLocation` to know what to load, and
// calls its mutation methods as thin orchestration wrappers (e.g.
// `WeatherViewModel.switchLocation(to:)` calls `LocationStore.switchLocation`
// and then reacts — restoring the weather cache, triggering a reload,
// pre-warming radar). Views that only need location data/CRUD (the
// locations list, the location picker) can read this store directly instead
// of going through the weather view model.
import Foundation
import CoreLocation
import Observation

/// Result of a quick, hardware-free check before deciding whether the
/// caller needs to show a loading indicator and acquire a fresh GPS fix.
enum GPSQuickCheck {
    /// A GPS request is already in flight — do nothing.
    case busy
    /// A recent fix is still fresh enough; `location` is already active (or
    /// was just made active) with no hardware round-trip needed.
    case usesCachedFix(SavedLocation)
    /// No usable recent fix — caller should show a loading indicator and
    /// call `acquireFreshGPSLocation(makeActive:)`.
    case needsFreshFix
}

/// Result of a full GPS hardware acquisition.
enum GPSAcquisitionResult {
    /// `replacedLocationID` is the previous GPS entry's id, if any — the
    /// caller owns that location's weather-cache cleanup, not this store.
    case success(location: SavedLocation, replacedLocationID: UUID?, shouldResetDaySelection: Bool)
    case failure
}

@MainActor
@Observable
final class LocationStore {
    var savedLocations: [SavedLocation] = []
    var activeLocationIndex: Int = 0

    private let geocoding = GeocodingService.shared
    private let udKey = "savedLocations_v1"
    private let activeLocationIndexKey = "activeLocationIndex_v1"

    /// Prevents concurrent GPS flows (e.g. layout switch re-firing `.task`).
    private var isRequestingGPS = false
    /// Skip a fresh GPS fix if the last one is younger than this.
    private let gpsCooldown: TimeInterval = 120
    private var lastGPSFix: Date?

    var activeLocation: SavedLocation? { savedLocations[safe: activeLocationIndex] }

    init() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: udKey),
           let locs = try? JSONDecoder().decode([SavedLocation].self, from: data) {
            savedLocations = locs.sorted { $0.sortOrder < $1.sortOrder }
        }
        if !savedLocations.isEmpty {
            let storedIndex = ud.integer(forKey: activeLocationIndexKey)
            activeLocationIndex = min(max(0, storedIndex), savedLocations.count - 1)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func addLocation(_ loc: SavedLocation) -> SavedLocation {
        savedLocations.append(loc)
        normalizeSortOrder()
        activeLocationIndex = savedLocations.count - 1
        saveLocations()
        saveActiveLocationIndex()
        return loc
    }

    @discardableResult
    func removeLocation(at index: Int) -> SavedLocation? {
        guard savedLocations.indices.contains(index) else { return nil }
        let removed = savedLocations[index]
        savedLocations.remove(at: index)
        activeLocationIndex = min(activeLocationIndex, max(0, savedLocations.count - 1))
        normalizeSortOrder()
        saveLocations()
        saveActiveLocationIndex()
        return removed
    }

    func moveLocations(from source: IndexSet, to destination: Int) {
        let activeID = activeLocation?.id
        guard !source.contains(where: { savedLocations[safe: $0]?.isGPS == true }) else { return }
        var reordered = savedLocations
        let moving = source.sorted().map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: adjustedDestination)
        if let gpsIndex = reordered.firstIndex(where: { $0.isGPS }) {
            let gpsLocation = reordered.remove(at: gpsIndex)
            reordered.insert(gpsLocation, at: 0)
        }
        savedLocations = reordered
        normalizeSortOrder()
        if let activeID, let newIndex = savedLocations.firstIndex(where: { $0.id == activeID }) {
            activeLocationIndex = newIndex
        } else {
            activeLocationIndex = min(activeLocationIndex, max(0, savedLocations.count - 1))
        }
        saveLocations()
        saveActiveLocationIndex()
    }

    func switchLocation(to index: Int) {
        guard savedLocations.indices.contains(index) else { return }
        activeLocationIndex = index
        saveActiveLocationIndex()
    }

    // MARK: - GPS

    func gpsQuickCheck(makeActive: Bool) -> GPSQuickCheck {
        guard !isRequestingGPS else { return .busy }
        guard let last = lastGPSFix,
              Date().timeIntervalSince(last) < gpsCooldown,
              let gpsIndex = savedLocations.firstIndex(where: { $0.isGPS }) else {
            return .needsFreshFix
        }
        if makeActive {
            activeLocationIndex = gpsIndex
            saveActiveLocationIndex()
        }
        guard let loc = activeLocation else { return .needsFreshFix }
        return .usesCachedFix(loc)
    }

    func acquireFreshGPSLocation(makeActive: Bool) async -> GPSAcquisitionResult {
        isRequestingGPS = true
        defer { isRequestingGPS = false }

        let previousActiveID = activeLocation?.id
        do {
            let clLoc = try await withTimeout(seconds: 10) {
                try await LocationService.shared.requestCurrentLocation()
            }
            let name = await geocoding.reverseGeocode(clLoc)

            let oldGPSIndex = savedLocations.firstIndex(where: { $0.isGPS })
            let replacedLocationID = oldGPSIndex.map { savedLocations[$0].id }

            let saved = SavedLocation(
                name: name,
                latitude: clLoc.coordinate.latitude,
                longitude: clLoc.coordinate.longitude,
                sortOrder: 0,
                isGPS: true
            )
            if let oldGPSIndex {
                savedLocations.remove(at: oldGPSIndex)
                savedLocations.insert(saved, at: 0)
            } else {
                savedLocations.insert(saved, at: 0)
            }
            lastGPSFix = Date()
            saveLocations()

            // Restore focus: GPS when taking over, otherwise the previously
            // shown location (its index may have shifted from the insert).
            var resetDaySelection = false
            if makeActive {
                activeLocationIndex = 0
                resetDaySelection = true
            } else if let previousActiveID, let idx = savedLocations.firstIndex(where: { $0.id == previousActiveID }) {
                activeLocationIndex = idx
            } else {
                activeLocationIndex = 0
                resetDaySelection = true
            }
            saveActiveLocationIndex()

            guard let active = activeLocation else { return .failure }
            return .success(location: active, replacedLocationID: replacedLocationID, shouldResetDaySelection: resetDaySelection)
        } catch {
            return .failure
        }
    }

    // MARK: - Persistence

    private func saveLocations() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
        WatchConnectivityService.shared.syncLocations(savedLocations)
        // Keep the warning-push registration in sync with the saved locations.
        Task { @MainActor in
            await PushRegistrationService.shared.syncRegistration()
        }
    }

    private func saveActiveLocationIndex() {
        UserDefaults.standard.set(activeLocationIndex, forKey: activeLocationIndexKey)
    }

    private func normalizeSortOrder() {
        for i in savedLocations.indices {
            savedLocations[i].sortOrder = i
        }
    }
}
