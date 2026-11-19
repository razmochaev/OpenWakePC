using System;
using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using WakePCAgent.Core;

namespace WakePCAgent;

public partial class App : System.Windows.Application
{
    public AgentConfig Config { get; private set; } = null!;
    public SchedulerAndIdle Scheduler { get; private set; } = null!;
    public HttpAgentServer Server { get; private set; } = null!;
    public RelayService Relay { get; private set; } = null!;

    private NotifyIcon? _trayIcon;
    private MainWindow? _mainWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        Config = AgentConfig.LoadOrCreate();
        RelayService? relayRef = null;
        Scheduler = new SchedulerAndIdle(Config, hrs => relayRef?.TrySendIdleNotifyAsync(hrs) ?? System.Threading.Tasks.Task.CompletedTask);
        Server = new HttpAgentServer(Config, Scheduler);
        Relay = new RelayService(Config, (path, query, viaRelay) => Server.DispatchCommandAsync(path, query, viaRelay));
        relayRef = Relay;

        Server.Start();
        Relay.Start();

        SetupTrayIcon();
        ShowMainWindow();
    }

    private void SetupTrayIcon()
    {
        _trayIcon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "OpenWakePC Agent",
            Visible = true
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("OpenWakePC Agent", null, (_, _) => ShowMainWindow());
        menu.Items.Add("Fix Firewall Rules (TCP 8765 / UDP 9)", null, (_, _) =>
        {
            WindowsSystem.FixFirewallRules(Config.ApiPort, Config.WolPort);
            _mainWindow?.RefreshUI();
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => ShutdownAgent());

        _trayIcon.ContextMenuStrip = menu;
        _trayIcon.DoubleClick += (_, _) => ShowMainWindow();
    }

    public void ShowMainWindow()
    {
        if (_mainWindow is null || !_mainWindow.IsLoaded)
        {
            _mainWindow = new MainWindow(this);
        }
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    public void RestartServices()
    {
        Config.Save();
        Server.Start();
        Relay.Start();
        _mainWindow?.RefreshUI();
    }

    public void ShutdownAgent()
    {
        _trayIcon?.Dispose();
        Relay.Dispose();
        Server.Dispose();
        Scheduler.Dispose();
        Shutdown();
    }
}
