// PushRegistrationService.swift
// Registers the device token and saved locations with the radar proxy,
// which polls DWD warnings and delivers them via APNs.
import Foundation
import os

@MainActor
final class PushRegistrationService {

    static let shared = PushRegistrationService()

    private static let logger = Logger(subsystem: "de.praxishartlep.weathermat", category: "Push")
    private let tokenKey = "pushDeviceToken_v1"
    /// True once the proxy accepted a registration AND has APNs configured —
    /// NotificationService then skips local warning notifications to avoid duplicates.
    static let pushActiveKey = "pushWarningsActive_v1"

    private init() {}

    var deviceToken: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    static var isPushActive: Bool {
        UserDefaults.standard.bool(forKey: pushActiveKey)
    }

    func updateDeviceToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey)
        Task { await syncRegistration() }
    }

    /// Sends token + all saved locations to the proxy. Safe to call often —
    /// no-ops without token or proxy config, failures are retried on next call.
    func syncRegistration() async {
        guard let token = deviceToken,
              let baseURL = RainRadarService.proxyBaseURL else { return }

        let locations = Self.loadSavedLocations().prefix(12).map { loc in
            PushLocationPayload(lat: loc.latitude, lon: loc.longitude, name: loc.name)
        }
        guard !locations.isEmpty else { return }

        var request = RainRadarService.authenticatedDwdRadarRequest(baseURL.appending(path: "push/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONEncoder().encode(
            PushRegistrationPayload(token: token, locations: Array(locations))
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let result = try JSONDecoder().decode(PushRegistrationResult.self, from: data)
            UserDefaults.standard.set(result.pushConfigured, forKey: Self.pushActiveKey)
            Self.logger.info("push registration OK (server configured: \(result.pushConfigured))")
        } catch {
            Self.logger.warning("push registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func loadSavedLocations() -> [SavedLocation] {
        guard let data = UserDefaults.standard.data(forKey: "savedLocations_v1"),
              let locations = try? JSONDecoder().decode([SavedLocation].self, from: data) else {
            return []
        }
        return locations
    }
}

private struct PushLocationPayload: Encodable {
    let lat: Double
    let lon: Double
    let name: String
}

private struct PushRegistrationPayload: Encodable {
    let token: String
    let locations: [PushLocationPayload]
}

private struct PushRegistrationResult: Decodable {
    let ok: Bool
    let pushConfigured: Bool
}
