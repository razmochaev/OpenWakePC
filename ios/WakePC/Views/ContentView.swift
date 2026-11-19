import SwiftUI
import WidgetKit

/// Primary control hub for Open Wake PC — 100% free, all features unlocked.
struct ContentView: View {
    @Binding var incomingQRCode: PCQRCode?

    @StateObject private var network = NetworkService.shared
    @StateObject private var geofence = GeofenceWakeService.shared
    @StateObject private var emptyDiscovery = PCDiscoveryService()

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("selectedTheme") private var selectedThemeId: String = "aura"
    @AppStorage("buttonIconsOnly") private var buttonIconsOnly: Bool = false
    @AppStorage("seenOnboarding") private var seenOnboarding: Bool = false
    @AppStorage("requireBiometricsForPower") private var requireBiometricsForPower: Bool = false

    @State private var profiles: [PCProfile] = []
    @State private var selectedProfileId: String?
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isDisplayAsleep = false
    @State private var sleepGraceUntil: Date = .distantPast
    @State private var isWaking = false
    @State private var supportedFeatures: Set<String> = []
    @State private var diagnostics: DiagnosticsInfo?
    @State private var lastAutoHealAt: Date = .distantPast

    // Live audio / display state
    @State private var volume: Double = 50
    @State private var isMuted: Bool = false
    @State private var isAdjustingVolume: Bool = false
    @State private var volumeSyncQuietUntil: Date = .distantPast
    @State private var micVolume: Double = 50
    @State private var isMicMuted: Bool = false
    @State private var isAdjustingMicVolume: Bool = false
    @State private var micSyncQuietUntil: Date = .distantPast
    @State private var brightness: Double = 80

    // Telemetry state
    @State private var cpuLoad: Double = 0
    @State private var ramLoad: Double = 0
    @State private var ramUsedGb: Double = 0
    @State private var ramTotalGb: Double = 0
    @State private var uptimeSeconds: Int = 0
    @State private var hasTelemetry = false

    // Schedule & idle state
    @State private var scheduledAction: ScheduleAction?
    @State private var scheduledRemainingSec: Int = 0
    @State private var idleAction: String?
    @State private var idleMinutes: Int = 10
    @State private var idleStreakSeconds: Int = 0
    @State private var customCommands: [CustomCommandInfo] = []

    // Modals & sheets
    @State private var showOnboarding = false
    @State private var showProfilePicker = false
    @State private var showAddProfile = false
    @State private var showQRScanner = false
    @State private var showTouchpad = false
    @State private var showSendToPC = false
    @State private var showScreenshot = false
    @State private var showRunningApps = false
    @State private var showAudioOutputs = false
    @State private var showAudioInputs = false
    @State private var showThemes = false
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var pendingPowerConfirm: PowerCommand?
    @State private var pendingScheduleAction: ScheduleAction?

    // Toast feedback
    @State private var toastMessage: String?
    @State private var toastIsError = false

    private var theme: AppTheme { AppTheme.theme(for: selectedThemeId) }
    private var foregroundPrimary: Color { theme.backgroundIsLight ? .black : .white }

