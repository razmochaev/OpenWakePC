using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace WakePCAgent.Core;

/// <summary>
/// Windows LAN HTTP API Server (`:8765`) implementing all 40+ Wake PC Agent endpoints,
/// Bearer token authentication, X-WakePC-Relay enforcement, chunked screenshots, and 500 MB uploads.
/// </summary>
public sealed class HttpAgentServer : IDisposable
{
    public static readonly string[] AllFeatures =
    {
        "telemetry", "screenshot", "screenshot-relay", "live-stream",
        "touchpad", "hotkeys", "send-text", "send-file", "clipboard-get",
        "custom-commands", "audio-output", "volume-state", "fullscreen-key",
        "idle-action", "idle-notify", "wol-relay"
    };

    private static readonly Regex SafeFilenameRegex = new(@"[^A-Za-z0-9._ -]+", RegexOptions.Compiled);

    private readonly AgentConfig _config;
    private readonly SchedulerAndIdle _scheduler;
    private HttpListener? _listener;
    private CancellationTokenSource? _cts;

    private string _cachedShotB64 = "";
    private int _cachedShotW;
    private int _cachedShotH;
    private DateTimeOffset _cachedShotAt = DateTimeOffset.MinValue;

    public bool IsRunning { get; private set; }
    public int RequestsCount { get; private set; }
    public event Action? StateChanged;

    public HttpAgentServer(AgentConfig config, SchedulerAndIdle scheduler)
    {
        _config = config;
        _scheduler = scheduler;
    }

