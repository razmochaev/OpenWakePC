import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI
import UniformTypeIdentifiers

/// Root Menu Bar application for Open Wake PC Mac Agent (macOS 14+, 100% Free & Open Source).
@main
struct WakePCAgentApp: App {
    @StateObject private var runtime = AgentRuntime.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(runtime: runtime, openWindow: openWindow)
        } label: {
            Image(systemName: runtime.server.isRunning ? "power.circle.fill" : "power.circle")
        }
        .menuBarExtraStyle(.window)

        Window(L10nMac.tr("welcome_title"), id: "welcome") {
            WelcomeView(runtime: runtime)
        }
        .windowResizability(.contentSize)

        Window(L10nMac.tr("pair_iphone"), id: "qr") {
            QRCodeView(urlString: runtime.config.buildQRURL())
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(runtime: runtime)
        }
    }
}

@MainActor
final class AgentRuntime: ObservableObject {
    static let shared = AgentRuntime()

    let config = AgentConfig.shared
    let commands = CustomCommandStore.shared
    let status = StatusChecker()
    let bonjour = BonjourService()
    let launchAtLogin = LaunchAtLogin()
    let scheduler = SchedulerAndIdleMonitor()
    let server: HTTPServer
    let relay: RelayClient
    private var cancellables: Set<AnyCancellable> = []
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "org.openwakepc.agent.netmonitor")
    private var ipWatchTimer: Timer?
    private var lastKnownIP: String = ""
    private var lastKnownMAC: String = ""

    private init() {
        let srv = HTTPServer(config: config, commands: commands, scheduler: scheduler)
        self.server = srv
        let rel = RelayClient(config: config) { path, query, viaRelay in
            await srv.dispatchCommand(path: path, query: query, viaRelay: viaRelay)
        }
        self.relay = rel
        scheduler.onIdleNotify = { [weak rel] hrs in
            rel?.sendIdleNotify(hours: hrs)
        }
        config.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        commands.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        status.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        bonjour.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        launchAtLogin.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        srv.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        rel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        startAll()
        startNetworkWatcher()
    }

    func startAll() {
        status.refresh()
        server.start()
        bonjour.start(config: config)
        relay.start()
    }

    func restartServices() {
        server.start()
        bonjour.start(config: config)
        relay.start()
        status.refresh()
    }

    private func startNetworkWatcher() {
        lastKnownIP = config.localIP
        lastKnownMAC = config.macAddress
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleNetworkChangeCheck(forceInvalidate: true)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
        ipWatchTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleNetworkChangeCheck(forceInvalidate: true)
            }
        }
    }

    private func handleNetworkChangeCheck(forceInvalidate: Bool) {
        if forceInvalidate {
            AgentConfig.invalidateNetworkCache()
        }
        let ip = config.localIP
        let mac = config.macAddress
        guard ip != "127.0.0.1" else { return }
        if ip != lastKnownIP || mac != lastKnownMAC {
            lastKnownIP = ip
            lastKnownMAC = mac
            bonjour.updateTXTRecord(config: config)
            status.refresh()
            objectWillChange.send()
            if config.relayMode != "off" && !relay.isOnline {
                relay.start()
            }
        }
    }
}

// MARK: - Menu Bar Popover

struct MenuBarView: View {
    @ObservedObject var runtime: AgentRuntime
    let openWindow: OpenWindowAction

    private var allHealthy: Bool {
        runtime.status.hasNetwork && runtime.server.isRunning && runtime.status.wolEnabled && runtime.status.firewallOK
    }

    private var summaryText: String {
        if !runtime.status.hasNetwork { return L10nMac.tr("status_no_network") }
        if !runtime.server.isRunning { return L10nMac.tr("status_server_stopped") }
        if !runtime.status.wolEnabled || !runtime.status.firewallOK { return L10nMac.tr("status_attention") }
        return L10nMac.tr("status_ready")
    }

