// NetatmoService.swift
import AuthenticationServices
import CoreLocation
import Foundation
import Security
import UIKit

@MainActor
final class NetatmoService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NetatmoService()

    private let statusKey = "netatmoLastStatus_v1"
    private let callbackScheme = "weathermat"
    private let redirectURI = "weathermat://oauth/netatmo"
    private var authSession: ASWebAuthenticationSession?

    private override init() {}

    var isConfigured: Bool {
        config != nil
    }

    var isConnected: Bool {
        token != nil
    }

    func authenticate() async throws {
        guard let config else {
            UserDefaults.standard.set("Client ID/Secret fehlen", forKey: statusKey)
            throw WeatherError.notAvailable
        }

        let state = UUID().uuidString
        var components = URLComponents(string: "https://api.netatmo.com/oauth2/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "read_station"),
            .init(name: "state", value: state),
            .init(name: "response_type", value: "code"),
        ]

        let callback = try await startAuthenticationSession(url: components.url!)
        guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else {
            UserDefaults.standard.set("Login abgebrochen", forKey: statusKey)
            throw WeatherError.notAvailable
        }

        let newToken = try await requestToken(code: code, config: config)
        try saveToken(newToken)
        UserDefaults.standard.set("verbunden", forKey: statusKey)
    }

    func disconnect() {
        try? KeychainStore.delete(account: "netatmoToken")
        UserDefaults.standard.set("nicht verbunden", forKey: statusKey)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
        }
        return ASPresentationAnchor()
    }

    func fetchNearestObservations(for location: CLLocation) async throws -> [NetatmoObservation] {
        guard isConfigured, let accessToken = try await validAccessToken() else {
            UserDefaults.standard.set(isConfigured ? "nicht verbunden" : "nicht konfiguriert", forKey: statusKey)
            return []
        }

        var request = URLRequest(url: URL(string: "https://api.netatmo.com/api/getstationsdata")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            UserDefaults.standard.set("API \(status)", forKey: statusKey)
            if status == 401 {
                try? KeychainStore.delete(account: "netatmoToken")
            }
            throw WeatherError.notAvailable
        }

        let decoded = try JSONDecoder().decode(NetatmoStationsResponse.self, from: data)
        guard let nearestDevice = decoded.body.devices
            .filter({ $0.location != nil })
            .min(by: {
                ($0.location?.distance(from: location) ?? .greatestFiniteMagnitude) <
                ($1.location?.distance(from: location) ?? .greatestFiniteMagnitude)
            })
        else {
            UserDefaults.standard.set("keine Station", forKey: statusKey)
            return []
        }

        let modules = nearestDevice.observations
            .map(\.observation)
            .filter { Date().timeIntervalSince($0.measuredAt) <= 24 * 60 * 60 }
            .sorted {
                if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        let freshCount = modules.filter(\.isFresh).count
        UserDefaults.standard.set(modules.isEmpty ? "keine Module" : "\(freshCount)/\(modules.count) frisch", forKey: statusKey)
        return modules
    }

    func fetchNearestObservation(for location: CLLocation) async throws -> NetatmoObservation? {
        try await fetchNearestObservations(for: location).preferredCalibrationObservation
    }

    private func startAuthenticationSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            func resumeOnce(_ result: Result<URL, Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    resumeOnce(.success(callbackURL))
                } else {
                    resumeOnce(.failure(error ?? WeatherError.notAvailable))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            authSession = session
            if !session.start() {
                resumeOnce(.failure(WeatherError.notAvailable))
            }
        }
    }

    private var config: NetatmoConfig? {
        guard let url = Bundle.main.url(forResource: "LocalConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let raw = try? PropertyListDecoder().decode(LocalNetatmoConfig.self, from: data)
        else { return nil }
        let clientID = (raw.netatmoClientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = (raw.netatmoClientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else { return nil }
        return NetatmoConfig(clientID: clientID, clientSecret: clientSecret)
    }

    private var token: NetatmoToken? {
        guard let data = try? KeychainStore.load(account: "netatmoToken") else { return nil }
        return try? JSONDecoder().decode(NetatmoToken.self, from: data)
    }

    private func saveToken(_ token: NetatmoToken) throws {
        let data = try JSONEncoder().encode(token)
        try KeychainStore.save(data, account: "netatmoToken")
    }

    private func validAccessToken() async throws -> String? {
        guard let token else { return nil }
        if Date() < token.expiresAt.addingTimeInterval(-60) {
            return token.accessToken
        }
        guard let config else { return nil }
        let refreshed = try await refreshToken(token.refreshToken, config: config)
        try saveToken(refreshed)
        return refreshed.accessToken
    }

    private func requestToken(code: String, config: NetatmoConfig) async throws -> NetatmoToken {
        let body = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "code": code,
            "redirect_uri": redirectURI,
        ]
        return try await tokenRequest(body: body)
    }

    private func refreshToken(_ refreshToken: String, config: NetatmoConfig) async throws -> NetatmoToken {
        let body = [
            "grant_type": "refresh_token",
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "refresh_token": refreshToken,
        ]
        return try await tokenRequest(body: body)
    }

    private func tokenRequest(body: [String: String]) async throws -> NetatmoToken {
        var request = URLRequest(url: URL(string: "https://api.netatmo.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { key, value in "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            UserDefaults.standard.set("Token \(status)", forKey: statusKey)
            throw WeatherError.notAvailable
        }

        let decoded = try JSONDecoder().decode(NetatmoTokenResponse.self, from: data)
        return NetatmoToken(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }
}

private struct LocalNetatmoConfig: Decodable {
    let netatmoClientID: String?
    let netatmoClientSecret: String?
}

private struct NetatmoConfig {
    let clientID: String
    let clientSecret: String
}

private struct NetatmoToken: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

private struct NetatmoTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: Int
}

private struct NetatmoStationsResponse: Decodable {
    let body: Body
    struct Body: Decodable {
        let devices: [Device]
    }
}

private struct Device: Decodable {
    let station_name: String
    let module_name: String?
    let place: Place?
    let dashboard_data: DashboardData?
    let modules: [Module]?

    var observations: [LocatedObservation] {
        var result: [LocatedObservation] = []
        if let location, let dashboard_data {
            result.append(
                LocatedObservation(
                    location: location,
                    observation: dashboard_data.observation(
                        stationName: station_name,
                        moduleName: module_name ?? "Innen"
                    )
                )
            )
        }
        for module in modules ?? [] {
            guard let dashboard = module.dashboard_data else { continue }
            result.append(
                LocatedObservation(
                    location: location ?? CLLocation(latitude: 0, longitude: 0),
                    observation: dashboard.observation(
                        stationName: station_name,
                        moduleName: module.module_name,
                        moduleType: module.type
                    )
                )
            )
        }
        return result
    }

    var location: CLLocation? {
        guard let coordinates = place?.location, coordinates.count >= 2 else { return nil }
        return CLLocation(latitude: coordinates[1], longitude: coordinates[0])
    }
}

private struct Module: Decodable {
    let module_name: String
    let type: String?
    let dashboard_data: DashboardData?
}

private struct Place: Decodable {
    let location: [Double]?
}

private struct DashboardData: Decodable {
    let time_utc: TimeInterval?
    let Temperature: Double?
    let Humidity: Int?
    let Pressure: Double?
    let CO2: Int?
    let Rain: Double?
    let sum_rain_24: Double?
    let WindStrength: Double?
    let GustStrength: Double?
    let WindAngle: Int?

    func observation(stationName: String, moduleName: String, moduleType: String? = nil) -> NetatmoObservation {
        NetatmoObservation(
            stationName: stationName,
            moduleName: moduleName,
            moduleType: moduleType,
            measuredAt: Date(timeIntervalSince1970: time_utc ?? Date().timeIntervalSince1970),
            temperature: Temperature,
            humidity: Humidity,
            pressure: Pressure,
            co2: CO2,
            rainRate: Rain,
            rainToday: sum_rain_24,
            windSpeed: WindStrength,
            windGust: GustStrength,
            windDirection: WindAngle
        )
    }
}

private struct LocatedObservation {
    let location: CLLocation
    let observation: NetatmoObservation
}

private enum KeychainStore {
    static func save(_ data: Data, account: String) throws {
        try? delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WeatherMat",
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw WeatherError.notAvailable }
    }

    static func load(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WeatherMat",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WeatherError.notAvailable }
        return item as? Data
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WeatherMat",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
