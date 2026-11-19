import Darwin
import Foundation

/// Sends standard 102-byte Wake-on-LAN Magic Packets over POSIX UDP broadcast (3x).
public enum WoLSender {
    public static func buildMagicPacket(mac: String) throws -> [UInt8] {
        let normalized = mac.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
        guard PCQRCode.isValidMAC(normalized) else {
            throw NetworkError.invalidMAC
        }

        let hexParts = normalized.split(separator: ":")
        var macBytes: [UInt8] = []
        macBytes.reserveCapacity(6)
        for part in hexParts {
            guard let byte = UInt8(part, radix: 16) else {
                throw NetworkError.invalidMAC
            }
            macBytes.append(byte)
        }

        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }

    public static func send(
        mac: String,
        broadcast: String,
        ip: String? = nil,
        port: Int = SharedConfig.defaultWoLPort,
        repeatCount: Int = 3
    ) throws {
        guard (1...65535).contains(port) else {
            throw NetworkError.invalidPort
        }
        let packet = try buildMagicPacket(mac: mac)
        let targetBroadcast = broadcast.isEmpty ? "255.255.255.255" : broadcast

        var targets: [(host: String, port: Int)] = [(targetBroadcast, port)]
        func appendUnique(_ host: String, _ targetPort: Int) {
            if !targets.contains(where: { $0.host == host && $0.port == targetPort }) {
                targets.append((host, targetPort))
            }
        }
        if targetBroadcast != "255.255.255.255" {
            appendUnique("255.255.255.255", port)
        }
        if let ip = ip?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ip.isEmpty,
           !ip.contains(":"),
           ip != "127.0.0.1" {
            var testAddr = in_addr()
            if inet_pton(AF_INET, ip, &testAddr) == 1 {
                appendUnique(ip, port)
            }
        }
        if port == 9 {
            appendUnique(targetBroadcast, 7)
        }

        var anySent = false
        var lastError: NetworkError?
        for target in targets {
            do {
                try sendPacket(packet, to: target.host, port: target.port, repeatCount: repeatCount)
                anySent = true
            } catch let err as NetworkError {
                lastError = err
            }
        }
        if !anySent {
            throw lastError ?? NetworkError.connectionFailed("Failed to send Magic Packet")
        }
    }

    private static func sendPacket(_ packet: [UInt8], to host: String, port: Int, repeatCount: Int) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw NetworkError.connectionFailed("Failed to create UDP socket")
        }
        defer { close(fd) }

        var enableBroadcast: Int32 = 1
        let optRes = setsockopt(
            fd,
            SOL_SOCKET,
            SO_BROADCAST,
            &enableBroadcast,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard optRes == 0 else {
            throw NetworkError.permissionDenied
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian

        let convRes = host.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        guard convRes == 1 else {
            throw NetworkError.connectionFailed("Invalid target address \(host)")
        }

        for _ in 0..<max(1, repeatCount) {
            let sent = packet.withUnsafeBytes { rawBuf -> ssize_t in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        sendto(
                            fd,
                            rawBuf.baseAddress,
                            packet.count,
                            0,
                            sockPtr,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
            if sent < 0 {
                let errCode = errno
                if errCode == EACCES || errCode == EPERM {
                    throw NetworkError.permissionDenied
                }
                throw NetworkError.connectionFailed("UDP sendto failed (errno \(errCode))")
            }
        }
    }
}
