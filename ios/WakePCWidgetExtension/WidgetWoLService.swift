import Foundation

/// Autonomous networking client for WakePCWidgetExtension (direct POSIX UDP WoL + LAN/E2EE Relay).
public enum WidgetWoLService {
    public static func wake(profile: PCProfile) throws {
        SharedStorage.shared.markWakeRequested(forProfileId: profile.id)
        try WoLSender.send(
            mac: profile.mac,
            broadcast: profile.resolvedBroadcast,
            port: profile.wolPort,
            repeatCount: 3
        )
    }

    public static func sendCommand(profile: PCProfile, path: String, query: [String: String] = [:]) async -> Bool {
        // 1. Try fast LAN request (2.5s when relay fallback is available)
        let lanTimeout = profile.supportsRelay ? SharedConfig.lanFallbackProbeTimeout : 6.0
        if await sendLAN(profile: profile, path: path, query: query, timeout: lanTimeout) {
            if path == "/status" {
                SharedStorage.shared.setOnline(true, forProfileId: profile.id)
            }
            return true
        }

        // 2. Fallback to E2EE Relay
        guard profile.supportsRelay else { return false }
        if (try? await RelayClient.shared.sendCommand(profile: profile, path: path, query: query, timeoutSec: 8)) != nil {
            if path == "/status" {
                SharedStorage.shared.setOnline(true, forProfileId: profile.id)
            }
            return true
        }
        return false
    }

    private static func sendLAN(
        profile: PCProfile,
        path: String,
        query: [String: String],
        timeout: TimeInterval
    ) async -> Bool {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = profile.ip
        comps.port = profile.apiPort
        comps.path = path
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        if !profile.token.isEmpty {
            req.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
        }

        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            return false
        }
        return true
    }
}
