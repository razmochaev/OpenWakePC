import SwiftUI
import WidgetKit

struct WakePCEntry: TimelineEntry {
    let date: Date
    let profile: PCProfile?
    let isOnline: Bool
}

struct WakePCProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WakePCEntry {
        WakePCEntry(
            date: Date(),
            profile: PCProfile(name: "My PC", emoji: "🖥️", mac: "AA:BB:CC:DD:EE:FF", ip: "192.168.1.50"),
            isOnline: true
        )
    }

    func snapshot(for configuration: SelectPCIntent, in context: Context) async -> WakePCEntry {
        await buildEntry(for: configuration)
    }

    func timeline(for configuration: SelectPCIntent, in context: Context) async -> Timeline<WakePCEntry> {
        let entry = await buildEntry(for: configuration)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func buildEntry(for configuration: SelectPCIntent) async -> WakePCEntry {
        let profiles = SharedStorage.shared.loadProfiles()
        let selected: PCProfile?
        if let chosenId = configuration.computer?.id {
            selected = profiles.first(where: { $0.id == chosenId }) ?? SharedStorage.shared.selectedProfile()
        } else {
            selected = SharedStorage.shared.selectedProfile()
        }

        let online: Bool
        if let profile = selected {
            online = SharedStorage.shared.isOnlineCached(forProfileId: profile.id).online
        } else {
            online = false
        }
        return WakePCEntry(date: Date(), profile: selected, isOnline: online)
    }
}

struct WakePCWidget: Widget {
    let kind: String = "WakePCWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPCIntent.self, provider: WakePCProvider()) { entry in
            WakePCWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("OpenWakePC")
        .description("Wake, sleep, restart, or shut down your computer directly from the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WakePCWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WakePCEntry

    var body: some View {
        if let profile = entry.profile {
            switch family {
            case .systemSmall:
                smallView(profile: profile)
            case .systemMedium:
                mediumView(profile: profile)
            default:
                largeView(profile: profile)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                Text("Add a PC in OpenWakePC")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func statusDot(_ online: Bool) -> some View {
        Circle()
            .fill(online ? Color.green : Color.gray)
            .frame(width: 8, height: 8)
    }

    private func smallView(profile: PCProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(profile.emoji)
                Text(profile.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                statusDot(entry.isOnline)
            }

            Spacer()

            Button(intent: WakeFromWidgetIntent(profileId: profile.id)) {
                Label("Wake", systemImage: "power")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private func mediumView(profile: PCProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(profile.emoji)
                Text(profile.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 5) {
                    statusDot(entry.isOnline)
                    Text(entry.isOnline ? "Online" : "Offline")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            }

            HStack(spacing: 10) {
                Button(intent: WakeFromWidgetIntent(profileId: profile.id)) {
                    widgetActionPill(icon: "power", title: "Wake", tint: .green)
                }
                .buttonStyle(.plain)

                Button(intent: SleepFromWidgetIntent(profileId: profile.id)) {
                    widgetActionPill(icon: "moon.zzz.fill", title: "Sleep", tint: .indigo)
                }
                .buttonStyle(.plain)

                Button(intent: ShutdownFromWidgetIntent(profileId: profile.id)) {
                    widgetActionPill(icon: "power.circle.fill", title: "Off", tint: .red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func largeView(profile: PCProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            mediumView(profile: profile)
            HStack(spacing: 10) {
                Button(intent: RestartFromWidgetIntent(profileId: profile.id)) {
                    widgetActionPill(icon: "arrow.clockwise", title: "Restart", tint: .orange)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("\(profile.deviceType.displayName) • \(profile.ip)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func widgetActionPill(icon: String, title: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(tint)
    }
}

// MARK: - Lock Screen Widget

struct WakePCLockScreenWidget: Widget {
    let kind: String = "WakePCLockScreenWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPCIntent.self, provider: WakePCProvider()) { entry in
            if let profile = entry.profile {
                Button(intent: WakeFromWidgetIntent(profileId: profile.id)) {
                    VStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.headline)
                        Text(profile.name)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .containerBackground(.clear, for: .widget)
            } else {
                Image(systemName: "power")
                    .containerBackground(.clear, for: .widget)
            }
        }
        .configurationDisplayName("Quick Wake")
        .description("Wake your PC directly from the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
