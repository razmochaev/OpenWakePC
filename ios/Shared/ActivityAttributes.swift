import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

/// Live Activity attributes for PC wake-up phases (`WakePCWakeLiveActivity`).
public struct WakeActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var phase: Phase
        public var message: String
        public var updatedAt: Date

        public init(phase: Phase, message: String, updatedAt: Date = Date()) {
            self.phase = phase
            self.message = message
            self.updatedAt = updatedAt
        }
    }

    public enum Phase: String, Codable, Hashable, Sendable {
        case sending
        case waking
        case awake
        case timeout
    }

    public var profileId: String
    public var pcName: String
    public var pcEmoji: String

    public init(profileId: String, pcName: String, pcEmoji: String) {
        self.profileId = profileId
        self.pcName = pcName
        self.pcEmoji = pcEmoji
    }
}

/// Live Activity attributes for scheduled shutdown/restart/sleep countdown (`WakePCWidgetLiveActivity`).
public struct ScheduledActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var action: ScheduleAction
        public var targetDate: Date
        public var isCancelled: Bool

        public init(action: ScheduleAction, targetDate: Date, isCancelled: Bool = false) {
            self.action = action
            self.targetDate = targetDate
            self.isCancelled = isCancelled
        }
    }

    public var profileId: String
    public var pcName: String
    public var pcEmoji: String

    public init(profileId: String, pcName: String, pcEmoji: String) {
        self.profileId = profileId
        self.pcName = pcName
        self.pcEmoji = pcEmoji
    }
}
#else
/// Stub phase enum when building for Mac Catalyst (where ActivityKit is unavailable).
public enum WakeActivityAttributes {
    public enum Phase: String, Codable, Hashable, Sendable {
        case sending
        case waking
        case awake
        case timeout
    }
}
#endif
