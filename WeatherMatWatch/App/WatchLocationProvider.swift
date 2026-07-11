// WatchLocationProvider.swift
// Same request/continuation pattern as the iOS LocationService — mirrored
// here rather than shared, since it's a few lines and the targets don't
// otherwise depend on each other.
import Foundation
@preconcurrency import CoreLocation

@MainActor
final class WatchLocationProvider: NSObject {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() async throws -> CLLocation {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if let continuation {
                    continuation.resume(throwing: CancellationError())
                }
                self.continuation = cont
                switch manager.authorizationStatus {
                case .authorizedWhenInUse, .authorizedAlways:
                    manager.requestLocation()
                case .notDetermined:
                    manager.requestWhenInUseAuthorization()
                default:
                    self.continuation = nil
                    cont.resume(throwing: WatchLocationError.unauthorized)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelPendingRequest() }
        }
    }

    private func cancelPendingRequest() {
        guard let continuation else { return }
        self.continuation = nil
        manager.stopUpdatingLocation()
        continuation.resume(throwing: CancellationError())
    }

    private func finish(with result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        switch result {
        case .success(let location): continuation.resume(returning: location)
        case .failure(let error):    continuation.resume(throwing: error)
        }
    }
}

enum WatchLocationError: Error { case unauthorized }

extension WatchLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor in self.finish(with: .success(loc)) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(with: .failure(error)) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch self.manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.manager.requestLocation()
            case .denied, .restricted:
                self.finish(with: .failure(WatchLocationError.unauthorized))
            default:
                break
            }
        }
    }
}
