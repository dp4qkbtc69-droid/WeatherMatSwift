// OpenMeteoService.swift
import Foundation
import CoreLocation

final class OpenMeteoService: WeatherProviding, @unchecked Sendable {

    let modelName: String
    let weight:    Double
    private let model: String

    // Per-model capability flags — different OpenMeteo models expose different variables.
    // Requesting an unsupported variable returns HTTP 400, silently dropping the whole model.
    private let supportsExtendedCurrent: Bool  // visibility, uv_index, precipitation in current
    private let supportsMinutely15:      Bool  // 15-min precipitation data
    private let supportsUVDaily:         Bool  // uv_index_max in daily
    private let supportsSunshineDaily:   Bool  // sunshine_duration in daily
    private let forecastHours:           Int   // max supported hourly horizon

    // ── Static instances ────────────────────────────────────────────────────
    static let bestMatch = OpenMeteoService(
        model: "best_match",    name: "OpenMeteo",      weight: ModelWeights.openMeteo,
        extendedCurrent: true,  minutely: true,  uvDaily: true,  sunshineDaily: true,  hours: 336
    )
    static let icon = OpenMeteoService(
        model: "icon_seamless", name: "OpenMeteo-ICON", weight: ModelWeights.iconSeamless,
        extendedCurrent: false, minutely: false, uvDaily: true,  sunshineDaily: true,  hours: 240
    )
    static let ecmwf = OpenMeteoService(
        model: "ecmwf_ifs025",  name: "ECMWF",          weight: ModelWeights.ecmwf,
        extendedCurrent: false, minutely: false, uvDaily: false, sunshineDaily: false, hours: 240
    )

    private init(model: String, name: String, weight: Double,
                 extendedCurrent: Bool, minutely: Bool,
                 uvDaily: Bool, sunshineDaily: Bool, hours: Int) {
        self.model                  = model
        self.modelName              = name
        self.weight                 = weight
        self.supportsExtendedCurrent = extendedCurrent
        self.supportsMinutely15     = minutely
        self.supportsUVDaily        = uvDaily
        self.supportsSunshineDaily  = sunshineDaily
        self.forecastHours          = hours
    }

    // MARK: - Fetch
    func fetchWeather(for location: CLLocation) async throws -> ModelWeatherData {
        let url = buildURL(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            #if DEBUG
            print("[\(modelName)] HTTP \(status) — fetch failed")
            #endif
            throw WeatherError.notAvailable
        }
        #if DEBUG
        print("[\(modelName)] OK")
        #endif
        do {
            return try parse(JSONDecoder().decode(OMResponse.self, from: data))
        } catch {
            #if DEBUG
            print("[\(modelName)] decode error: \(error)")
            #endif
            throw WeatherError.decodingError(error)
        }
    }

    // MARK: - URL builder (model-specific parameter sets)
    private func buildURL(lat: Double, lon: Double) -> URL {
        // current — extended params only available for best_match
        let currentParams: String = supportsExtendedCurrent
            ? "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,surface_pressure,visibility,uv_index,is_day,precipitation,cloud_cover"
            : "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,surface_pressure,is_day,cloud_cover"

        // daily — uv_index_max and sunshine_duration not in ECMWF
        let dailyParams: String = {
            var p = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,sunrise,sunset,wind_speed_10m_max"
            if supportsUVDaily        { p += ",uv_index_max" }
            if supportsSunshineDaily  { p += ",sunshine_duration" }
            return p
        }()

        var items: [URLQueryItem] = [
            .init(name: "latitude",        value: "\(lat)"),
            .init(name: "longitude",       value: "\(lon)"),
            .init(name: "models",          value: model),
            .init(name: "current",         value: currentParams),
            .init(name: "hourly",          value: "temperature_2m,weather_code,precipitation_probability,precipitation,wind_speed_10m,is_day,cloud_cover"),
            .init(name: "daily",           value: dailyParams),
            .init(name: "wind_speed_unit", value: "kmh"),
            .init(name: "timezone",        value: "auto"),
            .init(name: "forecast_days",   value: "14"),
            .init(name: "forecast_hours",  value: "\(forecastHours)"),
        ]
        if supportsMinutely15 {
            items += [
                .init(name: "minutely_15",           value: "precipitation,precipitation_probability,weather_code"),
                .init(name: "forecast_minutely_15",  value: "8"),
            ]
        }

        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = items
        return c.url!
    }

