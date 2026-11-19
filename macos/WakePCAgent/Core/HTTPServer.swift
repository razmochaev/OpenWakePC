import Foundation
import Network

/// Native HTTP/1.1 LAN API server (`NWListener` on `:8765`) + unified command router for E2EE Relay.
@MainActor
final class HTTPServer: ObservableObject {
    @Published private(set) var isRunning = false

    static let allFeatures = [
        "telemetry", "screenshot", "screenshot-relay", "live-stream", "audio-stream",
        "touchpad", "hotkeys", "send-text", "send-file", "clipboard-get",
        "custom-commands", "audio-output", "volume-state", "fullscreen-key",
        "idle-action", "idle-notify", "wol-relay",
    ]

    private let config: AgentConfig
    private let commands: CustomCommandStore
    private let scheduler: SchedulerAndIdleMonitor
    private let queue = DispatchQueue(label: "com.wakepc.agent.server")
    private var listener: NWListener?

    private var cachedScreenshotB64: String = ""
    private var cachedScreenshotSize: (width: Int, height: Int) = (0, 0)
    private var cachedScreenshotAt: Date = .distantPast

    init(config: AgentConfig, commands: CustomCommandStore, scheduler: SchedulerAndIdleMonitor) {
        self.config = config
        self.commands = commands
        self.scheduler = scheduler
    }

