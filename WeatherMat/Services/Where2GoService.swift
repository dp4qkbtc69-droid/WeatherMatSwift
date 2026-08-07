import Foundation
import CoreLocation

final class Where2GoService: Sendable {
    static let shared = Where2GoService()
    private let cacheTTL: TimeInterval = 30 * 60
    private let cache = Where2GoCache()

    private init() {}

    func findSpots(
        from origin: SavedLocation,
        radiusKm: Int,
        window: Where2GoWindow,
        sortMode: Where2GoSortMode
    ) async -> [Where2GoSpot] {
        let cacheKey = Where2GoCacheKey(origin: origin, radiusKm: radiusKm, window: window)
        if let cached = await cache.value(for: cacheKey, maxAge: cacheTTL) {
            return sorted(cached, by: sortMode)
        }

        let originCoordinate = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        let candidates = candidateCoordinates(from: originCoordinate, radiusKm: radiusKm)

        let forecasts = await withTaskGroup(of: (Where2GoCandidate, Where2GoForecastDay?).self) { group in
            for candidate in candidates {
                group.addTask {
                    let day = try? await self.fetchBestDay(for: candidate.coordinate, window: window)
                    return (candidate, day)
                }
            }

            var results: [(Where2GoCandidate, Where2GoForecastDay)] = []
            for await (candidate, day) in group {
                if let day {
                    results.append((candidate, day))
                }
            }
            return results
        }

        let bestWeatherSpots = forecasts.map { candidate, day in
            makeSpot(candidate: candidate, forecast: day, window: window)
        }
        .sorted(by: bestWeatherSort)
        .prefix(10)

        let named = await nameTopSpots(Array(bestWeatherSpots))
        await cache.store(named, for: cacheKey)
        return sorted(named, by: sortMode)
    }

    private func sorted(_ spots: [Where2GoSpot], by mode: Where2GoSortMode) -> [Where2GoSpot] {
        switch mode {
        case .best:
            return spots.sorted(by: bestWeatherSort)
        case .nearest:
            return spots.sorted {
                if $0.distanceKm == $1.distanceKm { return bestWeatherSort($0, $1) }
                return $0.distanceKm < $1.distanceKm
            }
        }
    }

    private func bestWeatherSort(_ lhs: Where2GoSpot, _ rhs: Where2GoSpot) -> Bool {
        if lhs.score == rhs.score {
            if abs(lhs.sunshineHours - rhs.sunshineHours) < 0.1 {
                return lhs.distanceKm < rhs.distanceKm
            }
            return lhs.sunshineHours > rhs.sunshineHours
        }
        return lhs.score > rhs.score
    }

    // Reduced from 3 rings × 12 bearings (37 parallel requests) to 2 rings ×
    // 8 bearings (17 requests) — still covers the radius in every direction,
    // just at a coarser resolution, for noticeably less network/battery use
    // per "Wohin?" lookup.
    private func candidateCoordinates(from origin: CLLocationCoordinate2D, radiusKm: Int) -> [Where2GoCandidate] {
        let rings = [0.5, 1.0].map { Double(radiusKm) * $0 }
        let bearings = stride(from: 0.0, to: 360.0, by: 45.0)
        var candidates: [Where2GoCandidate] = [
            Where2GoCandidate(coordinate: origin, distanceKm: 0, bearing: nil)
        ]

        for ring in rings {
            for bearing in bearings {
                candidates.append(
                    Where2GoCandidate(
                        coordinate: destination(from: origin, distanceKm: ring, bearingDegrees: bearing),
                        distanceKm: Int(ring.rounded()),
                        bearing: bearing
                    )
                )
            }
        }
        return candidates
    }

