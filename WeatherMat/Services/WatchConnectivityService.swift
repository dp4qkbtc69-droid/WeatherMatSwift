// WatchConnectivityService.swift
// Mirrors the saved-location list to a paired Watch app. The watch fetches
// its own weather via WeatherKit — this only keeps its location list in sync
// so locations don't need to be added twice.
import Foundation
import WatchConnectivity

final class WatchConnectivityService: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConnectivityService()

    private struct SyncedLocation: Codable {
        let id:        String
        let name:      String
        let latitude:  Double
        let longitude: Double
        let isGPS:     Bool
    }

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func syncLocations(_ locations: [SavedLocation]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload = locations.map {
            SyncedLocation(id: $0.id.uuidString, name: $0.name, latitude: $0.latitude, longitude: $0.longitude, isGPS: $0.isGPS)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? WCSession.default.updateApplicationContext(["locations": data])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
