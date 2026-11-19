import Foundation

/// App Group UserDefaults storage shared between WakePC, Widgets, Intents, and Live Activities.
public final class SharedStorage: @unchecked Sendable {
    public static let shared = SharedStorage()

    private enum Keys {
        static let pcProfilesData = "pcProfilesData"
        static let selectedProfileId = "selectedProfileId"
        static let customCommandsCache = "customCommandsCache"
        static let relayUrlRemote = "relay_url_remote"
        static let relayUrlRemoteTs = "relay_url_remote_ts"
        static let relayUrlWidget = "relay_url_widget"
        static let customRelayURL = "custom_relay_url"
        static let useCustomRelay = "use_custom_relay"
        static let relayDiscoveryURL = "relay_discovery_url"
        static let tokensMigratedToKeychain = "tokensMigratedToKeychain"
    }

    public let defaults: UserDefaults

    public init(suiteName: String = SharedConfig.appGroupID) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - Profiles (tokens securely kept in Shared Keychain)

    public func loadProfiles() -> [PCProfile] {
        guard let data = defaults.data(forKey: Keys.pcProfilesData),
              var profiles = try? JSONDecoder().decode([PCProfile].self, from: data)
        else {
            return []
        }

        let needsMigration = !defaults.bool(forKey: Keys.tokensMigratedToKeychain)
        for index in profiles.indices {
            let pid = profiles[index].id
            if let keychainToken = KeychainTokenStore.load(forProfileId: pid), !keychainToken.isEmpty {
                profiles[index].token = keychainToken
            } else if !profiles[index].token.isEmpty {
                KeychainTokenStore.save(token: profiles[index].token, forProfileId: pid)
            }
        }
        if needsMigration && !profiles.isEmpty {
            saveProfiles(profiles)
            defaults.set(true, forKey: Keys.tokensMigratedToKeychain)
        }
        return profiles
    }

    public func saveProfiles(_ profiles: [PCProfile]) {
        for profile in profiles where !profile.token.isEmpty {
            KeychainTokenStore.save(token: profile.token, forProfileId: profile.id)
        }
        let sanitized = profiles.map { $0.sanitizedForUserDefaults() }
        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: Keys.pcProfilesData)
        }
        defaults.set(true, forKey: Keys.tokensMigratedToKeychain)
    }

    public func removeProfile(id: String) {
        var profiles = loadProfiles()
        profiles.removeAll { $0.id == id }
        KeychainTokenStore.delete(forProfileId: id)
        saveProfiles(profiles)
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
    }

    public var selectedProfileId: String? {
        get { defaults.string(forKey: Keys.selectedProfileId) }
        set { defaults.set(newValue, forKey: Keys.selectedProfileId) }
    }

    public func selectedProfile() -> PCProfile? {
        let profiles = loadProfiles()
        if let id = selectedProfileId, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    // MARK: - Custom Commands Cache (for Shortcuts)

    public func saveCustomCommands(_ commands: [CustomCommandInfo], forProfileId profileId: String) {
        var all = loadAllCustomCommands()
        all[profileId] = commands
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Keys.customCommandsCache)
        }
    }

    public func loadAllCustomCommands() -> [String: [CustomCommandInfo]] {
        guard let data = defaults.data(forKey: Keys.customCommandsCache),
              let map = try? JSONDecoder().decode([String: [CustomCommandInfo]].self, from: data)
        else {
            return [:]
        }
        return map
    }

    // MARK: - Relay URL Configuration (Self-hosted first, discovery optional)

    /// Whether to override the free automatic cloud E2EE relay with a custom self-hosted URL.
    public var useCustomRelay: Bool {
        get {
            if defaults.object(forKey: Keys.useCustomRelay) != nil {
                return defaults.bool(forKey: Keys.useCustomRelay)
            }
            return !customRelayURL.isEmpty
        }
        set { defaults.set(newValue, forKey: Keys.useCustomRelay) }
    }

    /// Explicit user-configured relay base URL (e.g. https://relay.mydomain.com).
    public var customRelayURL: String {
        get { (defaults.string(forKey: Keys.customRelayURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            defaults.set(cleaned, forKey: Keys.customRelayURL)
            defaults.set(cleaned, forKey: Keys.relayUrlWidget)
        }
    }

    /// Optional discovery endpoint returning `{"relay_url": "..."}`.
    public var relayDiscoveryURL: String {
        get { (defaults.string(forKey: Keys.relayDiscoveryURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.relayDiscoveryURL) }
    }

    public func cachedDiscoveredRelayURL() -> (url: String, timestamp: TimeInterval)? {
        guard let url = defaults.string(forKey: Keys.relayUrlRemote), !url.isEmpty else {
            return nil
        }
        let ts = defaults.double(forKey: Keys.relayUrlRemoteTs)
        return (url, ts)
    }

    public func saveDiscoveredRelayURL(_ url: String) {
        let cleaned = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        defaults.set(cleaned, forKey: Keys.relayUrlRemote)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.relayUrlRemoteTs)
        defaults.set(cleaned, forKey: Keys.relayUrlWidget)
    }

    // MARK: - Widget Status Cache

    public func setOnline(_ isOnline: Bool, forProfileId id: String) {
        defaults.set(isOnline, forKey: "pc_online_\(id)")
        defaults.set(Date().timeIntervalSince1970, forKey: "pc_online_at_\(id)")
    }

    public func isOnlineCached(forProfileId id: String) -> (online: Bool, updatedAt: Date?) {
        let online = defaults.bool(forKey: "pc_online_\(id)")
        let ts = defaults.double(forKey: "pc_online_at_\(id)")
        return (online, ts > 0 ? Date(timeIntervalSince1970: ts) : nil)
    }

    public func markWakeRequested(forProfileId id: String) {
        defaults.set(Date().timeIntervalSince1970, forKey: "pc_wake_at_\(id)")
    }

    public func lastWakeRequested(forProfileId id: String) -> Date? {
        let ts = defaults.double(forKey: "pc_wake_at_\(id)")
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }
}
