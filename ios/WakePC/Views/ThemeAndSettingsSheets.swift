import SwiftUI

// MARK: - Theme Picker Sheet (All 21 Themes Free)

struct ThemePickerSheet: View {
    @Binding var selectedThemeId: String
    @AppStorage("appearanceOverride") private var appearanceOverride: String = "system"
    @AppStorage("buttonIconsOnly") private var buttonIconsOnly: Bool = false
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Picker(L10n.tr("appearance_mode"), selection: $appearanceOverride) {
                        Text(L10n.tr("appearance_system")).tag("system")
                        Text(L10n.tr("appearance_light")).tag("light")
                        Text(L10n.tr("appearance_dark")).tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    Toggle(L10n.tr("button_icons_only"), isOn: $buttonIconsOnly)
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(AppTheme.all) { theme in
                            Button {
                                HapticService.shared.selection()
                                selectedThemeId = theme.id
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(theme.gradient)
                                            .frame(height: 68)
                                        Image(systemName: "power")
                                            .font(.title3.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(selectedThemeId == theme.id ? Color.primary : Color.clear, lineWidth: 2.5)
                                    }
                                    Text(theme.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(GlassPressButtonStyle())
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle(L10n.tr("themes_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Settings Sheet (Custom Self-Hosted Relay URL, Face ID, Push, Idle Notify, Sound/Haptics)

struct SettingsSheet: View {
    let activeProfile: PCProfile?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("requireBiometricsForPower") private var requireBiometricsForPower: Bool = false
    @AppStorage("pcPresencePushEnabled") private var pcPresencePushEnabled: Bool = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true
    @AppStorage("soundEnabled") private var soundEnabled: Bool = true

    @State private var useCustomRelay: Bool = SharedStorage.shared.useCustomRelay
    @State private var customRelayURL: String = SharedStorage.shared.customRelayURL
    @State private var relayDiscoveryURL: String = SharedStorage.shared.relayDiscoveryURL
    @State private var idleNotifyHours: Int = 0
    @State private var saveNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.tr("settings_relay_mode_label"), selection: $useCustomRelay) {
                        Text(L10n.tr("settings_relay_mode_cloud")).tag(false)
                        Text(L10n.tr("settings_relay_mode_custom")).tag(true)
                    }
                    .onChange(of: useCustomRelay) { custom in
                        SharedStorage.shared.useCustomRelay = custom
                        NetworkService.shared.invalidateRouteCache()
                    }

                    if !useCustomRelay {
                        Label(L10n.tr("settings_relay_cloud_active"), systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    } else {
                        TextField("https://relay.example.com", text: $customRelayURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField(L10n.tr("settings_relay_discovery_placeholder"), text: $relayDiscoveryURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(L10n.tr("settings_save_relay")) {
                            SharedStorage.shared.customRelayURL = customRelayURL
                            SharedStorage.shared.relayDiscoveryURL = relayDiscoveryURL
                            SharedStorage.shared.useCustomRelay = !customRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            NetworkService.shared.invalidateRouteCache()
                            HapticService.shared.success()
                            saveNotice = L10n.tr("toast_relay_saved")
                        }
                    }
                } header: {
                    Text(L10n.tr("settings_relay_section"))
                } footer: {
                    Text(useCustomRelay ? L10n.tr("settings_relay_footer") : L10n.tr("settings_relay_cloud_footer"))
                }

                Section(L10n.tr("settings_security_section")) {
                    Toggle(L10n.tr("settings_biometrics"), isOn: $requireBiometricsForPower)
                }

                Section(L10n.tr("settings_notifications_section")) {
                    Toggle(L10n.tr("settings_presence_push"), isOn: $pcPresencePushEnabled)
                        .onChange(of: pcPresencePushEnabled) { enabled in
                            Task {
                                if enabled {
                                    await PushService.shared.requestPermissionsAndRegister()
                                }
                                await PushService.shared.syncAllProfilesIfEnabled()
                            }
                        }

                    if let profile = activeProfile, profile.hasAgentCredentials {
                        Picker(L10n.tr("settings_idle_notify"), selection: $idleNotifyHours) {
                            Text(L10n.tr("option_off")).tag(0)
                            Text("1h").tag(1)
                            Text("2h").tag(2)
                            Text("4h").tag(4)
                        }
                        .onChange(of: idleNotifyHours) { hrs in
                            Task {
                                _ = try? await NetworkService.shared.setIdleNotify(hours: hrs, on: profile)
                            }
                        }
                    }
                }

                Section(L10n.tr("settings_feedback_section")) {
                    Toggle(L10n.tr("settings_haptics"), isOn: $hapticsEnabled)
                    Toggle(L10n.tr("settings_sounds"), isOn: $soundEnabled)
                }

                Section {
                    Link(destination: URL(string: "https://razmochaev.com")!) {
                        Label(L10n.tr("settings_website"), systemImage: "globe")
                    }
                    Link(destination: URL(string: "https://github.com/razmochaev/OpenWakePC")!) {
                        Label(L10n.tr("settings_github"), systemImage: "arrow.down.circle")
                    }
                } header: {
                    Text(L10n.tr("settings_links_section"))
                } footer: {
                    Text("OpenWakePC • © 2026 razmochaev")
                }

                if let saveNotice {
                    Section {
                        Text(saveNotice).foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle(L10n.tr("settings_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Help & Built-in Diagnostics Sheet

private struct HelpGuideTopic: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let steps: [String]
    let tip: String
}

struct HelpSheet: View {
    let activeProfile: PCProfile?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var diagnostics = HelpDiagnostics()
    @ObservedObject private var network = NetworkService.shared

    var body: some View {
        NavigationStack {
            List {
                diagnosticsSection

                Section(L10n.tr("help_section_setup")) {
                    ForEach(setupTopics) { topic in
                        NavigationLink {
                            HelpGuideDetailView(topic: topic)
                        } label: {
                            HelpRowView(topic: topic)
                        }
                    }
                }

                Section(L10n.tr("help_section_features")) {
                    ForEach(featureTopics) { topic in
                        NavigationLink {
                            HelpGuideDetailView(topic: topic)
                        } label: {
                            HelpRowView(topic: topic)
                        }
                    }
                }

                Section(L10n.tr("help_section_troubleshooting")) {
                    ForEach(troubleshootingTopics) { topic in
                        NavigationLink {
                            HelpGuideDetailView(topic: topic)
                        } label: {
                            HelpRowView(topic: topic)
                        }
                    }
                }
            }
            .navigationTitle(L10n.tr("help_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section(L10n.tr("help_diagnostics_section")) {
            if let profile = activeProfile {
                HStack(spacing: 12) {
                    Text(profile.emoji)
                        .font(.title2)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(profile.ip):\(profile.apiPort) • \(profile.mac)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(network.lastUsedRoute == .relay ? "E2EE Relay" : "LAN")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((network.lastUsedRoute == .relay ? Color.blue : Color.green).opacity(0.15), in: Capsule())
                        .foregroundStyle(network.lastUsedRoute == .relay ? .blue : .green)
                }
                .padding(.vertical, 2)

                Button {
                    Task { await diagnostics.run(for: profile) }
                } label: {
                    HStack {
                        Label(L10n.tr("help_run_diagnostics"), systemImage: "stethoscope")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if diagnostics.isRunning {
                            ProgressView()
                        }
                    }
                }

                ForEach(diagnostics.steps) { step in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: step.status))
                            .foregroundStyle(color(for: step.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.subheadline.weight(.semibold))
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Label(L10n.tr("help_no_profile_hint"), systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var setupTopics: [HelpGuideTopic] {
        [
            HelpGuideTopic(
                id: "mac",
                icon: "laptopcomputer",
                tint: .indigo,
                title: L10n.tr("guide_mac_title"),
                subtitle: L10n.tr("guide_mac_subtitle"),
                steps: [
                    L10n.tr("guide_mac_step1"),
                    L10n.tr("guide_mac_step2"),
                    L10n.tr("guide_mac_step3"),
                    L10n.tr("guide_mac_step4"),
                ],
                tip: L10n.tr("guide_mac_tip")
            ),
            HelpGuideTopic(
                id: "wol",
                icon: "bolt.shield.fill",
                tint: .orange,
                title: L10n.tr("guide_wol_title"),
                subtitle: L10n.tr("guide_wol_subtitle"),
                steps: [
                    L10n.tr("guide_wol_step1"),
                    L10n.tr("guide_wol_step2"),
                    L10n.tr("guide_wol_step3"),
                    L10n.tr("guide_wol_step4"),
                    L10n.tr("guide_wol_step5"),
                ],
                tip: L10n.tr("guide_wol_tip")
            ),
        ]
    }

    private var featureTopics: [HelpGuideTopic] {
        [
            HelpGuideTopic(
                id: "relay",
                icon: "lock.shield.fill",
                tint: .green,
                title: L10n.tr("guide_relay_title"),
                subtitle: L10n.tr("guide_relay_subtitle"),
                steps: [
                    L10n.tr("guide_relay_step1"),
                    L10n.tr("guide_relay_step2"),
                    L10n.tr("guide_relay_step3"),
                ],
                tip: L10n.tr("guide_relay_tip")
            ),
            HelpGuideTopic(
                id: "buddy",
                icon: "point.3.connected.trianglepath.dotted",
                tint: .teal,
                title: L10n.tr("guide_buddy_title"),
                subtitle: L10n.tr("guide_buddy_subtitle"),
                steps: [
                    L10n.tr("guide_buddy_step1"),
                    L10n.tr("guide_buddy_step2"),
                    L10n.tr("guide_buddy_step3"),
                ],
                tip: L10n.tr("guide_buddy_tip")
            ),
            HelpGuideTopic(
                id: "controls",
                icon: "slider.horizontal.3",
                tint: .purple,
                title: L10n.tr("guide_controls_title"),
                subtitle: L10n.tr("guide_controls_subtitle"),
                steps: [
                    L10n.tr("guide_controls_step1"),
                    L10n.tr("guide_controls_step2"),
                    L10n.tr("guide_controls_step3"),
                    L10n.tr("guide_controls_step4"),
                    L10n.tr("guide_controls_step5"),
                ],
                tip: L10n.tr("guide_controls_tip")
            ),
            HelpGuideTopic(
                id: "siri",
                icon: "waveform.and.mic",
                tint: .pink,
                title: L10n.tr("guide_siri_title"),
                subtitle: L10n.tr("guide_siri_subtitle"),
                steps: [
                    L10n.tr("guide_siri_step1"),
                    L10n.tr("guide_siri_step2"),
                    L10n.tr("guide_siri_step3"),
                    L10n.tr("guide_siri_step4"),
                ],
                tip: L10n.tr("guide_siri_tip")
            ),
        ]
    }

    private var troubleshootingTopics: [HelpGuideTopic] {
        [
            HelpGuideTopic(
                id: "faq",
                icon: "wrench.and.screwdriver.fill",
                tint: .red,
                title: L10n.tr("guide_faq_title"),
                subtitle: L10n.tr("guide_faq_subtitle"),
                steps: [
                    L10n.tr("guide_faq_step1"),
                    L10n.tr("guide_faq_step2"),
                    L10n.tr("guide_faq_step3"),
                    L10n.tr("guide_faq_step4"),
                    L10n.tr("guide_faq_step5"),
                ],
                tip: L10n.tr("guide_faq_tip")
            ),
        ]
    }

    private func icon(for status: DiagnosticStep.Status) -> String {
        switch status {
        case .pending: return "clock"
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for status: DiagnosticStep.Status) -> Color {
        switch status {
        case .pending: return .gray
        case .ok: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}

private struct HelpRowView: View {
    let topic: HelpGuideTopic

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: topic.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(topic.tint)
                .frame(width: 34, height: 34)
                .background(topic.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .font(.subheadline.weight(.semibold))
                Text(topic.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct HelpGuideDetailView: View {
    let topic: HelpGuideTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: topic.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(topic.tint)
                        .frame(width: 52, height: 52)
                        .background(topic.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title)
                            .font(.headline)
                        Text(topic.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(topic.tint, in: Circle())

                        Text(step)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lightbulb.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("help_tip_label"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                        Text(topic.tip)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
