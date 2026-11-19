import Foundation

/// Persistent E2EE WebSocket client speaking the official `/agent/<deviceId>` challenge-response protocol.
@MainActor
final class RelayClient: ObservableObject {
    @Published private(set) var isOnline = false
    @Published private(set) var lastStatusMessage = "LAN-only"

    private let config: AgentConfig
    private let commandDispatcher: (String, [String: String], Bool) async -> Data
    private var runTask: Task<Void, Never>?
    private var wsTask: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?

    init(
        config: AgentConfig,
        commandDispatcher: @escaping (String, [String: String], Bool) async -> Data
    ) {
        self.config = config
        self.commandDispatcher = commandDispatcher
    }

    func start() {
        stop()
        if config.relayMode == "off" {
            lastStatusMessage = L10nMac.tr("relay_status_off")
            return
        }
        runTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        runTask?.cancel()
        runTask = nil
        isOnline = false
    }

    func sendIdleNotify(hours: Int) {
        guard let wsTask, isOnline else { return }
        let frame: [String: Any] = ["t": "notify", "event": "idle", "hours": hours]
        if let data = try? JSONSerialization.data(withJSONObject: frame),
           let text = String(data: data, encoding: .utf8) {
            wsTask.send(.string(text)) { _ in }
        }
    }

    private func resolveBaseURL() async -> String? {
        let custom = config.customRelayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if config.relayMode == "custom" {
            return custom.isEmpty ? nil : custom
        }
        if !custom.isEmpty {
            return custom
        }
        let discRaw = config.relayDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let discoveryStr = discRaw.isEmpty ? AgentConfig.defaultRelayDiscoveryURL : discRaw
        if let url = URL(string: discoveryStr),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let resolved = (obj["url"] as? String) ?? (obj["relay_url"] as? String),
           !resolved.isEmpty {
            return resolved.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return AgentConfig.defaultRelayFallbackURL
    }

    private func runLoop() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            do {
                guard let baseURL = await resolveBaseURL() else {
                    lastStatusMessage = "Relay URL unavailable"
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                let wsBase = baseURL
                    .replacingOccurrences(of: "https://", with: "wss://")
                    .replacingOccurrences(of: "http://", with: "ws://")
                guard let wsURL = URL(string: "\(wsBase)/agent/\(config.deviceId)") else {
                    lastStatusMessage = "Invalid relay URL"
                    return
                }

                let ws = URLSession.shared.webSocketTask(with: wsURL)
                self.wsTask = ws
                ws.resume()

                // 1. Receive challenge frame
                let challengeObj = try await receiveJSON(from: ws)
                guard challengeObj["t"] as? String == "challenge",
                      let nonce = challengeObj["nonce"] as? String
                else {
                    throw NSError(domain: "RelayClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "expected challenge"])
                }

                // 2. Send claim + HMAC proof
                let claim = RelayCrypto.roomClaim(token: config.token, deviceId: config.deviceId)
                let proof = RelayCrypto.claimProof(token: config.token, deviceId: config.deviceId, nonce: nonce)
                try await sendJSON(["t": "claim", "claim": claim, "proof": proof], over: ws)

                // 3. Receive ready frame
                let readyObj = try await receiveJSON(from: ws)
                guard readyObj["t"] as? String == "ready" else {
                    throw NSError(domain: "RelayClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "expected ready"])
                }

                backoff = 1
                isOnline = true
                lastStatusMessage = config.relayMode == "custom"
                    ? L10nMac.tr("relay_status_online_custom")
                    : L10nMac.tr("relay_status_online_cloud")
                startHeartbeat(ws: ws)

                // 4. Process incoming encrypted commands
                while !Task.isCancelled {
                    let frame = try await receiveJSON(from: ws)
                    let t = frame["t"] as? String ?? ""
                    if t == "cmd" {
                        await handleCommandFrame(frame, over: ws)
                    }
                }
            } catch {
                isOnline = false
                heartbeatTask?.cancel()
                heartbeatTask = nil
                wsTask?.cancel(with: .abnormalClosure, reason: nil)
                wsTask = nil
                lastStatusMessage = "Reconnecting (\(error.localizedDescription))"
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func startHeartbeat(ws: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                try? await self?.sendJSON(["t": "ping"], over: ws)
            }
        }
    }

    private func handleCommandFrame(_ frame: [String: Any], over ws: URLSessionWebSocketTask) async {
        let rid = frame["rid"] as? String ?? UUID().uuidString.lowercased()
        guard let envDict = frame["env"],
              let envData = try? JSONSerialization.data(withJSONObject: envDict),
              let envelope = try? JSONDecoder().decode(RelayCrypto.Envelope.self, from: envData)
        else { return }

        let responsePlain: Data
        do {
            let plain = try RelayCrypto.open(envelope: envelope, token: config.token, deviceId: config.deviceId)
            let cmd = try JSONDecoder().decode(RelayCrypto.CommandPayload.self, from: plain)
            if cmd.path.contains("..") || cmd.path.contains("//") {
                responsePlain = Data(#"{"success":false,"message":"bad_path"}"#.utf8)
            } else {
                responsePlain = await commandDispatcher(cmd.path, cmd.query ?? [:], true)
            }
        } catch {
            responsePlain = Data(#"{"success":false,"message":"decrypt_failed"}"#.utf8)
        }

        if let sealed = try? RelayCrypto.seal(
            plaintext: responsePlain,
            token: config.token,
            deviceId: config.deviceId,
            id: rid
        ),
           let sealedData = try? JSONEncoder().encode(sealed),
           let sealedObj = try? JSONSerialization.jsonObject(with: sealedData) {
            try? await sendJSON(["t": "resp", "rid": rid, "env": sealedObj], over: ws)
        }
    }

    private func sendJSON(_ obj: [String: Any], over ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let text = String(decoding: data, as: UTF8.self)
        try await ws.send(.string(text))
    }

    private func receiveJSON(from ws: URLSessionWebSocketTask) async throws -> [String: Any] {
        let msg = try await ws.receive()
        let rawData: Data
        switch msg {
        case .string(let s): rawData = Data(s.utf8)
        case .data(let d): rawData = d
        @unknown default: rawData = Data()
        }
        guard let obj = try JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw NSError(domain: "RelayClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid json"])
        }
        return obj
    }
}