    // MARK: - Parse
    private func parse(_ r: OMResponse) -> ModelWeatherData {
        let now = Date()
        let cur = r.current
        let h   = r.hourly
        let d   = r.daily

        let hourly: [ModelHourlyPoint] = h.time.indices.compactMap { i in
            guard let t    = dt(h.time[i]), t > now.addingTimeInterval(-3600),
                  let temp = h.temperature_2m[safe: i] ?? nil,   // skip null temps
                  let wmo  = h.weather_code[safe: i] ?? nil       // skip null wmo
            else { return nil }
            return ModelHourlyPoint(
                time:              t,
                temp:              temp,
                precipProbability: h.precipitation_probability[safe: i] ?? 0,
                precipMm:          h.precipitation[safe: i] ?? 0,
                windSpeed:         h.wind_speed_10m[safe: i] ?? 0,
                wmoCode:           wmo,
                isDay:             (h.is_day?[safe: i] ?? 1) == 1
            )
        }
        let daily: [ModelDailyPoint] = d.time.indices.compactMap { i in
            // Skip days where core values are null (model forecast edge)
            guard let wmo  = d.weather_code[safe: i] ?? nil,
                  let high = d.temperature_2m_max[safe: i] ?? nil,
                  let low  = d.temperature_2m_min[safe: i] ?? nil
            else { return nil }
            return ModelDailyPoint(
                date:              dd(d.time[i]) ?? now,
                high:              high,
                low:               low,
                precipProbability: (d.precipitation_probability_max?[safe: i] ?? nil) ?? 0,
                precipSum:         (d.precipitation_sum?[safe: i]               ?? nil) ?? 0,
                wmoCode:           wmo,
                sunrise:           d.sunrise.flatMap { dt($0[safe: i] ?? "") },
                sunset:            d.sunset.flatMap  { dt($0[safe: i] ?? "") },
                uvMax:             (d.uv_index_max?[safe: i]       ?? nil) ?? 0,
                windMax:           (d.wind_speed_10m_max?[safe: i]  ?? nil) ?? 0,
                sunshineDuration:  (d.sunshine_duration?[safe: i]   ?? nil) ?? 0
            )
        }
        let minutely: [ModelMinutelyPoint] = (r.minutely_15?.time ?? []).indices.compactMap { i in
            guard let t = dt(r.minutely_15!.time[i]),
                  t >= now.addingTimeInterval(-900) else { return nil }
            return ModelMinutelyPoint(
                time:              t,
                precipMm:          r.minutely_15?.precipitation?[safe: i] ?? 0,
                precipProbability: r.minutely_15?.precipitation_probability?[safe: i] ?? 0
            )
        }
        return ModelWeatherData(
            modelName:            modelName,
            weight:               weight,
            currentTemp:          cur.temperature_2m,
            currentFeelsLike:     cur.apparent_temperature,
            currentHumidity:      cur.relative_humidity_2m,
            currentWindSpeed:     cur.wind_speed_10m,
            currentWindDirection: cur.wind_direction_10m,
            currentPressure:      cur.surface_pressure,
            currentVisibility:    (cur.visibility ?? 10_000) / 1_000,
            currentUVIndex:       cur.uv_index ?? 0,
            currentIsDay:         cur.is_day == 1,
            currentPrecipitation: cur.precipitation ?? 0,
            currentWMOCode:       cur.weather_code,
            currentCloudCover:    cur.cloud_cover ?? 50,
            hourly:               hourly,
            daily:                daily,
            minutely:             minutely
        )
    }

    // MARK: - Date formatters
    private let dtFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"; return f
    }()
    private let dFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private func dt(_ s: String) -> Date? { dtFmt.date(from: s) }
    private func dd(_ s: String) -> Date? { dFmt.date(from: s) }
}

// MARK: - Decodable
private struct OMResponse: Decodable {
    let current: OMCurrent; let hourly: OMHourly; let daily: OMDaily; let minutely_15: OMMin15?
}
private struct OMCurrent: Decodable {
    let temperature_2m, apparent_temperature, wind_speed_10m, surface_pressure: Double
    let relative_humidity_2m, wind_direction_10m, weather_code, is_day: Int
    let visibility, uv_index, precipitation: Double?
    let cloud_cover: Int?
}
private struct OMHourly: Decodable {
    let time: [String]
    let temperature_2m: [Double?]   // nullable — some models emit null at forecast edges
    let weather_code:   [Int?]      // nullable for same reason
    let precipitation_probability: [Double]
    let precipitation: [Double]
    let wind_speed_10m: [Double]
    let is_day: [Int]?
    let cloud_cover: [Int]?
    private enum CK: String, CodingKey {
        case time, temperature_2m, weather_code, precipitation_probability, precipitation,
             wind_speed_10m, is_day, cloud_cover
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CK.self)
        time                      = try  c.decode([String].self,   forKey: .time)
        temperature_2m            = (try? c.decode([Double?].self, forKey: .temperature_2m)) ?? []
        weather_code              = (try? c.decode([Int?].self,    forKey: .weather_code))   ?? []
        precipitation_probability = (try? c.decode([Double?].self, forKey: .precipitation_probability))?.map { $0 ?? 0 } ?? []
        precipitation             = (try? c.decode([Double?].self, forKey: .precipitation))?.map { $0 ?? 0 } ?? []
        wind_speed_10m            = (try? c.decode([Double?].self, forKey: .wind_speed_10m))?.map { $0 ?? 0 } ?? []
        is_day                    = try? c.decode([Int].self,      forKey: .is_day)
        cloud_cover               = try? c.decode([Int].self,      forKey: .cloud_cover)
    }
}
private struct OMDaily: Decodable {
    let time: [String]
    let weather_code: [Int?]          // nullable — some models emit null at forecast edges
    let temperature_2m_max: [Double?] // nullable for same reason
    let temperature_2m_min: [Double?]
    let precipitation_sum: [Double?]?
    let precipitation_probability_max: [Double?]?
    let sunrise, sunset: [String]?
    let uv_index_max:        [Double?]?   // nullable elements at forecast edges
    let wind_speed_10m_max:  [Double?]?
    let sunshine_duration:   [Double?]?
}
private struct OMMin15: Decodable {
    let time: [String]; let precipitation, precipitation_probability: [Double]?
}
