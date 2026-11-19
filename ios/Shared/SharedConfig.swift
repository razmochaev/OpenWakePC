import Foundation

/// Shared constants across the main app and widget extension.
public enum SharedConfig {
    /// App Group suite shared between WakePC and WakePCWidgetExtension.
    public static var appGroupID: String {
        (Bundle.main.object(forInfoDictionaryKey: "WakePCAppGroupID") as? String)
            ?? "group.org.openwakepc.shared"
    }

    /// Shared Keychain access group (populated via Info.plist $(AppIdentifierPrefix)...).
    public static var keychainAccessGroup: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "WakePCKeychainGroup") as? String
        if let raw, !raw.isEmpty, !raw.contains("$(") {
            return raw
        }
        return nil
    }

    public static let keychainService = "app.wakepc.token"
    public static let urlScheme = "wakepc"
    public static let bonjourServiceType = "_wakepc._tcp"

    public static let defaultAPIPort = 8765
    public static let defaultWoLPort = 9
    public static let defaultRelayDiscoveryURL = "https://wakepc.app/relay.json"
    public static let defaultRelayFallbackURL = "https://relay.wakepc.app"

    /// Protocol timing constants.
    public static let routeCacheTTL: TimeInterval = 60.0
    public static let lanFallbackProbeTimeout: TimeInterval = 2.5
    public static let screenshotTimeout: TimeInterval = 15.0
    public static let uploadTimeout: TimeInterval = 60.0
    public static let pushRegistrationTimeout: TimeInterval = 10.0
    public static let relayDiscoveryCacheTTL: TimeInterval = 600.0
    public static let maxUploadBytes: Int64 = 500 * 1024 * 1024
    public static let geofenceRadiusMeters: Double = 150.0
}
