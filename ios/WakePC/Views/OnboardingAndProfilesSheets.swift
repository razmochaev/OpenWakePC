import SwiftUI

struct OnboardingView: View {
    let theme: AppTheme
    let onSelectDiscovered: (DiscoveredPC) -> Void
    let onScanQR: () -> Void
    let onAddManual: () -> Void
    let onDismiss: () -> Void

    @StateObject private var discovery = PCDiscoveryService()
    @State private var pulse = false

    private var fg: Color { theme.backgroundIsLight ? .black : .white }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemeBackdrop(theme: theme)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .stroke(theme.accentColor.opacity(0.4), lineWidth: 2)
                                .frame(width: 104, height: 104)
                                .scaleEffect(pulse ? 1.12 : 0.96)
                                .opacity(pulse ? 0.25 : 0.75)

                            Circle()
                                .fill(theme.gradient)
                                .frame(width: 82, height: 82)
                                .shadow(color: theme.accentColor.opacity(0.5), radius: 18, y: 6)

                            Image(systemName: "power")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 10)

                        VStack(spacing: 8) {
                            Text(L10n.tr("onboarding_title"))
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                            Text(L10n.tr("onboarding_subtitle"))
                                .font(.subheadline)
                                .opacity(0.75)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            featureRow("bolt.fill", L10n.tr("onboarding_feat_wol"))
                            featureRow("lock.shield.fill", L10n.tr("onboarding_feat_e2ee"))
                            featureRow("sparkles", L10n.tr("onboarding_feat_free"))
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                        if !discovery.discovered.isEmpty || discovery.isScanning {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(L10n.tr("discovery_section"))
                                        .font(.caption.weight(.semibold))
                                        .opacity(0.75)
                                    Spacer()
                                    if discovery.isScanning {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }

                                ForEach(discovery.discovered) { item in
                                    Button {
                                        HapticService.shared.success()
                                        onSelectDiscovered(item)
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
                        }

                        VStack(spacing: 10) {
                            Button {
                                HapticService.shared.selection()
                                discovery.startScan()
                            } label: {
                                HStack {
                                    Image(systemName: "wifi.circle.fill")
                                    Text(discovery.isScanning ? L10n.tr("onboarding_searching_lan") : L10n.tr("action_find_lan"))
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(GlassPressButtonStyle())

                            HStack(spacing: 10) {
                                Button(action: onScanQR) {
                                    Label(L10n.tr("action_scan_qr"), systemImage: "qrcode.viewfinder")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(GlassPressButtonStyle())

                                Button(action: onAddManual) {
                                    Label(L10n.tr("action_add_manual"), systemImage: "keyboard")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(GlassPressButtonStyle())
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .foregroundStyle(fg)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("action_skip"), action: onDismiss)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    pulse = true
                }
                discovery.startScan()
            }
            .onDisappear {
                discovery.stopScan()
            }
        }
    }

    private func featureRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accentColor)
                .frame(width: 28, height: 28)
                .background(theme.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text)
                .font(.subheadline)
        }
    }
}

struct ProfilePickerSheet: View {
    @Binding var profiles: [PCProfile]
    @Binding var selectedProfileId: String?
    let onSaveProfiles: ([PCProfile]) -> Void
    let onAddManual: () -> Void
    let onScanQR: () -> Void
    let onWakeAll: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var geofence = GeofenceWakeService.shared
    @State private var editingProfile: PCProfile?