    private func destination(
        from origin: CLLocationCoordinate2D,
        distanceKm: Double,
        bearingDegrees: Double
    ) -> CLLocationCoordinate2D {
        let radius = 6_371.0
        let angularDistance = distanceKm / radius
        let bearing = bearingDegrees * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180

        let lat2 = asin(
            sin(lat1) * cos(angularDistance)
            + cos(lat1) * sin(angularDistance) * cos(bearing)
        )
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angularDistance) * cos(lat1),
            cos(angularDistance) - sin(lat1) * sin(lat2)
        )

        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    private func fetchBestDay(
        for coordinate: CLLocationCoordinate2D,
        window: Where2GoWindow
    ) async throws -> Where2GoForecastDay? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: "\(coordinate.latitude)"),
            .init(name: "longitude", value: "\(coordinate.longitude)"),
            .init(name: "models", value: "best_match"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,sunshine_duration"),
            .init(name: "wind_speed_unit", value: "kmh"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "14")
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let decoded = try JSONDecoder().decode(Where2GoResponse.self, from: data)
        let days = decoded.daily.days
        let wantedDates = dates(for: window)
        let matching = days.filter { day in
            wantedDates.contains { Calendar.current.isDate($0, inSameDayAs: day.date) }
        }

        return matching.max { score(day: $0) < score(day: $1) }
    }

    private func dates(for window: Where2GoWindow) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        switch window {
        case .tomorrow:
            return [calendar.date(byAdding: .day, value: 1, to: today) ?? today]
        case .nextWeekend:
            let weekday = calendar.component(.weekday, from: today)
            let daysUntilSaturday = (7 - weekday + 7) % 7
            let saturdayOffset = daysUntilSaturday == 0 ? 7 : daysUntilSaturday
            guard let saturday = calendar.date(byAdding: .day, value: saturdayOffset, to: today),
                  let sunday = calendar.date(byAdding: .day, value: 1, to: saturday)
            else { return [] }
            return [saturday, sunday]
        }
    }

    private func makeSpot(
        candidate: Where2GoCandidate,
        forecast: Where2GoForecastDay,
        window: Where2GoWindow
    ) -> Where2GoSpot {
        Where2GoSpot(
            name: fallbackName(for: candidate),
            coordinate: candidate.coordinate,
            distanceKm: candidate.distanceKm,
            direction: directionName(for: candidate.bearing),
            score: Int(score(day: forecast).rounded()),
            temperature: Int(forecast.temperatureMax.rounded()),
            sunshineHours: forecast.sunshineDuration / 3600,
            precipitationProbability: Int(forecast.precipitationProbability.rounded()),
            windSpeed: Int(forecast.windMax.rounded()),
            condition: WMOCode.condition(for: forecast.weatherCode),
            dateLabel: dateLabel(for: forecast.date, window: window)
        )
    }

    private func score(day: Where2GoForecastDay) -> Double {
        let sunshineHours = day.sunshineDuration / 3600
        let sunScore = min(38, sunshineHours * 4.8)
        let rainScore = max(0, 28 - day.precipitationProbability * 0.28 - day.precipitationSum * 2.0)
        let comfortScore = max(0, 22 - abs(day.temperatureMax - 22) * 1.15)
        let windScore = max(0, 12 - max(0, day.windMax - 18) * 0.35)
        return min(100, max(0, sunScore + rainScore + comfortScore + windScore))
    }

    private func nameTopSpots(_ spots: [Where2GoSpot]) async -> [Where2GoSpot] {
        var named: [Where2GoSpot] = []
        for spot in spots {
            let location = CLLocation(latitude: spot.coordinate.latitude, longitude: spot.coordinate.longitude)
            let resolvedName = await GeocodingService.shared.reverseGeocode(location)
            let name = GeocodingService.isCoordinateFallback(resolvedName)
                ? fallbackName(for: Where2GoCandidate(coordinate: spot.coordinate, distanceKm: spot.distanceKm, bearing: bearing(for: spot.direction)))
                : resolvedName
            named.append(
                Where2GoSpot(
                    name: name,
                    coordinate: spot.coordinate,
                    distanceKm: spot.distanceKm,
                    direction: spot.direction,
                    score: spot.score,
                    temperature: spot.temperature,
                    sunshineHours: spot.sunshineHours,
                    precipitationProbability: spot.precipitationProbability,
                    windSpeed: spot.windSpeed,
                    condition: spot.condition,
                    dateLabel: spot.dateLabel
                )
            )
        }
        return named
    }

    private func fallbackName(for candidate: Where2GoCandidate) -> String {
        if candidate.distanceKm == 0 { return "Hier" }
        return "\(directionName(for: candidate.bearing)), \(candidate.distanceKm) km"
    }

    private func bearing(for direction: String) -> Double? {
        switch direction {
        case "N": return 0
        case "NO": return 45
        case "O": return 90
        case "SO": return 135
        case "S": return 180
        case "SW": return 225
        case "W": return 270
        case "NW": return 315
        default: return nil
        }
    }

    private func directionName(for bearing: Double?) -> String {
        guard let bearing else { return "Vor Ort" }
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int(((bearing + 22.5) / 45).rounded(.down)) % names.count
        return names[index]
    }

    private func dateLabel(for date: Date, window: Where2GoWindow) -> String {
        switch window {
        case .tomorrow:
            return "Morgen"
        case .nextWeekend:
            return date.formatted(.dateTime.weekday(.wide).locale(.init(identifier: "de_DE")))
        }
    }
}

private struct Where2GoCandidate {
    let coordinate: CLLocationCoordinate2D
    let distanceKm: Int
    let bearing: Double?
}

private struct Where2GoCacheKey: Hashable {
    let lat: Int
    let lon: Int
    let radiusKm: Int
    let window: Where2GoWindow
    let dayKey: String

    init(origin: SavedLocation, radiusKm: Int, window: Where2GoWindow) {
        lat = Int((origin.latitude * 100).rounded())
        lon = Int((origin.longitude * 100).rounded())
        self.radiusKm = radiusKm
        self.window = window
        dayKey = Self.dayFormatter.string(from: Date())
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private actor Where2GoCache {
    private struct Entry {
        let spots: [Where2GoSpot]
        let createdAt: Date
    }

    private var entries: [Where2GoCacheKey: Entry] = [:]

    func value(for key: Where2GoCacheKey, maxAge: TimeInterval) -> [Where2GoSpot]? {
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.createdAt) < maxAge
        else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.spots
    }

    func store(_ spots: [Where2GoSpot], for key: Where2GoCacheKey) {
        entries[key] = Entry(spots: spots, createdAt: Date())
    }
}

private struct Where2GoResponse: Decodable {
    let daily: Daily

    struct Daily: Decodable {
        let time: [String]
        let weather_code: [Int?]
        let temperature_2m_max: [Double?]
        let precipitation_sum: [Double?]
        let precipitation_probability_max: [Double?]
        let wind_speed_10m_max: [Double?]
        let sunshine_duration: [Double?]

        var days: [Where2GoForecastDay] {
            time.indices.compactMap { index in
                guard let date = Self.dateFormatter.date(from: time[index]),
                      let weatherCode = weather_code[safe: index] ?? nil,
                      let temperature = temperature_2m_max[safe: index] ?? nil
                else { return nil }

                return Where2GoForecastDay(
                    date: date,
                    weatherCode: weatherCode,
                    temperatureMax: temperature,
                    precipitationProbability: (precipitation_probability_max[safe: index] ?? nil) ?? 0,
                    precipitationSum: (precipitation_sum[safe: index] ?? nil) ?? 0,
                    windMax: (wind_speed_10m_max[safe: index] ?? nil) ?? 0,
                    sunshineDuration: (sunshine_duration[safe: index] ?? nil) ?? 0
                )
            }
        }

        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }()
    }
}
