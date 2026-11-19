import Foundation

public enum DeviceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case windows
    case mac

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .windows: return "Windows"
        case .mac: return "Mac"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .windows: return "desktopcomputer"
        case .mac: return "laptopcomputer"
        }
    }
}

public struct PCProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String
    public var mac: String
    public var ip: String
    public var broadcast: String
    public var wolPort: Int
    public var apiPort: Int
    /// Transient runtime copy; persisted securely in Shared Keychain (stripped from UserDefaults JSON).
    public var token: String
    public var deviceType: DeviceType
    public var deviceId: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        emoji: String = "🖥️",
        mac: String,
        ip: String,
        broadcast: String = "",
        wolPort: Int = SharedConfig.defaultWoLPort,
        apiPort: Int = SharedConfig.defaultAPIPort,
        token: String = "",
        deviceType: DeviceType = .windows,
        deviceId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.mac = mac.uppercased()
        self.ip = ip
        self.broadcast = broadcast.isEmpty ? Self.deriveBroadcast(from: ip) : broadcast
        self.wolPort = wolPort
        self.apiPort = apiPort
        self.token = token
        self.deviceType = deviceType
        self.deviceId = deviceId
    }

    public var resolvedBroadcast: String {
        broadcast.isEmpty ? Self.deriveBroadcast(from: ip) : broadcast
    }

    public var hasAgentCredentials: Bool {
        !token.isEmpty
    }

    public var supportsRelay: Bool {
        guard let deviceId, !deviceId.isEmpty, !token.isEmpty else { return false }
        return true
    }

    public static func deriveBroadcast(from ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return "255.255.255.255" }
        return "\(parts[0]).\(parts[1]).\(parts[2]).255"
    }

    /// Returns a copy without the token for safe storage in App Group UserDefaults.
    public func sanitizedForUserDefaults() -> PCProfile {
        var copy = self
        copy.token = ""
        return copy
    }
}

public struct PCQRCode: Equatable, Sendable {
    public let mac: String
    public let ip: String
    public let broadcast: String
    public let wolPort: Int
    public let apiPort: Int
    public let token: String
    public let deviceType: DeviceType
    public let deviceId: String?
    public let relayURL: String?

    public static let macPattern = "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
    public static let tokenPattern = "^[A-Za-z0-9_-]{8,64}$"

    public static func isValidMAC(_ value: String) -> Bool {
        value.range(of: macPattern, options: .regularExpression) != nil
    }

    public static func isValidToken(_ value: String) -> Bool {
        value.range(of: tokenPattern, options: .regularExpression) != nil
    }

    public static func maskToken(in urlString: String) -> String {
        urlString.replacingOccurrences(
            of: "token=[^&]+",
            with: "token=***",
            options: .regularExpression
        )
    }

    public static func parse(from rawString: String) -> PCQRCode? {
        guard let components = URLComponents(string: rawString.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == SharedConfig.urlScheme,
              components.host?.lowercased() == "config",
              let items = components.queryItems
        else {
            return nil
        }

        let map = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let val = item.value else { return nil }
            return (item.name, val)
        })

        guard let rawMac = map["mac"]?.replacingOccurrences(of: "-", with: ":").uppercased(),
              isValidMAC(rawMac),
              let ip = map["ip"], !ip.isEmpty
        else {
            return nil
        }

        let token = map["token"] ?? ""
        if !token.isEmpty && !isValidToken(token) {
            return nil
        }

        let bcast = map["bcast"] ?? map["broadcast"] ?? PCProfile.deriveBroadcast(from: ip)
        let wolPort = Int(map["wolPort"] ?? "") ?? SharedConfig.defaultWoLPort
        let apiPort = Int(map["apiPort"] ?? "") ?? SharedConfig.defaultAPIPort
        let deviceType = DeviceType(rawValue: (map["deviceType"] ?? "windows").lowercased()) ?? .windows
        let deviceId = map["deviceId"]
        let relayRaw = map["relay"]?.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let relayURL = (relayRaw?.isEmpty == false) ? relayRaw : nil

        return PCQRCode(
            mac: rawMac,
            ip: ip,
            broadcast: bcast,
            wolPort: wolPort,
            apiPort: apiPort,
            token: token,
            deviceType: deviceType,
            deviceId: deviceId,
            relayURL: relayURL
        )
    }
}

public enum ConnectionStatus: String, Equatable, Sendable {
    case unknown
    case checking
    case connected
    case failed
}

