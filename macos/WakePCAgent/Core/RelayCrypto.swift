import CryptoKit
import Foundation

/// Exact `wakepc-relay-v1` E2EE protocol matching iOS, Windows, and Python implementations 1:1.
enum RelayCrypto {
    static let protocolVersion = 1
    static let hkdfSalt = Data("wakepc-relay-v1".utf8)
    static let roomClaimLabel = Data("room-claim".utf8)
    static let gcmTagLength = 16

    struct Envelope: Codable, Sendable {
        let v: Int
        let id: String
        let ts: Int
        let n: String
        let c: String
    }

    struct CommandPayload: Codable, Sendable {
        let path: String
        let query: [String: String]?
    }

    static func deriveKey(token: String, deviceId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(token.utf8)),
            salt: hkdfSalt,
            info: Data(deviceId.utf8),
            outputByteCount: 32
        )
    }

    static func roomClaim(token: String, deviceId: String) -> String {
        let key = deriveKey(token: token, deviceId: deviceId)
        let mac = HMAC<SHA256>.authenticationCode(for: roomClaimLabel, using: key)
        return Data(mac).base64EncodedString()
    }

    static func claimProof(token: String, deviceId: String, nonce: String) -> String {
        let key = deriveKey(token: token, deviceId: deviceId)
        let claimBytes = Data(HMAC<SHA256>.authenticationCode(for: roomClaimLabel, using: key))
        let nonceBytes = Data(base64Encoded: nonce) ?? Data(nonce.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: nonceBytes, using: SymmetricKey(data: claimBytes))
        return Data(mac).base64EncodedString()
    }

    static func associatedData(deviceId: String) -> Data {
        Data("\(deviceId):v\(protocolVersion)".utf8)
    }

    static func seal(
        plaintext: Data,
        token: String,
        deviceId: String,
        id: String = UUID().uuidString.lowercased()
    ) throws -> Envelope {
        let key = deriveKey(token: token, deviceId: deviceId)
        let aad = associatedData(deviceId: deviceId)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nil, authenticating: aad)
        return Envelope(
            v: protocolVersion,
            id: id.lowercased(),
            ts: Int(Date().timeIntervalSince1970),
            n: Data(box.nonce).base64EncodedString(),
            c: (box.ciphertext + box.tag).base64EncodedString()
        )
    }

    static func open(envelope: Envelope, token: String, deviceId: String) throws -> Data {
        guard envelope.v == protocolVersion,
              let nonceData = Data(base64Encoded: envelope.n),
              let combined = Data(base64Encoded: envelope.c),
              combined.count > gcmTagLength
        else {
            throw NSError(domain: "RelayCrypto", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad_envelope"])
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let ct = combined.prefix(combined.count - gcmTagLength)
        let tag = combined.suffix(gcmTagLength)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let key = deriveKey(token: token, deviceId: deviceId)
        return try AES.GCM.open(box, using: key, authenticating: associatedData(deviceId: deviceId))
    }
}
