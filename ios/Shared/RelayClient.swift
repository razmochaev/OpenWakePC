import Foundation

/// E2EE Internet Relay client shared between WakePC and WakePCWidgetExtension.
/// Supports direct user-configured self-hosted relay URLs and optional `relay.json` discovery (TTL 600s).
public actor RelayClient {
    public static let shared = RelayClient()

    private struct DiscoveryResponse: Decodable {
        let url: String?
        let relay_url: String?
    }

    private let storage: SharedStorage
    private let session: URLSession

    public init(storage: SharedStorage = .shared, session: URLSession = .shared) {
        self.storage = storage
        self.session = session
    }

    public func resolveBaseURL() async throws -> String {
        let custom = storage.customRelayURL
        if storage.useCustomRelay && !custom.isEmpty {
            return custom
        }

        if let cached = storage.cachedDiscoveredRelayURL(),
           Date().timeIntervalSince1970 - cached.timestamp < SharedConfig.relayDiscoveryCacheTTL {
            return cached.url
        }

        let rawDiscovery = storage.relayDiscoveryURL
        let discoveryURLString = rawDiscovery.isEmpty ? SharedConfig.defaultRelayDiscoveryURL : rawDiscovery
        if let url = URL(string: discoveryURLString) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8.0
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let decoded = try? JSONDecoder().decode(DiscoveryResponse.self, from: data),
               let rawURL = decoded.url ?? decoded.relay_url {
                let resolved = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                if !resolved.isEmpty {
                    storage.saveDiscoveredRelayURL(resolved)
                    return resolved
                }
            }
        }

        storage.saveDiscoveredRelayURL(SharedConfig.defaultRelayFallbackURL)
        return SharedConfig.defaultRelayFallbackURL
    }

    public func sendCommand(
        profile: PCProfile,
        path: String,
        query: [String: String] = [:],
        timeoutSec: Int = 10
    ) async throws -> Data {
        guard let deviceId = profile.deviceId, !deviceId.isEmpty, !profile.token.isEmpty else {
            throw NetworkError.unauthorized
        }

        let baseURL = try await resolveBaseURL()
        guard let encodedDeviceId = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/send/\(encodedDeviceId)?timeout=\(timeoutSec)")
        else {
            throw NetworkError.connectionFailed("Invalid relay URL")
        }

        let payload = RelayCrypto.CommandPayload(path: path, query: query)
        let plaintext = try JSONEncoder().encode(payload)

        for attempt in 0..<3 {
            let envelope = try RelayCrypto.seal(
                plaintext: plaintext,
                token: profile.token,
                deviceId: deviceId
            )

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = TimeInterval(timeoutSec + 4)
            request.httpBody = try JSONEncoder().encode(envelope)

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch let urlErr as URLError where urlErr.code == .timedOut {
                throw NetworkError.timeout
            } catch {
                throw NetworkError.connectionFailed(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.connectionFailed("Invalid relay HTTP response")
            }

            switch http.statusCode {
            case 200..<300:
                let respEnvelope = try JSONDecoder().decode(RelayCrypto.Envelope.self, from: data)
                return try RelayCrypto.open(
                    envelope: respEnvelope,
                    token: profile.token,
                    deviceId: deviceId
                )
            case 429:
                if attempt < 2 {
                    let retryAfter = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1.5
                    let waitSec = min(max(retryAfter, 0.5), 5.0)
                    try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                    continue
                }
                throw NetworkError.connectionFailed("Relay HTTP 429")
            case 401, 403:
                throw NetworkError.unauthorized
            case 502:
                throw NetworkError.agentOffline
            case 504:
                throw NetworkError.timeout
            default:
                throw NetworkError.connectionFailed("Relay HTTP \(http.statusCode)")
            }
        }
        throw NetworkError.connectionFailed("Relay HTTP 429")
    }
}
