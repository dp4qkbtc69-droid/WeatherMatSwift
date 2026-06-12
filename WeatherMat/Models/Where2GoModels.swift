import Foundation
import CoreLocation

enum Where2GoWindow: String, CaseIterable, Identifiable, Codable {
    case tomorrow
    case nextWeekend

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tomorrow: return "Morgen"
        case .nextWeekend: return "Wochenende"
        }
    }

    var icon: String {
        switch self {
        case .tomorrow: return "sunrise.fill"
        case .nextWeekend: return "calendar"
        }
    }
}

enum Where2GoSortMode: String, CaseIterable, Identifiable, Codable {
    case best
    case nearest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Beste"
        case .nearest: return "Nächste"
        }
    }
}

struct Where2GoSpot: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
    let distanceKm: Int
    let direction: String
    let score: Int
    let temperature: Int
    let sunshineHours: Double
    let precipitationProbability: Int
    let windSpeed: Int
    let condition: WMOCondition
    let dateLabel: String

    static func == (lhs: Where2GoSpot, rhs: Where2GoSpot) -> Bool {
        lhs.id == rhs.id
    }
}

struct Where2GoForecastDay {
    let date: Date
    let weatherCode: Int
    let temperatureMax: Double
    let precipitationProbability: Double
    let precipitationSum: Double
    let windMax: Double
    let sunshineDuration: Double
}
