// RainRadarService.swift
import Foundation

struct RainRadarFrame: Identifiable, Equatable {
    let time: Date
    let path: String
    let isForecast: Bool

    var id: String { "\(path)-\(Int(time.timeIntervalSince1970))" }
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