public enum NetworkRoute: String, Equatable, Sendable {
    case lan
    case relay
}

public enum NetworkError: LocalizedError, Equatable, Sendable {
    case invalidMAC
    case invalidPort
    case connectionFailed(String)
    case timeout
    case permissionDenied
    case unauthorized
    case agentOffline
    case lanOnly
    case lanUnreachable
    case fileTooLarge
    case relayNotConfigured

    public var errorDescription: String? {
        switch self {
        case .invalidMAC: return L10n.tr("err_invalid_mac")
        case .invalidPort: return L10n.tr("err_invalid_port")
        case .connectionFailed(let msg): return msg
        case .timeout: return L10n.tr("err_timeout")
        case .permissionDenied: return L10n.tr("err_permission_denied")
        case .unauthorized: return L10n.tr("err_unauthorized")
        case .agentOffline: return L10n.tr("err_agent_offline")
        case .lanOnly: return L10n.tr("err_lan_only")
        case .lanUnreachable: return L10n.tr("err_lan_unreachable")
        case .fileTooLarge: return L10n.tr("err_file_too_large")
        case .relayNotConfigured: return L10n.tr("err_relay_not_configured")
        }
    }
}

public enum PowerCommand: String, CaseIterable, Identifiable, Sendable {
    case shutdown
    case restart
    case sleep
    case hibernate
    case lock
    case displayOff = "display-off"
    case displayOn = "display-on"

    public var id: String { rawValue }
    public var path: String { "/\(rawValue)" }
    public var isDestructive: Bool { self == .shutdown || self == .restart }
}

public enum ScheduleAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case shutdown
    case restart
    case sleep

    public var id: String { rawValue }
    public var schedulePath: String { "/\(rawValue)-in" }
}

// MARK: - Agent API DTOs

public struct ApiResponse: Codable, Sendable {
    public let success: Bool
    public let message: String?
    public let diagnostics: DiagnosticsInfo?
    public let data: ResponseData?
    public let features: [String]?

    public var resolvedFeatures: Set<String> {
        Set(features ?? data?.features ?? [])
    }
}

public struct DiagnosticsInfo: Codable, Equatable, Sendable {
    public let wifiConnected: Bool?
    public let primaryAdapter: String?
    public let hasMultipleAdapters: Bool?
    public let isVirtualAdapter: Bool?
    public let agentVersion: String?
    public let networkProfile: String?
    public let thirdPartyAntivirus: Bool?
    public let lanReachable: Bool?
    public let problems: [AgentProblem]?
}

public enum AgentProblem: String, Codable, Equatable, Identifiable, Sendable {
    case publicNetwork = "public_network"
    case antivirusPresent = "antivirus_present"
    case lanBlocked = "lan_blocked"
    case modernStandby = "modern_standby"

    public var id: String { rawValue }
}

public struct CustomCommandInfo: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let icon: String?
    public let iconImage: String?
    public let running: Bool?
    public let closable: Bool?
}

public struct RunningAppInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let icon: String?
    public let iconImage: String?
}

public struct AudioOutputInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

public struct ResponseData: Codable, Sendable {
    public let volume: Int?
    public let muted: Bool?
    public let micVolume: Int?
    public let micMuted: Bool?
    public let brightness: Int?
    public let displayAsleep: Bool?
    public let features: [String]?
    public let agentVersion: String?
    public let ip: String?
    public let mac: String?
    public let bcast: String?
    public let name: String?
    public let type: String?
    public let deviceId: String?
    public let token: String?

    public let cpuLoad: Double?
    public let ramLoad: Double?
    public let ramUsedGb: Double?
    public let ramTotalGb: Double?
    public let uptimeSeconds: Int?

    public let format: String?
    public let width: Int?
    public let height: Int?
    public let image: String?
    public let chunkIndex: Int?
    public let chunkCount: Int?
    public let audio: String?
    public let audioRate: Int?
    public let audioChannels: Int?
    public let audioSeq: Int64?

    public let commands: [CustomCommandInfo]?
    public let hasScheduled: Bool?
    public let action: String?
    public let remainingSeconds: Int?
    public let scheduledAt: Int?

    public let idleAction: String?
    public let idleMinutes: Int?
    public let idleStreakSeconds: Int?
    public let idleNotifyHours: Int?

    public let apps: [RunningAppInfo]?
    public let outputs: [AudioOutputInfo]?
    public let inputs: [AudioOutputInfo]?
    public let text: String?
    public let truncated: Bool?
}