    private var activeProfile: PCProfile? {
        if let id = selectedProfileId, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    private var buddyHelperProfile: PCProfile? {
        guard let active = activeProfile else { return nil }
        return profiles.first(where: { $0.id != active.id && $0.supportsRelay })
    }

    var body: some View {
        ZStack {
            ThemeBackdrop(theme: theme)

            VStack(spacing: 0) {
                topBar

                if let profile = activeProfile {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            statusBadgeRow(profile: profile)

                            PowerButton(
                                theme: theme,
                                isOnline: connectionStatus == .connected && !isDisplayAsleep,
                                isChecking: connectionStatus == .checking,
                                isWaking: isWaking
                            ) {
                                handleMainPowerButton(profile: profile)
                            }
                            .padding(.vertical, 6)

                            if connectionStatus != .connected, let helper = buddyHelperProfile {
                                buddyWakeBanner(target: profile, helper: helper)
                            }

                            if let diag = diagnostics, let problems = diag.problems, !problems.isEmpty {
                                agentProblemsBanner(problems: problems)
                            }

                            if scheduledAction != nil || idleAction != nil {
                                activeScheduleBanner(profile: profile)
                            }

                            if connectionStatus == .connected && hasTelemetry {
                                TelemetryCardView(
                                    cpuLoad: cpuLoad,
                                    ramLoad: ramLoad,
                                    ramUsedGb: ramUsedGb,
                                    ramTotalGb: ramTotalGb,
                                    uptimeSeconds: uptimeSeconds,
                                    theme: theme
                                )
                            }

                            powerActionGrid(profile: profile)

                            if profile.hasAgentCredentials {
                                VolumeControlView(
                                    volume: $volume,
                                    isMuted: $isMuted,
                                    isAdjusting: $isAdjustingVolume,
                                    theme: theme,
                                    supportsAudioOutputs: supportedFeatures.isEmpty || supportedFeatures.contains("audio-output"),
                                    onCommitVolume: { val in
                                        volumeSyncQuietUntil = Date().addingTimeInterval(2.0)
                                        sendSimple { _ = try await network.setVolume(val, on: profile) }
                                    },
                                    onStep: { up in
                                        sendSimple {
                                            let r = try await network.volumeStep(up: up, on: profile)
                                            applyVolumeFrom(r.data)
                                        }
                                    },
                                    onToggleMute: {
                                        sendSimple {
                                            let r = try await network.toggleMute(on: profile)
                                            applyVolumeFrom(r.data)
                                        }
                                    },
                                    onOpenOutputs: { showAudioOutputs = true }
                                )

                                MicControlView(
                                    micVolume: $micVolume,
                                    isMicMuted: $isMicMuted,
                                    isAdjusting: $isAdjustingMicVolume,
                                    theme: theme,
                                    onCommitMicVolume: { val in
                                        micSyncQuietUntil = Date().addingTimeInterval(2.0)
                                        sendSimple {
                                            let r = try await network.setMicVolume(val, on: profile)
                                            applyMicFrom(r.data, force: true)
                                        }
                                    },
                                    onStep: { up in
                                        micSyncQuietUntil = Date().addingTimeInterval(2.0)
                                        sendSimple {
                                            let r = try await network.micVolumeStep(up: up, on: profile)
                                            applyMicFrom(r.data, force: true)
                                        }
                                    },
                                    onToggleMute: {
                                        micSyncQuietUntil = Date().addingTimeInterval(2.0)
                                        sendSimple {
                                            let r = try await network.toggleMicMute(on: profile)
                                            applyMicFrom(r.data, force: true)
                                        }
                                    },
                                    onOpenInputs: { showAudioInputs = true }
                                )

                                BrightnessControlView(
                                    brightness: $brightness,
                                    theme: theme,
                                    onCommit: { val in
                                        sendSimple { _ = try await network.setBrightness(val, on: profile) }
                                    },
                                    onStep: { up in
                                        sendSimple {
                                            let r = try await network.brightnessStep(up: up, on: profile)
                                            if let b = r.data?.brightness { brightness = Double(b) }
                                        }
                                    }
                                )

                                MediaControlsView(
                                    supportsFullscreen: supportedFeatures.isEmpty || supportedFeatures.contains("fullscreen-key")
                                ) { path in
                                    sendSimple { _ = try await network.mediaAction(path, on: profile) }
                                }

                                if !customCommands.isEmpty {
                                    customCommandsSection(profile: profile)
                                }

                                toolsGrid
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                    .refreshable {
                        await pollStatus(for: profile, healIfNeeded: true)
                    }
                } else {
                    emptyStateView
                }
            }
            .foregroundStyle(foregroundPrimary)

            if let toastMessage {
                VStack {
                    ToastView(message: toastMessage, isError: toastIsError)
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .onAppear {
            loadProfiles()
            if !seenOnboarding && profiles.isEmpty {
                showOnboarding = true
            }
        }
        .onChange(of: incomingQRCode) { qr in
            guard let qr else { return }
            importQRCode(qr)
            incomingQRCode = nil
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, let profile = activeProfile {
                network.invalidateRouteCache(for: profile.id)
                Task { await pollStatus(for: profile, healIfNeeded: true) }
            }
        }
        .task(id: "\(selectedProfileId ?? ""):\(activeProfile?.ip ?? ""):\(activeProfile?.token ?? "")") {
            await runTelemetryAndStatusLoop()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(
                theme: theme,
                onSelectDiscovered: { item in
                    connectDiscoveredPC(item)
                    seenOnboarding = true
                    showOnboarding = false
                },
                onScanQR: {
                    showOnboarding = false
                    seenOnboarding = true
                    showQRScanner = true
                },
                onAddManual: {
                    showOnboarding = false
                    seenOnboarding = true
                    showAddProfile = true
                },
                onDismiss: {
                    seenOnboarding = true
                    showOnboarding = false
                }
            )
        }
        .sheet(isPresented: $showProfilePicker) {
            ProfilePickerSheet(
                profiles: $profiles,
                selectedProfileId: $selectedProfileId,
                onSaveProfiles: persistProfiles,
                onAddManual: {
                    showProfilePicker = false
                    showAddProfile = true
                },
                onScanQR: {
                    showProfilePicker = false
                    showQRScanner = true
                },
                onWakeAll: wakeAllProfiles
            )
        }
        .sheet(isPresented: $showAddProfile) {
            AddProfileSheet { newProfile in
                upsertProfile(newProfile)
                showToast(L10n.tr("toast_profile_added"))
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet { qr in
                importQRCode(qr)
            }
        }
        .sheet(isPresented: $showTouchpad) {
            if let profile = activeProfile {
                TouchpadSheet(profile: profile, theme: theme)
            }
        }
        .sheet(isPresented: $showSendToPC) {
            if let profile = activeProfile {
                SendToPCSheet(profile: profile, theme: theme)
            }
        }
        .sheet(isPresented: $showScreenshot) {
            if let profile = activeProfile {
                PCScreenshotSheet(profile: profile, theme: theme) { updated in
                    upsertProfile(updated)
                }
            }
        }
        .sheet(isPresented: $showRunningApps) {
            if let profile = activeProfile {
                RunningAppsSheet(profile: profile)
            }
        }
        .sheet(isPresented: $showAudioOutputs) {
            if let profile = activeProfile {
                AudioOutputSheet(profile: profile)
            }
        }
        .sheet(isPresented: $showAudioInputs) {
            if let profile = activeProfile {
                AudioInputSheet(profile: profile)
            }
        }
        .sheet(isPresented: $showThemes) {
            ThemePickerSheet(selectedThemeId: $selectedThemeId)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(activeProfile: activeProfile)
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet(activeProfile: activeProfile)
        }
        .sheet(item: $pendingPowerConfirm) { cmd in
            if let profile = activeProfile {
                PowerConfirmSheet(command: cmd, pcName: profile.name) {
                    Task { await executeConfirmedPower(cmd, on: profile) }
                }
            }
        }
        .sheet(item: $pendingScheduleAction) { action in
            if let profile = activeProfile {
                ScheduleActionSheet(
                    action: action,
                    supportsIdleAction: action == .shutdown || action == .sleep,
                    onScheduleMinutes: { minutes in
                        Task { await scheduleAction(action, minutes: minutes, on: profile) }
                    },
                    onIdleFinish: { minutes in
                        Task { await startIdleAction(action.rawValue, minutes: minutes, on: profile) }
                    }
                )
            }
        }
    }

    // MARK: - Top Bar & Sections

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showProfilePicker = true } label: {
                HStack(spacing: 8) {
                    Text(activeProfile?.emoji ?? "🖥️")
                    Text(activeProfile?.name ?? "OpenWakePC")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .opacity(0.7)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(GlassPressButtonStyle())

            Spacer()

            Button { showThemes = true } label: {
                Image(systemName: "paintpalette.fill")
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(GlassPressButtonStyle())

            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(GlassPressButtonStyle())

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(GlassPressButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func statusBadgeRow(profile: PCProfile) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionStatus == .connected ? Color.green : (connectionStatus == .checking ? Color.orange : Color.gray))
                .frame(width: 8, height: 8)
            Text(connectionStatus == .connected ? L10n.tr("status_online") : L10n.tr("status_offline"))
                .font(.caption.weight(.semibold))
            Text("•")
                .opacity(0.5)
            Text(network.lastUsedRoute == .relay ? "E2EE Relay" : "LAN")
                .font(.caption.weight(.medium))
                .opacity(0.8)
            if geofence.isEnabled(for: profile.id) {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.accentColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func buddyWakeBanner(target: PCProfile, helper: PCProfile) -> some View {
        Button {
            Task {
                do {
                    _ = try await network.buddyWake(target: target, via: helper)
                    HapticService.shared.success()
                    showToast(L10n.tr("toast_buddy_wake_sent", helper.name))
                } catch {
                    showToast(error.localizedDescription, isError: true)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .foregroundStyle(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("buddy_wake_title"))
                        .font(.subheadline.weight(.semibold))
                    Text(L10n.tr("buddy_wake_subtitle", helper.name))
                        .font(.caption)
                        .opacity(0.75)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(theme.accentColor)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(GlassPressButtonStyle())
    }

    private func agentProblemsBanner(problems: [AgentProblem]) -> some View {
        Button { showHelp = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L10n.tr("agent_problems_banner", problems.count))
                    .font(.caption.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .opacity(0.6)
            }
            .padding(12)
            .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(GlassPressButtonStyle())
    }

    private func activeScheduleBanner(profile: PCProfile) -> some View {
        HStack {
            Image(systemName: "timer")
                .foregroundStyle(theme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let action = scheduledAction {
                    Text("\(action.rawValue.capitalized) • \(scheduledRemainingSec / 60)m \(scheduledRemainingSec % 60)s")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                if let idle = idleAction {
                    Text("\(L10n.tr("idle_waiting_label")) (\(idle)): \(idleStreakSeconds / 60)/\(idleMinutes)m")
                        .font(.caption)
                        .opacity(0.8)
                }
            }
            Spacer()
            Button(L10n.tr("action_cancel")) {
                Task {
                    _ = try? await network.cancelScheduled(profile: profile)
                    scheduledAction = nil
                    idleAction = nil
                    LiveActivityManager.shared.endScheduledActivity(for: profile.id)
                    showToast(L10n.tr("toast_schedule_cancelled"))
                }
            }
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.red.opacity(0.22), in: Capsule())
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func powerActionGrid(profile: PCProfile) -> some View {
        let items: [(PowerCommand, String, String, ScheduleAction?)] = [
            (.shutdown, "power", L10n.tr("action_shutdown"), .shutdown),
            (.restart, "arrow.clockwise", L10n.tr("action_restart"), .restart),
            (.sleep, "moon.zzz.fill", L10n.tr("action_sleep"), .sleep),
            (.lock, "lock.fill", L10n.tr("action_lock"), nil),
            (.hibernate, "snowflake", L10n.tr("action_hibernate"), nil),
            isDisplayAsleep
                ? (.displayOn, "sun.max.fill", L10n.tr("action_display_on"), nil)
                : (.displayOff, "display.trianglebadge.exclamationmark", L10n.tr("action_display_off"), nil),
        ]

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(items, id: \.0) { cmd, icon, title, schedulable in
                Button {
                    triggerPowerCommand(cmd, on: profile)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.title3.weight(.semibold))
                        if !buttonIconsOnly {
                            Text(title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(GlassPressButtonStyle())
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        if let schedulable {
                            HapticService.shared.medium()
                            pendingScheduleAction = schedulable
                        }
                    }
                )
            }
        }
    }

    private func customCommandsSection(profile: PCProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("section_custom_commands"))
                .font(.caption.weight(.semibold))
                .opacity(0.75)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(customCommands) { cmd in
                        Button {
                            sendSimple {
                                _ = try await network.runCustomCommand(id: cmd.id, on: profile)
                                customCommands = try await network.fetchCustomCommands(profile: profile)
                                showToast(cmd.name)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(cmd.running == true ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 7, height: 7)
                                Image(systemName: cmd.icon ?? "terminal")
                                Text(cmd.name)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(GlassPressButtonStyle())
                        .contextMenu {
                            if cmd.closable == true && cmd.running == true {
                                Button(role: .destructive) {
                                    sendSimple {
                                        _ = try await network.closeCustomCommand(id: cmd.id, on: profile)
                                        customCommands = try await network.fetchCustomCommands(profile: profile)
                                    }
                                } label: {
                                    Label(L10n.tr("action_close"), systemImage: "xmark.circle")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var toolsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            toolTile(icon: "hand.point.up.left.fill", title: L10n.tr("tool_touchpad")) { showTouchpad = true }
            toolTile(icon: "rectangle.dashed.and.paperclip", title: L10n.tr("tool_screenshot")) { showScreenshot = true }
            toolTile(icon: "paperplane.fill", title: L10n.tr("tool_send_to_pc")) { showSendToPC = true }
            toolTile(icon: "app.badge", title: L10n.tr("tool_running_apps")) { showRunningApps = true }
        }
    }

    private func toolTile(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticService.shared.light()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(theme.accentColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(GlassPressButtonStyle())
    }

    private var emptyStateView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(theme.accentColor.opacity(0.16))
                        .frame(width: 92, height: 92)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(theme.accentColor)
                }
                .padding(.top, 36)

                VStack(spacing: 8) {
                    Text(L10n.tr("empty_title"))
                        .font(.title2.bold())
                    Text(L10n.tr("empty_subtitle"))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .opacity(0.75)
                        .padding(.horizontal, 28)
                }

                VStack(spacing: 10) {
                    Button {
                        HapticService.shared.selection()
                        emptyDiscovery.startScan()
                    } label: {
                        HStack {
                            if emptyDiscovery.isScanning {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "wifi.circle.fill")
                            }
                            Text(emptyDiscovery.isScanning ? L10n.tr("onboarding_searching_lan") : L10n.tr("action_find_lan"))
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(GlassPressButtonStyle())

                    HStack(spacing: 10) {
                        Button { showQRScanner = true } label: {
                            Label(L10n.tr("action_scan_qr"), systemImage: "qrcode.viewfinder")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(GlassPressButtonStyle())

                        Button { showAddProfile = true } label: {
                            Label(L10n.tr("action_add_manual"), systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(GlassPressButtonStyle())
                    }
                }
                .padding(.horizontal, 24)

                if !emptyDiscovery.discovered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("discovery_section"))
                            .font(.caption.weight(.semibold))
                            .opacity(0.7)

                        ForEach(emptyDiscovery.discovered) { item in
                            Button {
                                connectDiscoveredPC(item)
                                emptyDiscovery.stopScan()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(item.deviceType == .mac ? "💻" : "🖥️")
                                        .font(.title2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.subheadline.weight(.semibold))
                                        Text("\(item.ip) • \(item.mac)")
                                            .font(.caption2)
                                            .opacity(0.7)
                                    }
                                    Spacer()
                                    Text(L10n.tr("onboarding_connect_btn"))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(theme.gradient, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                                .padding(12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(GlassPressButtonStyle())
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 32)
        }
    }

    private func connectDiscoveredPC(_ item: DiscoveredPC) {
        let profile = PCProfile(
            name: item.name,
            emoji: item.deviceType == .mac ? "💻" : "🖥️",
            mac: item.mac,
            ip: item.ip,
            broadcast: item.broadcast,
            wolPort: item.wolPort,
            apiPort: item.apiPort,
            token: item.token ?? "",
            deviceType: item.deviceType,
            deviceId: item.deviceId
        )
        NetworkService.shared.invalidateRouteCache()
        upsertProfile(profile)
        HapticService.shared.success()
        showToast(L10n.tr("toast_profile_added"))
    }

    // MARK: - Actions & Polling

    private func loadProfiles() {
        profiles = SharedStorage.shared.loadProfiles()
        selectedProfileId = SharedStorage.shared.selectedProfileId ?? profiles.first?.id
    }

    private func persistProfiles(_ updated: [PCProfile]) {
        profiles = updated
        SharedStorage.shared.saveProfiles(updated)
        SharedStorage.shared.selectedProfileId = selectedProfileId
        WatchSyncService.shared.pushProfilesToWatch(updated)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func upsertProfile(_ profile: PCProfile) {
        var updated = profiles
        if let idx = updated.firstIndex(where: { $0.id == profile.id || $0.mac.uppercased() == profile.mac.uppercased() }) {
            updated[idx] = profile
        } else {
            updated.append(profile)
        }
        selectedProfileId = profile.id
        persistProfiles(updated)
    }

    private func importQRCode(_ qr: PCQRCode) {
        let profile = PCProfile(
            name: qr.deviceType == .mac ? "Mac" : "Windows PC",
            emoji: qr.deviceType == .mac ? "💻" : "🖥️",
            mac: qr.mac,
            ip: qr.ip,
            broadcast: qr.broadcast,
            wolPort: qr.wolPort,
            apiPort: qr.apiPort,
            token: qr.token,
            deviceType: qr.deviceType,
            deviceId: qr.deviceId
        )
        if let relay = qr.relayURL, !relay.isEmpty {
            SharedStorage.shared.customRelayURL = relay
            SharedStorage.shared.useCustomRelay = true
        } else {
            SharedStorage.shared.customRelayURL = ""
            SharedStorage.shared.useCustomRelay = false
        }
        NetworkService.shared.invalidateRouteCache()
        upsertProfile(profile)
        HapticService.shared.success()
        showToast(L10n.tr("toast_qr_imported"))
    }

    private func handleMainPowerButton(profile: PCProfile) {
        HapticService.shared.heavy()
        SoundService.shared.playTap()
        if connectionStatus == .connected && !isDisplayAsleep {
            triggerPowerCommand(.shutdown, on: profile)
        } else {
            Task { await wakeProfile(profile) }
        }
    }

    private func wakeProfile(_ profile: PCProfile) async {
        isWaking = true
        sleepGraceUntil = .distantPast
        network.invalidateRouteCache(for: profile.id)
        LiveActivityManager.shared.startWakeActivity(for: profile)
        defer { isWaking = false }

        var wolError: Error?
        do {
            try await network.wake(profile)
        } catch {
            wolError = error
        }

        if wolError != nil && !profile.supportsRelay {
            LiveActivityManager.shared.endWakeActivity(for: profile.id)
            HapticService.shared.error()
            showToast(wolError!.localizedDescription, isError: true)
            return
        }

        SoundService.shared.playSuccess()
        showToast(L10n.tr("toast_wol_sent", profile.name))
        LiveActivityManager.shared.updateWakeActivity(
            for: profile.id,
            phase: .waking,
            message: L10n.tr("live_waking_waiting")
        )

        let delaysNs: [UInt64] = [
            400_000_000,
            1_200_000_000,
            2_000_000_000,
        ]
        for attempt in 0..<14 {
            let delay = attempt < delaysNs.count ? delaysNs[attempt] : 2_500_000_000
            try? await Task.sleep(nanoseconds: delay)

            var current = activeProfile ?? profile
            if attempt == 2 || attempt == 5 {
                try? await network.wake(current)
            }
            if attempt == 3 && network.interfaces.wifi {
                if let healed = await LANAddressHealer.heal(profile: current) {
                    current.ip = healed.ip
                    current.apiPort = healed.port
                    current.broadcast = healed.broadcast
                    if let healedMAC = healed.mac, PCQRCode.isValidMAC(healedMAC) {
                        current.mac = healedMAC.uppercased()
                    }
                    if let healedToken = healed.token, !healedToken.isEmpty {
                        current.token = healedToken
                    }
                    upsertProfile(current)
                    network.invalidateRouteCache(for: current.id)
                }
            }

            let resp: ApiResponse? = if current.hasAgentCredentials {
                try? await network.executePower(.displayOn, on: current)
            } else {
                try? await network.fetchStatus(profile: current)
            }

            if let resp, resp.success {
                isDisplayAsleep = false
                connectionStatus = .connected
                await pollStatus(for: current, healIfNeeded: false)
                LiveActivityManager.shared.updateWakeActivity(
                    for: current.id,
                    phase: .awake,
                    message: L10n.tr("notif_pc_awake_title")
                )
                LiveActivityManager.shared.notifyPCAwake(current)
                HapticService.shared.success()
                return
            }
        }

        LiveActivityManager.shared.updateWakeActivity(
            for: profile.id,
            phase: .timeout,
            message: L10n.tr("live_waking_timeout")
        )
    }

    private func wakeAllProfiles() {
        Task {
            for p in profiles {
                try? await network.wake(p)
            }
            HapticService.shared.success()
            showToast(L10n.tr("toast_wake_all_sent"))
        }
    }

    private func triggerPowerCommand(_ cmd: PowerCommand, on profile: PCProfile) {
        HapticService.shared.medium()
        if cmd.isDestructive {
            pendingPowerConfirm = cmd
        } else {
            Task { await executeConfirmedPower(cmd, on: profile) }
        }
    }

    private func executeConfirmedPower(_ cmd: PowerCommand, on profile: PCProfile) async {
        if cmd.isDestructive && requireBiometricsForPower {
            let ok = await BiometricAuthService.authenticate(reason: L10n.tr("biometrics_reason"))
            guard ok else { return }
        }
        do {
            _ = try await network.executePower(cmd, on: profile)
            HapticService.shared.success()
            showToast(L10n.tr("toast_command_sent"))
            switch cmd {
            case .sleep, .hibernate:
                connectionStatus = .failed
                isDisplayAsleep = true
                sleepGraceUntil = Date().addingTimeInterval(10.0)
                SharedStorage.shared.setOnline(false, forProfileId: profile.id)
            case .shutdown:
                connectionStatus = .failed
                isDisplayAsleep = false
                SharedStorage.shared.setOnline(false, forProfileId: profile.id)
            case .displayOff:
                isDisplayAsleep = true
            case .displayOn:
                isDisplayAsleep = false
                sleepGraceUntil = .distantPast
            default:
                break
            }
        } catch {
            HapticService.shared.error()
            showToast(error.localizedDescription, isError: true)
        }
    }

    private func scheduleAction(_ action: ScheduleAction, minutes: Int, on profile: PCProfile) async {
        do {
            let resp = try await network.schedulePower(action, minutes: minutes, on: profile)
            applyScheduleFrom(resp.data)
            let targetDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
            LiveActivityManager.shared.startScheduledActivity(for: profile, action: action, targetDate: targetDate)
            HapticService.shared.success()
            showToast(L10n.tr("toast_schedule_started", minutes))
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    private func startIdleAction(_ action: String, minutes: Int, on profile: PCProfile) async {
        do {
            let resp = try await network.setIdleAction(action, minutes: minutes, on: profile)
            applyScheduleFrom(resp.data)
            HapticService.shared.success()
            showToast(L10n.tr("toast_idle_started"))
        } catch {
            showToast(error.localizedDescription, isError: true)
        }
    }

    private func sendSimple(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func runTelemetryAndStatusLoop() async {
        guard let profile = activeProfile else { return }
        await pollStatus(for: profile, healIfNeeded: true)

        var tickCount = 0
        var consecutiveTelemetryFailures = 0
        while !Task.isCancelled {
            let intervalNs: UInt64 = (network.lastUsedRoute == .relay) ? 5_000_000_000 : 2_000_000_000
            try? await Task.sleep(nanoseconds: intervalNs)
            guard let current = activeProfile else { break }
            if showScreenshot || Date() < sleepGraceUntil {
                continue
            }
            tickCount += 1

            if connectionStatus == .connected && current.hasAgentCredentials {
                if let tel = try? await network.fetchTelemetry(profile: current), let d = tel.data {
                    consecutiveTelemetryFailures = 0
                    cpuLoad = d.cpuLoad ?? cpuLoad
                    ramLoad = d.ramLoad ?? ramLoad
                    ramUsedGb = d.ramUsedGb ?? ramUsedGb
                    ramTotalGb = d.ramTotalGb ?? ramTotalGb
                    uptimeSeconds = d.uptimeSeconds ?? uptimeSeconds
                    hasTelemetry = true
                } else {
                    consecutiveTelemetryFailures += 1
                    if consecutiveTelemetryFailures >= 2 {
                        consecutiveTelemetryFailures = 0
                        if network.lastUsedRoute == .lan {
                            network.invalidateRouteCache(for: current.id)
                        }
                        await pollStatus(for: current, healIfNeeded: true)
                    }
                }
                if tickCount % 5 == 0 || (network.lastUsedRoute == .relay && network.interfaces.wifi && tickCount % 3 == 0) {
                    await pollStatus(for: current, healIfNeeded: false)
                }
            } else if tickCount % 3 == 0 {
                await pollStatus(for: current, healIfNeeded: true)
            }
        }
    }

    private func pollStatus(for profile: PCProfile, healIfNeeded: Bool) async {
        if connectionStatus == .unknown {
            connectionStatus = .checking
        }
        do {
            if profile.ip.contains(":") {
                throw NetworkError.lanUnreachable
            }
            let resp = try await network.fetchStatus(profile: profile)
            var updated = profile
            var needsUpdate = false
            var ipChanged = false
            if updated.token.isEmpty, let discoveredToken = resp.data?.token, !discoveredToken.isEmpty {
                updated.token = discoveredToken
                needsUpdate = true
            }
            if let discoveredIP = resp.data?.ip,
               PCDiscoveryService.isValidIPv4(discoveredIP),
               updated.ip != discoveredIP {
                updated.ip = discoveredIP
                updated.broadcast = (resp.data?.bcast?.isEmpty == false)
                    ? resp.data!.bcast!
                    : PCProfile.deriveBroadcast(from: discoveredIP)
                needsUpdate = true
                ipChanged = true
            }
            if let discoveredMAC = resp.data?.mac,
               PCQRCode.isValidMAC(discoveredMAC),
               updated.mac.uppercased() != discoveredMAC.uppercased() {
                updated.mac = discoveredMAC.uppercased()
                needsUpdate = true
            }
            if (updated.deviceId ?? "").isEmpty, let discoveredDeviceId = resp.data?.deviceId, !discoveredDeviceId.isEmpty {
                updated.deviceId = discoveredDeviceId
                needsUpdate = true
            }
            if needsUpdate {
                upsertProfile(updated)
                if ipChanged {
                    network.invalidateRouteCache(for: updated.id)
                }
            }

            connectionStatus = resp.success ? .connected : .failed
            isDisplayAsleep = resp.data?.displayAsleep ?? false
            supportedFeatures = resp.resolvedFeatures
            diagnostics = resp.diagnostics
            applyVolumeFrom(resp.data)
            applyMicFrom(resp.data)
            if let b = resp.data?.brightness { brightness = Double(b) }
            applyScheduleFrom(resp.data)
            if updated.hasAgentCredentials, resp.resolvedFeatures.contains("custom-commands"), customCommands.isEmpty || healIfNeeded {
                if let cmds = try? await network.fetchCustomCommands(profile: updated) {
                    customCommands = cmds
                }
            }
        } catch {
            connectionStatus = .failed
            SharedStorage.shared.setOnline(false, forProfileId: profile.id)
            let canAutoHealNow = Date().timeIntervalSince(lastAutoHealAt) >= 12.0
                || profile.ip.contains(":")
                || !profile.hasAgentCredentials
            if healIfNeeded && network.interfaces.wifi && canAutoHealNow {
                lastAutoHealAt = Date()
                if let healed = await LANAddressHealer.heal(profile: profile) {
                    var updated = profile
                    updated.ip = healed.ip
                    updated.apiPort = healed.port
                    updated.broadcast = healed.broadcast
                    if let healedMAC = healed.mac, PCQRCode.isValidMAC(healedMAC) {
                        updated.mac = healedMAC.uppercased()
                    }
                    if let healedToken = healed.token, !healedToken.isEmpty {
                        updated.token = healedToken
                    }
                    if (updated.deviceId ?? "").isEmpty, let healedDeviceId = healed.deviceId, !healedDeviceId.isEmpty {
                        updated.deviceId = healedDeviceId
                    }
                    upsertProfile(updated)
                    network.invalidateRouteCache(for: updated.id)
                    await pollStatus(for: updated, healIfNeeded: false)
                }
            }
        }
    }

    private func applyVolumeFrom(_ data: ResponseData?) {
        guard let data, !isAdjustingVolume, Date() > volumeSyncQuietUntil else { return }
        if let v = data.volume { volume = Double(v) }
        if let m = data.muted { isMuted = m }
    }

    private func applyMicFrom(_ data: ResponseData?, force: Bool = false) {
        guard let data else { return }
        if !force {
            guard !isAdjustingMicVolume, Date() > micSyncQuietUntil else { return }
        }
        if let mv = data.micVolume { micVolume = Double(mv) }
        if let mm = data.micMuted { isMicMuted = mm }
    }

    private func applyScheduleFrom(_ data: ResponseData?) {
        guard let data else { return }
        if data.hasScheduled == true, let raw = data.action, let act = ScheduleAction(rawValue: raw) {
            scheduledAction = act
            scheduledRemainingSec = data.remainingSeconds ?? 0
        } else {
            scheduledAction = nil
            scheduledRemainingSec = 0
        }
        idleAction = data.idleAction
        idleMinutes = data.idleMinutes ?? 10
        idleStreakSeconds = data.idleStreakSeconds ?? 0
    }

    private func showToast(_ message: String, isError: Bool = false) {
        withAnimation(.spring(response: 0.3)) {
            toastMessage = message
            toastIsError = isError
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(.easeOut) {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }
}
