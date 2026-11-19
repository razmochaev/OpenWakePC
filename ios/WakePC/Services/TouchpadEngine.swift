import Foundation

/// High-frequency delta coalescing queue for mouse movement and scrolling (clamped to ±5000).
public actor TouchpadQueue {
    public enum Command: Sendable {
        case move(dx: Int, dy: Int)
        case scroll(dx: Int, dy: Int)
        case click(button: String, count: Int)
        case drag(state: String)
        case text(String)
        case key(key: String, mods: [String])
    }

    private var moveCarryX: Int = 0
    private var moveCarryY: Int = 0
    private var scrollCarryX: Int = 0
    private var scrollCarryY: Int = 0
    private var discreteQueue: [Command] = []

    public func enqueue(_ command: Command) {
        switch command {
        case .move(let dx, let dy):
            moveCarryX = Self.clamp(moveCarryX + dx)
            moveCarryY = Self.clamp(moveCarryY + dy)
        case .scroll(let dx, let dy):
            scrollCarryX = Self.clamp(scrollCarryX + dx)
            scrollCarryY = Self.clamp(scrollCarryY + dy)
        default:
            discreteQueue.append(command)
        }
    }

    public func dequeueNext() -> Command? {
        if !discreteQueue.isEmpty {
            return discreteQueue.removeFirst()
        }
        if moveCarryX != 0 || moveCarryY != 0 {
            let cmd = Command.move(dx: moveCarryX, dy: moveCarryY)
            moveCarryX = 0
            moveCarryY = 0
            return cmd
        }
        if scrollCarryX != 0 || scrollCarryY != 0 {
            let cmd = Command.scroll(dx: scrollCarryX, dy: scrollCarryY)
            scrollCarryX = 0
            scrollCarryY = 0
            return cmd
        }
        return nil
    }

    public func clear() {
        moveCarryX = 0
        moveCarryY = 0
        scrollCarryX = 0
        scrollCarryY = 0
        discreteQueue.removeAll()
    }

    private static func clamp(_ value: Int) -> Int {
        max(-5000, min(5000, value))
    }
}

/// Sends coalesced touchpad & keyboard commands to the PC agent.
/// Mouse actions (`/mouse/*`) are strictly LAN-only; keyboard (`/key/*`) works over LAN & Relay.
@MainActor
public final class TouchpadModel: ObservableObject {
    @Published public var lanUnavailable: Bool = false
    @Published public var lastError: String?
    @Published public var sensitivity: Double = 1.4

    private let profile: PCProfile
    private let network: NetworkService
    private let queue = TouchpadQueue()
    private var flushTask: Task<Void, Never>?

    public init(profile: PCProfile, network: NetworkService = .shared) {
        self.profile = profile
        self.network = network
        self.lanUnavailable = !network.interfaces.wifi && !network.interfaces.vpn
        startPump()
    }

    deinit {
        flushTask?.cancel()
    }

    public func move(dx: CGFloat, dy: CGFloat) {
        guard !lanUnavailable else { return }
        let sx = Int((dx * sensitivity).rounded())
        let sy = Int((dy * sensitivity).rounded())
        guard sx != 0 || sy != 0 else { return }
        Task { await queue.enqueue(.move(dx: sx, dy: sy)) }
    }

    public func scroll(dx: CGFloat, dy: CGFloat) {
        guard !lanUnavailable else { return }
        let sx = Int(dx.rounded())
        let sy = Int(dy.rounded())
        guard sx != 0 || sy != 0 else { return }
        Task { await queue.enqueue(.scroll(dx: sx, dy: sy)) }
    }

    public func click(button: String = "left", count: Int = 1) {
        guard !lanUnavailable else { return }
        HapticService.shared.light()
        Task { await queue.enqueue(.click(button: button, count: count)) }
    }

    public func drag(down: Bool) {
        guard !lanUnavailable else { return }
        Task { await queue.enqueue(.drag(state: down ? "down" : "up")) }
    }

    public func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        Task { await queue.enqueue(.text(text)) }
    }

    public func pressKey(_ key: String, mods: [String] = []) {
        HapticService.shared.light()
        Task { await queue.enqueue(.key(key: key, mods: mods)) }
    }

    public func stop() {
        flushTask?.cancel()
        flushTask = nil
        Task { await queue.clear() }
    }

    private func startPump() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if let next = await self.queue.dequeueNext() {
                    await self.dispatch(next)
                } else {
                    try? await Task.sleep(nanoseconds: 16_000_000) // ~60 Hz idle poll
                }
            }
        }
    }

    private func dispatch(_ command: TouchpadQueue.Command) async {
        let path: String
        let query: [String: String]
        let lanOnly: Bool

        switch command {
        case .move(let dx, let dy):
            path = "/mouse/move"
            query = ["dx": String(dx), "dy": String(dy)]
            lanOnly = true
        case .scroll(let dx, let dy):
            path = "/mouse/scroll"
            query = ["dx": String(dx), "dy": String(dy)]
            lanOnly = true
        case .click(let button, let count):
            path = "/mouse/click"
            query = ["button": button, "count": String(count)]
            lanOnly = true
        case .drag(let state):
            path = "/mouse/drag"
            query = ["state": state]
            lanOnly = true
        case .text(let text):
            path = "/key/text"
            query = ["text": text]
            lanOnly = false
        case .key(let key, let mods):
            path = "/key/press"
            var q = ["key": key]
            if !mods.isEmpty {
                q["mods"] = mods.joined(separator: ",")
            }
            query = q
            lanOnly = false
        }

        do {
            _ = try await network.sendCommand(
                profile: profile,
                path: path,
                query: query,
                timeout: lanOnly ? 2.5 : 8.0,
                lanOnly: lanOnly
            )
            if lanOnly && lanUnavailable {
                lanUnavailable = false
            }
            lastError = nil
        } catch let err as NetworkError {
            if lanOnly && (err == .lanOnly || err == .lanUnreachable || err == .timeout) {
                lanUnavailable = true
            }
            lastError = err.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
    }
}
