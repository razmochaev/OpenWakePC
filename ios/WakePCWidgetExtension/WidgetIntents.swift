#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import AppIntents
import Foundation
import WidgetKit

public struct WidgetPCEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Computer"
    public static var defaultQuery = WidgetPCQuery()

    public let id: String
    public let name: String
    public let emoji: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(emoji) \(name)")
    }

    public init(profile: PCProfile) {
        self.id = profile.id
        self.name = profile.name
        self.emoji = profile.emoji
    }
}

public struct WidgetPCQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [WidgetPCEntity] {
        SharedStorage.shared.loadProfiles()
            .filter { identifiers.contains($0.id) }
            .map(WidgetPCEntity.init)
    }

    public func suggestedEntities() async throws -> [WidgetPCEntity] {
        SharedStorage.shared.loadProfiles().map(WidgetPCEntity.init)
    }

    public func defaultResult() async -> WidgetPCEntity? {
        SharedStorage.shared.selectedProfile().map(WidgetPCEntity.init)
    }
}

public struct SelectPCIntent: WidgetConfigurationIntent {
    public static var title: LocalizedStringResource = "Select Computer"
    public static var description = IntentDescription("Choose which computer to control from this widget.")

    @Parameter(title: "Computer")
    public var computer: WidgetPCEntity?

    public init() {}
}

private func findProfile(id: String) -> PCProfile? {
    let profiles = SharedStorage.shared.loadProfiles()
    if !id.isEmpty, let match = profiles.first(where: { $0.id == id }) {
        return match
    }
    return SharedStorage.shared.selectedProfile()
}

// MARK: - Interactive Home Screen Widget Intents (100% Free)

public struct WakeFromWidgetIntent: AppIntent {
    public static var title: LocalizedStringResource = "OpenWakePC"
    @Parameter(title: "Profile ID") public var profileId: String

    public init() { self.profileId = "" }
    public init(profileId: String) { self.profileId = profileId }

    public func perform() async throws -> some IntentResult {
        if let profile = findProfile(id: profileId) {
            try? WidgetWoLService.wake(profile: profile)
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }
}

public struct SleepFromWidgetIntent: AppIntent {
    public static var title: LocalizedStringResource = "Sleep PC"
    @Parameter(title: "Profile ID") public var profileId: String

    public init() { self.profileId = "" }
    public init(profileId: String) { self.profileId = profileId }

    public func perform() async throws -> some IntentResult {
        if let profile = findProfile(id: profileId) {
            _ = await WidgetWoLService.sendCommand(profile: profile, path: "/sleep")
            SharedStorage.shared.setOnline(false, forProfileId: profile.id)
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }
}

public struct ShutdownFromWidgetIntent: AppIntent {
    public static var title: LocalizedStringResource = "Shut Down PC"
    @Parameter(title: "Profile ID") public var profileId: String

    public init() { self.profileId = "" }
    public init(profileId: String) { self.profileId = profileId }

    public func perform() async throws -> some IntentResult {
        if let profile = findProfile(id: profileId) {
            _ = await WidgetWoLService.sendCommand(profile: profile, path: "/shutdown")
            SharedStorage.shared.setOnline(false, forProfileId: profile.id)
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }
}

public struct RestartFromWidgetIntent: AppIntent {
    public static var title: LocalizedStringResource = "Restart PC"
    @Parameter(title: "Profile ID") public var profileId: String

    public init() { self.profileId = "" }
    public init(profileId: String) { self.profileId = profileId }

    public func perform() async throws -> some IntentResult {
        if let profile = findProfile(id: profileId) {
            _ = await WidgetWoLService.sendCommand(profile: profile, path: "/restart")
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }
}

// MARK: - Control Center iOS 18 Intents

public struct WakeControlIntent: AppIntent {
    public static var title: LocalizedStringResource = "OpenWakePC"
    public init() {}
    public func perform() async throws -> some IntentResult {
        if let profile = SharedStorage.shared.selectedProfile() {
            try? WidgetWoLService.wake(profile: profile)
        }
        return .result()
    }
}

public struct SleepControlIntent: AppIntent {
    public static var title: LocalizedStringResource = "Sleep PC"
    public init() {}
    public func perform() async throws -> some IntentResult {
        if let profile = SharedStorage.shared.selectedProfile() {
            _ = await WidgetWoLService.sendCommand(profile: profile, path: "/sleep")
        }
        return .result()
    }
}

public struct ShutdownControlIntent: AppIntent {
    public static var title: LocalizedStringResource = "Shut Down PC"
    public init() {}
    public func perform() async throws -> some IntentResult {
        if let profile = SharedStorage.shared.selectedProfile() {
            _ = await WidgetWoLService.sendCommand(profile: profile, path: "/shutdown")
        }
        return .result()
    }
}

public struct MuteControlIntent: AppIntent {
    public static var title: LocalizedStringResource = "Mute PC"
    public init() {}
    public func perform() async throws -> some IntentResult {
        if let profile = SharedStorage.shared.selectedProfile() {
            _ = await WidgetWoLService.sendCommand(profile: profile, path: "/volume-mute")
        }
        return .result()
    }
}

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
// MARK: - Live Activity Cancel Intent

public struct CancelScheduledActivityIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Cancel Scheduled Action"
    @Parameter(title: "Profile ID") public var profileId: String

    public init() { self.profileId = "" }
    public init(profileId: String) { self.profileId = profileId }

    public func perform() async throws -> some IntentResult {
        if let profile = findProfile(id: profileId) {
            _ = await WidgetWoLService.sendCommand(profile: profile, path: "/cancel-scheduled")
        }
        for activity in Activity<ScheduledActivityAttributes>.activities where activity.attributes.profileId == profileId {
            let cancelled = ScheduledActivityAttributes.ContentState(
                action: activity.content.state.action,
                targetDate: Date(),
                isCancelled: true
            )
            await activity.end(ActivityContent(state: cancelled, staleDate: nil), dismissalPolicy: .immediate)
        }
        return .result()
    }
}
#endif
