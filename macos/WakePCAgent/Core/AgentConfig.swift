import Darwin
import Foundation

/// Persistent configuration for the Open Wake PC native macOS Menu Bar Agent.
@MainActor
final class AgentConfig: ObservableObject {
    static let shared = AgentConfig()
    static let agentVersion = "3.0.0-open-mac"
    static let defaultRelayDiscoveryURL = "https://wakepc.app/relay.json"
    static let defaultRelayFallbackURL = "https://relay.wakepc.app"

    private let defaults = UserDefaults.standard

    @Published var port: Int {
        didSet { defaults.set(port, forKey: "agent_port") }
    }
    @Published var wolPort: Int {
        didSet { defaults.set(wolPort, forKey: "agent_wol_port") }
    }
    @Published var token: String {
        didSet { defaults.set(token, forKey: "agent_token") }
    }
    @Published var deviceId: String {
        didSet { defaults.set(deviceId, forKey: "agent_device_id") }
    }
    @Published var relayMode: String {
        didSet { defaults.set(relayMode, forKey: "agent_relay_mode") }
    }
    @Published var customRelayURL: String {
        didSet { defaults.set(customRelayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), forKey: "agent_relay_url") }
    }
    @Published var relayDiscoveryURL: String {
        didSet { defaults.set(relayDiscoveryURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "agent_relay_discovery_url") }
    }
    @Published var seenWelcome: Bool {
        didSet { defaults.set(seenWelcome, forKey: "agent_seen_welcome") }
    }
    var requestsCount: Int = 0
    let hostname: String

    private nonisolated(unsafe) static var cachedNet: (ip: String, broadcast: String, interface: String, at: Date)?
    private nonisolated(unsafe) static var cachedMAC: (mac: String, at: Date)?
    private nonisolated static let netCacheLock = NSLock()

    var localIP: String {
        Self.detectPrimaryIPv4().ip
    }

    var broadcastAddress: String {
        Self.detectPrimaryIPv4().broadcast
    }

    var macAddress: String {
        Self.detectPrimaryMAC()
    }

    var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    private init() {
        self.hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let savedPort = defaults.integer(forKey: "agent_port")
        self.port = savedPort > 0 ? savedPort : 8765

        let savedWol = defaults.integer(forKey: "agent_wol_port")
        self.wolPort = savedWol > 0 ? savedWol : 9

        if let existingToken = defaults.string(forKey: "agent_token"), existingToken.count >= 8 {
            self.token = existingToken
        } else {
            let fresh = Self.generateToken()
            defaults.set(fresh, forKey: "agent_token")
            self.token = fresh
        }

        if let existingId = defaults.string(forKey: "agent_device_id"), !existingId.isEmpty {
            self.deviceId = existingId
        } else {
            let freshId = UUID().uuidString.lowercased()
            defaults.set(freshId, forKey: "agent_device_id")
            self.deviceId = freshId
        }

        let savedCustomURL = defaults.string(forKey: "agent_relay_url") ?? ""
        self.customRelayURL = savedCustomURL
        let savedMode = defaults.string(forKey: "agent_relay_mode")
        if let savedMode, ["cloud", "custom", "off"].contains(savedMode) {
            self.relayMode = savedMode
        } else {
            self.relayMode = savedCustomURL.isEmpty ? "cloud" : "custom"
        }
        self.relayDiscoveryURL = defaults.string(forKey: "agent_relay_discovery_url") ?? ""
        self.seenWelcome = defaults.bool(forKey: "agent_seen_welcome")
    }

    func regenerateToken() {
        token = Self.generateToken()
    }

    func buildQRURL() -> String {
        var comps = URLComponents()
        comps.scheme = "wakepc"
        comps.host = "config"
        var items = [
            URLQueryItem(name: "mac", value: macAddress),
            URLQueryItem(name: "ip", value: localIP),
            URLQueryItem(name: "bcast", value: broadcastAddress),
            URLQueryItem(name: "wolPort", value: String(wolPort)),
            URLQueryItem(name: "apiPort", value: String(port)),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "deviceType", value: "mac"),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]
        let cleanedRelay = customRelayURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if relayMode == "custom" && !cleanedRelay.isEmpty {
            items.append(URLQueryItem(name: "relay", value: cleanedRelay))
        }
        comps.queryItems = items
        return comps.url?.absoluteString ?? ""
    }

    static func generateToken(length: Int = 32) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    nonisolated static func invalidateNetworkCache() {
        netCacheLock.lock()
        cachedNet = nil
        cachedMAC = nil
        netCacheLock.unlock()
    }

    nonisolated static func detectPrimaryIPv4() -> (ip: String, broadcast: String, interface: String) {
        netCacheLock.lock()
        if let c = cachedNet, Date().timeIntervalSince(c.at) < 10.0 {
            netCacheLock.unlock()
            return (c.ip, c.broadcast, c.interface)
        }
        netCacheLock.unlock()

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return ("127.0.0.1", "255.255.255.255", "lo0")
        }
        defer { freeifaddrs(ifaddr) }

        var fallback = ("127.0.0.1", "255.255.255.255", "lo0")
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let iface = current.pointee
            let flags = Int32(iface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0
            if isUp, let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                let ip = numericIPv4(addr)
                var bcast = "255.255.255.255"
                if let maskAddr = iface.ifa_netmask,
                   let ipRaw = ipv4UInt32(addr),
                   let maskRaw = ipv4UInt32(maskAddr) {
                    let bcastRaw = ipRaw | ~maskRaw
                    bcast = uint32ToIPv4(bcastRaw)
                }
                if name == "en0" || name == "en1" {
                    netCacheLock.lock()
                    cachedNet = (ip, bcast, name, Date())
                    netCacheLock.unlock()
                    return (ip, bcast, name)
                }
                fallback = (ip, bcast, name)
            }
            cursor = iface.ifa_next
        }
        netCacheLock.lock()
        cachedNet = (fallback.0, fallback.1, fallback.2, Date())
        netCacheLock.unlock()
        return fallback
    }

    nonisolated static func detectPrimaryMAC() -> String {
        netCacheLock.lock()
        if let c = cachedMAC, Date().timeIntervalSince(c.at) < 10.0 {
            netCacheLock.unlock()
            return c.mac
        }
        netCacheLock.unlock()

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "00:00:00:00:00:00" }
        defer { freeifaddrs(ifaddr) }

        let preferredIface = detectPrimaryIPv4().interface
        var en0Fallback: String?
        var fallback = "00:00:00:00:00:00"
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let iface = current.pointee
            if let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: iface.ifa_name)
                let mac = linkAddressString(addr)
                if mac != "00:00:00:00:00:00" {
                    if name == preferredIface {
                        netCacheLock.lock()
                        cachedMAC = (mac, Date())
                        netCacheLock.unlock()
                        return mac
                    }
                    if name == "en0" {
                        en0Fallback = mac
                    }
                    fallback = mac
                }
            }
            cursor = iface.ifa_next
        }
        let result = en0Fallback ?? fallback
        netCacheLock.lock()
        cachedMAC = (result, Date())
        netCacheLock.unlock()
        return result
    }

    nonisolated private static func numericIPv4(_ addr: UnsafeMutablePointer<sockaddr>) -> String {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        return String(cString: buf)
    }

    nonisolated private static func ipv4UInt32(_ addr: UnsafeMutablePointer<sockaddr>) -> UInt32? {
        addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
            UInt32(bigEndian: ptr.pointee.sin_addr.s_addr)
        }
    }

    nonisolated private static func uint32ToIPv4(_ val: UInt32) -> String {
        "\((val >> 24) & 0xFF).\((val >> 16) & 0xFF).\((val >> 8) & 0xFF).\(val & 0xFF)"
    }

    nonisolated private static func linkAddressString(_ addr: UnsafeMutablePointer<sockaddr>) -> String {
        addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { ptr in
            let dl = ptr.pointee
            let nlen = Int(dl.sdl_nlen)
            let alen = Int(dl.sdl_alen)
            guard alen == 6 else { return "00:00:00:00:00:00" }
            let base = UnsafeRawPointer(ptr).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + nlen)
            let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
            return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }
}
