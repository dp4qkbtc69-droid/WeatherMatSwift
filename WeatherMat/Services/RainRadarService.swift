// RainRadarService.swift
import Foundation

struct RainRadarFrame: Identifiable, Equatable {
    let time: Date
    let path: String
    let isForecast: Bool
    var frameSource: FrameSource = .radar

    var id: String { "\(path)-\(Int(time.timeIntervalSince1970))" }

    enum FrameSource: Equatable {
        case radar
        case dwdIconEu(layerName: String)
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

    // In-memory preload populated while the user is on WeatherView.
    nonisolated(unsafe) static var preloadedTimeline: RainRadarTimeline?

    static func preloadIfNeeded() async {
        guard preloadedTimeline == nil else { return }
        guard let timeline = try? await fetchTimeline() else { return }
        preloadedTimeline = timeline
        saveTimelineCache(timeline)
    }

    static func loadCachedTimeline() -> RainRadarTimeline? {
        guard let data = UserDefaults.standard.data(forKey: "radar.timeline.v1"),
              let cache = try? JSONDecoder().decode(CachedRadarTimeline.self, from: data),
              Date().timeIntervalSince(cache.savedAt) < 10 * 60 else { return nil }
        return cache.toTimeline()
    }

    static func saveTimelineCache(_ timeline: RainRadarTimeline) {
        let cache = CachedRadarTimeline(
            host: timeline.host,
            attribution: timeline.attribution,
            isDwd: timeline.source == .dwd,
            tileMaxZoom: timeline.tileMaxZoom,
            frames: timeline.frames.map {
                CachedRadarTimeline.Frame(time: $0.time, path: $0.path, isForecast: $0.isForecast)
            },
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: "radar.timeline.v1")
        }
    }

    static func fetchTimeline() async throws -> RainRadarTimeline {
        if let dwdBaseURL = localDwdRadarBaseURL {
            do {
                return try await fetchDwdTimeline(baseURL: dwdBaseURL)
            } catch {
                print("[RainRadar] DWD proxy failed, using RainViewer fallback: \(error)")
            }
        }
        return try await fetchRainViewerTimeline()
    }

    private static func fetchDwdTimeline(baseURL: URL) async throws -> RainRadarTimeline {
        let timelineURL = baseURL.appending(path: "timeline.json")
        let (data, response) = try await URLSession.shared.data(from: timelineURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let raw = try JSONDecoder().decode(DwdRadarTimelineResponse.self, from: data)
        let frames = raw.frames.compactMap { frame -> RainRadarFrame? in
            guard let time = parseDwdDate(frame.time) else { return nil }
            return RainRadarFrame(time: time, path: "/tiles/\(frame.id)", isForecast: frame.isForecast)
        }
        guard !frames.isEmpty else { throw URLError(.cannotParseResponse) }

        return RainRadarTimeline(
            host: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            attribution: "DWD OpenData RV",
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
                           isForecast: false)
        }
        let forecast = (raw.radar.nowcast ?? []).map {
            RainRadarFrame(time: Date(timeIntervalSince1970: TimeInterval($0.time)),
                           path: $0.path,
                           isForecast: true)
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
        guard let url = Bundle.main.url(forResource: "LocalConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let config = try? PropertyListDecoder().decode(LocalRainRadarConfig.self, from: data) else {
            return nil
        }
        let rawValue = config.dwdRadarTileBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }
        return URL(string: rawValue)
    }

    private static func parseDwdDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct CachedRadarTimeline: Codable {
    struct Frame: Codable {
        let time: Date
        let path: String
        let isForecast: Bool
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
            frames: frames.map { RainRadarFrame(time: $0.time, path: $0.path, isForecast: $0.isForecast) }
        )
    }
}

private struct LocalRainRadarConfig: Decodable {
    let dwdRadarTileBaseURL: String

    private enum CodingKeys: String, CodingKey {
        case dwdRadarTileBaseURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dwdRadarTileBaseURL = try container.decodeIfPresent(String.self, forKey: .dwdRadarTileBaseURL) ?? ""
    }
}

