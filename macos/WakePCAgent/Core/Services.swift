import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

// MARK: - Custom Commands Store (app / url / shell)

struct CustomCommand: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case app
        case url
        case shell
        var id: String { rawValue }
    }

    var id: String = UUID().uuidString.lowercased()
    var name: String
    var kind: Kind
    var target: String
    var icon: String = "terminal"
}

@MainActor
final class CustomCommandStore: ObservableObject {
    static let shared = CustomCommandStore()
    private let key = "agent_custom_commands"

    @Published var commands: [CustomCommand] = []
    private var runningProcs: [String: Process] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CustomCommand].self, from: data) {
            commands = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ command: CustomCommand) {
        commands.append(command)
        save()
    }

    func remove(id: String) {
        commands.removeAll { $0.id == id }
        save()
    }

    func serializedList() -> [[String: Any]] {
        commands.map { cmd in
            let isRunning = runningState(for: cmd)
            return [
                "id": cmd.id,
                "name": cmd.name,
                "icon": cmd.icon,
                "running": isRunning,
                "closable": cmd.kind == .app || cmd.kind == .shell,
            ]
        }
    }

    func run(id: String) -> (Bool, String) {
        guard let cmd = commands.first(where: { $0.id == id }) else {
            return (false, "Command not found")
        }
        switch cmd.kind {
        case .app:
            let url = URL(fileURLWithPath: cmd.target)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return (true, "Launched \(cmd.name)")
        case .url:
            if let url = URL(string: cmd.target) {
                NSWorkspace.shared.open(url)
                return (true, "Opened \(cmd.name)")
            }
            return (false, "Invalid URL")
        case .shell:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd.target]
            try? p.run()
            runningProcs[cmd.id] = p
            return (true, "Executed \(cmd.name)")
        }
    }

    func close(id: String) -> (Bool, String) {
        guard let cmd = commands.first(where: { $0.id == id }) else {
            return (false, "Command not found")
        }
        if cmd.kind == .shell, let proc = runningProcs.removeValue(forKey: cmd.id) {
            if proc.isRunning { proc.terminate() }
            return (true, "Closed \(cmd.name)")
        }
        if cmd.kind == .app {
            let targetURL = URL(fileURLWithPath: cmd.target).standardizedFileURL
            for app in NSWorkspace.shared.runningApplications {
                if app.bundleURL?.standardizedFileURL == targetURL {
                    app.terminate()
                    return (true, "Closed \(cmd.name)")
                }
            }
        }
        return (false, "Only running apps or shell commands can be closed")
    }

    private func runningState(for cmd: CustomCommand) -> Bool {
        if cmd.kind == .shell, let proc = runningProcs[cmd.id] {
            return proc.isRunning
        }
        if cmd.kind == .app {
            let targetURL = URL(fileURLWithPath: cmd.target).standardizedFileURL
            return NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL?.standardizedFileURL == targetURL
            }
        }
        return false
    }
}

// MARK: - Bonjour Service (_wakepc._tcp)

@MainActor
final class BonjourService: NSObject, ObservableObject, NetServiceDelegate {
    @Published private(set) var isPublished = false
    private var service: NetService?

    func start(config: AgentConfig) {
        stop()
        let netService = NetService(
            domain: "local.",
            type: "_wakepc._tcp.",
            name: config.hostname,
            port: Int32(config.port)
        )
        netService.setTXTRecord(makeTXTRecord(config: config))
        netService.delegate = self
        netService.publish()
        service = netService
    }

    func updateTXTRecord(config: AgentConfig) {
        if let service, isPublished {
            service.setTXTRecord(makeTXTRecord(config: config))
        } else {
            start(config: config)
        }
    }

    private func makeTXTRecord(config: AgentConfig) -> Data {
        let txt: [String: Data] = [
            "ip": Data(config.localIP.utf8),
            "mac": Data(config.macAddress.utf8),
            "bcast": Data(config.broadcastAddress.utf8),
            "name": Data(config.hostname.utf8),
            "type": Data("mac".utf8),
            "deviceId": Data(config.deviceId.utf8),
            "token": Data(config.token.utf8),
            "apiPort": Data(String(config.port).utf8),
            "wolPort": Data(String(config.wolPort).utf8),
            "version": Data(AgentConfig.agentVersion.utf8),
        ]
        return NetService.data(fromTXTRecord: txt)
    }

    func stop() {
        service?.stop()
        service = nil
        isPublished = false
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in self.isPublished = true }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in self.isPublished = false }
    }
}

// MARK: - Status Checker & 1-Click macOS Fixes (WoL / Firewall)

