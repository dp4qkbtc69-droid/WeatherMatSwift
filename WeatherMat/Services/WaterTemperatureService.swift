// WaterTemperatureService.swift  –  Sea surface temperature + tides via Open-Meteo Marine API
import Foundation
import CoreLocation
import os

/// Combined result of one Marine API call — both fields are independently nil
/// (not an error) when there's no sea grid cell nearby (inland location) or,
/// for `tide`, when the location's tidal range is too small to be meaningful
/// (e.g. Baltic Sea) — the UI simply omits the relevant part of the card.
struct MarineConditions {
    let waterTemperature: WaterTemperatureData?
    let tide: TideData?
}

final class WaterTemperatureService: Sendable {

    private static let logger = Logger(subsystem: "de.praxishartlep.weathermat", category: "WaterTemperature")
    static let shared = WaterTemperatureService()
    private init() {}

    /// Minimum high/low spread (metres) over the forecast window for tide
    /// info to be worth showing. Below this — e.g. Baltic Sea, most inland
    /// seas — the hourly wiggle is noise, not a usable tide.
    private static let minimumTidalRangeMeters = 0.2

    func fetch(for location: CLLocation) async throws -> MarineConditions {
        var c = URLComponents(string: "https://marine-api.open-meteo.com/v1/marine")!
        c.queryItems = [
            .init(name: "latitude", value: "\(location.coordinate.latitude)"),
            .init(name: "longitude", value: "\(location.coordinate.longitude)"),
            .init(name: "current", value: "sea_surface_temperature"),
            .init(name: "hourly", value: "sea_level_height_msl"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "cell_selection", value: "sea"),
            .init(name: "timezone", value: "auto"),
        ]
        guard let url = c.url else { throw WeatherError.notAvailable }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            Self.logger.warning("HTTP error fetching marine data")
            throw WeatherError.notAvailable
        }

        let decoded = try JSONDecoder().decode(MarineResponse.self, from: data)

        let waterTemperature: WaterTemperatureData? = {
            guard let current = decoded.current,
                  let temp = current.sea_surface_temperature,
                  let time = Self.isoFormat.date(from: current.time)
            else { return nil }
            return WaterTemperatureData(temperature: temp, measuredAt: time)
        }()

        return MarineConditions(
            waterTemperature: waterTemperature,
            tide: Self.deriveTide(from: decoded.hourly)
        )
    }

    /// Open-Meteo's marine API only exposes the raw hourly sea-level curve,
    /// not discrete tide events — so "next high/low tide" is derived here by
    /// finding local extrema (turning points) in that curve.
    private static func deriveTide(from hourly: MarineHourly?) -> TideData? {
        guard let hourly else { return nil }
        let now = Date()

        let samples: [(time: Date, height: Double)] = zip(hourly.time, hourly.sea_level_height_msl)
            .compactMap { timeString, height in
                guard let height, let time = isoFormat.date(from: timeString) else { return nil }
                return (time, height)
            }
        guard samples.count >= 3 else { return nil }

        let heights = samples.map(\.height)
        let range = (heights.max() ?? 0) - (heights.min() ?? 0)
        guard range >= minimumTidalRangeMeters else { return nil }

        var events: [TideData.Event] = []
        for i in 1..<(samples.count - 1) {
            let prev = samples[i - 1].height, cur = samples[i].height, next = samples[i + 1].height
            if cur > prev, cur > next {
                events.append(TideData.Event(type: .high, time: samples[i].time, height: cur))
            } else if cur < prev, cur < next {
                events.append(TideData.Event(type: .low, time: samples[i].time, height: cur))
            }
        }

        let upcoming = events.filter { $0.time > now }.sorted { $0.time < $1.time }
        guard !upcoming.isEmpty else { return nil }

        let currentHeight = samples.last { $0.time <= now }?.height ?? samples[0].height
        return TideData(currentHeight: currentHeight, nextEvents: Array(upcoming.prefix(2)))
    }

    private static let isoFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
}

// MARK: - Decodable
private struct MarineResponse: Decodable {
    let current: MarineCurrent?
    let hourly: MarineHourly?
}
private struct MarineCurrent: Decodable {
    let time: String
    let sea_surface_temperature: Double?
}
private struct MarineHourly: Decodable {
    let time: [String]
    let sea_level_height_msl: [Double?]
}
