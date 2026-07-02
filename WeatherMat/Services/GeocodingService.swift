// GeocodingService.swift
import Foundation
import CoreLocation

struct GeocodedLocation: Identifiable {
    let id      = UUID()
    let name:    String
    let country: String
    let state:   String
    let lat:     Double
    let lon:     Double
    var subtitle: String { [state, country].filter { !$0.isEmpty }.joined(separator: ", ") }
}

final class GeocodingService: Sendable {

    static let shared = GeocodingService()
    private let owmKey: String?
    private let reverseCacheKey = "reverseGeocodeCache_v2"
    private let reverseCacheLimit = 200

    private init() {
        owmKey = Self.loadOWMKey()
    }

    private static func loadOWMKey() -> String? {
        guard let url = Bundle.main.url(forResource: "LocalConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let config = try? PropertyListDecoder().decode(LocalConfig.self, from: data)
        else { return nil }

        let key = config.openWeatherMapGeocodingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    // MARK: - Forward geocoding
    func search(_ query: String) async -> [GeocodedLocation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        if let r = try? await owmSearch(q), !r.isEmpty { return r }
        return (try? await omSearch(q)) ?? []
    }

    // MARK: - Reverse geocoding
    func reverseGeocode(_ location: CLLocation) async -> String {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let key = reverseCoordinateKey(lat: lat, lon: lon)
        if let cached = cachedReverseName(for: key), !Self.isCoordinateFallback(cached) {
            return cached
        }

        if let name = try? await owmReverse(lat: lat, lon: lon) {
            cacheReverseName(name, for: key)
            return name
        }
        if let name = try? await nominatim(lat: lat, lon: lon) {
            cacheReverseName(name, for: key)
            return name
        }

        return String(format: "%.2f°, %.2f°", lat, lon)
    }

    static func isCoordinateFallback(_ name: String) -> Bool {
        name.contains("°") || name.range(of: #"^-?\d+([.,]\d+)?\s*,\s*-?\d+([.,]\d+)?"#, options: .regularExpression) != nil
    }

    private func reverseCoordinateKey(lat: Double, lon: Double) -> String {
        let roundedLat = (lat * 1_000).rounded() / 1_000
        let roundedLon = (lon * 1_000).rounded() / 1_000
        return String(format: "%.3f,%.3f", roundedLat, roundedLon)
    }

    private func cachedReverseName(for key: String) -> String? {
        var cache = loadReverseCache()
        guard var entry = cache[key] else { return nil }
        entry.lastUsed = Date()
        cache[key] = entry
        saveReverseCache(cache)
        return entry.name
    }

    private func cacheReverseName(_ name: String, for key: String) {
        var cache = loadReverseCache()
        cache[key] = ReverseGeocodeCacheEntry(name: name, lastUsed: Date())
        if cache.count > reverseCacheLimit {
            let overflow = cache.count - reverseCacheLimit
            let staleKeys = cache
                .sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(overflow)
                .map(\.key)
            for staleKey in staleKeys {
                cache.removeValue(forKey: staleKey)
            }
        }
        saveReverseCache(cache)
    }

    private func loadReverseCache() -> [String: ReverseGeocodeCacheEntry] {
        guard let data = UserDefaults.standard.data(forKey: reverseCacheKey),
              let cache = try? JSONDecoder().decode([String: ReverseGeocodeCacheEntry].self, from: data)
        else { return [:] }
        return cache
    }

    private func saveReverseCache(_ cache: [String: ReverseGeocodeCacheEntry]) {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: reverseCacheKey)
        }
    }

    // MARK: - OWM geocoding
    private func owmSearch(_ q: String) async throws -> [GeocodedLocation] {
        guard let owmKey else { throw WeatherError.notAvailable }
        var c = URLComponents(string: "https://api.openweathermap.org/geo/1.0/direct")!
        c.queryItems = [.init(name:"q",value:q),.init(name:"limit",value:"5"),.init(name:"appid",value:owmKey)]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode([OWMItem].self, from: data).map {
            GeocodedLocation(name: $0.name, country: $0.country ?? "", state: $0.state ?? "", lat: $0.lat, lon: $0.lon)
        }
    }
    private func owmReverse(lat: Double, lon: Double) async throws -> String? {
        guard let owmKey else { throw WeatherError.notAvailable }
        var c = URLComponents(string: "https://api.openweathermap.org/geo/1.0/reverse")!
        c.queryItems = [.init(name:"lat",value:"\(lat)"),.init(name:"lon",value:"\(lon)"),.init(name:"limit",value:"1"),.init(name:"appid",value:owmKey)]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode([OWMItem].self, from: data).first?.name
    }

    // MARK: - Open-Meteo geocoding (fallback, no key)
    private func omSearch(_ q: String) async throws -> [GeocodedLocation] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name:"name",value:q),.init(name:"count",value:"5"),.init(name:"language",value:"de")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        struct R: Decodable { let results: [OMGeo]? }
        return (try JSONDecoder().decode(R.self, from: data).results ?? []).compactMap {
            guard let name = $0.name else { return nil }
            return GeocodedLocation(name: name, country: $0.country_code ?? "", state: $0.admin1 ?? "", lat: $0.latitude, lon: $0.longitude)
        }
    }

    // MARK: - Nominatim (reverse, fallback)
    private func nominatim(lat: Double, lon: Double) async throws -> String? {
        var c = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        c.queryItems = [.init(name:"lat",value:"\(lat)"),.init(name:"lon",value:"\(lon)"),.init(name:"format",value:"json"),.init(name:"accept-language",value:"de")]
        var req = URLRequest(url: c.url!)
        req.setValue("WeatherMat/2.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct R: Decodable {
            struct A: Decodable {
                let city, town, village, municipality, hamlet, suburb, city_district, county, state_district: String?
            }
            let display_name: String?
            let address: A?
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        if let address = r.address {
            if let name = address.city ?? address.town ?? address.village ?? address.municipality ?? address.hamlet ?? address.suburb ?? address.city_district ?? address.county ?? address.state_district {
                return name
            }
        }
        return r.display_name?
            .split(separator: ",")
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private struct OWMItem: Decodable { let name: String; let country,state: String?; let lat,lon: Double }
private struct OMGeo:  Decodable { let name,country_code,admin1: String?; let latitude,longitude: Double }
private struct LocalConfig: Decodable {
    let openWeatherMapGeocodingAPIKey: String
}
private struct ReverseGeocodeCacheEntry: Codable {
    let name: String
    var lastUsed: Date
}