    var body: some View {
        NavigationStack {
            List {
                if profiles.count >= 2 {
                    Section {
                        Button {
                            onWakeAll()
                            dismiss()
                        } label: {
                            Label(L10n.tr("action_wake_all"), systemImage: "bolt.horizontal.fill")
                                .font(.headline)
                        }
                    }
                }

                Section(L10n.tr("section_computers")) {
                    ForEach(profiles) { profile in
                        HStack(spacing: 12) {
                            Text(profile.emoji)
                                .font(.title2)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(profile.name)
                                        .font(.headline)
                                    if profile.id == selectedProfileId {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption)
                                    }
                                }
                                Text("\(profile.deviceType.displayName) • \(profile.ip) • \(profile.mac)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                editingProfile = profile
                            } label: {
                                Image(systemName: "pencil.circle")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedProfileId = profile.id
                            SharedStorage.shared.selectedProfileId = profile.id
                            dismiss()
                        }
                    }
                    .onDelete { offsets in
                        var updated = profiles
                        for idx in offsets {
                            let id = updated[idx].id
                            KeychainTokenStore.delete(forProfileId: id)
                            geofence.disable(for: id)
                        }
                        updated.remove(atOffsets: offsets)
                        if !updated.contains(where: { $0.id == selectedProfileId }) {
                            selectedProfileId = updated.first?.id
                        }
                        onSaveProfiles(updated)
                    }
                }

                Section {
                    Button(action: onScanQR) {
                        Label(L10n.tr("action_scan_qr"), systemImage: "qrcode.viewfinder")
                    }
                    Button(action: onAddManual) {
                        Label(L10n.tr("action_add_manual"), systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle(L10n.tr("profiles_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
            }
            .sheet(item: $editingProfile) { profile in
                AddProfileSheet(existing: profile) { edited in
                    var updated = profiles
                    if let idx = updated.firstIndex(where: { $0.id == edited.id }) {
                        updated[idx] = edited
                        onSaveProfiles(updated)
                    }
                }
            }
        }
    }
}

struct AddProfileSheet: View {
    let existing: PCProfile?
    let onSave: (PCProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = PCDiscoveryService()
    @StateObject private var geofence = GeofenceWakeService.shared

    @State private var name: String = ""
    @State private var emoji: String = "🖥️"
    @State private var mac: String = ""
    @State private var ip: String = ""
    @State private var broadcast: String = ""
    @State private var wolPort: String = "9"
    @State private var apiPort: String = "8765"
    @State private var token: String = ""
    @State private var deviceId: String = ""
    @State private var deviceType: DeviceType = .windows
    @State private var geofenceEnabled: Bool = false
    @State private var validationError: String?

    private let emojiChoices = ["🖥️", "💻", "🎮", "🍎", "⚙️", "🏠", "💼", "🚀"]

    init(existing: PCProfile? = nil, onSave: @escaping (PCProfile) -> Void) {
        self.existing = existing
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                if existing == nil {
                    Section {
                        Button {
                            discovery.startScan()
                        } label: {
                            HStack {
                                Label(L10n.tr("discovery_scan_lan"), systemImage: "wifi.circle")
                                Spacer()
                                if discovery.isScanning {
                                    ProgressView()
                                }
                            }
                        }

                        ForEach(discovery.discovered) { item in
                            Button {
                                name = item.name
                                ip = item.ip
                                mac = item.mac
                                broadcast = item.broadcast
                                apiPort = String(item.apiPort)
                                wolPort = String(item.wolPort)
                                deviceType = item.deviceType
                                deviceId = item.deviceId ?? ""
                                token = item.token ?? token
                                emoji = item.deviceType == .mac ? "💻" : "🖥️"
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name).font(.headline)
                                    Text("\(item.ip) • \(item.mac)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text(L10n.tr("discovery_section"))
                    }
                }

                Section(L10n.tr("profile_basic_section")) {
                    TextField(L10n.tr("profile_name"), text: $name)

                    Picker(L10n.tr("profile_device_type"), selection: $deviceType) {
                        ForEach(DeviceType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(emojiChoices, id: \.self) { item in
                                Text(item)
                                    .font(.title2)
                                    .padding(6)
                                    .background(emoji == item ? Color.accentColor.opacity(0.25) : Color.clear, in: Circle())
                                    .onTapGesture { emoji = item }
                            }
                        }
                    }
                }

                Section(L10n.tr("profile_network_section")) {
                    TextField("MAC (AA:BB:CC:DD:EE:FF)", text: $mac)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("IP (192.168.1.50)", text: $ip)
                        .keyboardType(.decimalPad)
                    TextField(L10n.tr("profile_broadcast_optional"), text: $broadcast)
                        .keyboardType(.decimalPad)
                    TextField("WoL Port (9)", text: $wolPort)
                        .keyboardType(.numberPad)
                    TextField("Agent API Port (8765)", text: $apiPort)
                        .keyboardType(.numberPad)
                }

                Section(L10n.tr("profile_agent_section")) {
                    SecureField(L10n.tr("profile_token_optional"), text: $token)
                        .autocorrectionDisabled()
                    TextField(L10n.tr("profile_device_id_optional"), text: $deviceId)
                        .autocorrectionDisabled()
                }

                if let existing {
                    Section(L10n.tr("geofence_section")) {
                        Toggle(L10n.tr("geofence_toggle"), isOn: $geofenceEnabled)
                            .onChange(of: geofenceEnabled) { enabled in
                                if enabled {
                                    geofence.enableForCurrentLocation(profile: existing)
                                } else {
                                    geofence.disable(for: existing.id)
                                }
                            }
                    }
                }

                if let validationError {
                    Section {
                        Text(validationError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existing == nil ? L10n.tr("profile_add_title") : L10n.tr("profile_edit_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("action_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_save")) { save() }
                }
            }
            .onAppear {
                if let p = existing {
                    name = p.name
                    emoji = p.emoji
                    mac = p.mac
                    ip = p.ip
                    broadcast = p.broadcast
                    wolPort = String(p.wolPort)
                    apiPort = String(p.apiPort)
                    token = p.token
                    deviceId = p.deviceId ?? ""
                    deviceType = p.deviceType
                    geofenceEnabled = geofence.isEnabled(for: p.id)
                }
            }
            .onDisappear {
                discovery.stopScan()
            }
        }
    }

    private func save() {
        let normalizedMAC = mac.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
        guard PCQRCode.isValidMAC(normalizedMAC) else {
            validationError = L10n.tr("err_invalid_mac")
            return
        }
        let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty else {
            validationError = L10n.tr("err_invalid_ip")
            return
        }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty && !PCQRCode.isValidToken(trimmedToken) {
            validationError = L10n.tr("err_invalid_token")
            return
        }

        let profile = PCProfile(
            id: existing?.id ?? UUID().uuidString.lowercased(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My PC" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji,
            mac: normalizedMAC,
            ip: trimmedIP,
            broadcast: broadcast.trimmingCharacters(in: .whitespacesAndNewlines),
            wolPort: Int(wolPort) ?? SharedConfig.defaultWoLPort,
            apiPort: Int(apiPort) ?? SharedConfig.defaultAPIPort,
            token: trimmedToken,
            deviceType: deviceType,
            deviceId: deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        onSave(profile)
        dismiss()
    }
}
