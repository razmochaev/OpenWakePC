import Darwin
import Foundation
import Network

public struct DiscoveredPC: Identifiable, Equatable, Sendable {
    public var id: String { mac.isEmpty ? ip : mac }
    public let name: String
    public let ip: String
    public let mac: String
    public let broadcast: String
    public let apiPort: Int
    public let wolPort: Int
    public let deviceType: DeviceType
    public let deviceId: String?
    public let token: String?
    public let agentVersion: String?
}

/// Discovers Wake PC Agents on the local network via Bonjour (`_wakepc._tcp`)
/// and concurrent HTTP `/status` subnet scanning on port 8765.
@MainActor
public final class PCDiscoveryService: ObservableObject {
    @Published public private(set) var discovered: [DiscoveredPC] = []
    @Published public private(set) var isScanning = false

    private var browser: NWBrowser?
    private let browseQueue = DispatchQueue(label: "com.wakepc.bonjour")

    public init() {}

    public func startScan() {
        stopScan()
        discovered = []
        isScanning = true
        startBonjourBrowse()
        Task {
            await scanLocalSubnet()
            isScanning = false
        }
    }

    public func stopScan() {
        browser?.cancel()
        browser = nil
        isScanning = false
    }

    private func startBonjourBrowse() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: SharedConfig.bonjourServiceType,
            domain: "local."
        )
        let nwBrowser = NWBrowser(for: descriptor, using: params)
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                self?.resolveBonjourResult(result)
            }
        }
        nwBrowser.start(queue: browseQueue)
        self.browser = nwBrowser
    }

    nonisolated private func resolveBonjourResult(_ result: NWBrowser.Result) {
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            for key in ["ip", "mac", "bcast", "name", "type", "deviceId", "token", "apiPort", "wolPort", "version"] {
                if let entry = record.getEntry(for: key), case .string(let val) = entry {
                    txt[key] = val
                }
            }
        }
        let txtSnapshot = txt

        if let txtIP = txtSnapshot["ip"], Self.isValidIPv4(txtIP) {
            let item = DiscoveredPC(
                name: txtSnapshot["name"] ?? txtIP,
                ip: txtIP,
                mac: (txtSnapshot["mac"] ?? "").uppercased(),
                broadcast: txtSnapshot["bcast"] ?? PCProfile.deriveBroadcast(from: txtIP),
                apiPort: Int(txtSnapshot["apiPort"] ?? "") ?? SharedConfig.defaultAPIPort,
                wolPort: Int(txtSnapshot["wolPort"] ?? "") ?? SharedConfig.defaultWoLPort,
                deviceType: DeviceType(rawValue: txtSnapshot["type"] ?? "windows") ?? .windows,
                deviceId: txtSnapshot["deviceId"],
                token: txtSnapshot["token"],
                agentVersion: txtSnapshot["version"]
            )
            Task { @MainActor [weak self] in
                self?.upsertDiscovered(item)
            }
        }

        let conn = NWConnection(to: result.endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let remote = conn.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remote {
                    let remoteIP = Self.cleanHostString("\(host)")
                    let resolvedIP = Self.isValidIPv4(txtSnapshot["ip"]) ? txtSnapshot["ip"]! : remoteIP
                    guard !resolvedIP.contains(":") else {
                        conn.cancel()
                        return
                    }
                    let item = DiscoveredPC(
                        name: txtSnapshot["name"] ?? resolvedIP,
                        ip: resolvedIP,
                        mac: (txtSnapshot["mac"] ?? "").uppercased(),
                        broadcast: txtSnapshot["bcast"] ?? PCProfile.deriveBroadcast(from: resolvedIP),
                        apiPort: Int(txtSnapshot["apiPort"] ?? "") ?? Int(port.rawValue),
                        wolPort: Int(txtSnapshot["wolPort"] ?? "") ?? SharedConfig.defaultWoLPort,
                        deviceType: DeviceType(rawValue: txtSnapshot["type"] ?? "windows") ?? .windows,
                        deviceId: txtSnapshot["deviceId"],
                        token: txtSnapshot["token"],
                        agentVersion: txtSnapshot["version"]
                    )
                    Task { @MainActor [weak self] in
                        self?.upsertDiscovered(item)
                    }
                }
                conn.cancel()
            } else if case .failed = state {
                conn.cancel()
            }
        }
        conn.start(queue: browseQueue)
    }

    private func scanLocalSubnet() async {
        guard let localIP = Self.localWiFiIPv4() else { return }
        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else { return }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.9
        config.timeoutIntervalForResource = 1.1
        let scanSession = URLSession(configuration: config)
        defer { scanSession.invalidateAndCancel() }

        await withTaskGroup(of: DiscoveredPC?.self) { group in
            var active = 0
            for host in 1...254 {
                let candidateIP = "\(prefix).\(host)"
                if candidateIP == localIP { continue }
                if active >= 32 {
                    if let found = await group.next(), let pc = found {
                        upsertDiscovered(pc)
                    }
                    active -= 1
                }
                active += 1
                group.addTask {
                    await Self.probeAgent(ip: candidateIP, port: SharedConfig.defaultAPIPort, session: scanSession)
                }
            }
            for await result in group {
                if let pc = result {
                    upsertDiscovered(pc)
                }
            }
        }
    }

    private func upsertDiscovered(_ pc: DiscoveredPC) {
        if let idx = discovered.firstIndex(where: {
            $0.id == pc.id || $0.ip == pc.ip || (pc.deviceId != nil && !pc.deviceId!.isEmpty && $0.deviceId == pc.deviceId)
        }) {
            let old = discovered[idx]
            let useIP = (pc.ip.contains(":") && !old.ip.isEmpty && !old.ip.contains(":")) ? old.ip : pc.ip
            let useBcast = (useIP == old.ip && !old.broadcast.isEmpty) ? old.broadcast : pc.broadcast
            let useMAC = !pc.mac.isEmpty ? pc.mac : old.mac
            let useToken = (pc.token?.isEmpty == false) ? pc.token : old.token
            let useDeviceId = (pc.deviceId?.isEmpty == false) ? pc.deviceId : old.deviceId
            discovered[idx] = DiscoveredPC(
                name: pc.name.isEmpty ? old.name : pc.name,
                ip: useIP,
                mac: useMAC,
                broadcast: useBcast,
                apiPort: pc.apiPort,
                wolPort: pc.wolPort,
                deviceType: pc.deviceType,
                deviceId: useDeviceId,
                token: useToken,
                agentVersion: pc.agentVersion ?? old.agentVersion
            )
        } else {
            discovered.append(pc)
        }
    }

    nonisolated public static func probeAgent(
        ip: String,
        port: Int = SharedConfig.defaultAPIPort,
        session: URLSession
    ) async -> DiscoveredPC? {
        guard let url = URL(string: "http://\(ip):\(port)/status") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.9
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ApiResponse.self, from: data),
              let info = decoded.data
        else {
            return nil
        }
        let resolvedIP = (info.ip?.isEmpty == false && isValidIPv4(info.ip)) ? info.ip! : ip
        return DiscoveredPC(
            name: info.name ?? resolvedIP,
            ip: resolvedIP,
            mac: (info.mac ?? "").uppercased(),
            broadcast: info.bcast ?? PCProfile.deriveBroadcast(from: resolvedIP),
            apiPort: port,
            wolPort: SharedConfig.defaultWoLPort,
            deviceType: DeviceType(rawValue: info.type ?? "windows") ?? .windows,
            deviceId: info.deviceId,
            token: info.token,
            agentVersion: info.agentVersion
        )
    }

    nonisolated public static func localWiFiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let iface = current.pointee
            if let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        return String(cString: hostBuffer)
                    }
                }
            }
            cursor = iface.ifa_next
        }
        return nil
    }

    nonisolated private static func cleanHostString(_ raw: String) -> String {
        if let pct = raw.firstIndex(of: "%") {
            return String(raw[..<pct])
        }
        return raw
    }

    nonisolated public static func isValidIPv4(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, !value.contains(":"), value != "127.0.0.1" else {
            return false
        }
        var addr = in_addr()
        return inet_pton(AF_INET, value, &addr) == 1
    }
}

