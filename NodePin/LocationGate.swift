import AppKit
import CoreLocation
import Observation

@Observable
final class LocationGate: NSObject, CLLocationManagerDelegate {
    private(set) var isAuthorized = false
    @ObservationIgnored var onAuthorizationChange: (() -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        update(manager.authorizationStatus)
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    private func update(_ status: CLAuthorizationStatus) {
        isAuthorized = status == .authorizedAlways || status == .authorized
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.update(status)
            self.onAuthorizationChange?()
        }
    }

    func openSettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        NSWorkspace.shared.open(URL(string: url)!)
    }
}
