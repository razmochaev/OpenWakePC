using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace WakePCAgent.Core;

/// <summary>
/// Manages countdown schedules, idle-action automation, idle push alerts, and custom commands.
/// </summary>
public sealed class SchedulerAndIdle : IDisposable
{
    private readonly AgentConfig _config;
    private readonly Func<int, Task>? _onIdleNotify;
    private readonly System.Threading.Timer _timer;
    private readonly Dictionary<string, Process> _runningCommands = new();

    private string? _scheduledAction;
    private DateTimeOffset? _scheduledAt;
    private string? _idleAction;
    private int _idleMinutes = 10;
    private int _idleStreakSeconds;
    private bool _notifiedCurrentStreak;

    public SchedulerAndIdle(AgentConfig config, Func<int, Task>? onIdleNotify = null)
    {
        _config = config;
        _onIdleNotify = onIdleNotify;
        _timer = new System.Threading.Timer(_ => Tick(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    }

    public Dictionary<string, object?> Schedule(string action, int minutes)
    {
        _scheduledAction = action;
        _scheduledAt = DateTimeOffset.UtcNow.AddMinutes(Math.Clamp(minutes, 1, 1440));
        return GetStatus();
    }

    public Dictionary<string, object?> CancelAll()
    {
        _scheduledAction = null;
        _scheduledAt = null;
        _idleAction = null;
        _idleStreakSeconds = 0;
        return GetStatus();
    }

    public Dictionary<string, object?> SetIdleAction(string? action, int minutes)
    {
        if (action is "shutdown" or "sleep")
        {
            _idleAction = action;
            _idleMinutes = Math.Clamp(minutes, 1, 240);
            _idleStreakSeconds = 0;
        }
        else
        {
            _idleAction = null;
            _idleStreakSeconds = 0;
        }
        return GetStatus();
    }

    public Dictionary<string, object?> SetIdleNotify(int hours)
    {
        _config.IdleNotifyHours = hours is 0 or 1 or 2 or 4 ? hours : 0;
        _config.Save();
        _notifiedCurrentStreak = false;
        return GetStatus();
    }

    public Dictionary<string, object?> GetStatus()
    {
        bool hasScheduled = _scheduledAction is not null && _scheduledAt is not null;
        int remaining = hasScheduled ? Math.Max(0, (int)(_scheduledAt!.Value - DateTimeOffset.UtcNow).TotalSeconds) : 0;
        return new Dictionary<string, object?>
        {
            ["hasScheduled"] = hasScheduled,
            ["action"] = _scheduledAction,
            ["remainingSeconds"] = remaining,
            ["scheduledAt"] = _scheduledAt?.ToUnixTimeSeconds(),
            ["idleAction"] = _idleAction,
            ["idleMinutes"] = _idleMinutes,
            ["idleStreakSeconds"] = _idleStreakSeconds,
            ["idleNotifyHours"] = _config.IdleNotifyHours
        };
    }

    public List<Dictionary<string, object?>> ListCustomCommands()
    {
        return _config.CustomCommands.Select(cmd =>
        {
            bool running = _runningCommands.TryGetValue(cmd.Id, out var proc) && !proc.HasExited;
            return new Dictionary<string, object?>
            {
                ["id"] = cmd.Id,
                ["name"] = cmd.Name,
                ["icon"] = cmd.Icon,
                ["iconImage"] = null,
                ["running"] = running,
                ["closable"] = cmd.Kind != CustomCommandKind.Url
            };
        }).ToList();
    }

    public (bool Ok, string Message) RunCustomCommand(string id)
    {
        var cmd = _config.CustomCommands.FirstOrDefault(c => c.Id == id);
        if (cmd is null) return (false, "Command not found");
        try
        {
            Process? proc = cmd.Kind switch
            {
                CustomCommandKind.Url => Process.Start(new ProcessStartInfo(cmd.Target) { UseShellExecute = true }),
                CustomCommandKind.App => Process.Start(new ProcessStartInfo(cmd.Target) { UseShellExecute = true }),
                CustomCommandKind.Shell => Process.Start(new ProcessStartInfo("cmd.exe", $"/c {cmd.Target}") { UseShellExecute = false, CreateNoWindow = true }),
                _ => null
            };
            if (proc is not null) _runningCommands[cmd.Id] = proc;
            return (true, $"Started {cmd.Name}");
        }
        catch (Exception ex) { return (false, ex.Message); }
    }

    public (bool Ok, string Message) CloseCustomCommand(string id)
    {
        if (!_runningCommands.Remove(id, out var proc)) return (true, "Already closed");
        try
        {
            if (!proc.HasExited)
            {
                if (!proc.CloseMainWindow()) proc.Kill(entireProcessTree: true);
            }
            return (true, "Closed");
        }
        catch (Exception ex) { return (false, ex.Message); }
    }

    private void Tick()
    {
        if (_scheduledAction is not null && _scheduledAt is not null && DateTimeOffset.UtcNow >= _scheduledAt.Value)
        {
            var act = _scheduledAction;
            _scheduledAction = null;
            _scheduledAt = null;
            WindowsSystem.ExecutePower(act);
            return;
        }

        if (_idleAction is not null || _config.IdleNotifyHours > 0)
        {
            int idleSec = WindowsSystem.GetIdleSeconds();
            if (idleSec >= 10)
            {
                _idleStreakSeconds = idleSec;
            }
            else
            {
                _idleStreakSeconds = 0;
                _notifiedCurrentStreak = false;
            }

            if (_idleAction is not null && _idleStreakSeconds >= _idleMinutes * 60)
            {
                var act = _idleAction;
                _idleAction = null;
                _idleStreakSeconds = 0;
                WindowsSystem.ExecutePower(act);
                return;
            }

            if (_config.IdleNotifyHours > 0 && !_notifiedCurrentStreak && _idleStreakSeconds >= _config.IdleNotifyHours * 3600)
            {
                _notifiedCurrentStreak = true;
                if (_onIdleNotify is not null) _ = _onIdleNotify(_config.IdleNotifyHours);
            }
        }
    }

    public void Dispose()
    {
        _timer.Dispose();
    }
}
