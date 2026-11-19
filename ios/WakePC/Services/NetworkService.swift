import Foundation
import Network
import UIKit

/// Core networking service managing NWPathMonitor, LAN vs E2EE Relay routing,
/// WoL UDP packets, all 40+ Wake PC Agent HTTP endpoints, chunked screenshots, and file uploads.
@MainActor
public final class NetworkService: ObservableObject {
    public static let shared = NetworkService()

    public struct Interfaces: Equatable, Sendable {
        public let wifi: Bool
        public let vpn: Bool
    }

    private struct RouteObservation {
        let route: NetworkRoute
        let interfaces: Interfaces
        let date: Date
    }

    @Published public private(set) var interfaces = Interfaces(wifi: true, vpn: false)
    @Published public private(set) var lastUsedRoute: NetworkRoute = .lan

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.wakepc.networkmonitor")
    private var observedRoutes: [String: RouteObservation] = [:]
    private let session: URLSession
    private let relayClient: RelayClient

    public init(relayClient: RelayClient = .shared) {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.relayClient = relayClient
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let hasWifi = path.usesInterfaceType(.wifi)
                || path.usesInterfaceType(.wiredEthernet)
                || path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
                || PCDiscoveryService.localWiFiIPv4() != nil
            let hasVPN = path.availableInterfaces.contains { iface in
                iface.name.hasPrefix("utun") || iface.name.hasPrefix("ppp") || iface.name.hasPrefix("ipsec")
            }
            Task { @MainActor [weak self] in
                self?.interfaces = Interfaces(wifi: hasWifi, vpn: hasVPN)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    public func invalidateRouteCache(for profileId: String? = nil) {
        if let profileId {
            observedRoutes.removeValue(forKey: profileId)
        } else {
            observedRoutes.removeAll()
        }
    }

    // MARK: - Wake-on-LAN & Buddy Wake

    public func wake(_ profile: PCProfile) async throws {
        SharedStorage.shared.markWakeRequested(forProfileId: profile.id)
        try WoLSender.send(
            mac: profile.mac,
            broadcast: profile.resolvedBroadcast,
            port: profile.wolPort,
            repeatCount: 3
        )
    }

    /// Buddy Wake: sends `/wake-other?mac=<target.mac>` via another online PC profile.
    public func buddyWake(target: PCProfile, via helperProfile: PCProfile) async throws -> ApiResponse {
        SharedStorage.shared.markWakeRequested(forProfileId: target.id)
        return try await sendCommand(
            profile: helperProfile,
            path: "/wake-other",
            query: [
                "mac": target.mac,
                "bcast": target.resolvedBroadcast,
                "wolPort": String(target.wolPort),
            ],
            timeout: 10.0
        )
    }

    // MARK: - Core Routed Command API (LAN + E2EE Relay Fallback)

    public func sendCommand(
        profile: PCProfile,
        path: String,
        query: [String: String] = [:],
        timeout: TimeInterval = 8.0,
        lanOnly: Bool = false
    ) async throws -> ApiResponse {
        let data = try await sendRawCommand(
            profile: profile,
            path: path,
            query: query,
            timeout: timeout,
            lanOnly: lanOnly
        )
        let decoded = try JSONDecoder().decode(ApiResponse.self, from: data)
        if path == "/status", decoded.success {
            SharedStorage.shared.setOnline(true, forProfileId: profile.id)
        }
        return decoded
    }

    public func sendRawCommand(
        profile: PCProfile,
        path: String,
        query: [String: String] = [:],
        timeout: TimeInterval = 8.0,
        lanOnly: Bool = false
    ) async throws -> Data {
        if lanOnly && !interfaces.wifi && !interfaces.vpn {
            throw NetworkError.lanOnly
        }

        let canUseRelay = !lanOnly && profile.supportsRelay
        let preferredRoute = cachedRoute(for: profile.id)

        // If relay is cached as active route (within 60s on identical interfaces), go straight to relay
        if canUseRelay && preferredRoute == .relay {
            do {
                let data = try await relayClient.sendCommand(
                    profile: profile,
                    path: path,
                    query: query,
                    timeoutSec: max(3, Int(ceil(timeout)))
                )
                recordRoute(.relay, for: profile.id)
                return data
            } catch NetworkError.relayNotConfigured {
                // Fall through to LAN
            }
        }

        // Attempt LAN first (with fast 2.5s probe cap only when route is not already confirmed LAN)
        let lanTimeout: TimeInterval = if canUseRelay && preferredRoute != .lan && timeout > SharedConfig.lanFallbackProbeTimeout {
            SharedConfig.lanFallbackProbeTimeout
        } else if canUseRelay {
            min(timeout, 8.0)
        } else {
            timeout
        }

        do {
            let data = try await sendLANRequest(
                profile: profile,
                path: path,
                query: query,
                timeout: lanTimeout
            )
            recordRoute(.lan, for: profile.id)
            return data
        } catch let err as NetworkError {
            if err == .unauthorized {
                throw err
            }
            guard canUseRelay else {
                throw lanOnly ? NetworkError.lanUnreachable : err
            }
            // Fallback to E2EE relay
            do {
                let data = try await relayClient.sendCommand(
                    profile: profile,
                    path: path,
                    query: query,
                    timeoutSec: max(3, Int(ceil(timeout)))
                )
                recordRoute(.relay, for: profile.id)
                return data
            } catch NetworkError.relayNotConfigured {
                throw err
            }
        }
    }

    private func sendLANRequest(
        profile: PCProfile,
        path: String,
        query: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = profile.ip
        comps.port = profile.apiPort
        comps.path = path.hasPrefix("/") ? path : "/\(path)"
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            throw NetworkError.connectionFailed("Invalid LAN URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        if !profile.token.isEmpty {
            req.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlErr as URLError {
            switch urlErr.code {
            case .timedOut: throw NetworkError.timeout
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                throw NetworkError.agentOffline
            default:
                throw NetworkError.connectionFailed(urlErr.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.connectionFailed("Invalid HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw NetworkError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 409 else {
            throw NetworkError.connectionFailed("Agent HTTP \(http.statusCode)")
        }
        return data
    }

    private func cachedRoute(for profileId: String) -> NetworkRoute? {
        guard let obs = observedRoutes[profileId],
              obs.interfaces == interfaces,
              Date().timeIntervalSince(obs.date) < SharedConfig.routeCacheTTL
        else {
            return nil
        }
        return obs.route
    }

    private func recordRoute(_ route: NetworkRoute, for profileId: String) {
        observedRoutes[profileId] = RouteObservation(
            route: route,
            interfaces: interfaces,
            date: Date()
        )
        lastUsedRoute = route
    }

    // MARK: - High-Level Endpoint Helpers

    public func fetchStatus(profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/status", timeout: 5.0)
    }

    public func fetchTelemetry(profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/telemetry", timeout: 5.0)
    }

    public func executePower(_ command: PowerCommand, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: command.path, timeout: 10.0)
    }

    public func schedulePower(_ action: ScheduleAction, minutes: Int, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(
            profile: profile,
            path: action.schedulePath,
            query: ["minutes": String(minutes)],
            timeout: 10.0
        )
    }

    public func fetchScheduledStatus(profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/scheduled-status", timeout: 6.0)
    }

    public func cancelScheduled(profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/cancel-scheduled", timeout: 8.0)
    }

    public func setIdleAction(_ action: String, minutes: Int = 10, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(
            profile: profile,
            path: "/idle-action",
            query: ["action": action, "minutes": String(minutes)],
            timeout: 8.0
        )
    }

    public func setIdleNotify(hours: Int, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(
            profile: profile,
            path: "/idle-notify",
            query: ["hours": String(hours)],
            timeout: 8.0
        )
    }

    public func setVolume(_ value: Int, on profile: PCProfile) async throws -> ApiResponse {
        let clamped = max(0, min(100, value))
        return try await sendCommand(profile: profile, path: "/volume-set/\(clamped)", timeout: 5.0)
    }

    public func volumeStep(up: Bool, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: up ? "/volume-up" : "/volume-down", timeout: 5.0)
    }

    public func toggleMute(on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/volume-mute", timeout: 5.0)
    }

    public func setMicVolume(_ value: Int, on profile: PCProfile) async throws -> ApiResponse {
        let clamped = max(0, min(100, value))
        return try await sendCommand(profile: profile, path: "/mic-set/\(clamped)", timeout: 5.0)
    }

    public func micVolumeStep(up: Bool, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: up ? "/mic-up" : "/mic-down", timeout: 5.0)
    }

    public func toggleMicMute(on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/mic-mute", timeout: 5.0)
    }

    public func fetchAudioOutputs(profile: PCProfile) async throws -> [AudioOutputInfo] {
        let resp = try await sendCommand(profile: profile, path: "/audio-outputs", timeout: 8.0)
        return resp.data?.outputs ?? []
    }

    public func setAudioOutput(id: String, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/audio-output/set", query: ["id": id], timeout: 8.0)
    }

    public func fetchAudioInputs(profile: PCProfile) async throws -> [AudioOutputInfo] {
        let resp = try await sendCommand(profile: profile, path: "/audio-inputs", timeout: 8.0)
        return resp.data?.inputs ?? resp.data?.outputs ?? []
    }

    public func setAudioInput(id: String, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/audio-input/set", query: ["id": id], timeout: 8.0)
    }

    public func setBrightness(_ value: Int, on profile: PCProfile) async throws -> ApiResponse {
        let clamped = max(0, min(100, value))
        return try await sendCommand(profile: profile, path: "/brightness-set/\(clamped)", timeout: 5.0)
    }

    public func brightnessStep(up: Bool, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: up ? "/brightness-up" : "/brightness-down", timeout: 5.0)
    }

    public func mediaAction(_ path: String, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: path, timeout: 5.0)
    }

    public func fetchRunningApps(profile: PCProfile) async throws -> [RunningAppInfo] {
        let resp = try await sendCommand(profile: profile, path: "/apps", timeout: 8.0)
        return resp.data?.apps ?? []
    }

    public func closeApp(id: String, force: Bool, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(
            profile: profile,
            path: "/apps/close",
            query: ["id": id, "force": force ? "true" : "false"],
            timeout: 10.0
        )
    }

    public func fetchCustomCommands(profile: PCProfile) async throws -> [CustomCommandInfo] {
        let resp = try await sendCommand(profile: profile, path: "/commands", timeout: 8.0)
        let cmds = resp.data?.commands ?? []
        SharedStorage.shared.saveCustomCommands(cmds, forProfileId: profile.id)
        return cmds
    }

    public func runCustomCommand(id: String, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/command/run", query: ["id": id], timeout: 10.0)
    }

    public func closeCustomCommand(id: String, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/command/close", query: ["id": id], timeout: 10.0)
    }

    public func openURL(_ urlString: String, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/open-url", query: ["url": urlString], timeout: 8.0)
    }

    public func sendClipboard(_ text: String, on profile: PCProfile) async throws -> ApiResponse {
        try await sendCommand(profile: profile, path: "/clipboard", query: ["text": text], timeout: 8.0)
    }

    public func getClipboard(from profile: PCProfile) async throws -> (text: String, truncated: Bool) {
        let resp = try await sendCommand(profile: profile, path: "/clipboard/get", timeout: 8.0)
        return (resp.data?.text ?? "", resp.data?.truncated ?? false)
    }

    // MARK: - Screenshot (Direct LAN + Chunked Relay Assembly)

    public func fetchScreenshot(
        profile: PCProfile,
        onChunkProgress: (@MainActor (Double) -> Void)? = nil
    ) async throws -> UIImage {
        let firstResp = try await sendCommand(
            profile: profile,
            path: "/screenshot",
            query: lastUsedRoute == .relay ? ["chunk": "0"] : [:],
            timeout: SharedConfig.screenshotTimeout
        )

        guard let firstData = firstResp.data, let firstChunk = firstData.image else {
            throw NetworkError.connectionFailed("Empty screenshot payload")
        }

        let totalChunks = max(1, firstData.chunkCount ?? 1)
        var combinedBase64 = firstChunk
        onChunkProgress?(1.0 / Double(totalChunks))

        if totalChunks > 1 {
            for idx in 1..<totalChunks {
                if lastUsedRoute == .relay {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                let chunkResp = try await sendCommand(
                    profile: profile,
                    path: "/screenshot",
                    query: ["chunk": String(idx)],
                    timeout: SharedConfig.screenshotTimeout
                )
                guard let piece = chunkResp.data?.image else {
                    throw NetworkError.connectionFailed("Missing screenshot chunk \(idx)")
                }
                combinedBase64.append(piece)
                onChunkProgress?(Double(idx + 1) / Double(totalChunks))
            }
        }

        guard let imgData = Data(base64Encoded: combinedBase64) else {
            throw NetworkError.connectionFailed("Invalid screenshot image bytes")
        }
        let preparedImage: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let raw = UIImage(data: imgData) else { return nil }
            return await raw.byPreparingForDisplay() ?? raw
        }.value
        guard let image = preparedImage else {
            throw NetworkError.connectionFailed("Invalid screenshot image bytes")
        }
        return image
    }

    public struct StreamFramePayload: Sendable {
        public let image: UIImage
        public let audioData: Data?
        public let audioRate: Int
        public let audioChannels: Int
        public let audioSeq: Int64
        public let isLAN: Bool
    }

    public func fetchStreamFrame(
        profile: PCProfile,
        includeAudio: Bool,
        sinceSeq: Int64
    ) async throws -> StreamFramePayload {
        let resp = try await sendCommand(
            profile: profile,
            path: "/stream/frame",
            query: [
                "audio": includeAudio ? "1" : "0",
                "since": String(sinceSeq),
            ],
            timeout: 5.0,
            lanOnly: false
        )
        let usedLAN = (lastUsedRoute == .lan)
        guard let d = resp.data,
              let imgB64 = d.image,
              let imgData = Data(base64Encoded: imgB64)
        else {
            throw NetworkError.connectionFailed("Empty stream frame")
        }
        let preparedImage: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let raw = UIImage(data: imgData) else { return nil }
            return await raw.byPreparingForDisplay() ?? raw
        }.value
        guard let image = preparedImage else {
            throw NetworkError.connectionFailed("Invalid stream frame bytes")
        }
        let audioData = d.audio.flatMap { Data(base64Encoded: $0) }
        return StreamFramePayload(
            image: image,
            audioData: audioData,
            audioRate: d.audioRate ?? 24000,
            audioChannels: d.audioChannels ?? 1,
            audioSeq: d.audioSeq ?? sinceSeq,
            isLAN: usedLAN
        )
    }

