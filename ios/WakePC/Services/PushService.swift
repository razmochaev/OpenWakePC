import Foundation
import UIKit
import UserNotifications

/// Manages APNs registration with the self-hosted E2EE relay (`POST /push/<deviceId>`)
/// and handles interactive `PC_IDLE` notifications (`PC_IDLE_SHUTDOWN`, `PC_IDLE_SLEEP`).
@MainActor
public final class PushService: ObservableObject {
    public static let shared = PushService()

    public static let idleCategoryID = "PC_IDLE"
    public static let idleShutdownActionID = "PC_IDLE_SHUTDOWN"
    public static let idleSleepActionID = "PC_IDLE_SLEEP"

    private let apnsTokenKey = "apns_token_hex"
    private let defaults = UserDefaults.standard

    public var apnsTokenHex: String? {
        get { defaults.string(forKey: apnsTokenKey) }
        set { defaults.set(newValue, forKey: apnsTokenKey) }
    }

    public func configureCategories() {
        let shutdown = UNNotificationAction(
            identifier: Self.idleShutdownActionID,
            title: L10n.tr("action_shutdown"),
            options: [.destructive]
        )
        let sleep = UNNotificationAction(
            identifier: Self.idleSleepActionID,
            title: L10n.tr("action_sleep"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.idleCategoryID,
            actions: [shutdown, sleep],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    public func requestPermissionsAndRegister() async {
        configureCategories()
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    public func didRegisterDeviceToken(_ tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        apnsTokenHex = hex
        Task {
            await syncAllProfilesIfEnabled()
        }
    }

    public func syncAllProfilesIfEnabled() async {
        let enabled = defaults.bool(forKey: "pcPresencePushEnabled")
        for profile in SharedStorage.shared.loadProfiles() where profile.supportsRelay {
            try? await registerOnRelay(profile: profile, enable: enabled)
        }
    }

    public func registerOnRelay(profile: PCProfile, enable: Bool) async throws {
        guard let deviceId = profile.deviceId,
              !deviceId.isEmpty,
              !profile.token.isEmpty,
              let tokenHex = apnsTokenHex,
              !tokenHex.isEmpty
        else {
            return
        }

        let baseURL = try await RelayClient.shared.resolveBaseURL()
        guard let encodedDeviceId = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/push/\(encodedDeviceId)")
        else {
            return
        }

        let body: [String: Any] = [
            "claim": RelayCrypto.roomClaim(token: profile.token, deviceId: deviceId),
            "token": tokenHex,
            "name": profile.name,
            "env": Self.detectAPNsEnvironment(),
            "enable": enable,
            "caps": ["presence", "idle"],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = SharedConfig.pushRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        _ = try await URLSession.shared.data(for: request)
    }

    public func handleIdleNotificationAction(actionId: String, deviceId: String?) async {
        let profiles = SharedStorage.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.deviceId == deviceId }) ?? profiles.first else {
            return
        }
        let cmd: PowerCommand
        switch actionId {
        case Self.idleShutdownActionID: cmd = .shutdown
        case Self.idleSleepActionID: cmd = .sleep
        default: return
        }

        do {
            _ = try await NetworkService.shared.executePower(cmd, on: profile)
        } catch {
            let content = UNMutableNotificationContent()
            content.title = L10n.tr("notif_idle_failed_title")
            content.body = error.localizedDescription
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "idle-action-failed-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(req)
        }
    }

    /// Reads `<key>aps-environment</key>` from `embedded.mobileprovision` to match production vs development APNs.
    public static func detectAPNsEnvironment() -> String {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .isoLatin1),
              let range = text.range(of: "<key>aps-environment</key>")
        else {
            #if DEBUG
            return "development"
            #else
            return "production"
            #endif
        }
        let tail = text[range.upperBound...]
        if tail.contains("<string>development</string>") {
            return "development"
        }
        return "production"
    }
}

/// UIApplicationDelegate adapter wired into WakePCApp via `@UIApplicationDelegateAdaptor`.
public final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            PushService.shared.configureCategories()
        }
        return true
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushService.shared.didRegisterDeviceToken(deviceToken)
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionId = response.actionIdentifier
        if actionId == PushService.idleShutdownActionID || actionId == PushService.idleSleepActionID {
            let deviceId = response.notification.request.content.userInfo["deviceId"] as? String
            await PushService.shared.handleIdleNotificationAction(actionId: actionId, deviceId: deviceId)
        }
    }
}
