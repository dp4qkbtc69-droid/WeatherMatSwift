// RadarPrewarmController.swift
// Pre-warms the radar proxy's tile cache for locations the app knows about,
// so opening the radar (or returning after an absence) serves already-
// rendered tiles instead of triggering a cold render on the server. Pure
// fire-and-forget background triggers with their own cooldown bookkeeping
// in UserDefaults and no per-instance state — like `RainRadarService`, a
// static namespace rather than an object `WeatherViewModel` would need to
// own or inject. Extracted from `WeatherViewModel`, which previously ran
// this directly alongside its own weather-loading and location logic.
import Foundation

enum RadarPrewarmController {
    private static let lastWarmedRadarKey = "lastWarmedRadarLocation_v1"
    private static let lastWarmedRadarAtKey = "lastWarmedRadarAt_v1"
    private static let lastWarmedAllKey = "lastWarmedAllLocations_v1"
    private static let lastWarmedAllAtKey = "lastWarmedAllLocationsAt_v1"
    /// Re-warm the same location after this long even if it didn't move: the
    /// server keeps dynamic hotspots only in memory, so a proxy restart (deploy,
    /// monthly rebuild, OOM) drops them. Re-warming on a long-absence return
    /// reheats the server hotspot *and* the app's QUIC connection before the
    /// first tile batch.
    private static let radarWarmCooldown: TimeInterval = 15 * 60

    /// Asks the radar proxy to render this location's tiles ahead of the user
    /// opening the radar. Re-triggers when the active location changed (~1 km
    /// granularity) *or* when the last warm is older than `radarWarmCooldown`,
    /// so a returning user after a long absence re-primes the server hotspot
    /// and the network connection instead of hitting cold tiles.
    static func prewarmIfNeeded(for location: SavedLocation) {
        let coord = String(format: "%.2f,%.2f", location.latitude, location.longitude)
        let defaults = UserDefaults.standard
        let sameCoord = defaults.string(forKey: lastWarmedRadarKey) == coord
        let lastAt = defaults.object(forKey: lastWarmedRadarAtKey) as? Date
        let fresh = lastAt.map { Date().timeIntervalSince($0) < radarWarmCooldown } ?? false
        guard !(sameCoord && fresh) else { return }
        Task.detached(priority: .utility) {
            let warmed = await RainRadarService.shared.warmLocation(latitude: location.latitude, longitude: location.longitude)
            guard warmed else { return }
            await MainActor.run {
                UserDefaults.standard.set(coord, forKey: lastWarmedRadarKey)
                UserDefaults.standard.set(Date(), forKey: lastWarmedRadarAtKey)
            }
        }
    }

    /// Registers every saved location with the proxy so each one opens the
    /// radar from cache. Re-registers when the set changed or the cooldown
    /// elapsed (proxy keeps hotspots only in memory + a persisted file).
    static func warmAll(_ locations: [SavedLocation]) {
        let coords = locations.map { (latitude: $0.latitude, longitude: $0.longitude) }
        guard !coords.isEmpty else { return }
        let signature = coords
            .map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) }
            .joined(separator: ";")
        let defaults = UserDefaults.standard
        let sameSet = defaults.string(forKey: lastWarmedAllKey) == signature
        let lastAt = defaults.object(forKey: lastWarmedAllAtKey) as? Date
        let fresh = lastAt.map { Date().timeIntervalSince($0) < radarWarmCooldown } ?? false
        guard !(sameSet && fresh) else { return }
        Task.detached(priority: .utility) {
            let warmed = await RainRadarService.shared.registerWarmLocations(coords)
            guard warmed else { return }
            await MainActor.run {
                UserDefaults.standard.set(signature, forKey: lastWarmedAllKey)
                UserDefaults.standard.set(Date(), forKey: lastWarmedAllAtKey)
            }
        }
    }
}
