// BrightSkyService.swift  –  DWD warnings via BrightSky API
import Foundation
import CoreLocation

final class BrightSkyService: @unchecked Sendable {

    static let shared = BrightSkyService()
    private init() {}

    // MARK: - Warnings
    func fetchWarnings(for location: CLLocation) async throws -> [DWDWarning] {
        var c = URLComponents(string: "https://api.brightsky.dev/alerts")!
        c.queryItems = [
            .init(name: "lat", value: "\(location.coordinate.latitude)"),
            .init(name: "lon", value: "\(location.coordinate.longitude)"),
        ]
        let (data, response) = try await URLSession.shared.data(from: c.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let raw = try? JSONDecoder().decode(BSAlertResponse.self, from: data)
        return (raw?.alerts ?? []).compactMap { a in
            guard let eid = a.id, let evDe = a.event_de else { return nil }
            return DWDWarning(
                id:         "\(eid)",
                eventDe:    evDe,
                headlineDe: a.headline_de ?? evDe,
                severity:   WarningSeverity(rawValue: a.severity ?? "Minor") ?? .minor,
                onset:      a.onset.flatMap { iso($0) },
                expires:    a.expires.flatMap { iso($0) }
            )
        }
    }

    private static let isoFormat = Date.ISO8601FormatStyle()

    private func iso(_ s: String) -> Date? {
        try? Self.isoFormat.parse(s)
    }
}

// MARK: - Decodable
private struct BSAlertResponse: Decodable { let alerts: [BSAlert]? }
private struct BSAlert: Decodable {
    let id: Int?; let event_de, headline_de, severity, onset, expires: String?
}
