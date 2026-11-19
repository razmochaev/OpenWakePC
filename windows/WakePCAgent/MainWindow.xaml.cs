using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing.Imaging;
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using QRCoder;
using WakePCAgent.Core;

namespace WakePCAgent;

public partial class MainWindow : Window
{
    private readonly App _app;

    public MainWindow(App app)
    {
        _app = app;
        InitializeComponent();
        _app.Server.StateChanged += () => Dispatcher.Invoke(RefreshUI);
        _app.Relay.StatusChanged += () => Dispatcher.Invoke(RefreshUI);
        RefreshUI();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Hide to system tray instead of quitting
        e.Cancel = true;
        Hide();
    }

    public void RefreshUI()
    {
        var net = AgentConfig.DetectPrimaryNetwork();
        StatusBadge.Text = _app.Server.IsRunning
            ? $"Online • Port {_app.Config.ApiPort} • {_app.Server.RequestsCount} requests"
            : "Server stopped";
        NetworkSummary.Text = $"IP: {net.Ip}\nMAC: {net.Mac}\nBroadcast: {net.Broadcast}\nDevice ID: {_app.Config.DeviceId}";
        RelayStatusText.Text = $"Relay: {_app.Relay.StatusText}";

        PortBox.Text = _app.Config.ApiPort.ToString();
        TokenBox.Text = _app.Config.Token;
        RelayUrlBox.Text = _app.Config.RelayUrl;
        RelayDiscoveryBox.Text = _app.Config.RelayDiscoveryUrl;

        RenderQrCode(_app.Config.BuildQrUrl());
        CommandsList.Items.Clear();
        foreach (var cmd in _app.Config.CustomCommands)
        {
            CommandsList.Items.Add($"{cmd.Name} ({cmd.Kind}) -> {cmd.Target}");
        }
    }

    private void RenderQrCode(string url)
    {
        using var gen = new QRCodeGenerator();
        using var data = gen.CreateQrCode(url, QRCodeGenerator.ECCLevel.Q);
        using var code = new PngByteQRCode(data);
        var pngBytes = code.GetGraphic(8);
        using var ms = new MemoryStream(pngBytes);
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.StreamSource = ms;
        bmp.EndInit();
        QrImage.Source = bmp;
    }

    private void OnSaveSettings(object sender, RoutedEventArgs e)
    {
        if (int.TryParse(PortBox.Text, out int port) && port is >= 1 and <= 65535)
            _app.Config.ApiPort = port;
        if (!string.IsNullOrWhiteSpace(TokenBox.Text) && TokenBox.Text.Trim().Length >= 8)
            _app.Config.Token = TokenBox.Text.Trim();
        _app.Config.RelayUrl = RelayUrlBox.Text.Trim().TrimEnd('/');
        _app.Config.RelayDiscoveryUrl = RelayDiscoveryBox.Text.Trim();
        _app.RestartServices();
    }

    private void OnRegenerateToken(object sender, RoutedEventArgs e)
    {
        _app.Config.RegenerateToken();
        _app.RestartServices();
    }

    private void OnFixFirewall(object sender, RoutedEventArgs e)
    {
        bool ok = WindowsSystem.FixFirewallRules(_app.Config.ApiPort, _app.Config.WolPort);
        System.Windows.MessageBox.Show(
            ok ? "Firewall rules added (TCP 8765 + UDP 9)." : "Run as Administrator to update Windows Firewall rules.",
            "OpenWakePC Agent");
    }

    private void OnEnableAutostart(object sender, RoutedEventArgs e)
    {
        bool ok = WindowsSystem.SetAutostartTask(true);
        System.Windows.MessageBox.Show(
            ok ? "Launch at login enabled (Task Scheduler: WakePCAgent)." : "Failed to register autostart task.",
            "OpenWakePC Agent");
    }

    private void OnAddCommand(object sender, RoutedEventArgs e)
    {
        var name = CmdNameBox.Text.Trim();
        var target = CmdTargetBox.Text.Trim();
        if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(target)) return;
        var kind = CmdKindBox.SelectedIndex switch
        {
            1 => CustomCommandKind.Url,
            2 => CustomCommandKind.Shell,
            _ => CustomCommandKind.App
        };
        _app.Config.CustomCommands.Add(new CustomCommand { Name = name, Kind = kind, Target = target });
        _app.Config.Save();
        CmdNameBox.Text = "";
        CmdTargetBox.Text = "";
        RefreshUI();
    }

    private void OnOpenLink(object sender, RequestNavigateEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        }
        catch { }
        e.Handled = true;
    }
}
