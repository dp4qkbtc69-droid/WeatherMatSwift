// WeatherModels.swift
import Foundation
import SwiftUI

// MARK: - Current Conditions
struct CurrentWeather: Codable {
    let temp:           Int
    let feelsLike:      Int
    let humidity:       Int
    let cloudCover:     Int   // 0–100 %
    let windSpeed:      Int
    let windDirection:  Int
    let pressure:       Int
    let visibility:     Int
    let uvIndex:        Double
    let isDay:          Bool
    let precipitation:  Double
    let airQuality:     AirQuality?
    let stationObservation: NetatmoObservation?
    let stationObservations: [NetatmoObservation]
    let condition:      WMOCondition
    let background:     WeatherBackground
}


// MARK: - Netatmo station
struct NetatmoObservation: Codable {
    let stationName: String
    let moduleName: String
    let moduleType: String?
    let measuredAt: Date
    let temperature: Double?
    let humidity: Int?
    let pressure: Double?
    let co2: Int?
    let rainRate: Double?
    let rainToday: Double?
    let windSpeed: Double?
    let windGust: Double?
    let windDirection: Int?

    var ageMinutes: Int {
        max(0, Int(Date().timeIntervalSince(measuredAt) / 60))
    }

    var isFresh: Bool {
        ageMinutes <= 45
    }

    var ageLabel: String {
        if ageMinutes < 60 { return "\(ageMinutes) min" }
        let hours = ageMinutes / 60
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d"
    }

    var displayName: String {
        if !moduleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return moduleName
        }
        switch moduleType {
        case "NAModule1": return "Außenmodul"
        case "NAModule2": return "Windmesser"
        case "NAModule3": return "Regenmesser"
        case "NAModule4": return "Innenmodul"
        default: return "Modul"
        }
    }

    var sortRank: Int {
        let normalizedName = displayName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        if normalizedName.contains("innen") { return 0 }
        if normalizedName.contains("galerie") { return 1 }
        if normalizedName.contains("terrasse") || normalizedName.contains("terasse") { return 2 }
        if normalizedName.contains("regen") { return 3 }
        switch moduleType {
        case "NAModule2": return 4
        case "NAModule1": return 5
        case "NAModule4": return 6
        default: return 7
        }
    }
}

// MARK: - Air Quality
struct AirQuality: Codable {
    let europeanAQI:     Int
    let pm10:            Double
    let pm25:            Double
    let nitrogenDioxide: Double
    let ozone:           Double

    var label: String {
        switch europeanAQI {
        case 0..<20:    return "Gut"
        case 20..<40:   return "Okay"
        case 40..<60:   return "Mäßig"
        case 60..<80:   return "Schlecht"
        case 80..<100:  return "Sehr schlecht"
        default:        return "Extrem"
        }
    }
}

// MARK: - Hourly Entry
struct HourlyEntry: Identifiable, Codable {
    var id: Date { time }
    let time:                   Date
    let temp:                   Int
    let condition:              WMOCondition
    let precipitationProbability: Int
    let precipitationMm:        Double
    let windSpeed:              Int
    let isDay:                  Bool
}

// MARK: - Daily Entry
struct DailyEntry: Identifiable, Codable {
    var id: Date { date }
    let date:                   Date
    let condition:              WMOCondition
    let high:                   Int
    let low:                    Int
    let precipitationProbability: Int
    let precipitationSum:       Double
    let sunrise:                Date
    let sunset:                 Date
    let uvMax:                  Double
    let windMax:                Int
    let sunshineDuration:       Double   // hours
}

// MARK: - Rain Analysis
enum RainType: String, Codable { case clear, soon, now }

struct RainAnalysis: Codable {
    let type:               RainType
    let text:               String
    let sub:                String
    let sfSymbol:           String
    let confidence:         ConfidenceLevel
    let minutesUntilRain:   Int?
    let minutesUntilClear:  Int?
    let chart:              [RainChartPoint]
}

struct RainChartPoint: Identifiable, Codable {
    var id: Date { time }
    let time:              Date
    let precipitationRate: Double
    let probability:       Double
}

// MARK: - Confidence
enum ConfidenceLevel: String, Codable {
    case high = "high", medium = "medium", low = "low"
    var label: String {
        switch self {
        case .high:   return "Hoch"
        case .medium: return "Mittel"
        case .low:    return "Gering"
        }
    }
    var color: Color {
        switch self {
        case .high:   return Color(hex: "#68d391")
        case .medium: return Color(hex: "#f6e05e")
        case .low:    return Color(hex: "#fc814a")
        }
    }
}


struct ForecastConfidenceBand: Identifiable, Codable {
    let id: String
    let title: String
    let subtitle: String
    let agreementPct: Int
    let confidence: ConfidenceLevel
}

// MARK: - Weather Background
enum WeatherBackground: String, Codable, Equatable {
    case sunny, cloudy, rainy, stormy, snowy, foggy, night, nightClear

    var gradient: LinearGradient { gradient(for: .dark) }

