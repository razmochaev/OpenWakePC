import CryptoKit
import Foundation

/// Exact Swift CryptoKit implementation of the `wakepc-relay-v1` E2EE protocol.
/// Matches `common/crypto.py` 1:1.
public enum RelayCrypto {
    public static let protocolVersion = 1
    public static let hkdfSalt = Data("wakepc-relay-v1".utf8)
    public static let roomClaimLabel = Data("room-claim".utf8)
    public static let gcmTagLength = 16

    public struct CommandPayload: Codable, Sendable {
        public let path: String
        public let query: [String: String]?

        public init(path: String, query: [String: String] = [:]) {
            self.path = path
            self.query = query.isEmpty ? nil : query
        }
    }

    public struct Envelope: Codable, Sendable {
        public let v: Int
        public let id: String
        public let ts: Int
        public let n: String
        public let c: String
    }

    public static func deriveKey(token: String, deviceId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: hkdfSalt,
            info: Data(deviceId.utf8),
            outputByteCount: 32
        )
    }

    public static func roomClaim(token: String, deviceId: String) -> String {
        let key = deriveKey(token: token, deviceId: deviceId)
        let mac = HMAC<SHA256>.authenticationCode(for: roomClaimLabel, using: key)
        return Data(mac).base64EncodedString()
    }

    public static func claimProof(token: String, deviceId: String, nonce: String) -> String {
        let key = deriveKey(token: token, deviceId: deviceId)
        let claimBytes = Data(HMAC<SHA256>.authenticationCode(for: roomClaimLabel, using: key))
        let nonceBytes = Data(base64Encoded: nonce) ?? Data(nonce.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: nonceBytes, using: SymmetricKey(data: claimBytes))
        return Data(mac).base64EncodedString()
    }

    public static func associatedData(deviceId: String) -> Data {
        Data("\(deviceId):v\(protocolVersion)".utf8)
    }

    public static func seal(
        plaintext: Data,
        token: String,
        deviceId: String,
        id: String = UUID().uuidString.lowercased(),
        timestamp: Int = Int(Date().timeIntervalSince1970)
    ) throws -> Envelope {
        let key = deriveKey(token: token, deviceId: deviceId)
        let aad = associatedData(deviceId: deviceId)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nil, authenticating: aad)
        let combinedCiphertextAndTag = sealedBox.ciphertext + sealedBox.tag

        return Envelope(
            v: protocolVersion,
            id: id.lowercased(),
            ts: timestamp,
            n: Data(sealedBox.nonce).base64EncodedString(),
            c: combinedCiphertextAndTag.base64EncodedString()
        )
    }

    public static func open(
        envelope: Envelope,
        token: String,
        deviceId: String
    ) throws -> Data {
        guard let nonceData = Data(base64Encoded: envelope.n),
              let combined = Data(base64Encoded: envelope.c),
              combined.count > gcmTagLength
        else {
            throw NetworkError.connectionFailed("Malformed E2EE response envelope")
        }

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let ciphertext = combined.prefix(combined.count - gcmTagLength)
        let tag = combined.suffix(gcmTagLength)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let key = deriveKey(token: token, deviceId: deviceId)
        let aad = associatedData(deviceId: deviceId)
        return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
    }
}
