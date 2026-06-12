// WeatherProviding.swift
import Foundation
import CoreLocation

protocol WeatherProviding: Sendable {
    var modelName: String { get }
    var weight:    Double { get }
    func fetchWeather(for location: CLLocation) async throws -> ModelWeatherData
}

enum WeatherError: LocalizedError {
    case networkError(Error)
    case decodingError(Error)
    case notAvailable
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .networkError(let e):  return "Netzwerkfehler: \(e.localizedDescription)"
        case .decodingError(let e): return "Datenfehler: \(e.localizedDescription)"
        case .notAvailable:         return "Wetterdaten nicht verfügbar"
        case .unauthorized:         return "Standortzugriff verweigert"
        }
    }
}