private struct DwdRadarTimelineResponse: Decodable {
    let tileMaxZoom: Int?
    let frames: [DwdRadarFrameResponse]
}

private struct DwdRadarFrameResponse: Decodable {
    let id: String
    let time: String
    let isForecast: Bool
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

// MARK: - DWD ICON-EU Forecast Service

enum DwdIconForecastService {

    private static let capabilitiesURL = URL(string:
        "https://maps.dwd.de/geoserver/dwd/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetCapabilities"
    )!
    private static let tileBase = "https://maps.dwd.de/geoserver/dwd/ows"
    // Hourly-resolution patterns first so the parser can abort early on the right layer.
    static let precipPatterns = ["TOTPREC_001H", "RR_001H", "PRECIP_001H",
                                  "TOTPREC", "PRECIP", "precipitation", "Niederschlag_RR"]

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    struct ForecastMeta: Sendable {
        let layerName: String
        let availableTimes: [Date]
    }

    static func loadFromCache() -> ForecastMeta? {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "dwd.iconeu.layerName"),
              let date = defaults.object(forKey: "dwd.iconeu.layerDate") as? Date,
              Date().timeIntervalSince(date) < 7 * 3600 else { return nil }
        let now = Date()
        // Use actual WMS times if stored; fall back to computed times.
        if let raw = defaults.array(forKey: "dwd.iconeu.times") as? [Double], !raw.isEmpty {
            let times = raw.map { Date(timeIntervalSince1970: $0) }.filter { $0 > now }
            if !times.isEmpty { return ForecastMeta(layerName: name, availableTimes: times) }
        }
        let times = computeExpectedTimes()
        return times.isEmpty ? nil : ForecastMeta(layerName: name, availableTimes: times)
    }

    static func saveToCache(_ layerName: String, times: [Date]) {
        UserDefaults.standard.set(layerName, forKey: "dwd.iconeu.layerName")
        UserDefaults.standard.set(Date(), forKey: "dwd.iconeu.layerDate")
        UserDefaults.standard.set(times.map { $0.timeIntervalSince1970 },
                                   forKey: "dwd.iconeu.times")
    }

    // Fallback when no WMS times are cached yet.
    static func computeExpectedTimes() -> [Date] {
        let sinceEpoch = Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970
        let runStart = Date(timeIntervalSince1970: floor(sinceEpoch / 21600.0) * 21600.0)
        let now = Date()
        return stride(from: 3600.0, through: 120 * 3600.0, by: 3600.0)
            .map { runStart.addingTimeInterval($0) }
            .filter { $0 > now }
    }

    static func fetchForecastMeta() async throws -> ForecastMeta {
        let request = URLRequest(url: capabilitiesURL,
                                 cachePolicy: .returnCacheDataElseLoad,
                                 timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let delegate = WMSCapabilitiesParser()
                let xml = XMLParser(data: data)
                xml.delegate = delegate
                xml.parse()
                if let meta = delegate.bestForecastMeta() {
                    cont.resume(returning: meta)
                } else {
                    cont.resume(throwing: URLError(.cannotParseResponse))
                }
            }
        }
    }

    static func tileURL(layerName: String, time: Date, x: Int, y: Int, zoom: Int) -> URL? {
        let bbox = webMercatorBBOX(x: x, y: y, zoom: zoom)
        let timeISO = isoFormatter.string(from: time)
        var c = URLComponents(string: tileBase)!
        c.queryItems = [
            URLQueryItem(name: "SERVICE",     value: "WMS"),
            URLQueryItem(name: "VERSION",     value: "1.3.0"),
            URLQueryItem(name: "REQUEST",     value: "GetMap"),
            URLQueryItem(name: "FORMAT",      value: "image/png"),
            URLQueryItem(name: "TRANSPARENT", value: "true"),
            URLQueryItem(name: "LAYERS",      value: layerName),
            URLQueryItem(name: "STYLES",      value: ""),
            URLQueryItem(name: "CRS",         value: "EPSG:3857"),
            URLQueryItem(name: "WIDTH",       value: "512"),
            URLQueryItem(name: "HEIGHT",      value: "512"),
            URLQueryItem(name: "BBOX",        value: bbox),
            URLQueryItem(name: "TIME",        value: timeISO),
        ]
        return c.url
    }

    private static func webMercatorBBOX(x: Int, y: Int, zoom: Int) -> String {
        let originShift = 20_037_508.342789244
        let tileMeters = originShift * 2.0 / pow(2.0, Double(zoom))
        let minX = -originShift + Double(x) * tileMeters
        let maxX = minX + tileMeters
        let maxY = originShift - Double(y) * tileMeters
        let minY = maxY - tileMeters
        return "\(minX),\(minY),\(maxX),\(maxY)"
    }
}

