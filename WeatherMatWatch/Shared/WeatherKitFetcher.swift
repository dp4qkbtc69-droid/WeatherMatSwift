// WeatherKitFetcher.swift
// Direct WeatherKit fetch for the watch — deliberately independent of the
// iPhone app's multi-model ensemble so the watch (Ultra: own GPS + cellular)
// stays fully functional without the phone nearby.
import Foundation
@preconcurrency import CoreLocation
@preconcurrency import WeatherKit

enum WeatherKitFetcher {

    enum FetchError: Error { case noDailyEntry }

    static func fetchSnapshot(for location: WatchLocation) async throws -> WatchWeatherSnapshot {
        let clLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        let service = WeatherService.shared

        let (current, hourlyForecast, dailyForecast) = try await service.weather(
            for: clLocation, including: .current, .hourly, .daily
        )

        guard let today = dailyForecast.forecast.first else { throw FetchError.noDailyEntry }

        let (symbol, label) = conditionIcon(current.condition, isDay: current.isDaylight)
        let (rainText, rainSymbol) = rainSummary(current: current, hourly: hourlyForecast)

        return WatchWeatherSnapshot(
            locationName:   location.name,
            currentTemp:    Int(current.temperature.converted(to: .celsius).value.rounded()),
            highTemp:       Int(today.highTemperature.converted(to: .celsius).value.rounded()),
            lowTemp:        Int(today.lowTemperature.converted(to: .celsius).value.rounded()),
            sfSymbol:       symbol,
            conditionLabel: label,
            rainSummary:    rainText,
            rainSFSymbol:   rainSymbol,
            fetchedAt:      Date()
        )
    }

    /// Maps a fetch failure to a short, actionable message — mirrors
    /// WeatherKitService.diagnosticMessage(for:) on the iOS side so the same
    /// class of error (e.g. JWT auth) is recognisable in both places.
    static func diagnosticMessage(for error: Error) -> String {
        let nsError = error as NSError
        let rawMessage = "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"

        if rawMessage.contains("WDSJWTAuthenticatorServiceListener") {
            return "WeatherKit-Auth fehlgeschlagen (JWT). Capability/Provisioning prüfen."
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet: return "Keine Internetverbindung"
            case NSURLErrorCannotFindHost:         return "WeatherKit-Host nicht erreichbar"
            case NSURLErrorTimedOut:               return "Zeitüberschreitung beim Wetterdienst"
            case NSURLErrorCannotConnectToHost:    return "Keine Verbindung zum Wetterdienst"
            default:                               return "Netzwerkfehler \(nsError.code)"
            }
        }
        let domain = nsError.domain
            .replacingOccurrences(of: "WeatherDaemon.", with: "")
            .replacingOccurrences(of: "com.apple.", with: "")
        return "\(domain) \(nsError.code)"
    }

    // MARK: - Rain timing ("regnet es heute noch, wann, und bis wann?")
    private static func rainSummary(
        current: WeatherKit.CurrentWeather,
        hourly: Forecast<HourWeather>
    ) -> (text: String, sfSymbol: String) {
        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        func isRainHour(_ hour: HourWeather) -> Bool {
            hour.precipitationChance >= 0.4 || hour.precipitationAmount.converted(to: .millimeters).value >= 0.2
        }

        func nextClearHour(after date: Date) -> HourWeather? {
            hourly.forecast.first { hour in
                calendar.isDateInToday(hour.date) && hour.date > date && !isRainHour(hour)
            }
        }

        let currentRateMmPerHour = current.precipitationIntensity.converted(to: .metersPerSecond).value * 3_600_000
        if currentRateMmPerHour >= 0.1 {
            if let clearHour = nextClearHour(after: now) {
                return ("Regen bis \(formatter.string(from: clearHour.date))", "cloud.rain.fill")
            }
            return ("Regnet gerade", "cloud.rain.fill")
        }

        let nextRainHour = hourly.forecast.first { hour in
            calendar.isDateInToday(hour.date) && hour.date > now && isRainHour(hour)
        }

        if let nextRainHour {
            if let clearHour = nextClearHour(after: nextRainHour.date) {
                let start = formatter.string(from: nextRainHour.date)
                let end = formatter.string(from: clearHour.date)
                return ("Regen \(start)–\(end)", "cloud.rain.fill")
            }
            return ("Regen ab \(formatter.string(from: nextRainHour.date))", "cloud.rain.fill")
        }

        return ("Heute kein Regen mehr", "checkmark.circle.fill")
    }

    // MARK: - Condition → SF Symbol / German label
    private static func conditionIcon(_ condition: WeatherCondition, isDay: Bool) -> (symbol: String, label: String) {
        switch condition {
        case .clear, .mostlyClear:
            return (isDay ? "sun.max.fill" : "moon.stars.fill", "Klar")
        case .partlyCloudy:
            return (isDay ? "cloud.sun.fill" : "cloud.moon.fill", "Teilweise bewölkt")
        case .cloudy, .mostlyCloudy:
            return ("cloud.fill", "Bewölkt")
        case .foggy, .haze, .smoky, .blowingDust:
            return ("cloud.fog.fill", "Neblig")
        case .drizzle, .freezingDrizzle:
            return ("cloud.drizzle.fill", "Nieselregen")
        case .rain, .sunShowers:
            return ("cloud.rain.fill", "Regen")
        case .heavyRain, .freezingRain:
            return ("cloud.heavyrain.fill", "Starker Regen")
        case .snow, .flurries, .sunFlurries:
            return ("cloud.snow.fill", "Schnee")
        case .heavySnow, .blizzard, .blowingSnow:
            return ("cloud.snow.fill", "Starker Schneefall")
        case .sleet, .wintryMix:
            return ("cloud.sleet.fill", "Schneeregen")
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms:
            return ("cloud.bolt.rain.fill", "Gewitter")
        case .hail:
            return ("cloud.hail.fill", "Hagel")
        case .hot:
            return ("thermometer.sun.fill", "Hitze")
        case .frigid:
            return ("thermometer.snowflake", "Extreme Kälte")
        case .windy, .breezy:
            return ("wind", "Windig")
        case .tropicalStorm, .hurricane:
            return ("hurricane", "Sturm")
        @unknown default:
            return ("cloud.fill", "Unbekannt")
        }
    }
}
