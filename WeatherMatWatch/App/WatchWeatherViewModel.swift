// WatchWeatherViewModel.swift
import Foundation
import WidgetKit
import Observation

@MainActor
@Observable
final class WatchWeatherViewModel {
    var locations: [WatchLocation]
    var selectedLocationID: String
    var snapshot: WatchWeatherSnapshot?
    var isLoading = false
    var errorMessage: String?

    private let locationProvider = WatchLocationProvider()

    var selectedLocationName: String {
        locations.first(where: { $0.id == selectedLocationID })?.name ?? "WeatherMat"
    }

    init() {
        let storedLocations = WatchSharedStore.locations
        locations = storedLocations.isEmpty ? [.gpsPlaceholder] : storedLocations
        selectedLocationID = WatchSharedStore.selectedLocationID ?? WatchLocation.gpsPlaceholder.id
        snapshot = WatchSharedStore.snapshot(for: selectedLocationID)

        LocationSyncReceiver.shared.onLocationsReceived = { [weak self] synced in
            self?.mergeSyncedLocations(synced)
        }
    }

    private func mergeSyncedLocations(_ synced: [WatchLocation]) {
        let gps = locations.first(where: { $0.isGPS }) ?? .gpsPlaceholder
        locations = [gps] + synced.filter { !$0.isGPS }
        WatchSharedStore.locations = locations
        if !locations.contains(where: { $0.id == selectedLocationID }) {
            selectedLocationID = gps.id
            WatchSharedStore.selectedLocationID = selectedLocationID
        }
    }

    func selectLocation(_ id: String) {
        guard selectedLocationID != id else { return }
        selectedLocationID = id
        WatchSharedStore.selectedLocationID = id
        snapshot = WatchSharedStore.snapshot(for: id)
        Task { await refresh() }
    }

    func refreshOnAppear() async {
        WatchSharedStore.selectedLocationID = selectedLocationID
        await refresh()
    }

    func refresh() async {
        guard var location = locations.first(where: { $0.id == selectedLocationID }) else { return }
        isLoading = snapshot == nil
        errorMessage = nil

        if location.isGPS {
            do {
                let fix = try await locationProvider.requestLocation()
                location.latitude = fix.coordinate.latitude
                location.longitude = fix.coordinate.longitude
                if let idx = locations.firstIndex(where: { $0.id == location.id }) {
                    locations[idx] = location
                    WatchSharedStore.locations = locations
                }
            } catch {
                if snapshot == nil { errorMessage = "GPS nicht verfügbar" }
                isLoading = false
                return
            }
        }

        do {
            let fresh = try await WeatherKitFetcher.fetchSnapshot(for: location)
            snapshot = fresh
            WatchSharedStore.saveSnapshot(fresh, for: location.id)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            if snapshot == nil { errorMessage = WeatherKitFetcher.diagnosticMessage(for: error) }
        }
        isLoading = false
    }
}