private final class WMSCapabilitiesParser: NSObject, XMLParserDelegate {

    private struct LayerData {
        var name = ""
        var times: [Date] = []
    }

    private var stack: [LayerData] = []
    private var chars = ""
    private var inTimeDimension = false
    private var matched: (name: String, times: [Date])?

    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func bestForecastMeta() -> DwdIconForecastService.ForecastMeta? {
        guard let m = matched, !m.times.isEmpty else { return nil }
        return DwdIconForecastService.ForecastMeta(layerName: m.name, availableTimes: m.times)
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?, qualifiedName _: String?,
                attributes attrs: [String: String] = [:]) {
        chars = ""
        if elementName == "Layer" {
            stack.append(LayerData())
        } else if elementName == "Dimension", attrs["name"]?.lowercased() == "time" {
            inTimeDimension = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        chars += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?, qualifiedName _: String?) {
        switch elementName {
        case "Name":
            if !stack.isEmpty {
                stack[stack.count - 1].name = chars.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "Dimension":
            if inTimeDimension, !stack.isEmpty {
                stack[stack.count - 1].times = parseTimes(chars)
            }
            inTimeDimension = false
        case "Layer":
            if let layer = stack.last {
                let isPrecip = DwdIconForecastService.precipPatterns.contains { layer.name.contains($0) }
                if isPrecip, !layer.times.isEmpty {
                    let now = Date()
                    let future = layer.times.filter { $0 > now && $0 <= now.addingTimeInterval(120 * 3600) }
                    if !future.isEmpty {
                        // Prefer hourly layers (_001H / _1H) over longer accumulation periods.
                        let isHourly = layer.name.contains("001H") || layer.name.contains("_1H")
                        if matched == nil {
                            matched = (layer.name, future)
                            if isHourly { parser.abortParsing() }  // ideal match – stop early
                        } else if isHourly {
                            matched = (layer.name, future)          // upgrade to hourly
                            parser.abortParsing()
                        }
                    }
                }
                stack.removeLast()
            }
        default:
            break
        }
        chars = ""
    }

    private func parseTimes(_ raw: String) -> [Date] {
        var dates: [Date] = []
        for part in raw.components(separatedBy: ",") {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let chunks = p.components(separatedBy: "/")
            if chunks.count == 3,
               let start = parseDate(chunks[0]),
               let end   = parseDate(chunks[1]) {
                let step = parseDuration(chunks[2])
                if step > 0 {
                    var t = start
                    while t <= end { dates.append(t); t = t.addingTimeInterval(step) }
                    continue
                }
            }
            if let d = parseDate(p) { dates.append(d) }
        }
        return dates
    }

    private func parseDate(_ s: String) -> Date? {
        Self.isoFrac.date(from: s) ?? Self.iso.date(from: s)
    }

    private func parseDuration(_ s: String) -> TimeInterval {
        guard s.hasPrefix("PT") else { return 0 }
        let rest = s.dropFirst(2)
        if rest.hasSuffix("H"), let h = Double(rest.dropLast()) { return h * 3600 }
        if rest.hasSuffix("M"), let m = Double(rest.dropLast()) { return m * 60 }
        return 0
    }
}