@MainActor
final class StatusChecker: ObservableObject {
    @Published var hasNetwork = true
    @Published var wolEnabled = false
    @Published var firewallOK = true

    func refresh() {
        let ip = AgentConfig.detectPrimaryIPv4().ip
        hasNetwork = ip != "127.0.0.1"

        let pmsetOut = MacSystemController.shared.runProcessOutput("/usr/bin/pmset", ["-g"])
        wolEnabled = pmsetOut.contains("womp                 1") || pmsetOut.contains("womp\t1") || pmsetOut.contains("womp 1")

        let fwOut = MacSystemController.shared.runProcessOutput(
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            ["--getglobalstate"]
        )
        // Firewall is OK if disabled or if stealth/block-all is not active
        firewallOK = fwOut.lowercased().contains("disabled") || !fwOut.lowercased().contains("block all")
    }

    func fixWakeOnLAN() {
        let script = #"do shell script "pmset -a womp 1 networkoversleep 1 tcpkeepalive 1" with administrator privileges"#
        MacSystemController.shared.runProcess("/usr/bin/osascript", ["-e", script])
        refresh()
    }

    func openFirewallSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Launch At Login (SMAppService)

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Scheduler & Idle Monitor

@MainActor
final class SchedulerAndIdleMonitor: ObservableObject {
    private(set) var scheduledAction: String?
    private(set) var scheduledAt: Date?
    private(set) var idleAction: String?
    private(set) var idleMinutes: Int = 10
    private(set) var idleStreakSeconds: Int = 0
    private(set) var idleNotifyHours: Int {
        didSet { UserDefaults.standard.set(idleNotifyHours, forKey: "agent_idle_notify_hours") }
    }

    var onIdleNotify: ((Int) -> Void)?
    private var notifiedCurrentStreak = false
    private var timer: Timer?

    init() {
        self.idleNotifyHours = UserDefaults.standard.integer(forKey: "agent_idle_notify_hours")
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func schedule(action: String, minutes: Int) -> [String: Any] {
        scheduledAction = action
        scheduledAt = Date().addingTimeInterval(TimeInterval(max(1, min(minutes, 1440)) * 60))
        return statusDict()
    }

    func cancelAll() -> [String: Any] {
        scheduledAction = nil
        scheduledAt = nil
        idleAction = nil
        idleStreakSeconds = 0
        return statusDict()
    }

    func setIdleAction(_ action: String?, minutes: Int) -> [String: Any] {
        if let action, action == "shutdown" || action == "sleep" {
            idleAction = action
            idleMinutes = max(1, min(minutes, 240))
            idleStreakSeconds = 0
        } else {
            idleAction = nil
            idleStreakSeconds = 0
        }
        return statusDict()
    }

    func setIdleNotify(hours: Int) -> [String: Any] {
        idleNotifyHours = [0, 1, 2, 4].contains(hours) ? hours : 0
        notifiedCurrentStreak = false
        return statusDict()
    }

    func statusDict() -> [String: Any] {
        let hasScheduled = scheduledAction != nil && scheduledAt != nil
        let remaining = hasScheduled ? max(0, Int(scheduledAt!.timeIntervalSinceNow)) : 0
        var dict: [String: Any] = [
            "hasScheduled": hasScheduled,
            "remainingSeconds": remaining,
            "idleMinutes": idleMinutes,
            "idleStreakSeconds": idleStreakSeconds,
            "idleNotifyHours": idleNotifyHours,
        ]
        if let scheduledAction { dict["action"] = scheduledAction }
        if let scheduledAt { dict["scheduledAt"] = Int(scheduledAt.timeIntervalSince1970) }
        if let idleAction { dict["idleAction"] = idleAction }
        return dict
    }

    private func tick() {
        if let action = scheduledAction, let target = scheduledAt, Date() >= target {
            scheduledAction = nil
            scheduledAt = nil
            _ = MacSystemController.shared.executePower(action)
            return
        }

        if idleAction != nil || idleNotifyHours > 0 {
            let idleSec = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
            if idleSec >= 10 {
                idleStreakSeconds = Int(idleSec)
            } else {
                idleStreakSeconds = 0
                notifiedCurrentStreak = false
            }

            if let action = idleAction, idleStreakSeconds >= idleMinutes * 60 {
                idleAction = nil
                idleStreakSeconds = 0
                _ = MacSystemController.shared.executePower(action)
                return
            }

            if idleNotifyHours > 0 && !notifiedCurrentStreak && idleStreakSeconds >= idleNotifyHours * 3600 {
                notifiedCurrentStreak = true
                onIdleNotify?(idleNotifyHours)
            }
        }
    }
}