    private var relayRowOK: Bool {
        runtime.config.relayMode == "off" ? true : runtime.relay.isOnline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header card
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.config.hostname)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(runtime.config.localIP):\(runtime.config.port)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(allHealthy ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(summaryText)
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.7), in: Capsule())
            }

            // Primary QR Pairing button
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "qr")
            } label: {
                Label(L10nMac.tr("pair_iphone"), systemImage: "qrcode")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Live status card
            VStack(spacing: 0) {
                statusRow(
                    icon: "wifi",
                    title: L10nMac.tr("status_network"),
                    ok: runtime.status.hasNetwork,
                    detail: runtime.config.localIP
                )
                Divider().padding(.leading, 28)
                statusRow(
                    icon: "network",
                    title: L10nMac.tr("status_server"),
                    ok: runtime.server.isRunning,
                    detail: runtime.server.isRunning
                        ? String(format: L10nMac.tr("port_detail"), runtime.config.port)
                        : L10nMac.tr("stopped")
                )
                Divider().padding(.leading, 28)
                statusRow(
                    icon: "lock.shield",
                    title: "E2EE Relay",
                    ok: relayRowOK,
                    detail: runtime.relay.lastStatusMessage
                )
                Divider().padding(.leading, 28)
                statusRow(
                    icon: "bonjour",
                    title: L10nMac.tr("status_discovery"),
                    ok: runtime.bonjour.isPublished,
                    detail: runtime.bonjour.isPublished ? L10nMac.tr("visible") : L10nMac.tr("hidden")
                )
                Divider().padding(.leading, 28)
                statusRow(
                    icon: "bolt.fill",
                    title: L10nMac.tr("status_wol"),
                    ok: runtime.status.wolEnabled,
                    detail: runtime.status.wolEnabled ? L10nMac.tr("enabled") : L10nMac.tr("disabled"),
                    fixAction: runtime.status.wolEnabled ? nil : { runtime.status.fixWakeOnLAN() }
                )
                Divider().padding(.leading, 28)
                statusRow(
                    icon: "shield.lefthalf.filled",
                    title: L10nMac.tr("status_firewall"),
                    ok: runtime.status.firewallOK,
                    detail: runtime.status.firewallOK ? L10nMac.tr("firewall_ok") : L10nMac.tr("firewall_may_block"),
                    fixAction: runtime.status.firewallOK ? nil : { runtime.status.openFirewallSettings() }
                )
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            // Bottom bar
            HStack(spacing: 10) {
                Text("\(L10nMac.tr("requests_count")): \(runtime.config.requestsCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    runtime.status.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10nMac.tr("refresh"))

                SettingsLink {
                    Label(L10nMac.tr("settings"), systemImage: "gearshape")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help(L10nMac.tr("quit"))
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func statusRow(
        icon: String,
        title: String,
        ok: Bool,
        detail: String,
        fixAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(ok ? Color.green : Color.orange)
                .frame(width: 16)
            Text(title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let fixAction {
                Button(L10nMac.tr("fix"), action: fixAction)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(ok ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// MARK: - QR Code & Welcome Views

struct QRCodeView: View {
    let urlString: String

    var body: some View {
        VStack(spacing: 14) {
            if let img = generateQR(from: urlString) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            }
            Text(L10nMac.tr("scan_qr"))
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            Button(L10nMac.tr("copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 320)
    }

    private func generateQR(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

struct WelcomeView: View {
    @ObservedObject var runtime: AgentRuntime
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(L10nMac.tr("welcome_title")).font(.title2.bold())
            Text(L10nMac.tr("welcome_menubar_hint"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            QRCodeView(urlString: runtime.config.buildQRURL())
            Button(L10nMac.tr("welcome_done")) {
                runtime.config.seenWelcome = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Settings View (General / Commands)

struct SettingsView: View {
    @ObservedObject var runtime: AgentRuntime
    @ObservedObject var config: AgentConfig
    @ObservedObject var commands: CustomCommandStore
    @State private var showAddCommand = false

    init(runtime: AgentRuntime) {
        self.runtime = runtime
        self.config = runtime.config
        self.commands = runtime.commands
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L10nMac.tr("general"), systemImage: "gearshape") }
            commandsTab
                .tabItem { Label(L10nMac.tr("commands_tab"), systemImage: "bolt.horizontal.circle") }
        }
        .frame(width: 520, height: 460)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker(L10nMac.tr("relay_mode_label"), selection: $config.relayMode) {
                    Text(L10nMac.tr("relay_mode_cloud")).tag("cloud")
                    Text(L10nMac.tr("relay_mode_custom")).tag("custom")
                    Text(L10nMac.tr("relay_mode_off")).tag("off")
                }
                .onChange(of: config.relayMode) { _, _ in
                    runtime.restartServices()
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(config.relayMode == "off" ? Color.secondary : (runtime.relay.isOnline ? Color.green : Color.orange))
                        .frame(width: 8, height: 8)
                    Text(runtime.relay.lastStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if config.relayMode == "custom" {
                    TextField(L10nMac.tr("relay_custom_placeholder"), text: $config.customRelayURL)
                    Button(L10nMac.tr("apply_restart")) { runtime.restartServices() }
                }
            } header: {
                Text(L10nMac.tr("relay_section"))
            } footer: {
                Text(L10nMac.tr("relay_cloud_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10nMac.tr("server_section")) {
                TextField(L10nMac.tr("port_label"), value: $config.port, format: .number)
                HStack {
                    TextField(L10nMac.tr("token_label"), text: $config.token)
                    Button(L10nMac.tr("regenerate")) {
                        config.regenerateToken()
                        runtime.restartServices()
                    }
                }
                Button(L10nMac.tr("apply_restart")) { runtime.restartServices() }
            }

            Section(L10nMac.tr("startup")) {
                Toggle(L10nMac.tr("launch_at_login"), isOn: Binding(
                    get: { runtime.launchAtLogin.isEnabled },
                    set: { runtime.launchAtLogin.setEnabled($0) }
                ))
            }

            Section(L10nMac.tr("info")) {
                LabeledContent(L10nMac.tr("ip_address"), value: config.localIP)
                LabeledContent(L10nMac.tr("mac_address"), value: config.macAddress)
                LabeledContent(L10nMac.tr("broadcast_label"), value: config.broadcastAddress)
                LabeledContent(L10nMac.tr("hostname"), value: config.hostname)
            }

            Section {
                LabeledContent(L10nMac.tr("website_label")) {
                    Link("razmochaev.com", destination: URL(string: "https://razmochaev.com")!)
                }
                LabeledContent(L10nMac.tr("github_label")) {
                    Link("github.com/razmochaev/OpenWakePC", destination: URL(string: "https://github.com/razmochaev/OpenWakePC")!)
                }
            } header: {
                Text(L10nMac.tr("links_section"))
            } footer: {
                Text("OpenWakePC Agent • © 2026 razmochaev")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var commandsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Explanation header card
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10nMac.tr("commands_header_title"))
                        .font(.headline)
                    Text(L10nMac.tr("commands_header_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // 1-Click presets
            VStack(alignment: .leading, spacing: 6) {
                Text(L10nMac.tr("commands_presets_label"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        presetChip(title: L10nMac.tr("preset_safari"), icon: "safari", kind: .app, target: "/Applications/Safari.app")
                        presetChip(title: L10nMac.tr("preset_youtube"), icon: "play.rectangle.fill", kind: .url, target: "https://www.youtube.com")
                        presetChip(title: L10nMac.tr("preset_music"), icon: "music.note", kind: .app, target: "/System/Applications/Music.app")
                        presetChip(title: L10nMac.tr("preset_screensaver"), icon: "sparkles.tv", kind: .app, target: "/System/Library/CoreServices/ScreenSaverEngine.app")
                        presetChip(
                            title: L10nMac.tr("preset_trash"),
                            icon: "trash",
                            kind: .shell,
                            target: #"osascript -e 'tell application "Finder" to empty trash'"#
                        )
                    }
                }
            }

            // Commands list or friendly empty state
            if commands.commands.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(L10nMac.tr("commands_empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(commands.commands) { cmd in
                            commandCard(cmd)
                        }
                    }
                    .padding(2)
                }
            }

            HStack {
                Text(L10nMac.tr("commands_hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showAddCommand = true
                } label: {
                    Label(L10nMac.tr("commands_add"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 4)
        .sheet(isPresented: $showAddCommand) {
            AddCommandSheet { cmd in commands.add(cmd) }
        }
    }

    private func presetChip(title: String, icon: String, kind: CustomCommand.Kind, target: String) -> some View {
        let alreadyAdded = commands.commands.contains { $0.target == target }
        return Button {
            if !alreadyAdded {
                commands.add(CustomCommand(name: title, kind: kind, target: target, icon: icon))
            }
        } label: {
            Label(title, systemImage: alreadyAdded ? "checkmark.circle.fill" : icon)
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(alreadyAdded)
    }

    private func commandCard(_ cmd: CustomCommand) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: iconFor(cmd))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cmd.name)
                        .font(.subheadline.weight(.semibold))
                    Text(kindLabel(cmd.kind))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(cmd.target)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(L10nMac.tr("command_run_btn")) {
                _ = commands.run(id: cmd.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                commands.remove(id: cmd.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10nMac.tr("command_delete_tip"))
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func iconFor(_ cmd: CustomCommand) -> String {
        if !cmd.icon.isEmpty && cmd.icon != "terminal" { return cmd.icon }
        switch cmd.kind {
        case .app: return "app.badge"
        case .url: return "globe"
        case .shell: return "terminal"
        }
    }

    private func kindLabel(_ kind: CustomCommand.Kind) -> String {
        switch kind {
        case .app: return L10nMac.tr("command_kind_app")
        case .url: return L10nMac.tr("command_kind_url")
        case .shell: return L10nMac.tr("command_kind_shell")
        }
    }
}

struct AddCommandSheet: View {
    let onAdd: (CustomCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: CustomCommand.Kind = .app
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10nMac.tr("commands_add"))
                .font(.headline)

            Picker(L10nMac.tr("command_kind"), selection: $kind) {
                Text(L10nMac.tr("command_kind_app")).tag(CustomCommand.Kind.app)
                Text(L10nMac.tr("command_kind_url")).tag(CustomCommand.Kind.url)
                Text(L10nMac.tr("command_kind_shell")).tag(CustomCommand.Kind.shell)
            }
            .pickerStyle(.segmented)

            TextField(L10nMac.tr("command_name"), text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField(targetPlaceholder, text: $target)
                    .textFieldStyle(.roundedBorder)
                if kind == .app {
                    Button(L10nMac.tr("choose_app")) { pickApplication() }
                }
            }

            HStack {
                Button(L10nMac.tr("cancel")) { dismiss() }
                Spacer()
                Button(L10nMac.tr("add")) {
                    let icon: String = switch kind {
                    case .app: "app.badge"
                    case .url: "globe"
                    case .shell: "terminal"
                    }
                    onAdd(CustomCommand(name: name, kind: kind, target: target, icon: icon))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private var targetPlaceholder: String {
        switch kind {
        case .app: return L10nMac.tr("command_target_app")
        case .url: return L10nMac.tr("command_target_url")
        case .shell: return L10nMac.tr("command_target_shell")
        }
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            target = url.path
            if name.isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
        }
    }
}

enum L10nMac {
    private static let fallbackEN: [String: String] = [
        "agent_title": "OpenWakePC Agent",
        "status_network": "Network (Wi-Fi)",
        "status_wol": "Wake-on-LAN",
        "status_firewall": "Firewall",
        "status_server": "Local Server",
        "status_discovery": "Bonjour Discovery",
        "enabled": "Enabled",
        "disabled": "Disabled",
        "firewall_ok": "OK",
        "firewall_may_block": "May block",
        "port_detail": "Port %d",
        "stopped": "Stopped",
        "visible": "Visible",
        "hidden": "Hidden",
        "fix": "Fix",
        "refresh": "Refresh",
        "settings": "Settings",
        "quit": "Quit",
        "scan_qr": "Scan this QR code in the OpenWakePC iPhone app",
        "general": "General",
        "server_section": "Local Server",
        "port_label": "Port",
        "token_label": "Access Token",
        "regenerate": "Regenerate",
        "apply_restart": "Apply & Restart",
        "startup": "Startup",
        "launch_at_login": "Launch at login",
        "info": "This Mac",
        "ip_address": "IP Address",
        "mac_address": "MAC Address",
        "broadcast_label": "Broadcast",
        "hostname": "Hostname",
        "requests_count": "Commands handled",
        "status_ready": "Ready",
        "status_attention": "Attention",
        "status_server_stopped": "Server stopped",
        "status_no_network": "No network",
        "pair_iphone": "Pair iPhone",
        "welcome_title": "OpenWakePC Agent is Running",
        "welcome_menubar_hint": "Look for the icon in your menu bar next to the clock. Scan the QR code in OpenWakePC on iPhone to connect.",
        "welcome_done": "Done",
        "copy": "Copy Link",
        "commands_tab": "Commands",
        "commands_header_title": "Quick Buttons for iPhone",
        "commands_header_desc": "Add apps, websites, or shell actions — they appear automatically on the main screen of OpenWakePC on your iPhone.",
        "commands_presets_label": "Ready presets (click to add):",
        "preset_safari": "Safari",
        "preset_youtube": "YouTube",
        "preset_music": "Music",
        "preset_screensaver": "Screen Saver",
        "preset_trash": "Empty Trash",
        "commands_empty": "No custom commands yet. Pick a preset above or add your own.",
        "commands_add": "Add Command",
        "commands_hint": "Buttons sync to your iPhone automatically",
        "command_test": "Run",
        "command_run_btn": "Run",
        "command_delete_tip": "Remove command",
        "command_kind": "Type",
        "command_kind_app": "Application",
        "command_kind_url": "Website / URL",
        "command_kind_shell": "Shell (zsh)",
        "command_target_app": "/Applications/Safari.app",
        "command_target_url": "https://youtube.com",
        "command_target_shell": "e.g. open -a Safari",
        "command_name": "Button Name on iPhone",
        "choose_app": "Choose...",
        "add": "Add",
        "cancel": "Cancel",
        "relay_section": "Remote Access (E2EE Relay)",
        "relay_mode_label": "Relay Mode",
        "relay_mode_cloud": "Free Cloud E2EE (Auto)",
        "relay_mode_custom": "Custom Server",
        "relay_mode_off": "Wi-Fi Only",
        "relay_cloud_hint": "Works out of the box via free zero-knowledge E2EE relay (AES-256-GCM). The relay never sees your commands or keys.",
        "relay_custom_placeholder": "Custom relay URL (https://...)",
        "relay_status_online_cloud": "Cloud (E2EE)",
        "relay_status_online_custom": "Custom (E2EE)",
        "relay_status_off": "Wi-Fi Only",
        "links_section": "Links",
        "website_label": "Website",
        "github_label": "GitHub (Downloads)",
    ]

    static func tr(_ key: String) -> String {
        let def = fallbackEN[key] ?? key
        return NSLocalizedString(key, tableName: nil, bundle: .main, value: def, comment: "")
    }
}
