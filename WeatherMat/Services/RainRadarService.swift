// RainRadarService.swift
import Foundation
import os

struct RainRadarFrame: Identifiable, Equatable {
    let time: Date
    let path: String
    let isForecast: Bool
    let sourceKind: SourceKind
    let precipitationType: PrecipitationType
    let referenceTime: Date?

    var id: String { "\(path)-\(Int(time.timeIntervalSince1970))" }

    enum SourceKind: String, Codable {
        case dwdRadar = "dwd-rv"
        case iconEu = "icon-eu-wms"
        case iconEuRaw = "icon-eu-raw"
        case rainViewer = "rainviewer"
        case unknown
    }

    enum PrecipitationType: String, Codable {
        case rain
        case snow
        case mixed
        case hail
        case unknown
    }
}

enum RainRadarSource {
    case dwd
    case rainViewer
}

struct RainRadarTimeline {
    let host: String
    let attribution: String
    let source: RainRadarSource
    let tileMaxZoom: Int?
    let frames: [RainRadarFrame]

    var latestObservedFrame: RainRadarFrame? {
        frames.last { !$0.isForecast } ?? frames.last
    }
}

/// Everything `RadarV2Store` and friends need from the radar timeline/proxy
/// layer, abstracted so tests can inject a stub instead of hitting the
/// network and `UserDefaults`. `RainRadarService.shared` is the default,
/// production-backed conformer.
protocol RainRadarServiceProtocol: Sendable {
    @MainActor var preloadedTimeline: RainRadarTimeline? { get set }
    func preloadIfNeeded() async
    func loadCachedTimeline() -> RainRadarTimeline?
    func saveTimelineCache(_ timeline: RainRadarTimeline)
    func fetchTimeline() async throws -> RainRadarTimeline
    func resolveDwdRadarBaseURL() async -> URL?
    func resolvedProxyBaseURL() async -> URL?
    func authenticatedDwdRadarRequest(_ url: URL, cachePolicy: URLRequest.CachePolicy) -> URLRequest
    func warmLocation(latitude: Double, longitude: Double) async -> Bool
    func registerWarmLocations(_ coordinates: [(latitude: Double, longitude: Double)]) async -> Bool
}

extension RainRadarServiceProtocol {
    /// Convenience overload matching the concrete type's default parameter —
    /// protocol requirements can't carry default argument values themselves.
    func authenticatedDwdRadarRequest(_ url: URL) -> URLRequest {
        authenticatedDwdRadarRequest(url, cachePolicy: .useProtocolCachePolicy)
    }
}

final class RainRadarService: RainRadarServiceProtocol, @unchecked Sendable {
    static let shared = RainRadarService()

    private let logger = Logger(subsystem: "de.praxishartlep.weathermat", category: "RainRadar")
    private let timelineCacheKey = "radar.timeline.v8.rawServerTiles"
    private let localConfig: LocalRainRadarConfig?
    private let resolvedBaseURLCache = ResolvedBaseURLCache()

    private static let isoFormatWithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoFormat = Date.ISO8601FormatStyle()

    // In-memory preload populated while the user is on WeatherView.
    @MainActor var preloadedTimeline: RainRadarTimeline?

    init() {
        localConfig = Self.loadLocalConfig()
    }

    @MainActor
    func preloadIfNeeded() async {
        guard preloadedTimeline == nil else { return }
        guard let timeline = try? await fetchTimeline() else { return }
        preloadedTimeline = timeline
        saveTimelineCache(timeline)
    }

    func loadCachedTimeline() -> RainRadarTimeline? {
        // 30-min window: the cached timeline already carries forecast frames, so
        // it renders instantly on a long-absence return while load() kicks off a
        // background refresh to pull in newer observations.
        guard let data = UserDefaults.standard.data(forKey: timelineCacheKey),
              let cache = try? JSONDecoder().decode(CachedRadarTimeline.self, from: data),
              Date().timeIntervalSince(cache.savedAt) < 30 * 60 else { return nil }
        return cache.toTimeline()
    }