/// Automatically heals stale LAN IP addresses (e.g. after DHCP lease renewal) and repairs missing LAN credentials by matching MAC address or deviceId.
public enum LANAddressHealer {
    public struct Candidate: Sendable {
        public let ip: String
        public let port: Int
        public let broadcast: String
        public let mac: String?
        public let token: String?
        public let deviceId: String?
    }

    private final class BonjourHealState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<Candidate?, Never>
        var browser: NWBrowser?

        init(continuation: CheckedContinuation<Candidate?, Never>) {
            self.continuation = continuation
        }

        func finish(with candidate: Candidate?) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let b = browser
            browser = nil
            lock.unlock()
            b?.cancel()
            continuation.resume(returning: candidate)
        }
    }

    private static func bonjourHeal(profile: PCProfile, timeoutMs: Int = 1200) async -> Candidate? {
        let targetMAC = profile.mac.uppercased()
        let targetDeviceId = (profile.deviceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetMAC.isEmpty || !targetDeviceId.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            let state = BonjourHealState(continuation: continuation)
            let queue = DispatchQueue(label: "com.wakepc.bonjour.heal")
            let params = NWParameters()
            params.includePeerToPeer = true
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: SharedConfig.bonjourServiceType,
                domain: "local."
            )
            let browser = NWBrowser(for: descriptor, using: params)
            state.browser = browser

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case .bonjour(let record) = result.metadata else { continue }
                    var txt: [String: String] = [:]
                    for key in ["ip", "mac", "bcast", "deviceId", "token", "apiPort"] {
                        if let entry = record.getEntry(for: key), case .string(let val) = entry {
                            txt[key] = val
                        }
                    }
                    guard let txtIP = txt["ip"], PCDiscoveryService.isValidIPv4(txtIP) else { continue }
                    let txtMAC = (txt["mac"] ?? "").uppercased()
                    let txtDeviceId = (txt["deviceId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let matchedDeviceId = !targetDeviceId.isEmpty && txtDeviceId == targetDeviceId
                    let matchedMAC = !targetMAC.isEmpty && txtMAC == targetMAC
                    guard matchedDeviceId || matchedMAC else { continue }

                    let port = Int(txt["apiPort"] ?? "") ?? profile.apiPort
                    let bcast = (txt["bcast"]?.isEmpty == false) ? txt["bcast"]! : PCProfile.deriveBroadcast(from: txtIP)
                    state.finish(with: Candidate(
                        ip: txtIP,
                        port: port,
                        broadcast: bcast,
                        mac: txtMAC.isEmpty ? nil : txtMAC,
                        token: txt["token"],
                        deviceId: txtDeviceId.isEmpty ? nil : txtDeviceId
                    ))
                    return
                }
            }

            browser.stateUpdateHandler = { newState in
                if case .failed = newState {
                    state.finish(with: nil)
                }
            }

            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                state.finish(with: nil)
            }
        }
    }

    public static func heal(profile: PCProfile) async -> Candidate? {
        let targetMAC = profile.mac.uppercased()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.8
        let scanSession = URLSession(configuration: config)
        defer { scanSession.invalidateAndCancel() }

        if PCDiscoveryService.isValidIPv4(profile.ip),
           let direct = await PCDiscoveryService.probeAgent(ip: profile.ip, port: profile.apiPort, session: scanSession),
           targetMAC.isEmpty || direct.mac.uppercased() == targetMAC || (profile.deviceId != nil && direct.deviceId == profile.deviceId) {
            return Candidate(
                ip: direct.ip,
                port: direct.apiPort,
                broadcast: direct.broadcast,
                mac: direct.mac,
                token: direct.token,
                deviceId: direct.deviceId
            )
        }

        if let byBonjour = await bonjourHeal(profile: profile) {
            return byBonjour
        }

        guard let localIP = PCDiscoveryService.localWiFiIPv4() else { return nil }
        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"

        return await withTaskGroup(of: DiscoveredPC?.self) { group in
            var active = 0
            for host in 1...254 {
                let candidateIP = "\(prefix).\(host)"
                if candidateIP == localIP || candidateIP == profile.ip { continue }
                if active >= 32 {
                    if let found = await group.next(), let pc = found,
                       (!targetMAC.isEmpty && pc.mac.uppercased() == targetMAC)
                        || (profile.deviceId != nil && !profile.deviceId!.isEmpty && pc.deviceId == profile.deviceId) {
                        group.cancelAll()
                        return Candidate(
                            ip: pc.ip,
                            port: pc.apiPort,
                            broadcast: pc.broadcast,
                            mac: pc.mac,
                            token: pc.token,
                            deviceId: pc.deviceId
                        )
                    }
                    active -= 1
                }
                active += 1
                group.addTask {
                    await PCDiscoveryService.probeAgent(ip: candidateIP, port: profile.apiPort, session: scanSession)
                }
            }
            for await item in group {
                if let pc = item,
                   (!targetMAC.isEmpty && pc.mac.uppercased() == targetMAC)
                    || (profile.deviceId != nil && !profile.deviceId!.isEmpty && pc.deviceId == profile.deviceId) {
                    group.cancelAll()
                    return Candidate(
                        ip: pc.ip,
                        port: pc.apiPort,
                        broadcast: pc.broadcast,
                        mac: pc.mac,
                        token: pc.token,
                        deviceId: pc.deviceId
                    )
                }
            }
            return nil
        }
    }
}
