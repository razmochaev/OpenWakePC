import AppIntents
import Foundation

// MARK: - App Entities

public struct PCProfileEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Computer"
    public static var defaultQuery = PCProfileQuery()

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

public struct PCProfileQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [PCProfileEntity] {
        SharedStorage.shared.loadProfiles()
            .filter { identifiers.contains($0.id) }
            .map(PCProfileEntity.init)
    }

    public func suggestedEntities() async throws -> [PCProfileEntity] {
        SharedStorage.shared.loadProfiles().map(PCProfileEntity.init)
    }

    public func defaultResult() async -> PCProfileEntity? {
        SharedStorage.shared.selectedProfile().map(PCProfileEntity.init)
    }
}

public struct PCCommandEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "PC Command"
    public static var defaultQuery = PCCommandQuery()

    public let id: String
    public let profileId: String
    public let commandId: String
    public let name: String

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    public init(profileId: String, command: CustomCommandInfo) {
        self.id = "\(profileId)::\(command.id)"
        self.profileId = profileId
        self.commandId = command.id
        self.name = command.name
    }
}

public struct PCCommandQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [PCCommandEntity] {
        let all = try await suggestedEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [PCCommandEntity] {
        let cache = SharedStorage.shared.loadAllCustomCommands()
        return cache.flatMap { (profileId, cmds) in
            cmds.map { PCCommandEntity(profileId: profileId, command: $0) }
        }
    }
}

// MARK: - Helper

private func resolveProfile(_ entity: PCProfileEntity?) throws -> PCProfile {
    let profiles = SharedStorage.shared.loadProfiles()
    if let entity, let match = profiles.first(where: { $0.id == entity.id }) {
        return match
    }
    if let selected = SharedStorage.shared.selectedProfile() {
        return selected
    }
    throw NetworkError.connectionFailed(L10n.tr("err_no_profile"))
}

// MARK: - 10 App Intents (100% Free — Zero Paywall)

public struct TurnOnPCIntent: AppIntent {
    public static var title: LocalizedStringResource = "Turn On PC"
    public static var description = IntentDescription("Wakes up your computer via Wake-on-LAN.")
    public static var openAppWhenRun = false

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        await MainActor.run {
            SharedStorage.shared.markWakeRequested(forProfileId: profile.id)
        }
        try WoLSender.send(mac: profile.mac, broadcast: profile.resolvedBroadcast, port: profile.wolPort)
        return .result(dialog: "Waking \(profile.name)")
    }
}

public struct ShutdownPCIntent: AppIntent {
    public static var title: LocalizedStringResource = "Shut Down PC"
    public static var openAppWhenRun = false

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        _ = try await NetworkService.shared.executePower(.shutdown, on: profile)
        return .result(dialog: "Shutting down \(profile.name)")
    }
}

public struct RestartPCIntent: AppIntent {
    public static var title: LocalizedStringResource = "Restart PC"
    public static var openAppWhenRun = false

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        _ = try await NetworkService.shared.executePower(.restart, on: profile)
        return .result(dialog: "Restarting \(profile.name)")
    }
}

public struct SleepPCIntent: AppIntent {
    public static var title: LocalizedStringResource = "Sleep PC"
    public static var openAppWhenRun = false

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        _ = try await NetworkService.shared.executePower(.sleep, on: profile)
        return .result(dialog: "Putting \(profile.name) to sleep")
    }
}

public struct LockPCIntent: AppIntent {
    public static var title: LocalizedStringResource = "Lock PC"
    public static var openAppWhenRun = false

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        _ = try await NetworkService.shared.executePower(.lock, on: profile)
        return .result(dialog: "Locked \(profile.name)")
    }
}

public struct MutePCIntent: AppIntent {
    public static var title: LocalizedStringResource = "Mute PC"
    public static var openAppWhenRun = false

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        _ = try await NetworkService.shared.toggleMute(on: profile)
        return .result(dialog: "Toggled mute on \(profile.name)")
    }
}

public struct SetVolumePCIntent: AppIntent {
    public static var title: LocalizedStringResource = "Set PC Volume"
    public static var openAppWhenRun = false

    @Parameter(title: "Volume", default: 50, inclusiveRange: (0, 100))
    public var volume: Int

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        _ = try await NetworkService.shared.setVolume(volume, on: profile)
        return .result(dialog: "Set \(profile.name) volume to \(volume)%")
    }
}

public struct ScheduleShutdownIntent: AppIntent {
    public static var title: LocalizedStringResource = "Schedule PC Shutdown"
    public static var openAppWhenRun = false

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 1440))
    public var minutes: Int

    @Parameter(title: "Computer")
    public var computer: PCProfileEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profile = try resolveProfile(computer)
        _ = try await NetworkService.shared.schedulePower(.shutdown, minutes: minutes, on: profile)
        return .result(dialog: "Scheduled \(profile.name) shutdown in \(minutes) minutes")
    }
}

public struct RunPCCommandIntent: AppIntent {
    public static var title: LocalizedStringResource = "Run PC Command"
    public static var openAppWhenRun = false

    @Parameter(title: "Command")
    public var command: PCCommandEntity

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let profiles = SharedStorage.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.id == command.profileId }) else {
            throw NetworkError.connectionFailed(L10n.tr("err_no_profile"))
        }
        _ = try await NetworkService.shared.runCustomCommand(id: command.commandId, on: profile)
        return .result(dialog: "Ran \(command.name) on \(profile.name)")
    }
}

public struct CancelScheduledActivityIntent: AppIntent {
    public static var title: LocalizedStringResource = "Cancel Scheduled Action"
    public static var openAppWhenRun = false

    @Parameter(title: "Profile ID")
    public var profileId: String

    public init() {
        self.profileId = ""
    }

    public init(profileId: String) {
        self.profileId = profileId
    }

    public func perform() async throws -> some IntentResult {
        let profiles = SharedStorage.shared.loadProfiles()
        if let profile = profiles.first(where: { $0.id == profileId }) ?? profiles.first {
            _ = try? await NetworkService.shared.cancelScheduled(profile: profile)
            await MainActor.run {
                LiveActivityManager.shared.endScheduledActivity(for: profile.id)
            }
        }
        return .result()
    }
}

// MARK: - App Shortcuts Provider (Siri)

public struct WakePCShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnPCIntent(),
            phrases: [
                "Turn on my computer in \(.applicationName)",
                "Wake my PC in \(.applicationName)",
                "Включи компьютер в \(.applicationName)",
                "Разбуди ПК в \(.applicationName)",
            ],
            shortTitle: "Turn On PC",
            systemImageName: "power"
        )
    }
}
