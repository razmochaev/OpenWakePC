#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif
import AudioToolbox
import Foundation
import LocalAuthentication
import UIKit
import UserNotifications

// MARK: - Haptics & Sound

@MainActor
public final class HapticService {
    public static let shared = HapticService()

    private let lightGen = UIImpactFeedbackGenerator(style: .light)
    private let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionGen = UISelectionFeedbackGenerator()
    private let notifGen = UINotificationFeedbackGenerator()

    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hapticsEnabled") }
    }

    public func light() { guard isEnabled else { return }; lightGen.impactOccurred() }
    public func medium() { guard isEnabled else { return }; mediumGen.impactOccurred() }
    public func heavy() { guard isEnabled else { return }; heavyGen.impactOccurred() }
    public func rigid() { guard isEnabled else { return }; rigidGen.impactOccurred() }
    public func selection() { guard isEnabled else { return }; selectionGen.selectionChanged() }
    public func success() { guard isEnabled else { return }; notifGen.notificationOccurred(.success) }
    public func warning() { guard isEnabled else { return }; notifGen.notificationOccurred(.warning) }
    public func error() { guard isEnabled else { return }; notifGen.notificationOccurred(.error) }
}

@MainActor
public final class SoundService {
    public static let shared = SoundService()

    public var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }

    public func playTap() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1104)
    }

    public func playSuccess() {
        guard isEnabled else { return }
        AudioServicesPlaySystemSound(1057)
    }
}

// MARK: - Biometrics (Face ID / Touch ID)

public enum BiometricAuthService {
    public static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var err: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}

// MARK: - Live Activity Coordinator

@MainActor
public final class LiveActivityManager {
    public static let shared = LiveActivityManager()

    #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    private var wakeActivities: [String: Activity<WakeActivityAttributes>] = [:]
    private var scheduledActivities: [String: Activity<ScheduledActivityAttributes>] = [:]

    public func startWakeActivity(for profile: PCProfile) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endWakeActivity(for: profile.id)
        let attrs = WakeActivityAttributes(profileId: profile.id, pcName: profile.name, pcEmoji: profile.emoji)
        let state = WakeActivityAttributes.ContentState(phase: .sending, message: L10n.tr("live_waking_sending"))
        if let act = try? Activity.request(
            attributes: attrs,
            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(90))
        ) {
            wakeActivities[profile.id] = act
        }
    }

    public func updateWakeActivity(for profileId: String, phase: WakeActivityAttributes.Phase, message: String) {
        guard let act = wakeActivities[profileId] else { return }
        let state = WakeActivityAttributes.ContentState(phase: phase, message: message)
        Task {
            await act.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60)))
            if phase == .awake || phase == .timeout {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await act.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
                wakeActivities.removeValue(forKey: profileId)
            }
        }
    }

    public func endWakeActivity(for profileId: String) {
        guard let act = wakeActivities.removeValue(forKey: profileId) else { return }
        Task { await act.end(nil, dismissalPolicy: .immediate) }
    }

    public func startScheduledActivity(for profile: PCProfile, action: ScheduleAction, targetDate: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endScheduledActivity(for: profile.id)
        let attrs = ScheduledActivityAttributes(profileId: profile.id, pcName: profile.name, pcEmoji: profile.emoji)
        let state = ScheduledActivityAttributes.ContentState(action: action, targetDate: targetDate, isCancelled: false)
        if let act = try? Activity.request(
            attributes: attrs,
            content: ActivityContent(state: state, staleDate: targetDate)
        ) {
            scheduledActivities[profile.id] = act
        }
    }

    public func endScheduledActivity(for profileId: String) {
        guard let act = scheduledActivities.removeValue(forKey: profileId) else { return }
        Task { await act.end(nil, dismissalPolicy: .immediate) }
    }
    #else
    public func startWakeActivity(for profile: PCProfile) {}
    public func updateWakeActivity(for profileId: String, phase: WakeActivityAttributes.Phase, message: String) {}
    public func endWakeActivity(for profileId: String) {}
    public func startScheduledActivity(for profile: PCProfile, action: ScheduleAction, targetDate: Date) {}
    public func endScheduledActivity(for profileId: String) {}
    #endif

    public func notifyPCAwake(_ profile: PCProfile) {
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("notif_pc_awake_title")
        content.body = L10n.tr("notif_pc_awake_body", profile.name)
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "pc-awake-\(profile.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Built-in Step-by-Step Diagnostics

public struct DiagnosticStep: Identifiable, Sendable {
    public enum Status: Sendable { case pending, ok, warning, failed }
    public let id = UUID()
    public let title: String
    public let detail: String
    public let status: Status
}

@MainActor
public final class HelpDiagnostics: ObservableObject {
    @Published public private(set) var steps: [DiagnosticStep] = []
    @Published public private(set) var isRunning = false

    public init() {}

    public func run(for profile: PCProfile) async {
        isRunning = true
        steps = []
        defer { isRunning = false }

        let net = NetworkService.shared

        // Step 1: Wi-Fi / VPN check
        if net.interfaces.wifi {
            steps.append(DiagnosticStep(
                title: L10n.tr("diag_wifi_title"),
                detail: net.interfaces.vpn ? L10n.tr("conn_hint_vpn_ok") : L10n.tr("diag_wifi_ok"),
                status: .ok
            ))
        } else {
            steps.append(DiagnosticStep(
                title: L10n.tr("diag_wifi_title"),
                detail: L10n.tr("diag_wifi_off"),
                status: .warning
            ))
        }

        // Step 2: Subnet check
        if let localIP = PCDiscoveryService.localWiFiIPv4() {
            let sameSubnet = localIP.split(separator: ".").prefix(3) == profile.ip.split(separator: ".").prefix(3)
            steps.append(DiagnosticStep(
                title: L10n.tr("diag_subnet_title"),
                detail: sameSubnet ? "\(localIP) ↔ \(profile.ip)" : L10n.tr("conn_fail_different_network"),
                status: sameSubnet ? .ok : .warning
            ))
        }

        // Step 3: Agent reachability & token verification
        do {
            let resp = try await net.fetchStatus(profile: profile)
            steps.append(DiagnosticStep(
                title: L10n.tr("diag_agent_title"),
                detail: "\(L10n.tr("diag_agent_ok")) (\(net.lastUsedRoute.rawValue.uppercased()))",
                status: .ok
            ))
            if let probs = resp.diagnostics?.problems, !probs.isEmpty {
                let list = probs.map(\.rawValue).joined(separator: ", ")
                steps.append(DiagnosticStep(
                    title: L10n.tr("diag_problems_title"),
                    detail: list,
                    status: .warning
                ))
            }
        } catch let err as NetworkError {
            let status: DiagnosticStep.Status = (err == .unauthorized) ? .failed : .failed
            steps.append(DiagnosticStep(
                title: L10n.tr("diag_agent_title"),
                detail: err.localizedDescription,
                status: status
            ))
        } catch {
            steps.append(DiagnosticStep(
                title: L10n.tr("diag_agent_title"),
                detail: error.localizedDescription,
                status: .failed
            ))
        }
    }
}
