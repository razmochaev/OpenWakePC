import Foundation

#if canImport(WatchConnectivity) && !targetEnvironment(macCatalyst)
import WatchConnectivity

/// Synchronizes PC profiles with a paired Apple Watch companion and executes watch commands.
public final class WatchSyncService: NSObject, WCSessionDelegate, @unchecked Sendable {
    public static let shared = WatchSyncService()

    private override init() {
        super.init()
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    public func pushProfilesToWatch(_ profiles: [PCProfile]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let sanitized = profiles.map { $0.sanitizedForUserDefaults() }
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        try? session.updateApplicationContext(["profiles": data])
    }

    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if activationState == .activated {
            pushProfilesToWatch(SharedStorage.shared.loadProfiles())
        }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor in
            let profiles = SharedStorage.shared.loadProfiles()

            if let wakeId = message["wakeProfileId"] as? String,
               let target = profiles.first(where: { $0.id == wakeId }) {
                do {
                    try await NetworkService.shared.wake(target)
                    replyHandler(["success": true])
                } catch {
                    replyHandler(["success": false, "error": error.localizedDescription])
                }
                return
            }

            if let cmdProfileId = message["commandProfileId"] as? String,
               let command = message["command"] as? String,
               let target = profiles.first(where: { $0.id == cmdProfileId }) {
                let path = command.hasPrefix("/") ? command : "/\(command)"
                do {
                    let resp = try await NetworkService.shared.sendCommand(profile: target, path: path)
                    var reply: [String: Any] = ["success": resp.success]
                    if let vol = resp.data?.volume { reply["volume"] = vol }
                    if let muted = resp.data?.muted { reply["muted"] = muted }
                    replyHandler(reply)
                } catch {
                    replyHandler(["success": false, "error": error.localizedDescription])
                }
                return
            }

            replyHandler(["success": false, "error": "Unsupported watch command"])
        }
    }
}
#else
/// No-op stub on Mac Catalyst where WatchConnectivity is unavailable.
public final class WatchSyncService: @unchecked Sendable {
    public static let shared = WatchSyncService()
    private init() {}
    public func activate() {}
    public func pushProfilesToWatch(_ profiles: [PCProfile]) {}
}
#endif
