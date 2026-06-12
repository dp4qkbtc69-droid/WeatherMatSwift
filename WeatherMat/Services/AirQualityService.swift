// AirQualityService.swift
import Foundation
import CoreLocation

final class AirQualityService: Sendable {
    static let shared = AirQualityService()
    private init() {}

    func fetch(for location: CLLocation) async throws -> AirQuality {
        var c = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        c.queryItems = [
            .init(name: "latitude", value: "\(location.coordinate.latitude)"),
            .init(name: "longitude", value: "\(location.coordinate.longitude)"),
            .init(name: "current", value: "european_aqi,pm10,pm2_5,nitrogen_dioxide,ozone"),
            .init(name: "timezone", value: "auto")
        ]

        let (data, response) = try await URLSession.shared.data(from: c.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WeatherError.notAvailable }
        let decoded = try JSONDecoder().decode(AirQualityResponse.self, from: data)
        let current = decoded.current
        guard let europeanAQI = current.european_aqi else { throw WeatherError.notAvailable }
        return AirQuality(
            europeanAQI: Int(europeanAQI.rounded()),
            pm10: current.pm10 ?? 0,
            pm25: current.pm2_5 ?? 0,
            nitrogenDioxide: current.nitrogen_dioxide ?? 0,
            ozone: current.ozone ?? 0
        )
    }
}

private struct AirQualityResponse: Decodable {
    let current: Current

    struct Current: Decodable {
        let european_aqi: Double?
        let pm10: Double?
        let pm2_5: Double?
        let nitrogen_dioxide: Double?
        let ozone: Double?
    }
}
