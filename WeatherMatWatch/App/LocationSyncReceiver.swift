// LocationSyncReceiver.swift
// Receives the saved-location list from the iPhone app via WatchConnectivity.
// Only the location list travels this way — weather itself is fetched
// directly on the watch via WeatherKit (see WeatherKitFetcher).
import Foundation
import WatchConnectivity

final class LocationSyncReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = LocationSyncReceiver()

    /// Set by the view model; called on the main thread with the decoded list.
    var onLocationsReceived: (([WatchLocation]) -> Void)?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["locations"] as? Data,
              let decoded = try? JSONDecoder().decode([SyncedLocationDTO].self, from: data)
        else { return }
        let mapped = decoded.map {
            WatchLocation(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude, isGPS: $0.isGPS)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onLocationsReceived?(mapped)
        }
    }
}

/// Mirrors WatchConnectivityService.SyncedLocation on the iPhone side — kept
/// as a private duplicate rather than a shared file since the schema is tiny
/// and stable.
private struct SyncedLocationDTO: Codable {
    let id:        String
    let name:      String
    let latitude:  Double
    let longitude: Double
    let isGPS:     Bool
}
