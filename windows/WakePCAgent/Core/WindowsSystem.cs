using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Management;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using NAudio.CoreAudioApi;

namespace WakePCAgent.Core;

/// <summary>
/// Native Windows OS integrations: Power, WASAPI Audio + COM IPolicyConfig output switching,
/// WMI + DDC/CI Brightness, SendInput Touchpad/Keyboard/Media, Screenshot, Running Apps,
/// Telemetry, Buddy Wake WoL, and Diagnostics/Firewall/Autostart Auto-Fix.
/// </summary>
public static class WindowsSystem
{
    // MARK: - Power

    public static (bool Ok, string Message) ExecutePower(string action)
    {
        try
        {
            switch (action)
            {
                case "shutdown":
                    Process.Start(new ProcessStartInfo("shutdown", "/s /t 0") { CreateNoWindow = true, UseShellExecute = false });
                    return (true, "Shutdown command sent");
                case "restart":
                    Process.Start(new ProcessStartInfo("shutdown", "/r /t 0") { CreateNoWindow = true, UseShellExecute = false });
                    return (true, "Restart command sent");
                case "sleep":
                    SetSuspendState(false, false, false);
                    return (true, "Sleep command sent");
                case "hibernate":
                    Process.Start(new ProcessStartInfo("shutdown", "/h") { CreateNoWindow = true, UseShellExecute = false });
                    return (true, "Hibernate command sent");
                case "lock":
                    LockWorkStation();
                    return (true, "Lock command sent");
                case "display-off":
                    SendMessage((IntPtr)0xFFFF, 0x0112, (IntPtr)0xF170, (IntPtr)2);
                    return (true, "Display off sent");
                case "display-on":
                    SendMessage((IntPtr)0xFFFF, 0x0112, (IntPtr)0xF170, (IntPtr)(-1));
                    MouseMove(1, 0);
                    return (true, "Display on sent");
                default:
                    return (false, $"Unknown power action: {action}");
            }
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    // MARK: - Wake-on-LAN (Buddy Wake)

    public static bool SendWoL(string mac, string broadcast, int port)
    {
        var parts = mac.Trim().Replace("-", ":").ToUpperInvariant().Split(':');
        if (parts.Length != 6) return false;
        var macBytes = new byte[6];
        for (int i = 0; i < 6; i++)
        {
            if (!byte.TryParse(parts[i], System.Globalization.NumberStyles.HexNumber, null, out macBytes[i]))
                return false;
        }
        var packet = new byte[102];
        for (int i = 0; i < 6; i++) packet[i] = 0xFF;
        for (int i = 0; i < 16; i++) Buffer.BlockCopy(macBytes, 0, packet, 6 + i * 6, 6);

        using var udp = new UdpClient { EnableBroadcast = true };
        var ep = new IPEndPoint(IPAddress.Parse(string.IsNullOrWhiteSpace(broadcast) ? "255.255.255.255" : broadcast), port);
        for (int i = 0; i < 3; i++) udp.Send(packet, packet.Length, ep);
        return true;
    }

    // MARK: - Telemetry & Diagnostics

    public static Dictionary<string, object> GetTelemetry()
    {
        var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        GlobalMemoryStatusEx(ref mem);
        double totalGb = Math.Round(mem.ullTotalPhys / 1073741824.0, 2);
        double usedGb = Math.Round((mem.ullTotalPhys - mem.ullAvailPhys) / 1073741824.0, 2);
        double ramLoad = mem.ullTotalPhys > 0 ? Math.Round(usedGb / totalGb * 100.0, 1) : 0;

        double cpuLoad = SampleCpuLoadPercent();

        return new Dictionary<string, object>
        {
            ["cpuLoad"] = cpuLoad,
            ["ramLoad"] = ramLoad,
            ["ramUsedGb"] = usedGb,
            ["ramTotalGb"] = totalGb,
            ["uptimeSeconds"] = Environment.TickCount64 / 1000L
        };
    }

    private static double SampleCpuLoadPercent()
    {
        try
        {
            if (!GetSystemTimes(out var idle1, out var kernel1, out var user1)) return 0;
            System.Threading.Thread.Sleep(100);
            if (!GetSystemTimes(out var idle2, out var kernel2, out var user2)) return 0;

            ulong dIdle = idle2 - idle1;
            ulong dKernel = kernel2 - kernel1;
            ulong dUser = user2 - user1;
            ulong total = dKernel + dUser;
            if (total == 0) return 0;
            double busy = (double)(total - dIdle) / total * 100.0;
            return Math.Round(Math.Clamp(busy, 0.0, 100.0), 1);
        }
        catch { return 0; }
    }

    public static Dictionary<string, object> GetDiagnostics(int apiPort)
    {
        var net = AgentConfig.DetectPrimaryNetwork();
        var problems = new List<string>();
        bool thirdPartyAv = DetectThirdPartyAntivirus();
        if (thirdPartyAv) problems.Add("antivirus_present");

        bool fwOk = CheckFirewallRule(apiPort);
        if (!fwOk) problems.Add("lan_blocked");

        bool modernStandby = CheckModernStandby();
        if (modernStandby) problems.Add("modern_standby");

        return new Dictionary<string, object>
        {
            ["wifiConnected"] = net.IsWifi,
            ["primaryAdapter"] = net.AdapterName,
            ["hasMultipleAdapters"] = net.HasMultiple,
            ["isVirtualAdapter"] = net.IsVirtual,
            ["agentVersion"] = AgentConfig.AgentVersion,
            ["networkProfile"] = "private",
            ["thirdPartyAntivirus"] = thirdPartyAv,
            ["lanReachable"] = fwOk,
            ["problems"] = problems
        };
    }

    public static bool DetectThirdPartyAntivirus()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\SecurityCenter2", "SELECT displayName FROM AntiVirusProduct");
            foreach (var obj in searcher.Get())
            {
                var name = obj["displayName"]?.ToString() ?? "";
                if (!string.IsNullOrEmpty(name) && !name.Contains("Windows Defender", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }
        catch { }
        return false;
    }

    public static bool CheckFirewallRule(int apiPort)
    {
        try
        {
            var outText = RunCommandOutput("netsh", "advfirewall firewall show rule name=\"WakePC Agent - HTTP\"");
            return outText.Contains(apiPort.ToString(), StringComparison.Ordinal);
        }
        catch { return true; }
    }

    public static bool FixFirewallRules(int apiPort, int wolPort)
    {
        try
        {
            RunCommandOutput("netsh", "advfirewall firewall delete rule name=\"WakePC Agent - HTTP\"");
            RunCommandOutput("netsh", "advfirewall firewall delete rule name=\"WakePC Agent - WoL\"");
            RunCommandOutput("netsh", $"advfirewall firewall add rule name=\"WakePC Agent - HTTP\" dir=in action=allow protocol=TCP localport={apiPort} profile=any");
            RunCommandOutput("netsh", $"advfirewall firewall add rule name=\"WakePC Agent - WoL\" dir=in action=allow protocol=UDP localport={wolPort} profile=any");
            return true;
        }
        catch { return false; }
    }

    public static bool SetAutostartTask(bool enable)
    {
        var exePath = Environment.ProcessPath ?? "";
        try
        {
            if (enable)
            {
                var res = RunCommandOutput("schtasks", $"/Create /TN \"WakePCAgent\" /TR \"\\\"{exePath}\\\"\" /SC ONLOGON /RL HIGHEST /F");
                if (res.Contains("SUCCESS", StringComparison.OrdinalIgnoreCase)) return true;
            }
            else
            {
                RunCommandOutput("schtasks", "/Delete /TN \"WakePCAgent\" /F");
            }
        }
        catch { }

        // Non-elevated fallback via HKCU Run key
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Run", writable: true);
            if (key is null) return false;
            if (enable) key.SetValue("OpenWakePCAgent", $"\"{exePath}\"");
            else key.DeleteValue("OpenWakePCAgent", throwOnMissingValue: false);
            return true;
        }
        catch { return false; }
    }

    private static bool CheckModernStandby()
    {
        try
        {
            var txt = RunCommandOutput("powercfg", "/a");
            return txt.Contains("S0 Low Power Idle", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    // MARK: - Audio (WASAPI + COM IPolicyConfig)

    public static (int Volume, bool Muted) GetVolumeState()
    {
        try
        {
            using var en = new MMDeviceEnumerator();
            using var dev = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            return ((int)Math.Round(dev.AudioEndpointVolume.MasterVolumeLevelScalar * 100f), dev.AudioEndpointVolume.Mute);
        }
        catch { return (50, false); }
    }

    public static (int Volume, bool Muted) SetVolume(int level)
    {
        int clamped = Math.Clamp(level, 0, 100);
        try
        {
            using var en = new MMDeviceEnumerator();
            using var dev = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            dev.AudioEndpointVolume.MasterVolumeLevelScalar = clamped / 100f;
            if (clamped > 0) dev.AudioEndpointVolume.Mute = false;
            return (clamped, dev.AudioEndpointVolume.Mute);
        }
        catch { return (clamped, false); }
    }

    public static (int Volume, bool Muted) ToggleMute()
    {
        try
        {
            using var en = new MMDeviceEnumerator();
            using var dev = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            dev.AudioEndpointVolume.Mute = !dev.AudioEndpointVolume.Mute;
            return ((int)Math.Round(dev.AudioEndpointVolume.MasterVolumeLevelScalar * 100f), dev.AudioEndpointVolume.Mute);
        }
        catch { return (50, false); }
    }

    public static (int Volume, bool Muted) GetMicState()
    {
        try
        {
            using var en = new MMDeviceEnumerator();
            using var dev = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
            return ((int)Math.Round(dev.AudioEndpointVolume.MasterVolumeLevelScalar * 100f), dev.AudioEndpointVolume.Mute);
        }
        catch { return (50, false); }
    }

    public static (int Volume, bool Muted) SetMicVolume(int level)
    {
        int clamped = Math.Clamp(level, 0, 100);
        try
        {
            using var en = new MMDeviceEnumerator();
            using var dev = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
            dev.AudioEndpointVolume.MasterVolumeLevelScalar = clamped / 100f;
            if (clamped > 0) dev.AudioEndpointVolume.Mute = false;
            return (clamped, dev.AudioEndpointVolume.Mute);
        }
        catch { return (clamped, false); }
    }

    public static (int Volume, bool Muted) ToggleMicMute()
    {
        try
        {
            using var en = new MMDeviceEnumerator();
            using var dev = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
            dev.AudioEndpointVolume.Mute = !dev.AudioEndpointVolume.Mute;
            return ((int)Math.Round(dev.AudioEndpointVolume.MasterVolumeLevelScalar * 100f), dev.AudioEndpointVolume.Mute);
        }
        catch { return (50, false); }
    }

    public static List<Dictionary<string, object>> ListAudioOutputs()
    {
        var list = new List<Dictionary<string, object>>();
        try
        {
            using var en = new MMDeviceEnumerator();
            string defaultId = "";
            try { defaultId = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID; } catch { }
            foreach (var dev in en.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                list.Add(new Dictionary<string, object>
                {
                    ["id"] = dev.ID,
                    ["name"] = dev.FriendlyName,
                    ["isDefault"] = dev.ID == defaultId
                });
            }
        }
        catch { }
        return list;
    }

    public static bool SetAudioOutput(string deviceId)
    {
        try
        {
            var policy = (IPolicyConfig)new PolicyConfigClient();
            policy.SetDefaultEndpoint(deviceId, 0); // eConsole
            policy.SetDefaultEndpoint(deviceId, 1); // eMultimedia
            return true;
        }
        catch { return false; }
    }

    public static List<Dictionary<string, object>> ListAudioInputs()
    {
        var list = new List<Dictionary<string, object>>();
        try
        {
            using var en = new MMDeviceEnumerator();
            string defaultId = "";
            try { defaultId = en.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia).ID; } catch { }
            foreach (var dev in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                list.Add(new Dictionary<string, object>
                {
                    ["id"] = dev.ID,
                    ["name"] = dev.FriendlyName,
                    ["isDefault"] = dev.ID == defaultId
                });
            }
        }
        catch { }
        return list;
    }

    public static bool SetAudioInput(string deviceId)
    {
        try
        {
            var policy = (IPolicyConfig)new PolicyConfigClient();
            policy.SetDefaultEndpoint(deviceId, 0); // eConsole
            policy.SetDefaultEndpoint(deviceId, 1); // eMultimedia
            policy.SetDefaultEndpoint(deviceId, 2); // eCommunications
            return true;
        }
        catch { return false; }
    }

    // MARK: - Brightness (WMI for laptops)

    public static int GetBrightness()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentBrightness FROM WmiMonitorBrightness");
            foreach (var obj in searcher.Get())
                return Convert.ToInt32(obj["CurrentBrightness"]);
        }
        catch { }
        return 80;
    }

    public static int SetBrightness(int level)
    {
        int clamped = Math.Clamp(level, 0, 100);
        try
        {
            using var searcher = new ManagementObjectSearcher(@"root\WMI", "SELECT * FROM WmiMonitorBrightnessMethods");
            foreach (ManagementObject obj in searcher.Get())
            {
                obj.InvokeMethod("WmiSetBrightness", new object[] { 1u, (byte)clamped });
            }
            return clamped;
        }
        catch { return GetBrightness(); }
    }

    // MARK: - Media, Mouse & Keyboard (Win32 SendInput)

    public static void MediaControl(string action)
    {
        ushort vk = action switch
        {
            "play-pause" => 0xB3, // VK_MEDIA_PLAY_PAUSE
            "next" => 0xB0,       // VK_MEDIA_NEXT_TRACK
            "prev" => 0xB1,       // VK_MEDIA_PREV_TRACK
            "fullscreen" => 0x46, // 'F'
            _ => 0
        };
        if (vk != 0) SendVirtualKey(vk, Array.Empty<string>());
    }

    public static void MouseMove(int dx, int dy)
    {
        var input = new INPUT
        {
            type = 0,
            U = new InputUnion { mi = new MOUSEINPUT { dx = dx, dy = dy, dwFlags = 0x0001 } }
        };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public static void MouseScroll(int dx, int dy)
    {
        if (dy != 0)
        {
            var v = new INPUT { type = 0, U = new InputUnion { mi = new MOUSEINPUT { mouseData = unchecked((uint)(dy * 30)), dwFlags = 0x0800 } } };
            SendInput(1, new[] { v }, Marshal.SizeOf<INPUT>());
        }
        if (dx != 0)
        {
            var h = new INPUT { type = 0, U = new InputUnion { mi = new MOUSEINPUT { mouseData = unchecked((uint)(dx * 30)), dwFlags = 0x01000 } } };
            SendInput(1, new[] { h }, Marshal.SizeOf<INPUT>());
        }
    }

    public static void MouseClick(string button, int count)
    {
        uint down = button == "right" ? 0x0008u : 0x0002u;
        uint up = button == "right" ? 0x0010u : 0x0004u;
        for (int i = 0; i < Math.Clamp(count, 1, 3); i++)
        {
            var inputs = new[]
            {
                new INPUT { type = 0, U = new InputUnion { mi = new MOUSEINPUT { dwFlags = down } } },
                new INPUT { type = 0, U = new InputUnion { mi = new MOUSEINPUT { dwFlags = up } } }
            };
            SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        }
    }

    public static void MouseDrag(string state)
    {
        uint flag = state == "down" ? 0x0002u : 0x0004u;
        var input = new INPUT { type = 0, U = new InputUnion { mi = new MOUSEINPUT { dwFlags = flag } } };
        SendInput(1, new[] { input }, Marshal.SizeOf<INPUT>());
    }

    public static void TypeText(string text)
    {
        var inputs = new List<INPUT>(text.Length * 2);
        foreach (char ch in text)
        {
            inputs.Add(new INPUT { type = 1, U = new InputUnion { ki = new KEYBDINPUT { wScan = ch, dwFlags = 0x0004 } } });
            inputs.Add(new INPUT { type = 1, U = new InputUnion { ki = new KEYBDINPUT { wScan = ch, dwFlags = 0x0004 | 0x0002 } } });
        }
        if (inputs.Count > 0) SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    public static void PressKey(string key, string[] mods)
    {
        ushort vk = key.ToLowerInvariant() switch
        {
            "escape" or "esc" => 0x1B,
            "tab" => 0x09,
            "enter" or "return" => 0x0D,
            "backspace" => 0x08,
            "delete" => 0x2E,
            "space" => 0x20,
            "left" => 0x25,
            "up" => 0x26,
            "right" => 0x27,
            "down" => 0x28,
            var s when s.Length == 1 && char.IsLetterOrDigit(s[0]) => char.ToUpperInvariant(s[0]),
            _ => 0
        };
        if (vk != 0) SendVirtualKey(vk, mods);
    }

    private static void SendVirtualKey(ushort vk, string[] mods)
    {
        var modVks = mods.Select(m => m.ToLowerInvariant() switch
        {
            "ctrl" or "control" => (ushort)0x11,
            "alt" or "option" => (ushort)0x12,
            "shift" => (ushort)0x10,
            "win" or "cmd" or "meta" => (ushort)0x5B,
            _ => (ushort)0
        }).Where(v => v != 0).ToList();

        var inputs = new List<INPUT>();
        foreach (var mv in modVks)
            inputs.Add(new INPUT { type = 1, U = new InputUnion { ki = new KEYBDINPUT { wVk = mv } } });
        inputs.Add(new INPUT { type = 1, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk } } });
        inputs.Add(new INPUT { type = 1, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = 0x0002 } } });
        for (int i = modVks.Count - 1; i >= 0; i--)
            inputs.Add(new INPUT { type = 1, U = new InputUnion { ki = new KEYBDINPUT { wVk = modVks[i], dwFlags = 0x0002 } } });
        SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    // MARK: - Screenshot, Apps, Clipboard, URL

    public static (byte[] Data, int Width, int Height) CaptureScreenshotJpeg()
    {
        var bounds = Screen.PrimaryScreen?.Bounds ?? new Rectangle(0, 0, 1920, 1080);
        using var rawBmp = new Bitmap(bounds.Width, bounds.Height);
        using (var g = Graphics.FromImage(rawBmp))
        {
            g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
        }

        const int maxWidth = 1280;
        int targetW = bounds.Width > maxWidth ? maxWidth : bounds.Width;
        int targetH = bounds.Width > maxWidth
            ? Math.Max(1, (int)Math.Round(bounds.Height * (maxWidth / (double)bounds.Width)))
            : bounds.Height;

        Bitmap outputBmp = rawBmp;
        Bitmap? resizedBmp = null;
        if (targetW != bounds.Width || targetH != bounds.Height)
        {
            resizedBmp = new Bitmap(targetW, targetH);
            using (var rg = Graphics.FromImage(resizedBmp))
            {
                rg.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                rg.DrawImage(rawBmp, 0, 0, targetW, targetH);
            }
            outputBmp = resizedBmp;
        }

        try
        {
            using var ms = new MemoryStream();
            var jpegCodec = ImageCodecInfo.GetImageEncoders().FirstOrDefault(c => c.FormatID == ImageFormat.Jpeg.Guid);
            if (jpegCodec != null)
            {
                using var encoderParams = new EncoderParameters(1);
                encoderParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 62L);
                outputBmp.Save(ms, jpegCodec, encoderParams);
            }
            else
            {
                outputBmp.Save(ms, ImageFormat.Jpeg);
            }
            return (ms.ToArray(), targetW, targetH);
        }
        finally
        {
            resizedBmp?.Dispose();
        }
    }

