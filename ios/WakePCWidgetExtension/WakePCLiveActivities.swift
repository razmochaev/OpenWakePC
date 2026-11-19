#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Wake-Up Live Activity

struct WakePCWakeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WakeActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Text(context.attributes.pcEmoji)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.pcName)
                        .font(.headline)
                    Text(context.state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: icon(for: context.state.phase))
                    .font(.title2)
                    .foregroundStyle(color(for: context.state.phase))
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.pcEmoji).font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.pcName).font(.headline)
                        Text(context.state.message).font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: icon(for: context.state.phase))
                        .foregroundStyle(color(for: context.state.phase))
                }
            } compactLeading: {
                Text(context.attributes.pcEmoji)
            } compactTrailing: {
                Image(systemName: icon(for: context.state.phase))
                    .foregroundStyle(color(for: context.state.phase))
            } minimal: {
                Image(systemName: "power")
            }
        }
    }

    private func icon(for phase: WakeActivityAttributes.Phase) -> String {
        switch phase {
        case .sending: return "bolt.fill"
        case .waking: return "hourglass"
        case .awake: return "checkmark.circle.fill"
        case .timeout: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for phase: WakeActivityAttributes.Phase) -> Color {
        switch phase {
        case .sending, .waking: return .orange
        case .awake: return .green
        case .timeout: return .red
        }
    }
}

// MARK: - Scheduled Countdown Live Activity

struct WakePCWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScheduledActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Text(context.attributes.pcEmoji)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(context.attributes.pcName) • \(context.state.action.rawValue.capitalized)")
                        .font(.headline)
                    Text(timerInterval: Date()...max(Date(), context.state.targetDate), countsDown: true)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: CancelScheduledActivityIntent(profileId: context.attributes.profileId)) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.pcEmoji)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading) {
                        Text(context.attributes.pcName).font(.headline)
                        Text(timerInterval: Date()...max(Date(), context.state.targetDate), countsDown: true)
                            .font(.caption.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: CancelScheduledActivityIntent(profileId: context.attributes.profileId)) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            } compactLeading: {
                Image(systemName: "timer")
            } compactTrailing: {
                Text(timerInterval: Date()...max(Date(), context.state.targetDate), countsDown: true)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44)
            } minimal: {
                Image(systemName: "timer")
            }
        }
    }
}
#endif
