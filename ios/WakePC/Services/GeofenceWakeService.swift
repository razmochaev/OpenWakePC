import CoreLocation
import Foundation
import UserNotifications

/// Monitors a ~150m CLCircularRegion around saved home coordinates and wakes tagged PCs on arrival.
@MainActor
public final class GeofenceWakeService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = GeofenceWakeService()

    public struct HomeLocation: Codable, Equatable, Sendable {
        public let lat: Double
        public let lon: Double
    }

    @Published public private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var monitoredProfileIds: Set<String> = []

    private let locationManager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let minWakeCooldownSeconds: TimeInterval = 300

    private override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
        refreshMonitoredSet()
    }

    public func isEnabled(for profileId: String) -> Bool {
        homeLocation(for: profileId) != nil
    }

    public func homeLocation(for profileId: String) -> HomeLocation? {
        guard let data = defaults.data(forKey: "geofence_home_\(profileId)") else { return nil }
        return try? JSONDecoder().decode(HomeLocation.self, from: data)
    }

    public func enableForCurrentLocation(profile: PCProfile) {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
        guard let coord = locationManager.location?.coordinate else {
            locationManager.requestLocation()
            return
        }
        saveHomeLocation(HomeLocation(lat: coord.latitude, lon: coord.longitude), for: profile.id)
    }

    public func saveHomeLocation(_ home: HomeLocation, for profileId: String) {
        if let data = try? JSONEncoder().encode(home) {
            defaults.set(data, forKey: "geofence_home_\(profileId)")
        }
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: home.lat, longitude: home.lon),
            radius: SharedConfig.geofenceRadiusMeters,
            identifier: "wakepc_home_\(profileId)"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false
        locationManager.startMonitoring(for: region)
        refreshMonitoredSet()
    }

    public func disable(for profileId: String) {
        defaults.removeObject(forKey: "geofence_home_\(profileId)")
        let targetId = "wakepc_home_\(profileId)"
        for region in locationManager.monitoredRegions where region.identifier == targetId {
            locationManager.stopMonitoring(for: region)
        }
        refreshMonitoredSet()
    }

    private func refreshMonitoredSet() {
        var ids: Set<String> = []
        for region in locationManager.monitoredRegions {
            if region.identifier.hasPrefix("wakepc_home_") {
                ids.insert(String(region.identifier.dropFirst("wakepc_home_".count)))
            }
        }
        monitoredProfileIds = ids
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Current coordinate updated for subsequent enable calls.
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal; handled gracefully in UI.
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix("wakepc_home_") else { return }
        let profileId = String(region.identifier.dropFirst("wakepc_home_".count))
        Task { @MainActor in
            await self.handleRegionEntry(profileId: profileId)
        }
    }

    private func handleRegionEntry(profileId: String) async {
        let lastTs = defaults.double(forKey: "geofence_last_wake_\(profileId)")
        guard Date().timeIntervalSince1970 - lastTs > minWakeCooldownSeconds else { return }

        let profiles = SharedStorage.shared.loadProfiles()
        guard let target = profiles.first(where: { $0.id == profileId }) else { return }

        defaults.set(Date().timeIntervalSince1970, forKey: "geofence_last_wake_\(profileId)")

        do {
            try await NetworkService.shared.wake(target)
        } catch {
            // Fallback to Buddy Wake via any other configured relay-capable profile
            for helper in profiles where helper.id != target.id && helper.supportsRelay {
                if (try? await NetworkService.shared.buddyWake(target: target, via: helper)) != nil {
                    break
                }
            }
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.tr("notif_geofence_title")
        content.body = L10n.tr("notif_geofence_body", target.name)
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "geofence-wake-\(profileId)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(req)
    }
}