    func start() {
        stop()
        guard (1...65535).contains(config.port),
              let port = NWEndpoint.Port(rawValue: UInt16(config.port))
        else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state {
                        self?.isRunning = true
                    } else if case .failed = state {
                        self?.isRunning = false
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(connection: connection, buffer: Data())
    }

    nonisolated private func receiveHTTPRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var acc = buffer
            if let chunk { acc.append(chunk) }

            let headerSep = Data("\r\n\r\n".utf8)
            if let range = acc.range(of: headerSep) {
                let headerData = acc[..<range.lowerBound]
                let bodyStart = range.upperBound
                let headerText = String(decoding: headerData, as: UTF8.self)
                let lines = headerText.components(separatedBy: "\r\n")
                let requestLine = lines.first?.split(separator: " ") ?? []
                let method = requestLine.count > 0 ? String(requestLine[0]) : "GET"
                let rawTarget = requestLine.count > 1 ? String(requestLine[1]) : "/"

                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }

                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                let currentBodyLen = acc.count - bodyStart
                if currentBodyLen < contentLength && !isComplete && error == nil && contentLength <= 500 * 1024 * 1024 {
                    self.receiveHTTPRequest(connection: connection, buffer: acc)
                    return
                }

                let bodyData = Data(acc[bodyStart..<min(acc.count, bodyStart + contentLength)])
                Task { @MainActor in
                    let (statusCode, responseBody) = await self.processHTTP(
                        method: method,
                        rawTarget: rawTarget,
                        headers: headers,
                        body: bodyData
                    )
                    self.sendHTTPResponse(connection: connection, status: statusCode, body: responseBody)
                }
            } else if !isComplete && error == nil && acc.count < 64 * 1024 {
                self.receiveHTTPRequest(connection: connection, buffer: acc)
            } else {
                connection.cancel()
            }
        }
    }

    nonisolated private func sendHTTPResponse(connection: NWConnection, status: Int, body: Data) {
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Error")
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func processHTTP(
        method: String,
        rawTarget: String,
        headers: [String: String],
        body: Data
    ) async -> (Int, Data) {
        let comps = URLComponents(string: "http://localhost\(rawTarget)")
        let path = comps?.path ?? "/"
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        let authHeader = headers["authorization"] ?? ""
        let expected = "Bearer \(config.token)"
        let viaRelay = headers["x-wakepc-relay"] == "1"

        // Allow unauthenticated /status for direct LAN discovery; invalid Bearer still returns 401
        if path == "/status" && authHeader.isEmpty && !viaRelay {
            let sys = MacSystemController.shared
            let vol = sys.volumeState()
            let mic = sys.micState()
            let payload: [String: Any] = [
                "success": true,
                "message": "OpenWakePC Agent",
                "features": Self.allFeatures,
                "data": [
                    "ip": config.localIP,
                    "mac": config.macAddress,
                    "bcast": config.broadcastAddress,
                    "name": config.hostname,
                    "type": "mac",
                    "deviceId": config.deviceId,
                    "token": config.token,
                    "agentVersion": AgentConfig.agentVersion,
                    "features": Self.allFeatures,
                    "volume": vol.volume,
                    "muted": vol.muted,
                    "micVolume": mic.volume,
                    "micMuted": mic.muted,
                    "brightness": sys.getBrightness(),
                ],
            ]
            return (200, jsonBytes(payload))
        }

        guard authHeader == expected else {
            return (401, jsonBytes(["success": false, "message": "Unauthorized"]))
        }

        if path == "/upload" {
            if viaRelay {
                return (403, jsonBytes(["success": false, "message": "lanOnly"]))
            }
            return handleUpload(filename: query["name"] ?? "upload.bin", body: body)
        }

        // Merge JSON body fields on POST as fallback when parameters are passed in body
        if method == "POST",
           !body.isEmpty,
           (headers["content-type"] ?? "").lowercased().contains("application/json"),
           let jsonObj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for (k, v) in jsonObj where query[k] == nil {
                query[k] = "\(v)"
            }
        }

        let respData = await dispatchCommand(path: path, query: query, viaRelay: viaRelay)
        return (200, respData)
    }

    private func handleUpload(filename: String, body: Data) -> (Int, Data) {
        if body.count > 500 * 1024 * 1024 {
            return (413, jsonBytes(["success": false, "message": "File exceeds 500 MB limit"]))
        }
        let base = URL(fileURLWithPath: filename).lastPathComponent
        let sanitized = base.replacingOccurrences(of: "[^A-Za-z0-9._ -]+", with: "_", options: .regularExpression)
        let safeName = sanitized.isEmpty ? "upload.bin" : sanitized
        let dest = config.downloadsDirectory.appendingPathComponent(safeName)
        do {
            try FileManager.default.createDirectory(at: config.downloadsDirectory, withIntermediateDirectories: true)
            try body.write(to: dest)
            config.requestsCount += 1
            return (200, okJSON(message: "Saved \(safeName)", data: ["name": safeName, "bytes": body.count]))
        } catch {
            return (500, errJSON(error.localizedDescription))
        }
    }

    /// Unified dispatcher called both by LAN HTTP requests and E2EE Relay commands.
    func dispatchCommand(path: String, query: [String: String], viaRelay: Bool) async -> Data {
        config.requestsCount += 1
        let sys = MacSystemController.shared

        if viaRelay && (path.hasPrefix("/mouse/") || path == "/upload") {
            return errJSON("This feature is available on local Wi-Fi only (lanOnly)")
        }

        switch path {
        case "/status", "/":
            let vol = sys.volumeState()
            let mic = sys.micState()
            var data = scheduler.statusDict()
            data["ip"] = config.localIP
            data["mac"] = config.macAddress
            data["bcast"] = config.broadcastAddress
            data["name"] = config.hostname
            data["type"] = "mac"
            data["deviceId"] = config.deviceId
            data["agentVersion"] = AgentConfig.agentVersion
            data["features"] = Self.allFeatures
            data["volume"] = vol.volume
            data["muted"] = vol.muted
            data["micVolume"] = mic.volume
            data["micMuted"] = mic.muted
            data["brightness"] = sys.getBrightness()
            let diag: [String: Any] = [
                "wifiConnected": true,
                "primaryAdapter": AgentConfig.detectPrimaryIPv4().interface,
                "hasMultipleAdapters": false,
                "isVirtualAdapter": false,
                "agentVersion": AgentConfig.agentVersion,
                "networkProfile": "private",
                "thirdPartyAntivirus": false,
                "lanReachable": true,
                "problems": [] as [String],
            ]
            return okJSON(message: "Online", data: data, diagnostics: diag)

        case "/telemetry":
            return okJSON(data: sys.telemetry())

        case "/shutdown", "/restart", "/sleep", "/hibernate", "/lock", "/display-off", "/display-on":
            let (ok, msg) = sys.executePower(String(path.dropFirst()))
            return ok ? okJSON(message: msg) : errJSON(msg)

        case "/wake-other":
            let mac = query["mac"] ?? ""
            let bcast = query["bcast"] ?? config.broadcastAddress
            let port = Int(query["wolPort"] ?? "") ?? config.wolPort
            return sys.sendWoL(mac: mac, broadcast: bcast, port: port)
                ? okJSON(message: "WoL sent to \(mac)")
                : errJSON("Invalid MAC or broadcast")

        case "/shutdown-in", "/restart-in", "/sleep-in":
            let action = path.dropFirst().replacingOccurrences(of: "-in", with: "")
            let mins = Int(query["minutes"] ?? "0") ?? 0
            guard mins >= 1 else { return errJSON("Invalid minutes") }
            return okJSON(message: "Scheduled \(action)", data: scheduler.schedule(action: action, minutes: mins))

        case "/scheduled-status":
            return okJSON(data: scheduler.statusDict())

        case "/cancel-scheduled":
            return okJSON(message: "Cancelled", data: scheduler.cancelAll())

        case "/idle-action":
            let mins = Int(query["minutes"] ?? "10") ?? 10
            return okJSON(message: "Updated", data: scheduler.setIdleAction(query["action"], minutes: mins))

        case "/idle-notify":
            let hrs = Int(query["hours"] ?? "0") ?? 0
            return okJSON(message: "Updated", data: scheduler.setIdleNotify(hours: hrs))

        case "/volume-up":
            let v = sys.adjustVolume(delta: 5)
            return okJSON(data: ["volume": v.0, "muted": v.1])

        case "/volume-down":
            let v = sys.adjustVolume(delta: -5)
            return okJSON(data: ["volume": v.0, "muted": v.1])

        case "/volume-mute":
            let v = sys.toggleMute()
            return okJSON(data: ["volume": v.0, "muted": v.1])

        case "/mic-up":
            let m = sys.adjustMicVolume(delta: 5)
            return okJSON(data: ["micVolume": m.0, "micMuted": m.1])

        case "/mic-down":
            let m = sys.adjustMicVolume(delta: -5)
            return okJSON(data: ["micVolume": m.0, "micMuted": m.1])

        case "/mic-mute":
            let m = sys.toggleMicMute()
            return okJSON(data: ["micVolume": m.0, "micMuted": m.1])

        case "/audio-outputs":
            let list = sys.listAudioOutputs().map { ["id": $0.id, "name": $0.name, "isDefault": $0.isDefault] as [String: Any] }
            return okJSON(data: ["outputs": list])

        case "/audio-output/set":
            guard let id = query["id"], sys.setAudioOutput(id: id) else { return errJSON("Audio output not found") }
            let list = sys.listAudioOutputs().map { ["id": $0.id, "name": $0.name, "isDefault": $0.isDefault] as [String: Any] }
            return okJSON(message: "Updated", data: ["outputs": list])

        case "/audio-inputs":
            let list = sys.listAudioInputs().map { ["id": $0.id, "name": $0.name, "isDefault": $0.isDefault] as [String: Any] }
            return okJSON(data: ["inputs": list])

        case "/audio-input/set":
            guard let id = query["id"], sys.setAudioInput(id: id) else { return errJSON("Audio input not found") }
            let list = sys.listAudioInputs().map { ["id": $0.id, "name": $0.name, "isDefault": $0.isDefault] as [String: Any] }
            return okJSON(message: "Updated", data: ["inputs": list])

        case "/brightness-up":
            return okJSON(data: ["brightness": sys.setBrightness(sys.getBrightness() + 10)])

        case "/brightness-down":
            return okJSON(data: ["brightness": sys.setBrightness(sys.getBrightness() - 10)])

        case "/media-play-pause", "/media-next", "/media-prev", "/media-fullscreen":
            sys.mediaAction(path.replacingOccurrences(of: "/media-", with: ""))
            return okJSON()

        case "/screenshot":
            return handleScreenshot(query: query, viaRelay: viaRelay)

        case "/apps":
            let apps = sys.listRunningApps().map { ["id": $0.id, "name": $0.name, "icon": $0.icon ?? "app"] as [String: Any] }
            return okJSON(data: ["apps": apps])

        case "/apps/close":
            let force = (query["force"] ?? "false").lowercased() == "true"
            let (ok, msg) = sys.closeApp(pidString: query["id"] ?? "", force: force)
            return ok ? okJSON(message: msg) : errJSON(msg)

        case "/commands":
            return okJSON(data: ["commands": commands.serializedList()])

        case "/command/run":
            let (ok, msg) = commands.run(id: query["id"] ?? "")
            return ok ? okJSON(message: msg, data: ["commands": commands.serializedList()]) : errJSON(msg)

        case "/command/close":
            let (ok, msg) = commands.close(id: query["id"] ?? "")
            return ok ? okJSON(message: msg, data: ["commands": commands.serializedList()]) : errJSON(msg)

        case "/open-url":
            guard let url = query["url"], sys.openURL(url) else { return errJSON("Invalid URL") }
            return okJSON(message: "URL opened")

        case "/clipboard":
            sys.setClipboard(query["text"] ?? "")
            return okJSON(message: "Copied to clipboard")

        case "/clipboard/get":
            let (text, truncated) = sys.getClipboard()
            return okJSON(data: ["text": text, "truncated": truncated])

        case "/mouse/move":
            let dx = max(-5000, min(5000, Int(query["dx"] ?? "0") ?? 0))
            let dy = max(-5000, min(5000, Int(query["dy"] ?? "0") ?? 0))
            sys.mouseMove(dx: dx, dy: dy)
            return okJSON()

        case "/mouse/scroll":
            let dx = max(-5000, min(5000, Int(query["dx"] ?? "0") ?? 0))
            let dy = max(-5000, min(5000, Int(query["dy"] ?? "0") ?? 0))
            sys.mouseScroll(dx: dx, dy: dy)
            return okJSON()

        case "/mouse/click":
            sys.mouseClick(button: query["button"] ?? "left", count: Int(query["count"] ?? "1") ?? 1)
            return okJSON()

        case "/mouse/drag":
            sys.mouseDrag(state: query["state"] ?? "up")
            return okJSON()

        case "/key/text":
            sys.typeText(query["text"] ?? "")
            return okJSON()

        case "/key/press":
            let mods = (query["mods"] ?? "").split(separator: ",").map(String.init)
            sys.pressKey(query["key"] ?? "", mods: mods)
            return okJSON()

        case "/stream/frame":
            let includeAudio = !viaRelay && (query["audio"] != "0")
            let sinceSeq = Int64(query["since"] ?? "0") ?? 0
            guard let frame = await ScreenStreamManager.shared.requestFrame(
                includeAudio: includeAudio,
                sinceSeq: sinceSeq,
                viaRelay: viaRelay
            ) else {
                return errJSON("Screen recording permission required")
            }
            var payload: [String: Any] = [
                "format": "jpeg",
                "width": frame.width,
                "height": frame.height,
                "image": frame.imageData.base64EncodedString(),
                "audioRate": frame.sampleRate,
                "audioChannels": frame.channels,
                "audioSeq": frame.audioSeq,
            ]
            if !frame.audioData.isEmpty {
                payload["audio"] = frame.audioData.base64EncodedString()
            }
            return okJSON(data: payload)

        case "/stream/stop":
            ScreenStreamManager.shared.stop()
            return okJSON(message: "Stream stopped")

        default:
            if path.hasPrefix("/volume-set/"), let level = Int(path.dropFirst("/volume-set/".count)) {
                let v = sys.setVolume(level)
                return okJSON(data: ["volume": v.0, "muted": v.1])
            }
            if path.hasPrefix("/mic-set/"), let level = Int(path.dropFirst("/mic-set/".count)) {
                let m = sys.setMicVolume(level)
                return okJSON(data: ["micVolume": m.0, "micMuted": m.1])
            }
            if path.hasPrefix("/brightness-set/"), let level = Int(path.dropFirst("/brightness-set/".count)) {
                return okJSON(data: ["brightness": sys.setBrightness(level)])
            }
            return errJSON("Unknown endpoint: \(path)")
        }
    }

    private func handleScreenshot(query: [String: String], viaRelay: Bool) -> Data {
        let chunkParam = query["chunk"]
        let forceChunks = viaRelay || chunkParam != nil
        let needFresh = cachedScreenshotB64.isEmpty || chunkParam == nil || chunkParam == "0" || Date().timeIntervalSince(cachedScreenshotAt) > 30
        if needFresh {
            guard let shot = MacSystemController.shared.captureScreenshotJPEG() else {
                return errJSON("Screen recording permission required")
            }
            cachedScreenshotB64 = shot.data.base64EncodedString()
            cachedScreenshotSize = (shot.width, shot.height)
            cachedScreenshotAt = Date()
        }

        if !forceChunks {
            return okJSON(data: [
                "format": "jpeg",
                "width": cachedScreenshotSize.width,
                "height": cachedScreenshotSize.height,
                "image": cachedScreenshotB64,
                "chunkIndex": 0,
                "chunkCount": 1,
            ])
        }

        let chunkChars = 220 * 1024
        let totalLen = cachedScreenshotB64.count
        let chunkCount = max(1, Int(ceil(Double(totalLen) / Double(chunkChars))))
        let idx = max(0, min(chunkCount - 1, Int(chunkParam ?? "0") ?? 0))
        let startIdx = cachedScreenshotB64.index(cachedScreenshotB64.startIndex, offsetBy: idx * chunkChars)
        let endOffset = min(totalLen, (idx + 1) * chunkChars)
        let endIdx = cachedScreenshotB64.index(cachedScreenshotB64.startIndex, offsetBy: endOffset)
        return okJSON(data: [
            "format": "jpeg",
            "width": cachedScreenshotSize.width,
            "height": cachedScreenshotSize.height,
            "image": String(cachedScreenshotB64[startIdx..<endIdx]),
            "chunkIndex": idx,
            "chunkCount": chunkCount,
        ])
    }

    private func okJSON(message: String = "OK", data: [String: Any]? = nil, diagnostics: [String: Any]? = nil) -> Data {
        var dict: [String: Any] = ["success": true, "message": message, "features": Self.allFeatures]
        if let data { dict["data"] = data }
        if let diagnostics { dict["diagnostics"] = diagnostics }
        return jsonBytes(dict)
    }

    private func errJSON(_ message: String) -> Data {
        jsonBytes(["success": false, "message": message, "features": Self.allFeatures])
    }

    private func jsonBytes(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"success":false}"#.utf8)
    }
}