    public func stopStream(profile: PCProfile) async {
        _ = try? await sendCommand(profile: profile, path: "/stream/stop", timeout: 2.0, lanOnly: false)
    }

    // MARK: - LAN-Only File Upload (up to 500 MB with progress)

    public func uploadFile(
        fileURL: URL,
        filename: String,
        to profile: PCProfile,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ApiResponse {
        guard interfaces.wifi || interfaces.vpn else {
            throw NetworkError.lanOnly
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > SharedConfig.maxUploadBytes {
            throw NetworkError.fileTooLarge
        }

        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = profile.ip
        comps.port = profile.apiPort
        comps.path = "/upload"
        comps.queryItems = [URLQueryItem(name: "name", value: filename)]
        guard let url = comps.url else {
            throw NetworkError.connectionFailed("Invalid upload URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = SharedConfig.uploadTimeout
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if !profile.token.isEmpty {
            req.setValue("Bearer \(profile.token)", forHTTPHeaderField: "Authorization")
        }

        let delegate = UploadProgressDelegate(onProgress: onProgress)
        let uploadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { uploadSession.finishTasksAndInvalidate() }

        let (data, response) = try await uploadSession.upload(for: req, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.connectionFailed("Invalid upload response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw NetworkError.unauthorized
        }
        if http.statusCode == 413 {
            throw NetworkError.fileTooLarge
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.connectionFailed("Upload HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ApiResponse.self, from: data)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let ratio = min(1.0, max(0.0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        onProgress(ratio)
    }
}