    public static List<Dictionary<string, object>> ListRunningApps()
    {
        return Process.GetProcesses()
            .Where(p => p.MainWindowHandle != IntPtr.Zero && !string.IsNullOrWhiteSpace(p.MainWindowTitle))
            .Select(p => new Dictionary<string, object>
            {
                ["id"] = p.Id.ToString(),
                ["name"] = p.ProcessName,
                ["icon"] = "app"
            })
            .Take(50)
            .ToList();
    }

    public static (bool Ok, string Message) CloseApp(string pidStr, bool force)
    {
        if (!int.TryParse(pidStr, out int pid)) return (false, "Invalid app id");
        try
        {
            using var proc = Process.GetProcessById(pid);
            if (force)
            {
                proc.Kill(entireProcessTree: true);
                return (true, "Application terminated");
            }
            if (!proc.CloseMainWindow()) return (false, "Application did not close");
            return proc.WaitForExit(3000) ? (true, "Application closed") : (false, "Application did not close");
        }
        catch (Exception ex) { return (false, ex.Message); }
    }

    public static bool OpenUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) return false;
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
        return true;
    }

    public static void SetClipboardText(string text)
    {
        RunSta(() => System.Windows.Clipboard.SetText(text));
    }

    public static (string Text, bool Truncated) GetClipboardText(int maxChars = 65536)
    {
        string txt = "";
        RunSta(() => { if (System.Windows.Clipboard.ContainsText()) txt = System.Windows.Clipboard.GetText(); });
        if (txt.Length > maxChars) return (txt[..maxChars], true);
        return (txt, false);
    }

    public static int GetIdleSeconds()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref info)) return 0;
        uint elapsedMs = unchecked((uint)Environment.TickCount - info.dwTime);
        return (int)(elapsedMs / 1000);
    }

    private static void RunSta(Action action)
    {
        var t = new System.Threading.Thread(() => { try { action(); } catch { } });
        t.SetApartmentState(System.Threading.ApartmentState.STA);
        t.Start();
        t.Join(2000);
    }

    private static string RunCommandOutput(string file, string args)
    {
        using var p = Process.Start(new ProcessStartInfo(file, args)
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true
        });
        if (p is null) return "";
        var output = p.StandardOutput.ReadToEnd();
        p.WaitForExit(5000);
        return output;
    }

    // MARK: - Win32 Interop & COM IPolicyConfig

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    private class PolicyConfigClient { }

    [Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        int GetMixFormat(string pszDeviceName, IntPtr ppFormat);
        int GetDeviceFormat(string pszDeviceName, bool bDefault, IntPtr ppFormat);
        int ResetDeviceFormat(string pszDeviceName);
        int SetDeviceFormat(string pszDeviceName, IntPtr pEndpointFormat, IntPtr mixFormat);
        int GetProcessingPeriod(string pszDeviceName, bool bDefault, IntPtr pmftDefaultPeriod, IntPtr pmftMinimumPeriod);
        int SetProcessingPeriod(string pszDeviceName, IntPtr pmftPeriod);
        int GetShareMode(string pszDeviceName, IntPtr pMode);
        int SetShareMode(string pszDeviceName, IntPtr mode);
        int GetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        int SetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int role);
        int SetEndpointVisibility(string pszDeviceName, bool bVisible);
    }

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool LockWorkStation();

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out ulong lpIdleTime, out ulong lpKernelTime, out ulong lpUserTime);

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }
}
