import SwiftUI

struct PowerButton: View {
    let theme: AppTheme
    let isOnline: Bool
    let isChecking: Bool
    let isWaking: Bool
    let onTap: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(theme.accentColor.opacity(isOnline || isWaking ? 0.45 : 0.18), lineWidth: 2)
                    .frame(width: 174, height: 174)
                    .scaleEffect(pulse ? 1.08 : 0.96)
                    .opacity(pulse ? 0.25 : 0.75)

                Circle()
                    .fill(theme.gradient)
                    .frame(width: 148, height: 148)
                    .shadow(color: theme.accentColor.opacity(0.5), radius: 24, y: 10)
                    .overlay {
                        if let decor = theme.buttonDecor {
                            ThemeButtonArt(decor: decor)
                                .clipShape(Circle())
                        }
                    }

                VStack(spacing: 6) {
                    if isChecking || isWaking {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.3)
                    } else {
                        Image(systemName: isOnline ? "power.circle.fill" : "power")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text(labelText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .buttonStyle(GlassPressButtonStyle())
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var labelText: String {
        if isWaking { return L10n.tr("status_waking") }
        if isChecking { return L10n.tr("status_checking") }
        return isOnline ? L10n.tr("status_online") : L10n.tr("action_wake")
    }
}

struct VolumeControlView: View {
    @Binding var volume: Double
    @Binding var isMuted: Bool
    @Binding var isAdjusting: Bool
    let theme: AppTheme
    let supportsAudioOutputs: Bool
    let onCommitVolume: (Int) -> Void
    let onStep: (Bool) -> Void
    let onToggleMute: () -> Void
    let onOpenOutputs: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label(L10n.tr("control_volume"), systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(isMuted ? L10n.tr("volume_muted") : "\(Int(volume))%")
                    .font(.subheadline.monospacedDigit())
                    .opacity(0.8)
                if supportsAudioOutputs {
                    Button(action: onOpenOutputs) {
                        Image(systemName: "airplayaudio")
                            .font(.subheadline.weight(.semibold))
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(GlassPressButtonStyle())
                }
            }

            HStack(spacing: 12) {
                Button(action: onToggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())

                Button { onStep(false) } label: {
                    Image(systemName: "minus")
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())

                Slider(value: $volume, in: 0...100, step: 1) { editing in
                    isAdjusting = editing
                    if !editing {
                        onCommitVolume(Int(volume))
                    }
                }
                .tint(theme.accentColor)

                Button { onStep(true) } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MicControlView: View {
    @Binding var micVolume: Double
    @Binding var isMicMuted: Bool
    @Binding var isAdjusting: Bool
    let theme: AppTheme
    let onCommitMicVolume: (Int) -> Void
    let onStep: (Bool) -> Void
    let onToggleMute: () -> Void
    let onOpenInputs: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label(L10n.tr("control_mic"), systemImage: isMicMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(isMicMuted ? L10n.tr("mic_muted") : "\(Int(micVolume))%")
                    .font(.subheadline.monospacedDigit())
                    .opacity(0.8)
                Button(action: onOpenInputs) {
                    Image(systemName: "airplayaudio")
                        .font(.subheadline.weight(.semibold))
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
            }

            HStack(spacing: 12) {
                Button(action: onToggleMute) {
                    Image(systemName: isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(isMicMuted ? Color.red : Color.primary)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())

                Button { onStep(false) } label: {
                    Image(systemName: "minus")
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())

                Slider(value: $micVolume, in: 0...100, step: 1) { editing in
                    isAdjusting = editing
                    if !editing {
                        onCommitMicVolume(Int(micVolume))
                    }
                }
                .tint(isMicMuted ? .red : theme.accentColor)

                Button { onStep(true) } label: {
                    Image(systemName: "plus")
                        .frame(width: 30, height: 30)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct BrightnessControlView: View {
    @Binding var brightness: Double
    let theme: AppTheme
    let onCommit: (Int) -> Void
    let onStep: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(L10n.tr("control_brightness"), systemImage: "sun.max.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(brightness))%")
                    .font(.subheadline.monospacedDigit())
                    .opacity(0.8)
            }
            HStack(spacing: 12) {
                Button { onStep(false) } label: {
                    Image(systemName: "sun.min")
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())

                Slider(value: $brightness, in: 0...100, step: 1) { editing in
                    if !editing {
                        onCommit(Int(brightness))
                    }
                }
                .tint(theme.accentColor)

                Button { onStep(true) } label: {
                    Image(systemName: "sun.max")
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(GlassPressButtonStyle())
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MediaControlsView: View {
    let supportsFullscreen: Bool
    let onAction: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            mediaBtn("backward.fill", path: "/media-prev")
            mediaBtn("playpause.fill", path: "/media-play-pause")
            mediaBtn("forward.fill", path: "/media-next")
            if supportsFullscreen {
                mediaBtn("arrow.up.left.and.arrow.down.right", path: "/media-fullscreen")
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func mediaBtn(_ icon: String, path: String) -> some View {
        Button {
            HapticService.shared.light()
            onAction(path)
        } label: {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

struct TelemetryCardView: View {
    let cpuLoad: Double
    let ramLoad: Double
    let ramUsedGb: Double
    let ramTotalGb: Double
    let uptimeSeconds: Int
    let theme: AppTheme

    var body: some View {
        HStack(spacing: 10) {
            metricTile(
                title: "CPU",
                value: "\(Int(cpuLoad.rounded()))%",
                subtitle: L10n.tr("telemetry_cpu_load"),
                progress: cpuLoad / 100.0
            )
            metricTile(
                title: "RAM",
                value: "\(Int(ramLoad.rounded()))%",
                subtitle: String(format: "%.1f/%.0f GB", ramUsedGb, ramTotalGb),
                progress: ramLoad / 100.0
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(L10n.tr("telemetry_uptime"))
                        .font(.caption2.weight(.semibold))
                        .opacity(0.7)
                    Spacer(minLength: 2)
                    Text(formatUptime(uptimeSeconds))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                ProgressView(value: 1.0)
                    .tint(.green.opacity(0.75))
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                    Text(L10n.tr("status_online"))
                        .font(.caption2)
                        .opacity(0.68)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metricTile(title: String, value: String, subtitle: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
                Spacer(minLength: 2)
                Text(value)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .lineLimit(1)
            }
            ProgressView(value: min(1.0, max(0.0, progress)))
                .tint(theme.accentColor)
            Text(subtitle)
                .font(.caption2.monospacedDigit())
                .opacity(0.68)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func formatUptime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let mins = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }
}

struct ToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }
}
