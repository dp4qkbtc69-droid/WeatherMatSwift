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

enum RainRadarService {

    private static let logger = Logger(subsystem: "de.praxishartlep.weathermat", category: "RainRadar")
    private static let timelineCacheKey = "radar.timeline.v8.rawServerTiles"
    private static let localConfig = loadLocalConfig()
    private static let isoFormatWithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoFormat = Date.ISO8601FormatStyle()

    // In-memory preload populated while the user is on WeatherView.
    @MainActor static var preloadedTimeline: RainRadarTimeline?

    @MainActor
    static func preloadIfNeeded() async {
        guard preloadedTimeline == nil else { return }
        guard let timeline = try? await fetchTimeline() else { return }
        preloadedTimeline = timeline
        saveTimelineCache(timeline)
    }

    static func loadCachedTimeline() -> RainRadarTimeline? {
        // 30-min window: the cached timeline already carries forecast frames, so
        // it renders instantly on a long-absence return while load() kicks off a
        // background refresh to pull in newer observations.
        guard let data = UserDefaults.standard.data(forKey: timelineCacheKey),
              let cache = try? JSONDecoder().decode(CachedRadarTimeline.self, from: data),
              Date().timeIntervalSince(cache.savedAt) < 30 * 60 else { return nil }
        return cache.toTimeline()
    }

    static func saveTimelineCache(_ timeline: RainRadarTimeline) {
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

    static func fetchTimeline() async throws -> RainRadarTimeline {
        if let dwdBaseURL = localDwdRadarBaseURL {
            do {
                return try await fetchDwdTimeline(baseURL: dwdBaseURL)
            } catch {
                logger.warning("DWD proxy failed, using RainViewer fallback: \(String(describing: error), privacy: .public)")
            }
        }
        return try await fetchRainViewerTimeline()
    }

    private static func fetchDwdTimeline(baseURL: URL) async throws -> RainRadarTimeline {
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
            guard let time = parseDwdDate(frame.time) else { return nil }
            return RainRadarFrame(
                time: time,
                path: "/tiles/\(frame.id)",
                isForecast: frame.isForecast,
                sourceKind: RainRadarFrame.SourceKind(rawValue: frame.source ?? "") ?? .unknown,
                precipitationType: RainRadarFrame.PrecipitationType(rawValue: frame.precipitationType ?? "") ?? .unknown,
                referenceTime: frame.referenceTime.flatMap(RainRadarService.parseDwdDate)
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

    private static func fetchRainViewerTimeline() async throws -> RainRadarTimeline {
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

    private static var localDwdRadarBaseURL: URL? {
        let rawValue = localConfig?.dwdRadarTileBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else { return nil }
        return URL(string: rawValue)
    }

    /// Proxy base URL for sibling services (push registration, warm-location).
    static var proxyBaseURL: URL? {
        localDwdRadarBaseURL
    }

    static func authenticatedDwdRadarRequest(_ url: URL, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: cachePolicy)
        if let token = localDwdRadarToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-radar-token")
        }
        return request
    }

    static func warmLocation(latitude: Double, longitude: Double) async {
        guard let baseURL = localDwdRadarBaseURL else { return }
        guard var components = URLComponents(url: baseURL.appending(path: "warm-location"), resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", longitude))
        ]
        guard let url = components.url else { return }
        var request = authenticatedDwdRadarRequest(url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Registers all saved locations as warm hotspots in one call, so every one
    /// of them opens the radar from cache — not just the active location.
    static func registerWarmLocations(_ coordinates: [(latitude: Double, longitude: Double)]) async {
        guard let baseURL = localDwdRadarBaseURL, !coordinates.isEmpty else { return }
        var request = authenticatedDwdRadarRequest(baseURL.appending(path: "warm-locations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        let body: [String: Any] = [
            "locations": coordinates.map { ["lat": $0.latitude, "lon": $0.longitude] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data
        _ = try? await URLSession.shared.data(for: request)
    }

    private static var localDwdRadarToken: String? {
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
    let dwdRadarTileToken: String

    private enum CodingKeys: String, CodingKey {
        case dwdRadarTileBaseURL
        case dwdRadarTileToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dwdRadarTileBaseURL = try container.decodeIfPresent(String.self, forKey: .dwdRadarTileBaseURL) ?? ""
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
