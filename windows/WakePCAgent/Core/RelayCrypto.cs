using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WakePCAgent.Core;

public sealed class RelayEnvelope
{
    [JsonPropertyName("v")] public int V { get; set; } = 1;
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("ts")] public long Ts { get; set; }
    [JsonPropertyName("n")] public string N { get; set; } = "";
    [JsonPropertyName("c")] public string C { get; set; } = "";
}

public sealed class RelayCommandPayload
{
    [JsonPropertyName("path")] public string Path { get; set; } = "/";
    [JsonPropertyName("query")] public Dictionary<string, string>? Query { get; set; }
}

/// <summary>
/// Exact `wakepc-relay-v1` E2EE cryptography matching iOS CryptoKit, macOS, and Python 1:1.
/// </summary>
public static class RelayCrypto
{
    public const int ProtocolVersion = 1;
    private static readonly byte[] HkdfSalt = Encoding.UTF8.GetBytes("wakepc-relay-v1");
    private static readonly byte[] RoomClaimLabel = Encoding.UTF8.GetBytes("room-claim");
    private const int GcmNonceBytes = 12;
    private const int GcmTagBytes = 16;

    public static byte[] DeriveKey(string token, string deviceId)
    {
        return HKDF.DeriveKey(
            HashAlgorithmName.SHA256,
            ikm: Encoding.UTF8.GetBytes(token),
            outputLength: 32,
            salt: HkdfSalt,
            info: Encoding.UTF8.GetBytes(deviceId));
    }

    public static string RoomClaim(byte[] key)
    {
        var mac = HMACSHA256.HashData(key, RoomClaimLabel);
        return Convert.ToBase64String(mac);
    }

    public static string ClaimProof(string nonce, byte[] key)
    {
        var claimBytes = HMACSHA256.HashData(key, RoomClaimLabel);
        byte[] nonceBytes;
        try { nonceBytes = Convert.FromBase64String(nonce); }
        catch { nonceBytes = Encoding.UTF8.GetBytes(nonce); }
        var mac = HMACSHA256.HashData(claimBytes, nonceBytes);
        return Convert.ToBase64String(mac);
    }

    public static byte[] AssociatedData(string deviceId) =>
        Encoding.UTF8.GetBytes($"{deviceId}:v{ProtocolVersion}");

    public static RelayEnvelope Seal(byte[] plaintext, byte[] key, string deviceId, string? id = null)
    {
        var nonce = RandomNumberGenerator.GetBytes(GcmNonceBytes);
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[GcmTagBytes];
        var aad = AssociatedData(deviceId);

        using var aes = new AesGcm(key, GcmTagBytes);
        aes.Encrypt(nonce, plaintext, ciphertext, tag, aad);

        var combined = new byte[ciphertext.Length + tag.Length];
        Buffer.BlockCopy(ciphertext, 0, combined, 0, ciphertext.Length);
        Buffer.BlockCopy(tag, 0, combined, ciphertext.Length, tag.Length);

        return new RelayEnvelope
        {
            V = ProtocolVersion,
            Id = (id ?? Guid.NewGuid().ToString("D")).ToLowerInvariant(),
            Ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            N = Convert.ToBase64String(nonce),
            C = Convert.ToBase64String(combined)
        };
    }

    public static byte[] Open(RelayEnvelope envelope, byte[] key, string deviceId)
    {
        if (envelope.V != ProtocolVersion)
            throw new CryptographicException("bad_version");

        var nonce = Convert.FromBase64String(envelope.N);
        var combined = Convert.FromBase64String(envelope.C);
        if (nonce.Length != GcmNonceBytes || combined.Length <= GcmTagBytes)
            throw new CryptographicException("bad_envelope");

        var ctLen = combined.Length - GcmTagBytes;
        var ciphertext = combined.AsSpan(0, ctLen);
        var tag = combined.AsSpan(ctLen, GcmTagBytes);
        var plaintext = new byte[ctLen];

        using var aes = new AesGcm(key, GcmTagBytes);
        aes.Decrypt(nonce, ciphertext, tag, plaintext, AssociatedData(deviceId));
        return plaintext;
    }
}