    func saveTimelineCache(_ timeline: RainRadarTimeline) {
        let cache = CachedRadarTimeline(
            host: timeline.host,
            attribution: timeline.attribution,
            isDwd: timeline.source == .dwd,
            tileMaxZoom: timeline.tileMaxZoom,
            frames: timeline.frames.map {
                CachedRadarTimeline.Frame(
                    time: $0.time,
                    path: $0.path,
                    isForecast: $0.isForecast,
                    sourceKind: $0.sourceKind,
                    precipitationType: $0.precipitationType,
                    referenceTime: $0.referenceTime
                )
            },
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: timelineCacheKey)
        }
    }

    func fetchTimeline() async throws -> RainRadarTimeline {
        if let dwdBaseURL = await resolveDwdRadarBaseURL() {
            do {
                return try await fetchDwdTimeline(baseURL: dwdBaseURL)
            } catch {
                logger.warning("DWD proxy failed, using RainViewer fallback: \(String(describing: error), privacy: .public)")
            }
        }
        return try await fetchRainViewerTimeline()
    }

    private func fetchDwdTimeline(baseURL: URL) async throws -> RainRadarTimeline {
        let timelineURL = baseURL.appending(path: "timeline.json")
        // Bounded timeout so a hung proxy surfaces as a retryable error instead
        // of holding "loading" for the 60 s default — but long enough to ride
        // out a cold cache rebuild on the proxy (~15 s after a restart), so we
        // don't needlessly fall back to RainViewer right after a redeploy.
        var request = authenticatedDwdRadarRequest(timelineURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let raw = try JSONDecoder().decode(DwdRadarTimelineResponse.self, from: data)
        let frames = raw.frames.compactMap { frame -> RainRadarFrame? in
            guard let time = Self.parseDwdDate(frame.time) else { return nil }
            return RainRadarFrame(
                time: time,
                path: "/tiles/\(frame.id)",
                isForecast: frame.isForecast,
                sourceKind: RainRadarFrame.SourceKind(rawValue: frame.source ?? "") ?? .unknown,
                precipitationType: RainRadarFrame.PrecipitationType(rawValue: frame.precipitationType ?? "") ?? .unknown,
                referenceTime: frame.referenceTime.flatMap(Self.parseDwdDate)
            )
        }
        guard !frames.isEmpty else { throw URLError(.cannotParseResponse) }

        return RainRadarTimeline(
            host: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            attribution: raw.source ?? "WeatherMat RadarEngine",
            source: .dwd,
            tileMaxZoom: raw.tileMaxZoom,
            frames: frames
        )
    }

    private func fetchRainViewerTimeline() async throws -> RainRadarTimeline {
        let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let raw = try JSONDecoder().decode(RainViewerResponse.self, from: data)
        let observed = raw.radar.past.map {
            RainRadarFrame(time: Date(timeIntervalSince1970: TimeInterval($0.time)),
                           path: $0.path,
                           isForecast: false,
                           sourceKind: .rainViewer,
                           precipitationType: .unknown,
                           referenceTime: nil)
        }
        let forecast = (raw.radar.nowcast ?? []).map {
            RainRadarFrame(time: Date(timeIntervalSince1970: TimeInterval($0.time)),
                           path: $0.path,
                           isForecast: true,
                           sourceKind: .rainViewer,
                           precipitationType: .unknown,
                           referenceTime: nil)
        }
        return RainRadarTimeline(
            host: raw.host,
            attribution: "RainViewer, DWD-Blitzdichte zuschaltbar",
            source: .rainViewer,
            tileMaxZoom: 9,
            frames: observed + forecast
        )
    }

    private var localDwdRadarBaseURL: URL? {
        let rawValue = localConfig?.dwdRadarTileBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else { return nil }
        return URL(string: rawValue)
    }

    /// External (internet-reachable) fallback for when the local LAN address
    /// isn't reachable — e.g. away from home, or the local host/IP is down.
    private var externalDwdRadarBaseURL: URL? {
        let rawValue = localConfig?.dwdRadarTileExternalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else { return nil }
        return URL(string: rawValue)
    }

    /// Caches which base URL last answered a reachability probe, so repeated
    /// calls in the same session (timeline, tiles, warm-location, push) don't
    /// each pay the probe latency — re-probed after `ttl`. An actor because
    /// this mutable cache is touched from multiple concurrent call sites.
    private actor ResolvedBaseURLCache {
        private var cache: (url: URL, resolvedAt: Date)?
        private let ttl: TimeInterval = 120

        func get() -> URL? {
            guard let cache, Date().timeIntervalSince(cache.resolvedAt) < ttl else { return nil }
            return cache.url
        }

        func set(_ url: URL?) {
            cache = url.map { ($0, Date()) }
        }
    }

    /// Resolves the DWD radar proxy base URL, preferring the local LAN address
    /// (lower latency at home) and falling back to the external URL if the
    /// local one doesn't answer — e.g. local IP/host is currently unreachable.
    func resolveDwdRadarBaseURL() async -> URL? {
        if let cached = await resolvedBaseURLCache.get() {
            return cached
        }
        let local = localDwdRadarBaseURL
        // Short timeout for the LAN probe: on the home network it answers in
        // a few ms, and off the home network (e.g. cellular routing to a
        // private IP) it should fail fast — no point waiting long for it.
        if let local, await probeReachable(local, timeout: 2.5) {
            await resolvedBaseURLCache.set(local)
            return local
        }
        let external = externalDwdRadarBaseURL
        // Longer timeout here: this probe is what carries the "away from
        // home" case, and a slow cellular connection doing DNS+TCP+TLS can
        // easily take longer than the LAN probe's 2.5 s — a false negative
        // here means silently losing DWD radar to the RainViewer fallback.
        if let external, await probeReachable(external, timeout: 6) {
            await resolvedBaseURLCache.set(external)
            return external
        }
        await resolvedBaseURLCache.set(nil)
        // Neither probe succeeded — fall back to whichever is configured so the
        // caller still gets a real error (and log line) instead of silently
        // skipping straight to RainViewer without ever trying the proxy.
        // Prefer external here: if we reach this line, the local probe above
        // already failed, so retrying local is pointless — external at least
        // has a chance (its probe may have just timed out, not truly failed).
        return external ?? local
    }

    private func probeReachable(_ baseURL: URL, timeout: TimeInterval) async -> Bool {
        var request = authenticatedDwdRadarRequest(baseURL.appending(path: "ping"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = timeout
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Proxy base URL for sibling services (push registration, warm-location).
    /// Resolves local-vs-external the same way `fetchTimeline` does.
    func resolvedProxyBaseURL() async -> URL? {
        await resolveDwdRadarBaseURL()
    }

    func authenticatedDwdRadarRequest(_ url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: cachePolicy)
        if let token = localDwdRadarToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-radar-token")
        }
        return request
    }

    func warmLocation(latitude: Double, longitude: Double) async -> Bool {
        guard let baseURL = await resolveDwdRadarBaseURL() else { return false }
        guard var components = URLComponents(url: baseURL.appending(path: "warm-location"), resolvingAgainstBaseURL: false) else { return false }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", longitude))
        ]
        guard let url = components.url else { return false }
        var request = authenticatedDwdRadarRequest(url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Registers all saved locations as warm hotspots in one call, so every one
    /// of them opens the radar from cache — not just the active location.
    func registerWarmLocations(_ coordinates: [(latitude: Double, longitude: Double)]) async -> Bool {
        guard !coordinates.isEmpty, let baseURL = await resolveDwdRadarBaseURL() else { return false }
        var request = authenticatedDwdRadarRequest(baseURL.appending(path: "warm-locations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let body: [String: Any] = [
            "locations": coordinates.map { ["lat": $0.latitude, "lon": $0.longitude] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        request.httpBody = data
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private var localDwdRadarToken: String? {
        let rawValue = localConfig?.dwdRadarTileToken.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return rawValue.isEmpty ? nil : rawValue
    }

    private static func loadLocalConfig() -> LocalRainRadarConfig? {
        guard let url = Bundle.main.url(forResource: "LocalConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let config = try? PropertyListDecoder().decode(LocalRainRadarConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// Pure/stateless, so it stays a type-level utility rather than an
    /// injected dependency — `RegionPackService`'s date decoder also calls
    /// this directly.
    static func parseDwdDate(_ value: String) -> Date? {
        if let date = try? isoFormatWithFractionalSeconds.parse(value) {
            return date
        }
        return try? isoFormat.parse(value)
    }
}

private struct CachedRadarTimeline: Codable {
    struct Frame: Codable {
        let time: Date
        let path: String
        let isForecast: Bool
        let sourceKind: RainRadarFrame.SourceKind?
        let precipitationType: RainRadarFrame.PrecipitationType?
        let referenceTime: Date?
    }
    let host: String
    let attribution: String
    let isDwd: Bool
    let tileMaxZoom: Int?
    let frames: [Frame]
    let savedAt: Date

    func toTimeline() -> RainRadarTimeline {
        RainRadarTimeline(
            host: host,
            attribution: attribution,
            source: isDwd ? .dwd : .rainViewer,
            tileMaxZoom: tileMaxZoom,
            frames: frames.map {
                RainRadarFrame(
                    time: $0.time,
                    path: $0.path,
                    isForecast: $0.isForecast,
                    sourceKind: $0.sourceKind ?? (isDwd ? .dwdRadar : .rainViewer),
                    precipitationType: $0.precipitationType ?? .unknown,
                    referenceTime: $0.referenceTime
                )
            }
        )
    }
}

private struct LocalRainRadarConfig: Decodable {
    let dwdRadarTileBaseURL: String
    let dwdRadarTileExternalBaseURL: String
    let dwdRadarTileToken: String

    private enum CodingKeys: String, CodingKey {
        case dwdRadarTileBaseURL
        case dwdRadarTileExternalBaseURL
        case dwdRadarTileToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dwdRadarTileBaseURL = try container.decodeIfPresent(String.self, forKey: .dwdRadarTileBaseURL) ?? ""
        dwdRadarTileExternalBaseURL = try container.decodeIfPresent(String.self, forKey: .dwdRadarTileExternalBaseURL) ?? ""
        dwdRadarTileToken = try container.decodeIfPresent(String.self, forKey: .dwdRadarTileToken) ?? ""
    }
}

private struct DwdRadarTimelineResponse: Decodable {
    let source: String?
    let tileMaxZoom: Int?
    let frames: [DwdRadarFrameResponse]
}

private struct DwdRadarFrameResponse: Decodable {
    let id: String
    let time: String
    let isForecast: Bool
    let source: String?
    let precipitationType: String?
    let referenceTime: String?
}

private struct RainViewerResponse: Decodable {
    let host: String
    let radar: RainViewerRadar
}

private struct RainViewerRadar: Decodable {
    let past: [RainViewerFrame]
    let nowcast: [RainViewerFrame]?
}

private struct RainViewerFrame: Decodable {
    let time: Int
    let path: String
}
