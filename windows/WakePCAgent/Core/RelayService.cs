using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WakePCAgent.Core;

/// <summary>
/// Persistent E2EE WebSocket client speaking the official `/agent/{deviceId}` challenge-response protocol.
/// </summary>
public sealed class RelayService : IDisposable
{
    private readonly AgentConfig _config;
    private readonly Func<string, Dictionary<string, string>, bool, Task<string>> _dispatcher;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(10) };

    private CancellationTokenSource? _cts;
    private ClientWebSocket? _activeSocket;
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    public bool IsOnline { get; private set; }
    public string StatusText { get; private set; } = "LAN-only";
    public event Action? StatusChanged;

    public RelayService(
        AgentConfig config,
        Func<string, Dictionary<string, string>, bool, Task<string>> dispatcher)
    {
        _config = config;
        _dispatcher = dispatcher;
    }

    public void Start()
    {
        Stop();
        if (string.IsNullOrWhiteSpace(_config.RelayUrl) && string.IsNullOrWhiteSpace(_config.RelayDiscoveryUrl))
        {
            SetStatus(false, "LAN-only");
            return;
        }
        _cts = new CancellationTokenSource();
        _ = Task.Run(() => RunLoopAsync(_cts.Token));
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;
        try { _activeSocket?.Dispose(); } catch { }
        _activeSocket = null;
        SetStatus(false, "Stopped");
    }

    public async Task TrySendIdleNotifyAsync(int hours)
    {
        var ws = _activeSocket;
        if (ws is null || ws.State != WebSocketState.Open || !IsOnline) return;
        await SendJsonAsync(ws, new { t = "notify", @event = "idle", hours }, CancellationToken.None);
    }

    private async Task<string?> ResolveBaseUrlAsync(CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(_config.RelayUrl))
            return _config.RelayUrl.TrimEnd('/');

        if (!string.IsNullOrWhiteSpace(_config.RelayDiscoveryUrl))
        {
            using var resp = await _http.GetAsync(_config.RelayDiscoveryUrl, ct);
            resp.EnsureSuccessStatusCode();
            var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
            if (doc.RootElement.TryGetProperty("url", out var urlEl) ||
                doc.RootElement.TryGetProperty("relay_url", out urlEl))
                return urlEl.GetString()?.TrimEnd('/');
        }
        return null;
    }

    private async Task RunLoopAsync(CancellationToken ct)
    {
        int backoffSec = 1;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var baseUrl = await ResolveBaseUrlAsync(ct);
                if (string.IsNullOrWhiteSpace(baseUrl))
                {
                    SetStatus(false, "Relay URL unavailable");
                    await Task.Delay(5000, ct);
                    continue;
                }

                var wsUrl = baseUrl
                    .Replace("https://", "wss://", StringComparison.OrdinalIgnoreCase)
                    .Replace("http://", "ws://", StringComparison.OrdinalIgnoreCase)
                    + $"/agent/{Uri.EscapeDataString(_config.DeviceId)}";

                using var ws = new ClientWebSocket();
                _activeSocket = ws;
                await ws.ConnectAsync(new Uri(wsUrl), ct);

                var key = RelayCrypto.DeriveKey(_config.Token, _config.DeviceId);

                // 1. Challenge
                var challenge = await ReceiveJsonAsync(ws, ct);
                if (challenge is null || !challenge.RootElement.TryGetProperty("t", out var tEl) || tEl.GetString() != "challenge")
                    throw new InvalidOperationException("expected challenge");
                var nonce = challenge.RootElement.GetProperty("nonce").GetString() ?? "";

                // 2. Claim + Proof
                var claim = RelayCrypto.RoomClaim(key);
                var proof = RelayCrypto.ClaimProof(nonce, key);
                await SendJsonAsync(ws, new { t = "claim", claim, proof }, ct);

                // 3. Ready
                var ready = await ReceiveJsonAsync(ws, ct);
                if (ready is null || !ready.RootElement.TryGetProperty("t", out var rEl) || rEl.GetString() != "ready")
                    throw new InvalidOperationException("expected ready");

                backoffSec = 1;
                SetStatus(true, "Relay online");

                using var hbCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                var hbTask = RunHeartbeatAsync(ws, hbCts.Token);

                try
                {
                    while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
                    {
                        using var frame = await ReceiveJsonAsync(ws, ct);
                        if (frame is null) break;
                        if (frame.RootElement.TryGetProperty("t", out var ft) && ft.GetString() == "cmd")
                        {
                            _ = HandleCommandFrameAsync(ws, frame.RootElement.Clone(), key, ct);
                        }
                    }
                }
                finally
                {
                    hbCts.Cancel();
                    try { await hbTask; } catch { }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                SetStatus(false, $"Reconnecting ({ex.Message})");
                try { await Task.Delay(TimeSpan.FromSeconds(backoffSec), ct); } catch { break; }
                backoffSec = Math.Min(backoffSec * 2, 30);
            }
            finally
            {
                _activeSocket = null;
            }
        }
    }

    private async Task RunHeartbeatAsync(ClientWebSocket ws, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
        {
            await Task.Delay(TimeSpan.FromSeconds(25), ct);
            await SendJsonAsync(ws, new { t = "ping" }, ct);
        }
    }

    private async Task HandleCommandFrameAsync(ClientWebSocket ws, JsonElement frame, byte[] key, CancellationToken ct)
    {
        var rid = frame.TryGetProperty("rid", out var ridEl) ? (ridEl.GetString() ?? "") : "";
        string replyJson;
        try
        {
            var env = frame.GetProperty("env").Deserialize<RelayEnvelope>()
                ?? throw new InvalidOperationException("bad_envelope");
            var plainBytes = RelayCrypto.Open(env, key, _config.DeviceId);
            var cmd = JsonSerializer.Deserialize<RelayCommandPayload>(plainBytes)
                ?? throw new InvalidOperationException("bad_plaintext");

            if (cmd.Path.Contains("..") || cmd.Path.Contains("//"))
            {
                replyJson = """{"success":false,"message":"bad_path"}""";
            }
            else
            {
                replyJson = await _dispatcher(cmd.Path, cmd.Query ?? new Dictionary<string, string>(), true);
            }
        }
        catch (Exception ex)
        {
            replyJson = JsonSerializer.Serialize(new { success = false, message = ex.Message });
        }

        var sealedResp = RelayCrypto.Seal(Encoding.UTF8.GetBytes(replyJson), key, _config.DeviceId, rid);
        await SendJsonAsync(ws, new { t = "resp", rid, env = sealedResp }, ct);
    }

    private async Task SendJsonAsync(ClientWebSocket ws, object payload, CancellationToken ct)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload));
        await _sendLock.WaitAsync(ct);
        try
        {
            if (ws.State == WebSocketState.Open)
            {
                await ws.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, ct);
            }
        }
        finally
        {
            _sendLock.Release();
        }
    }

    private static async Task<JsonDocument?> ReceiveJsonAsync(ClientWebSocket ws, CancellationToken ct)
    {
        var buf = new byte[16 * 1024];
        using var ms = new MemoryStream();
        while (true)
        {
            var res = await ws.ReceiveAsync(buf, ct);
            if (res.MessageType == WebSocketMessageType.Close) return null;
            ms.Write(buf, 0, res.Count);
            if (ms.Length > 4 * 1024 * 1024) throw new InvalidOperationException("relay frame too large");
            if (res.EndOfMessage) break;
        }
        ms.Position = 0;
        return await JsonDocument.ParseAsync(ms, cancellationToken: ct);
    }

    private void SetStatus(bool online, string text)
    {
        IsOnline = online;
        StatusText = text;
        StatusChanged?.Invoke();
    }

    public void Dispose()
    {
        Stop();
        _http.Dispose();
        _sendLock.Dispose();
    }
}
