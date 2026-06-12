// WeatherKitService.swift
// Requires: WeatherKit capability in Xcode + signed entitlement (developer.apple.com)
import Foundation
import CoreLocation
import WeatherKit

final class WeatherKitService: WeatherProviding, @unchecked Sendable {

    let modelName = "WeatherKit"
    let weight    = ModelWeights.weatherKit
    static let shared = WeatherKitService()
    private let service = WeatherService.shared
    private let statusKey = "weatherKitLastStatus_v1"
    private init() {}

    // MARK: - Fetch
    func fetchWeather(for location: CLLocation) async throws -> ModelWeatherData {
        do {
            let core: (WeatherKit.CurrentWeather, Forecast<HourWeather>, Forecast<DayWeather>) =
                try await service.weather(for: location, including: .current, .hourly, .daily)
            async let minuteForecast: Forecast<MinuteWeather>? = try? await service.weather(for: location, including: .minute)
            #if DEBUG
            print("[WeatherKit] OK")
            #endif
            UserDefaults.standard.set("aktiv", forKey: statusKey)
            return parse(current: core.0, hourlyForecast: core.1, dailyForecast: core.2, minuteForecast: await minuteForecast)
        } catch {
            #if DEBUG
            print("[WeatherKit] failed: \(error)")
            #endif
            UserDefaults.standard.set(diagnosticMessage(for: error), forKey: statusKey)
            throw WeatherError.networkError(error)
        }
    }

    private func diagnosticMessage(for error: Error) -> String {
        let nsError = error as NSError
        let rawMessage = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"

        if rawMessage.contains("WDSJWTAuthenticatorServiceListener") {
            return "WeatherKit Authentifizierung fehlgeschlagen (JWT Fehler 2). App-ID/WeatherKit Capability im Apple Developer Portal prüfen."
        }

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "Keine Internetverbindung"
            case NSURLErrorCannotFindHost:
                return "Apple WeatherKit Host nicht erreichbar (DNS -1003)"
            case NSURLErrorTimedOut:
                return "Zeitüberschreitung beim Apple WeatherKit Dienst"
            case NSURLErrorCannotConnectToHost:
                return "Keine Verbindung zum Apple WeatherKit Dienst"
            default:
                return "Netzwerkfehler \(nsError.code): \(nsError.localizedDescription)"
            }
        }

        let domain = nsError.domain
            .replacingOccurrences(of: "WeatherDaemon.", with: "")
            .replacingOccurrences(of: "com.apple.", with: "")
        return "\(domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    // MARK: - Parse
    private func parse(
        current cur: WeatherKit.CurrentWeather,
        hourlyForecast: Forecast<HourWeather>,
        dailyForecast: Forecast<DayWeather>,
        minuteForecast: Forecast<MinuteWeather>?
    ) -> ModelWeatherData {
        let now = Date()

        let hourly: [ModelHourlyPoint] = hourlyForecast.forecast
            .filter { $0.date > now.addingTimeInterval(-3_600) }
            .prefix(240)
            .map { h in
                ModelHourlyPoint(
                    time:              h.date,
                    temp:              h.temperature.converted(to: .celsius).value,
                    precipProbability: h.precipitationChance * 100,
                    precipMm:          h.precipitationAmount.converted(to: .millimeters).value,
                    windSpeed:         h.wind.speed.converted(to: .kilometersPerHour).value,
                    wmoCode:           wkToWMO(h.condition),
                    isDay:             h.isDaylight
                )
            }

        let daily: [ModelDailyPoint] = dailyForecast.forecast.map { d in
            ModelDailyPoint(
                date:              d.date,
                high:              d.highTemperature.converted(to: .celsius).value,
                low:               d.lowTemperature.converted(to: .celsius).value,
                precipProbability: d.precipitationChance * 100,
                precipSum:         d.precipitationAmount.converted(to: .millimeters).value,
                wmoCode:           wkToWMO(d.condition),
                sunrise:           d.sun.sunrise,
                sunset:            d.sun.sunset,
                uvMax:             Double(d.uvIndex.value),
                windMax:           d.wind.speed.converted(to: .kilometersPerHour).value,
                sunshineDuration:  0   // WeatherKit doesn't expose sunshine duration
            )
        }

        // MinuteForecast: ~60 slots of 1-min data (availability varies by region)
        // precipitationIntensity is Measurement<UnitSpeed> (mm/h as length/time)
        // Convert via m/s → mm/h: 1 m/s = 3,600,000 mm/h
        let minutely: [ModelMinutelyPoint] = (minuteForecast?.forecast ?? [])
            .prefix(60)
            .map { m in
                ModelMinutelyPoint(
                    time:              m.date,
                    precipMm:          m.precipitationIntensity.converted(to: .metersPerSecond).value * 3_600_000 / 60,
                    precipProbability: m.precipitationChance * 100
                )
            }

        return ModelWeatherData(
            modelName:            modelName,
            weight:               weight,
            currentTemp:          cur.temperature.converted(to: .celsius).value,
            currentFeelsLike:     cur.apparentTemperature.converted(to: .celsius).value,
            currentHumidity:      Int(cur.humidity * 100),
            currentWindSpeed:     cur.wind.speed.converted(to: .kilometersPerHour).value,
            currentWindDirection: Int(cur.wind.direction.value),
            currentPressure:      cur.pressure.converted(to: .hectopascals).value,
            currentVisibility:    cur.visibility.converted(to: .kilometers).value,
            currentUVIndex:       Double(cur.uvIndex.value),
            currentIsDay:         cur.isDaylight,
            currentPrecipitation: cur.precipitationIntensity.converted(to: .metersPerSecond).value * 3_600_000,
            currentWMOCode:       wkToWMO(cur.condition),
            currentCloudCover:    Int(cur.cloudCover * 100),
            hourly:   hourly,
            daily:    daily,
            minutely: minutely
        )
    }

    // MARK: - Condition mapping
    private func wkToWMO(_ condition: WeatherCondition) -> Int {
        switch condition {
        case .clear, .mostlyClear, .hot, .frigid:                       return 0
        case .partlyCloudy:                                             return 2
        case .mostlyCloudy, .cloudy, .breezy, .windy:                   return 3
        case .foggy, .haze, .smoky, .blowingDust:                       return 45
        case .drizzle:                                                  return 53
        case .freezingDrizzle:                                          return 55
        case .rain, .sunShowers:                                        return 63
        case .freezingRain, .heavyRain:                                 return 65
        case .flurries, .snow:                                          return 73
        case .sunFlurries:                                              return 85
        case .heavySnow, .blizzard, .blowingSnow:                       return 75
        case .sleet, .wintryMix:                                        return 68
        case .isolatedThunderstorms, .scatteredThunderstorms:           return 80
        case .thunderstorms, .strongStorms:                             return 95
        case .hail:                                                     return 96
        case .tropicalStorm, .hurricane:                                return 99
        @unknown default:                                               return 3
        }
    }
}
