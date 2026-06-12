// ModelWeatherData.swift
// Intermediate representation from each provider before ensemble combination.
import Foundation

struct ModelWeatherData {
    let modelName:            String
    let weight:               Double

    // Current
    let currentTemp:          Double
    let currentFeelsLike:     Double
    let currentHumidity:      Int
    let currentWindSpeed:     Double
    let currentWindDirection: Int
    let currentPressure:      Double
    let currentVisibility:    Double
    let currentUVIndex:       Double
    let currentIsDay:         Bool
    let currentPrecipitation: Double
    let currentWMOCode:       Int
    let currentCloudCover:    Int      // 0–100 %

    // Time series
    let hourly:   [ModelHourlyPoint]
    let daily:    [ModelDailyPoint]
    let minutely: [ModelMinutelyPoint]  // 15-min or 1-min slots
}

struct ModelHourlyPoint {
    let time:               Date
    let temp:               Double
    let precipProbability:  Double   // 0–100
    let precipMm:           Double
    let windSpeed:          Double
    let wmoCode:            Int
    let isDay:              Bool
}

struct ModelDailyPoint {
    let date:               Date
    let high:               Double
    let low:                Double
    let precipProbability:  Double
    let precipSum:          Double
    let wmoCode:            Int
    let sunrise:            Date?
    let sunset:             Date?
    let uvMax:              Double
    let windMax:            Double
    let sunshineDuration:   Double   // seconds
}

struct ModelMinutelyPoint {
    let time:               Date
    let precipMm:           Double
    let precipProbability:  Double
}

// MARK: - Model Weights
/// Baseline weights reflecting each model's reliability and data resolution.
/// Horizon-adjusted multipliers are applied per entry in EnsembleService.
enum ModelWeights {
    static let weatherKit:  Double = 0.30  // Apple blend — excellent 0-24 h
    static let openMeteo:   Double = 0.22  // Auto-select regional model
    static let iconSeamless:Double = 0.26  // DWD ICON — best for Germany/Europe, 0-72 h
    static let ecmwf:       Double = 0.22  // Global benchmark — best for 5-14 days

    /// Returns normalised weights for the subset of models that responded.
    static func normalized(available: [String]) -> [String: Double] {
        let all: [String: Double] = [
            "WeatherKit":     weatherKit,
            "OpenMeteo":      openMeteo,
            "OpenMeteo-ICON": iconSeamless,
            "ECMWF":          ecmwf,
        ]
        let active = all.filter { available.contains($0.key) }
        let total  = active.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return active.mapValues { $0 / total }
    }
}

enum ForecastModelRules {
    static func horizonMultiplier(_ model: String, hoursAhead h: Double) -> Double {
        switch model {
        case "WeatherKit":     return h < 6 ? 2.2 : h < 24 ? 1.6 : h < 48 ? 0.9 : 0.2
        case "OpenMeteo-ICON": return h < 6 ? 1.9 : h < 48 ? 1.5 : h < 96 ? 1.0 : 0.5
        case "OpenMeteo":      return h < 24 ? 1.1 : h < 72 ? 1.3 : 1.0
        case "ECMWF":          return h < 6 ? 0.3 : h < 48 ? 0.8 : h < 120 ? 1.5 : 2.2
        default:               return 1.0
        }
    }

    static func skyClass(_ code: Int) -> Int {
        switch code {
        case 0, 1:         return 0
        case 2:            return 1
        case 3:            return 2
        case 45, 48:       return 3
        case 51...67:      return 4
        case 71...77:      return 5
        case 80...99:      return 6
        default:           return 2
        }
    }
}