    func gradient(for colorScheme: ColorScheme) -> LinearGradient {
        switch self {
        case .sunny:
            let colors = colorScheme == .light
                ? [Color(hex: "#78dcff"), Color(hex: "#1a9be8"), Color(hex: "#2b79d6")]
                : [Color(hex: "#54cfff"), Color(hex: "#0f83d8"), Color(hex: "#0757b5")]
            return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        case .cloudy:
            return LinearGradient(colors: [Color(hex: "#8ed9f7"), Color(hex: "#3c9bd1"), Color(hex: "#2b74b9")], startPoint: .top, endPoint: .bottom)
        case .rainy:
            return LinearGradient(colors: [Color(hex: "#66add8"), Color(hex: "#2f7fac"), Color(hex: "#235f95")], startPoint: .top, endPoint: .bottom)
        case .stormy:
            return LinearGradient(colors: [Color(hex: "#386f9f"), Color(hex: "#183c68")], startPoint: .top, endPoint: .bottom)
        case .snowy:
            return LinearGradient(colors: [Color(hex: "#d8f1ff"), Color(hex: "#7db9e8")], startPoint: .top, endPoint: .bottom)
        case .foggy:
            return LinearGradient(colors: [Color(hex: "#b9d5e8"), Color(hex: "#6f93ad")], startPoint: .top, endPoint: .bottom)
        case .night:
            return LinearGradient(colors: [Color(hex: "#1a2540"), Color(hex: "#0a0f1e")], startPoint: .top, endPoint: .bottom)
        case .nightClear:
            return LinearGradient(colors: [Color(hex: "#0f1a35"), Color(hex: "#06091a")], startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - DWD Warning
struct DWDWarning: Identifiable, Codable {
    let id:         String
    let eventDe:    String
    let headlineDe: String
    let severity:   WarningSeverity
    let onset:      Date?
    let expires:    Date?
}

enum WarningSeverity: String, Codable, Comparable {
    case minor = "Minor", moderate = "Moderate", severe = "Severe", extreme = "Extreme"
    private static let order: [WarningSeverity] = [.minor, .moderate, .severe, .extreme]
    static func < (lhs: Self, rhs: Self) -> Bool {
        (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
    var sfSymbol: String {
        switch self {
        case .minor, .moderate: return "exclamationmark.triangle.fill"
        case .severe, .extreme: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch self {
        case .minor:    return .yellow
        case .moderate: return .orange
        case .severe:   return .red
        case .extreme:  return Color(hex: "#7b0000")
        }
    }
}

// MARK: - Saved Location (UserDefaults / Codable)
struct SavedLocation: Codable, Identifiable, Equatable {
    let id:         UUID
    var name:       String
    var country:    String
    var state:      String
    var latitude:   Double
    var longitude:  Double
    var sortOrder:  Int
    var isGPS:      Bool

    init(id: UUID = UUID(), name: String, country: String = "", state: String = "",
         latitude: Double, longitude: Double, sortOrder: Int = 0, isGPS: Bool = false) {
        self.id        = id
        self.name      = name
        self.country   = country
        self.state     = state
        self.latitude  = latitude
        self.longitude = longitude
        self.sortOrder = sortOrder
        self.isGPS     = isGPS
    }

    var subtitle: String { [state, country].filter { !$0.isEmpty }.joined(separator: ", ") }
}

// MARK: - Full Ensemble Result
struct EnsembleWeatherData: Codable {
    let current:      CurrentWeather
    let today:        DailyEntry
    let hourly:       [HourlyEntry]
    let daily:        [DailyEntry]
    let rain:         RainAnalysis
    let warnings:     [DWDWarning]
    let agreementPct: Int
    let confidence:   ConfidenceLevel
    let confidenceBands: [ForecastConfidenceBand]
    let activeModels: [String]
}

// MARK: - Local user feedback
enum WeatherFeedback: String, CaseIterable, Identifiable, Codable {
    case matches
    case tempTooHigh
    case tempTooLow
    case rainMissing
    case rainFalseAlarm
    case tooSunny
    case tooCloudy
    case windTooHigh
    case windTooLow

    var id: String { rawValue }

    static let quickReportCases: [WeatherFeedback] = [
        .rainFalseAlarm,
        .rainMissing,
        .tooSunny,
        .tooCloudy
    ]

    var label: String {
        switch self {
        case .matches:        return "Passt gut"
        case .tempTooHigh:    return "Zu warm"
        case .tempTooLow:     return "Zu kalt"
        case .rainMissing:    return "Regen fehlt"
        case .rainFalseAlarm: return "Regen falsch"
        case .tooSunny:       return "Zu sonnig"
        case .tooCloudy:      return "Zu bewölkt"
        case .windTooHigh:    return "Wind zu stark"
        case .windTooLow:     return "Wind zu schwach"
        }
    }

    var compactLabel: String {
        switch self {
        case .matches:        return "Passt"
        case .rainMissing:    return "Niederschlag"
        case .rainFalseAlarm: return "Kein Niederschlag"
        case .tooSunny:       return "Keine Sonne"
        case .tooCloudy:      return "Sonne"
        default:              return label
        }
    }

    var quickReportIcon: String {
        switch self {
        case .rainMissing:    return "cloud.rain.fill"
        case .rainFalseAlarm: return "cloud.slash.fill"
        case .tooSunny:       return "cloud.fill"
        case .tooCloudy:      return "sun.max.fill"
        default:              return icon
        }
    }

    var quickReportTint: Color {
        switch self {
        case .rainMissing:    return Color(hex: "#9ee8ff")
        case .rainFalseAlarm: return Color.white
        case .tooSunny:       return Color(hex: "#e8f3ff")
        case .tooCloudy:      return Color(hex: "#ffe08a")
        default:              return .white
        }
    }

    var icon: String {
        switch self {
        case .matches:        return "checkmark.circle.fill"
        case .tempTooHigh:    return "thermometer.high"
        case .tempTooLow:     return "thermometer.low"
        case .rainMissing:    return "cloud.rain.fill"
        case .rainFalseAlarm: return "cloud.sun.fill"
        case .tooSunny:       return "sun.max.fill"
        case .tooCloudy:      return "cloud.fill"
        case .windTooHigh:    return "wind"
        case .windTooLow:     return "wind.snow"
        }
    }
}

// MARK: - Color hex helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 200, 200, 200)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255,
                  blue: Double(b)/255, opacity: Double(a)/255)
    }
}

// MARK: - Array safe subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
