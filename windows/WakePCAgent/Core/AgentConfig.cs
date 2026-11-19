using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;

namespace WakePCAgent.Core;

public enum CustomCommandKind
{
    App,
    Url,
    Shell
}

public sealed class CustomCommand
{
    public string Id { get; set; } = Guid.NewGuid().ToString("D");
    public string Name { get; set; } = "";
    public CustomCommandKind Kind { get; set; } = CustomCommandKind.App;
    public string Target { get; set; } = "";
    public string Icon { get; set; } = "terminal";
}

/// <summary>
/// Persistent configuration stored in %APPDATA%\OpenWakePC\config.json,
/// with optional relay.cfg override next to the executable.
/// </summary>
public sealed class AgentConfig
{
    public const string AgentVersion = "3.0.0-open-win";
    public const long MaxUploadBytes = 500L * 1024L * 1024L;

    public int ApiPort { get; set; } = 8765;
    public int WolPort { get; set; } = 9;
    public string Token { get; set; } = GenerateToken();
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("D");
    public string RelayUrl { get; set; } = "";
    public string RelayDiscoveryUrl { get; set; } = "";
    public int IdleNotifyHours { get; set; } = 0;
    public List<CustomCommand> CustomCommands { get; set; } = new();

    public static string ConfigDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenWakePC");

    public static string ConfigPath => Path.Combine(ConfigDirectory, "config.json");

    public static string DownloadsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    public string Hostname => Environment.MachineName;

    public static AgentConfig LoadOrCreate()
    {
        AgentConfig cfg;
        if (File.Exists(ConfigPath))
        {
            try
            {
                var json = File.ReadAllText(ConfigPath);
                cfg = JsonSerializer.Deserialize<AgentConfig>(json) ?? new AgentConfig();
            }
            catch
            {
                cfg = new AgentConfig();
            }
        }
        else
        {
            cfg = new AgentConfig();
            cfg.Save();
        }

        if (string.IsNullOrWhiteSpace(cfg.Token) || cfg.Token.Length < 8)
        {
            cfg.Token = GenerateToken();
            cfg.Save();
        }
        if (string.IsNullOrWhiteSpace(cfg.DeviceId))
        {
            cfg.DeviceId = Guid.NewGuid().ToString("D");
            cfg.Save();
        }

        // Optional relay.cfg override next to executable (compatible with WakePC Agent convention)
        var overrideFile = Path.Combine(AppContext.BaseDirectory, "relay.cfg");
        if (File.Exists(overrideFile))
        {
            var line = File.ReadAllText(overrideFile).Trim().TrimEnd('/');
            if (!string.IsNullOrEmpty(line))
            {
                cfg.RelayUrl = line;
            }
        }
        return cfg;
    }

    public void Save()
    {
        Directory.CreateDirectory(ConfigDirectory);
        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(ConfigPath, json);
    }

    public void RegenerateToken()
    {
        Token = GenerateToken();
        Save();
    }

    public string BuildQrUrl()
    {
        var net = DetectPrimaryNetwork();
        var qs = new Dictionary<string, string>
        {
            ["mac"] = net.Mac,
            ["ip"] = net.Ip,
            ["bcast"] = net.Broadcast,
            ["wolPort"] = WolPort.ToString(),
            ["apiPort"] = ApiPort.ToString(),
            ["token"] = Token,
            ["deviceType"] = "windows",
            ["deviceId"] = DeviceId
        };
        var query = string.Join("&", qs.Select(kv => $"{kv.Key}={Uri.EscapeDataString(kv.Value)}"));
        return $"wakepc://config?{query}";
    }

    public static string GenerateToken(int length = 32)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";
        var bytes = RandomNumberGenerator.GetBytes(length);
        var chars = new char[length];
        for (int i = 0; i < length; i++)
        {
            chars[i] = alphabet[bytes[i] % alphabet.Length];
        }
        return new string(chars);
    }

    public static (string Ip, string Broadcast, string Mac, string AdapterName, bool IsWifi, bool IsVirtual, bool HasMultiple) DetectPrimaryNetwork()
    {
        var upIfaces = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up
                     && n.NetworkInterfaceType != NetworkInterfaceType.Loopback
                     && n.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
            .ToList();

        NetworkInterface? best = upIfaces.FirstOrDefault(n =>
            n.GetIPProperties().GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork)
            && n.GetIPProperties().UnicastAddresses.Any(u => u.Address.AddressFamily == AddressFamily.InterNetwork));

        best ??= upIfaces.FirstOrDefault(n =>
            n.GetIPProperties().UnicastAddresses.Any(u => u.Address.AddressFamily == AddressFamily.InterNetwork));

        if (best is null)
        {
            return ("127.0.0.1", "255.255.255.255", "00:00:00:00:00:00", "Loopback", false, false, false);
        }

        var uni = best.GetIPProperties().UnicastAddresses
            .First(u => u.Address.AddressFamily == AddressFamily.InterNetwork);
        var ipBytes = uni.Address.GetAddressBytes();
        var maskBytes = uni.IPv4Mask?.GetAddressBytes() ?? new byte[] { 255, 255, 255, 0 };
        var bcastBytes = new byte[4];
        for (int i = 0; i < 4; i++) bcastBytes[i] = (byte)(ipBytes[i] | ~maskBytes[i]);

        var macBytes = best.GetPhysicalAddress().GetAddressBytes();
        var mac = macBytes.Length == 6
            ? string.Join(":", macBytes.Select(b => b.ToString("X2")))
            : "00:00:00:00:00:00";

        var descLow = (best.Description + " " + best.Name).ToLowerInvariant();
        var isWifi = best.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 || descLow.Contains("wi-fi");
        var isVirtual = descLow.Contains("virtual") || descLow.Contains("vmware") || descLow.Contains("vbox") || descLow.Contains("hyper-v") || descLow.Contains("docker");

        return (
            uni.Address.ToString(),
            new IPAddress(bcastBytes).ToString(),
            mac,
            best.Name,
            isWifi,
            isVirtual,
            upIfaces.Count > 1
        );
    }
}