    public void Start()
    {
        Stop();
        _cts = new CancellationTokenSource();
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://+:{_config.ApiPort}/");
        try
        {
            _listener.Start();
            IsRunning = true;
            StateChanged?.Invoke();
            _ = Task.Run(() => AcceptLoopAsync(_cts.Token));
        }
        catch
        {
            // Fallback to localhost binding if URLACL not yet elevated
            _listener = new HttpListener();
            _listener.Prefixes.Add($"http://localhost:{_config.ApiPort}/");
            _listener.Start();
            IsRunning = true;
            StateChanged?.Invoke();
            _ = Task.Run(() => AcceptLoopAsync(_cts.Token));
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _listener?.Stop(); _listener?.Close(); } catch { }
        _listener = null;
        IsRunning = false;
        StateChanged?.Invoke();
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener is not null && _listener.IsListening)
        {
            try
            {
                var ctx = await _listener.GetContextAsync();
                _ = Task.Run(() => HandleHttpContextAsync(ctx), ct);
            }
            catch { break; }
        }
    }

    private async Task HandleHttpContextAsync(HttpListenerContext ctx)
    {
        try
        {
            ctx.Response.ContentType = "application/json; charset=utf-8";
            ctx.Response.AddHeader("Access-Control-Allow-Origin", "*");

            var path = ctx.Request.Url?.AbsolutePath ?? "/";
            var auth = ctx.Request.Headers["Authorization"] ?? "";
            bool viaRelay = ctx.Request.Headers["X-WakePC-Relay"] == "1";

            // Unauthenticated /status for direct LAN discovery
            if (path == "/status" && string.IsNullOrEmpty(auth) && !viaRelay)
            {
                var net = AgentConfig.DetectPrimaryNetwork();
                var pub = JsonSerializer.Serialize(new
                {
                    success = true,
                    message = "OpenWakePC Agent",
                    features = AllFeatures,
                    data = new
                    {
                        ip = net.Ip,
                        mac = net.Mac,
                        bcast = net.Broadcast,
                        name = _config.Hostname,
                        type = "windows",
                        deviceId = _config.DeviceId,
                        token = _config.Token,
                        agentVersion = AgentConfig.AgentVersion,
                        features = AllFeatures
                    }
                });
                await WriteResponseAsync(ctx.Response, 200, pub);
                return;
            }

            if (!IsBearerValid(auth))
            {
                await WriteResponseAsync(ctx.Response, 401, """{"success":false,"message":"Unauthorized"}""");
                return;
            }

            var query = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string? key in ctx.Request.QueryString.AllKeys)
            {
                if (key is not null) query[key] = ctx.Request.QueryString[key] ?? "";
            }

            if (path == "/upload")
            {
                if (viaRelay)
                {
                    await WriteResponseAsync(ctx.Response, 403, ErrJson("This feature requires local Wi-Fi (lanOnly)"));
                    return;
                }
                var (code, body) = await HandleUploadAsync(ctx.Request, query.GetValueOrDefault("name", "upload.bin"));
                await WriteResponseAsync(ctx.Response, code, body);
                return;
            }

            // Merge JSON body fields on POST when parameters are passed in request body
            if (ctx.Request.HttpMethod == "POST"
                && ctx.Request.HasEntityBody
                && (ctx.Request.ContentType ?? "").Contains("application/json", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    using var reader = new StreamReader(ctx.Request.InputStream, ctx.Request.ContentEncoding ?? Encoding.UTF8);
                    var rawBody = await reader.ReadToEndAsync();
                    using var doc = JsonDocument.Parse(rawBody);
                    if (doc.RootElement.ValueKind == JsonValueKind.Object)
                    {
                        foreach (var prop in doc.RootElement.EnumerateObject())
                        {
                            if (!query.ContainsKey(prop.Name))
                                query[prop.Name] = prop.Value.ValueKind == JsonValueKind.String
                                    ? (prop.Value.GetString() ?? "")
                                    : prop.Value.ToString();
                        }
                    }
                }
                catch { }
            }

            var json = await DispatchCommandAsync(path, query, viaRelay);
            await WriteResponseAsync(ctx.Response, 200, json);
        }
        catch (Exception ex)
        {
            try { await WriteResponseAsync(ctx.Response, 500, ErrJson(ex.Message)); } catch { }
        }
    }

    private bool IsBearerValid(string header)
    {
        if (!header.StartsWith("Bearer ", StringComparison.Ordinal)) return false;
        var provided = Encoding.UTF8.GetBytes(header[7..].Trim());
        var expected = Encoding.UTF8.GetBytes(_config.Token);
        return provided.Length == expected.Length && CryptographicOperations.FixedTimeEquals(provided, expected);
    }

    private async Task<(int StatusCode, string Body)> HandleUploadAsync(HttpListenerRequest req, string rawName)
    {
        var baseName = Path.GetFileName(rawName).Trim();
        var cleaned = SafeFilenameRegex.Replace(baseName, "_").Trim('.', ' ');
        var safeName = string.IsNullOrEmpty(cleaned) ? "upload.bin" : cleaned;

        Directory.CreateDirectory(AgentConfig.DownloadsDirectory);
        var dest = Path.Combine(AgentConfig.DownloadsDirectory, safeName);
        if (File.Exists(dest))
        {
            var stem = Path.GetFileNameWithoutExtension(safeName);
            var ext = Path.GetExtension(safeName);
            dest = Path.Combine(AgentConfig.DownloadsDirectory, $"{stem}_{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}{ext}");
        }

        long total = 0;
        var buffer = new byte[64 * 1024];
        try
        {
            await using var fs = File.Create(dest);
            int read;
            while ((read = await req.InputStream.ReadAsync(buffer)) > 0)
            {
                total += read;
                if (total > AgentConfig.MaxUploadBytes)
                {
                    fs.Close();
                    File.Delete(dest);
                    return (413, ErrJson("File exceeds 500 MB limit"));
                }
                await fs.WriteAsync(buffer.AsMemory(0, read));
            }
            RequestsCount++;
            StateChanged?.Invoke();
            return (200, OkJson($"Saved {Path.GetFileName(dest)}", new { name = Path.GetFileName(dest), bytes = total }));
        }
        catch (Exception ex)
        {
            try { File.Delete(dest); } catch { }
            return (500, ErrJson(ex.Message));
        }
    }

    public Task<string> DispatchCommandAsync(string path, Dictionary<string, string> query, bool viaRelay)
    {
        RequestsCount++;
        StateChanged?.Invoke();

        var norm = "/" + path.Trim('/');
        if (norm == "/") norm = "/status";

        if (viaRelay && (norm.StartsWith("/mouse/", StringComparison.Ordinal) || norm == "/upload"))
            return Task.FromResult(ErrJson("This feature requires local Wi-Fi (lanOnly)"));

        switch (norm)
        {
            case "/status":
            {
                var net = AgentConfig.DetectPrimaryNetwork();
                var (vol, muted) = WindowsSystem.GetVolumeState();
                var (micVol, micMuted) = WindowsSystem.GetMicState();
                var data = _scheduler.GetStatus();
                data["mac"] = net.Mac;
                data["bcast"] = net.Broadcast;
                data["name"] = _config.Hostname;
                data["type"] = "windows";
                data["deviceId"] = _config.DeviceId;
                data["agentVersion"] = AgentConfig.AgentVersion;
                data["features"] = AllFeatures;
                data["volume"] = vol;
                data["muted"] = muted;
                data["micVolume"] = micVol;
                data["micMuted"] = micMuted;
                data["brightness"] = WindowsSystem.GetBrightness();
                return Task.FromResult(OkJson("Online", data, WindowsSystem.GetDiagnostics(_config.ApiPort)));
            }
            case "/telemetry":
                return Task.FromResult(OkJson("OK", WindowsSystem.GetTelemetry()));

            case "/shutdown":
            case "/restart":
            case "/sleep":
            case "/hibernate":
            case "/lock":
            case "/display-off":
            case "/display-on":
            {
                var (ok, msg) = WindowsSystem.ExecutePower(norm[1..]);
                return Task.FromResult(ok ? OkJson(msg) : ErrJson(msg));
            }
            case "/wake-other":
            {
                var mac = query.GetValueOrDefault("mac", "");
                var net = AgentConfig.DetectPrimaryNetwork();
                var bcast = query.GetValueOrDefault("bcast", net.Broadcast);
                int wolPort = int.TryParse(query.GetValueOrDefault("wolPort"), out var wp) ? wp : _config.WolPort;
                return Task.FromResult(WindowsSystem.SendWoL(mac, bcast, wolPort)
                    ? OkJson($"WoL sent to {mac}")
                    : ErrJson("Invalid MAC address"));
            }
            case "/shutdown-in":
            case "/restart-in":
            case "/sleep-in":
            {
                if (!int.TryParse(query.GetValueOrDefault("minutes"), out int mins) || mins < 1)
                    return Task.FromResult(ErrJson("Invalid minutes"));
                var act = norm[1..].Replace("-in", "");
                return Task.FromResult(OkJson($"Scheduled {act}", _scheduler.Schedule(act, mins)));
            }
            case "/scheduled-status":
                return Task.FromResult(OkJson("OK", _scheduler.GetStatus()));

            case "/cancel-scheduled":
                return Task.FromResult(OkJson("Cancelled", _scheduler.CancelAll()));

            case "/idle-action":
            {
                int mins = int.TryParse(query.GetValueOrDefault("minutes"), out var m) ? m : 10;
                return Task.FromResult(OkJson("Updated", _scheduler.SetIdleAction(query.GetValueOrDefault("action"), mins)));
            }
            case "/idle-notify":
            {
                int hrs = int.TryParse(query.GetValueOrDefault("hours"), out var h) ? h : 0;
                return Task.FromResult(OkJson("Updated", _scheduler.SetIdleNotify(hrs)));
            }
            case "/volume-up":
            {
                var cur = WindowsSystem.GetVolumeState().Volume;
                var (v, m) = WindowsSystem.SetVolume(cur + 5);
                return Task.FromResult(OkJson("OK", new { volume = v, muted = m }));
            }
            case "/volume-down":
            {
                var cur = WindowsSystem.GetVolumeState().Volume;
                var (v, m) = WindowsSystem.SetVolume(cur - 5);
                return Task.FromResult(OkJson("OK", new { volume = v, muted = m }));
            }
            case "/volume-mute":
            {
                var (v, m) = WindowsSystem.ToggleMute();
                return Task.FromResult(OkJson("OK", new { volume = v, muted = m }));
            }
            case "/mic-up":
            {
                var cur = WindowsSystem.GetMicState().Volume;
                var (mv, mm) = WindowsSystem.SetMicVolume(cur + 5);
                return Task.FromResult(OkJson("OK", new { micVolume = mv, micMuted = mm }));
            }
            case "/mic-down":
            {
                var cur = WindowsSystem.GetMicState().Volume;
                var (mv, mm) = WindowsSystem.SetMicVolume(cur - 5);
                return Task.FromResult(OkJson("OK", new { micVolume = mv, micMuted = mm }));
            }
            case "/mic-mute":
            {
                var (mv, mm) = WindowsSystem.ToggleMicMute();
                return Task.FromResult(OkJson("OK", new { micVolume = mv, micMuted = mm }));
            }
            case "/audio-outputs":
                return Task.FromResult(OkJson("OK", new { outputs = WindowsSystem.ListAudioOutputs() }));

            case "/audio-output/set":
            {
                var id = query.GetValueOrDefault("id", "");
                bool ok = WindowsSystem.SetAudioOutput(id);
                return Task.FromResult(ok ? OkJson("Updated", new { outputs = WindowsSystem.ListAudioOutputs() }) : ErrJson("Audio output not found"));
            }
            case "/audio-inputs":
                return Task.FromResult(OkJson("OK", new { inputs = WindowsSystem.ListAudioInputs() }));

            case "/audio-input/set":
            {
                var id = query.GetValueOrDefault("id", "");
                bool ok = WindowsSystem.SetAudioInput(id);
                return Task.FromResult(ok ? OkJson("Updated", new { inputs = WindowsSystem.ListAudioInputs() }) : ErrJson("Audio input not found"));
            }
            case "/brightness-up":
                return Task.FromResult(OkJson("OK", new { brightness = WindowsSystem.SetBrightness(WindowsSystem.GetBrightness() + 10) }));

            case "/brightness-down":
                return Task.FromResult(OkJson("OK", new { brightness = WindowsSystem.SetBrightness(WindowsSystem.GetBrightness() - 10) }));

            case "/media-play-pause":
            case "/media-next":
            case "/media-prev":
            case "/media-fullscreen":
                WindowsSystem.MediaControl(norm["/media-".Length..]);
                return Task.FromResult(OkJson("OK"));

            case "/screenshot":
                return Task.FromResult(HandleScreenshot(query, viaRelay));

            case "/apps":
                return Task.FromResult(OkJson("OK", new { apps = WindowsSystem.ListRunningApps() }));

            case "/apps/close":
            {
                bool force = string.Equals(query.GetValueOrDefault("force"), "true", StringComparison.OrdinalIgnoreCase);
                var (ok, msg) = WindowsSystem.CloseApp(query.GetValueOrDefault("id", ""), force);
                return Task.FromResult(ok ? OkJson(msg) : ErrJson(msg));
            }
            case "/commands":
                return Task.FromResult(OkJson("OK", new { commands = _scheduler.ListCustomCommands() }));

            case "/command/run":
            {
                var (ok, msg) = _scheduler.RunCustomCommand(query.GetValueOrDefault("id", ""));
                return Task.FromResult(ok ? OkJson(msg, new { commands = _scheduler.ListCustomCommands() }) : ErrJson(msg));
            }
            case "/command/close":
            {
                var (ok, msg) = _scheduler.CloseCustomCommand(query.GetValueOrDefault("id", ""));
                return Task.FromResult(ok ? OkJson(msg, new { commands = _scheduler.ListCustomCommands() }) : ErrJson(msg));
            }
            case "/open-url":
                return Task.FromResult(WindowsSystem.OpenUrl(query.GetValueOrDefault("url", ""))
                    ? OkJson("URL opened")
                    : ErrJson("Invalid URL"));

            case "/clipboard":
                WindowsSystem.SetClipboardText(query.GetValueOrDefault("text", ""));
                return Task.FromResult(OkJson("Clipboard updated"));

            case "/clipboard/get":
            {
                var (txt, trunc) = WindowsSystem.GetClipboardText();
                return Task.FromResult(OkJson("OK", new { text = txt, truncated = trunc }));
            }
            case "/mouse/move":
            {
                int dx = Math.Clamp(ParseInt(query.GetValueOrDefault("dx")), -5000, 5000);
                int dy = Math.Clamp(ParseInt(query.GetValueOrDefault("dy")), -5000, 5000);
                WindowsSystem.MouseMove(dx, dy);
                return Task.FromResult(OkJson("OK"));
            }
            case "/mouse/scroll":
            {
                int dx = Math.Clamp(ParseInt(query.GetValueOrDefault("dx")), -5000, 5000);
                int dy = Math.Clamp(ParseInt(query.GetValueOrDefault("dy")), -5000, 5000);
                WindowsSystem.MouseScroll(dx, dy);
                return Task.FromResult(OkJson("OK"));
            }
            case "/mouse/click":
                WindowsSystem.MouseClick(query.GetValueOrDefault("button", "left"), Math.Clamp(ParseInt(query.GetValueOrDefault("count"), 1), 1, 3));
                return Task.FromResult(OkJson("OK"));

            case "/mouse/drag":
                WindowsSystem.MouseDrag(query.GetValueOrDefault("state", "up"));
                return Task.FromResult(OkJson("OK"));

            case "/key/text":
                WindowsSystem.TypeText(query.GetValueOrDefault("text", ""));
                return Task.FromResult(OkJson("OK"));

            case "/key/press":
            {
                var mods = query.GetValueOrDefault("mods", "").Split(',', StringSplitOptions.RemoveEmptyEntries);
                WindowsSystem.PressKey(query.GetValueOrDefault("key", ""), mods);
                return Task.FromResult(OkJson("OK"));
            }
            case "/stream/frame":
            {
                var shot = WindowsSystem.CaptureScreenshotJpeg();
                return Task.FromResult(OkJson("OK", new
                {
                    format = "jpeg",
                    width = shot.Width,
                    height = shot.Height,
                    image = Convert.ToBase64String(shot.Data),
                    audioRate = 24000,
                    audioChannels = 1,
                    audioSeq = 0L
                }));
            }
            case "/stream/stop":
                return Task.FromResult(OkJson("Stream stopped"));

            default:
            {
                if (norm.StartsWith("/volume-set/", StringComparison.Ordinal) && int.TryParse(norm["/volume-set/".Length..], out int volLevel))
                {
                    var (v, m) = WindowsSystem.SetVolume(volLevel);
                    return Task.FromResult(OkJson("OK", new { volume = v, muted = m }));
                }
                if (norm.StartsWith("/mic-set/", StringComparison.Ordinal) && int.TryParse(norm["/mic-set/".Length..], out int micLevel))
                {
                    var (mv, mm) = WindowsSystem.SetMicVolume(micLevel);
                    return Task.FromResult(OkJson("OK", new { micVolume = mv, micMuted = mm }));
                }
                if (norm.StartsWith("/brightness-set/", StringComparison.Ordinal) && int.TryParse(norm["/brightness-set/".Length..], out int br))
                {
                    return Task.FromResult(OkJson("OK", new { brightness = WindowsSystem.SetBrightness(br) }));
                }
                return Task.FromResult(ErrJson($"Unknown endpoint: {norm}"));
            }
        }
    }

    private string HandleScreenshot(Dictionary<string, string> query, bool viaRelay)
    {
        bool hasChunkParam = query.TryGetValue("chunk", out var chunkStr);
        bool forceChunks = viaRelay || hasChunkParam;
        bool needFresh = string.IsNullOrEmpty(_cachedShotB64) || !hasChunkParam || chunkStr == "0"
            || (DateTimeOffset.UtcNow - _cachedShotAt).TotalSeconds > 30;

        if (needFresh)
        {
            var shot = WindowsSystem.CaptureScreenshotJpeg();
            _cachedShotB64 = Convert.ToBase64String(shot.Data);
            _cachedShotW = shot.Width;
            _cachedShotH = shot.Height;
            _cachedShotAt = DateTimeOffset.UtcNow;
        }

        if (!forceChunks)
        {
            return OkJson("OK", new
            {
                format = "jpeg",
                width = _cachedShotW,
                height = _cachedShotH,
                image = _cachedShotB64,
                chunkIndex = 0,
                chunkCount = 1
            });
        }

        const int chunkChars = 220 * 1024;
        int totalChunks = Math.Max(1, (int)Math.Ceiling(_cachedShotB64.Length / (double)chunkChars));
        int idx = Math.Clamp(ParseInt(chunkStr), 0, totalChunks - 1);
        int start = idx * chunkChars;
        int len = Math.Min(chunkChars, _cachedShotB64.Length - start);
        return OkJson("OK", new
        {
            format = "jpeg",
            width = _cachedShotW,
            height = _cachedShotH,
            image = _cachedShotB64.Substring(start, len),
            chunkIndex = idx,
            chunkCount = totalChunks
        });
    }

    private static int ParseInt(string? raw, int fallback = 0) => int.TryParse(raw, out int val) ? val : fallback;

    private static string OkJson(string message = "OK", object? data = null, object? diagnostics = null) =>
        JsonSerializer.Serialize(new { success = true, message, diagnostics, data, features = AllFeatures });

    private static string ErrJson(string message) =>
        JsonSerializer.Serialize(new { success = false, message, features = AllFeatures });

    private static async Task WriteResponseAsync(HttpListenerResponse resp, int statusCode, string json)
    {
        resp.StatusCode = statusCode;
        var bytes = Encoding.UTF8.GetBytes(json);
        resp.ContentLength64 = bytes.Length;
        await resp.OutputStream.WriteAsync(bytes);
        resp.Close();
    }

    public void Dispose()
    {
        Stop();
    }
}
