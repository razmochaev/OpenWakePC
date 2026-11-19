import AppKit
import CoreAudio
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import IOKit
import ScreenCaptureKit

struct AudioOutput: Codable, Identifiable {
    let id: String
    let name: String
    let isDefault: Bool
}

struct AppEntry: Codable, Identifiable {
    let id: String
    let name: String
    let icon: String?
    let iconImage: String?
}

/// Native macOS system integrations (DisplayServices brightness, CoreAudio volume & outputs,
/// CGEvent touchpad/keyboard/media, NSWorkspace apps, screencapture screenshots, WoL UDP).
final class MacSystemController: @unchecked Sendable {
    static let shared = MacSystemController()

    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (UInt32, Float) -> Int32
    private typealias IOAVServiceCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias IOAVServiceCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias IOAVServiceWriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias IOAVServiceReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private var displayServicesHandle: UnsafeMutableRawPointer?
    private var getBrightnessFn: GetBrightnessFn?
    private var setBrightnessFn: SetBrightnessFn?
    private var ioKitHandle: UnsafeMutableRawPointer?
    private var avCreateWithServiceFn: IOAVServiceCreateWithServiceFn?
    private var avCreateFn: IOAVServiceCreateFn?
    private var avWriteI2CFn: IOAVServiceWriteI2CFn?
    private var avReadI2CFn: IOAVServiceReadI2CFn?
    private let brightnessLock = NSLock()
    private var cachedBrightness: (value: Int, maxVal: Int, at: Date)?
    private var lastDDCFailureAt: Date?
    private var lastNonZeroMicVolume: Int = 75
    private var isMicMutedState: Bool = false
    private var cachedAudioState: (outVol: Int, outMuted: Bool, inVol: Int, at: Date)?

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        if let handle = dlopen(path, RTLD_LAZY) {
            displayServicesHandle = handle
            if let sym = dlsym(handle, "DisplayServicesGetBrightness") {
                getBrightnessFn = unsafeBitCast(sym, to: GetBrightnessFn.self)
            }
            if let sym = dlsym(handle, "DisplayServicesSetBrightness") {
                setBrightnessFn = unsafeBitCast(sym, to: SetBrightnessFn.self)
            }
        }

        let ioKitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
        if let handle = dlopen(ioKitPath, RTLD_LAZY) {
            ioKitHandle = handle
            if let sym = dlsym(handle, "IOAVServiceCreateWithService") {
                avCreateWithServiceFn = unsafeBitCast(sym, to: IOAVServiceCreateWithServiceFn.self)
            }
            if let sym = dlsym(handle, "IOAVServiceCreate") {
                avCreateFn = unsafeBitCast(sym, to: IOAVServiceCreateFn.self)
            }
            if let sym = dlsym(handle, "IOAVServiceWriteI2C") {
                avWriteI2CFn = unsafeBitCast(sym, to: IOAVServiceWriteI2CFn.self)
            }
            if let sym = dlsym(handle, "IOAVServiceReadI2C") {
                avReadI2CFn = unsafeBitCast(sym, to: IOAVServiceReadI2CFn.self)
            }
        }
    }

    // MARK: - Power Controls

    func executePower(_ action: String) -> (Bool, String) {
        switch action {
        case "shutdown":
            runProcess("/usr/bin/osascript", ["-e", #"tell application "System Events" to shut down"#])
            return (true, "Shutdown command sent")
        case "restart":
            runProcess("/usr/bin/osascript", ["-e", #"tell application "System Events" to restart"#])
            return (true, "Restart command sent")
        case "sleep", "hibernate":
            runProcess("/usr/bin/pmset", ["sleepnow"])
            return (true, "Sleep command sent")
        case "lock":
            runProcess("/usr/bin/osascript", ["-e", #"tell application "System Events" to keystroke "q" using {command down, control down}"#])
            return (true, "Lock command sent")
        case "display-off":
            runProcess("/usr/bin/pmset", ["displaysleepnow"])
            return (true, "Display sleep sent")
        case "display-on":
            runProcess("/usr/bin/caffeinate", ["-u", "-t", "2"])
            return (true, "Display wake sent")
        default:
            return (false, "Unknown power action")
        }
    }

    // MARK: - Wake-on-LAN (Buddy Wake)

    func sendWoL(mac: String, broadcast: String, port: Int) -> Bool {
        let parts = mac.uppercased().split(separator: ":")
        guard parts.count == 6 else { return false }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return false }

        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard broadcast.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return false }

        for _ in 0..<3 {
            _ = packet.withUnsafeBytes { raw in
                withUnsafePointer(to: &addr) { aptr in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                        sendto(fd, raw.baseAddress, packet.count, 0, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        return true
    }

    // MARK: - Telemetry (CPU / RAM / Uptime)

    func telemetry() -> [String: Any] {
        let totalMem = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGb = round((totalMem / 1_073_741_824.0) * 100.0) / 100.0

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let pageSize = Double(vm_kernel_page_size)
        var usedGb = 0.0
        var ramLoad = 0.0
        let kerr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            let usedBytes = Double(vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count) * pageSize
            usedGb = round((usedBytes / 1_073_741_824.0) * 100.0) / 100.0
            ramLoad = totalMem > 0 ? round((usedBytes / totalMem) * 1000.0) / 10.0 : 0.0
        }

        var loadAvg = [Double](repeating: 0, count: 3)
        getloadavg(&loadAvg, 3)
        let cores = max(1.0, Double(ProcessInfo.processInfo.activeProcessorCount))
        let cpuLoad = min(100.0, round((loadAvg[0] / cores) * 1000.0) / 10.0)

        return [
            "cpuLoad": cpuLoad,
            "ramLoad": ramLoad,
            "ramUsedGb": usedGb,
            "ramTotalGb": totalGb,
            "uptimeSeconds": Int(ProcessInfo.processInfo.systemUptime),
        ]
    }

    // MARK: - Audio (Volume, Mute, CoreAudio Outputs & Inputs)

    private func refreshAudioState(force: Bool = false) -> (outVol: Int, outMuted: Bool, inVol: Int) {
        if !force, let cached = cachedAudioState, Date().timeIntervalSince(cached.at) < 2.0 {
            return (cached.outVol, cached.outMuted, cached.inVol)
        }
        let script = "((output volume of (get volume settings)) as string) & \",\" & ((output muted of (get volume settings)) as string) & \",\" & ((input volume of (get volume settings)) as string)"
        let out = runProcessOutput("/usr/bin/osascript", ["-e", script])
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        let outVol = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? (cachedAudioState?.outVol ?? 50)
        let outMuted = parts.count > 1 && parts[1].trimmingCharacters(in: .whitespaces) == "true"
        let inVol = parts.count > 2 ? (Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? (cachedAudioState?.inVol ?? 50)) : (cachedAudioState?.inVol ?? 50)
        cachedAudioState = (outVol, outMuted, inVol, Date())
        return (outVol, outMuted, inVol)
    }

    func volumeState() -> (volume: Int, muted: Bool) {
        let s = refreshAudioState()
        return (s.outVol, s.outMuted)
    }

    func setVolume(_ level: Int) -> (Int, Bool) {
        let clamped = max(0, min(100, level))
        runProcess("/usr/bin/osascript", ["-e", "set volume output volume \(clamped)"])
        cachedAudioState = nil
        return volumeState()
    }

    func adjustVolume(delta: Int) -> (Int, Bool) {
        let current = volumeState().volume
        return setVolume(current + delta)
    }

    func toggleMute() -> (Int, Bool) {
        let cur = volumeState()
        runProcess("/usr/bin/osascript", ["-e", "set volume output muted \(!cur.muted)"])
        cachedAudioState = nil
        return volumeState()
    }

    func micState() -> (volume: Int, muted: Bool) {
        let vol = refreshAudioState().inVol
        if vol == 0 {
            isMicMutedState = true
            return (0, true)
        }
        lastNonZeroMicVolume = vol
        isMicMutedState = false
        return (vol, false)
    }

    func setMicVolume(_ level: Int) -> (Int, Bool) {
        let clamped = max(0, min(100, level))
        runProcess("/usr/bin/osascript", ["-e", "set volume input volume \(clamped)"])
        if let prev = cachedAudioState {
            cachedAudioState = (prev.outVol, prev.outMuted, clamped, Date())
        }
        if clamped > 0 {
            lastNonZeroMicVolume = clamped
            isMicMutedState = false
        } else {
            isMicMutedState = true
        }
        return (clamped, clamped == 0)
    }

    func adjustMicVolume(delta: Int) -> (Int, Bool) {
        let cur = micState()
        let base = cur.muted ? lastNonZeroMicVolume : cur.volume
        return setMicVolume(base + delta)
    }

    func toggleMicMute() -> (Int, Bool) {
        let cur = micState()
        if !cur.muted && cur.volume > 0 {
            lastNonZeroMicVolume = cur.volume
            isMicMutedState = true
            runProcess("/usr/bin/osascript", ["-e", "set volume input volume 0"])
            if let prev = cachedAudioState {
                cachedAudioState = (prev.outVol, prev.outMuted, 0, Date())
            }
            return (0, true)
        } else {
            let restored = max(10, lastNonZeroMicVolume)
            isMicMutedState = false
            runProcess("/usr/bin/osascript", ["-e", "set volume input volume \(restored)"])
            if let prev = cachedAudioState {
                cachedAudioState = (prev.outVol, prev.outMuted, restored, Date())
            }
            return (restored, false)
        }
    }

    func listAudioOutputs() -> [AudioOutput] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else {
            return []
        }

        let defaultId = defaultAudioOutputDeviceID()
        var results: [AudioOutput] = []
        for dev in devices where hasOutputStreams(deviceId: dev) {
            let name = audioDeviceName(deviceId: dev) ?? "Audio Device \(dev)"
            results.append(AudioOutput(id: String(dev), name: name, isDefault: dev == defaultId))
        }
        return results
    }

    func setAudioOutput(id: String) -> Bool {
        guard var devId = UInt32(id) else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devId
        )
        return status == noErr
    }

    private func defaultAudioOutputDeviceID() -> AudioDeviceID {
        var devId: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devId)
        return devId
    }

    private func hasOutputStreams(deviceId: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceId, &addr, 0, nil, &size) == noErr && size > 0
    }

    func listAudioInputs() -> [AudioOutput] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else {
            return []
        }

        let defaultId = defaultAudioInputDeviceID()
        var results: [AudioOutput] = []
        for dev in devices where hasInputStreams(deviceId: dev) {
            let name = audioDeviceName(deviceId: dev) ?? "Audio Input \(dev)"
            results.append(AudioOutput(id: String(dev), name: name, isDefault: dev == defaultId))
        }
        return results
    }

    func setAudioInput(id: String) -> Bool {
        guard var devId = UInt32(id) else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devId
        )
        return status == noErr
    }

    private func defaultAudioInputDeviceID() -> AudioDeviceID {
        var devId: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devId)
        return devId
    }

    private func hasInputStreams(deviceId: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceId, &addr, 0, nil, &size) == noErr && size > 0
    }

    private func audioDeviceName(deviceId: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(deviceId, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? (cfName as String) : nil
    }

    // MARK: - Brightness (DisplayServices + Apple Silicon DDC/CI via IOAVService)

    func getBrightness() -> Int {
        if let fn = getBrightnessFn {
            var level: Float = 0.8
            if fn(CGMainDisplayID(), &level) == 0 {
                return max(0, min(100, Int((level * 100.0).rounded())))
            }
        }

        brightnessLock.lock()
        defer { brightnessLock.unlock() }

        let now = Date()
        if let cached = cachedBrightness, now.timeIntervalSince(cached.at) < 3.0 {
            return cached.value
        }
        if let failAt = lastDDCFailureAt, now.timeIntervalSince(failAt) < 5.0 {
            return cachedBrightness?.value ?? 80
        }

        if let (percent, maxVal) = ddcReadBrightness() {
            cachedBrightness = (percent, maxVal, Date())
            lastDDCFailureAt = nil
            return percent
        }

        lastDDCFailureAt = Date()
        return cachedBrightness?.value ?? 80
    }

    func setBrightness(_ percent: Int) -> Int {
        let clamped = max(0, min(100, percent))
        let mainDisplay = CGMainDisplayID()
        let mainSupportsSystem = supportsDisplayServices(mainDisplay)
        let online = activeOnlineDisplays()

        if let setFn = setBrightnessFn {
            for displayId in online where supportsDisplayServices(displayId) {
                _ = setFn(displayId, Float(clamped) / 100.0)
            }
        }

        let hasNonSystemExternal = online.contains { CGDisplayIsBuiltin($0) == 0 && !supportsDisplayServices($0) }
        if !mainSupportsSystem || hasNonSystemExternal {
            brightnessLock.lock()
            defer { brightnessLock.unlock() }

            lastDDCFailureAt = nil
            let maxVal = cachedBrightness?.maxVal ?? ddcReadBrightness()?.maxVal ?? 100
            if ddcWriteBrightness(clamped, maxVal: maxVal) {
                cachedBrightness = (clamped, maxVal, Date())
            }
            if !mainSupportsSystem {
                return cachedBrightness?.value ?? clamped
            }
        }

        return getBrightness()
    }

    private func supportsDisplayServices(_ displayId: CGDirectDisplayID) -> Bool {
        guard let fn = getBrightnessFn else { return false }
        var probe: Float = 0.0
        return fn(displayId, &probe) == 0
    }

    private func activeOnlineDisplays() -> [CGDirectDisplayID] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(16, &displays, &count) == .success, count > 0 {
            return Array(displays.prefix(Int(count)))
        }
        return [CGMainDisplayID()]
    }

    private func externalAVServices() -> [CFTypeRef] {
        guard let createWithSvc = avCreateWithServiceFn else {
            if let av = avCreateFn?(kCFAllocatorDefault)?.takeRetainedValue() {
                return [av]
            }
            return []
        }

        var external: [CFTypeRef] = []
        var other: [CFTypeRef] = []
        var iter: io_iterator_t = 0

        if let matching = IOServiceMatching("DCPAVServiceProxy"),
           IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS {
            defer { IOObjectRelease(iter) }
            while true {
                let svc = IOIteratorNext(iter)
                if svc == 0 { break }
                defer { IOObjectRelease(svc) }
                let loc = IORegistryEntryCreateCFProperty(
                    svc,
                    "Location" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? String
                if loc == "Embedded" { continue }
                if let av = createWithSvc(kCFAllocatorDefault, svc)?.takeRetainedValue() {
                    if loc == "External" {
                        external.append(av)
                    } else if loc == nil {
                        other.append(av)
                    }
                }
            }
        }

        if !external.isEmpty {
            return external
        }
        if !other.isEmpty {
            return other
        }
        if let av = avCreateFn?(kCFAllocatorDefault)?.takeRetainedValue() {
            return [av]
        }
        return []
    }

    private func ddcReadBrightness() -> (percent: Int, maxVal: Int)? {
        guard let writeI2C = avWriteI2CFn, let readI2C = avReadI2CFn else {
            return nil
        }

        // DDC/CI Get VCP Feature 0x10 (Luminance): [0x82, 0x01, 0x10, chk]
        let getPacket: [UInt8] = [0x82, 0x01, 0x10, 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0x10]

        for av in externalAVServices() {
            for _ in 0..<2 {
                var send = getPacket
                let wrc = send.withUnsafeMutableBytes { buf -> IOReturn in
                    guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
                    return writeI2C(av, 0x37, 0x51, ptr, UInt32(buf.count))
                }
                guard wrc == kIOReturnSuccess else {
                    usleep(20_000)
                    continue
                }

                // Monitors require ~40-50 ms before returning the DDC/CI VCP reply frame.
                usleep(45_000)

                var reply = [UInt8](repeating: 0, count: 12)
                let rrc = reply.withUnsafeMutableBytes { buf -> IOReturn in
                    guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
                    return readI2C(av, 0x37, 0x00, ptr, UInt32(buf.count))
                }
                guard rrc == kIOReturnSuccess,
                      reply[0] == 0x6E,
                      (reply[1] & 0x7F) >= 8,
                      reply[2] == 0x02,
                      reply[3] == 0x00,
                      reply[4] == 0x10 else {
                    usleep(20_000)
                    continue
                }

                var chk: UInt8 = 0x50
                for i in 0..<10 {
                    chk ^= reply[i]
                }
                guard chk == reply[10] else {
                    usleep(20_000)
                    continue
                }

                let maxVal = (Int(reply[6]) << 8) | Int(reply[7])
                let curVal = (Int(reply[8]) << 8) | Int(reply[9])
                guard maxVal > 0 else {
                    usleep(20_000)
                    continue
                }

                let percent = max(0, min(100, Int((Double(curVal) / Double(maxVal) * 100.0).rounded())))
                return (percent, maxVal)
            }
        }
        return nil
    }

    private func ddcWriteBrightness(_ percent: Int, maxVal: Int) -> Bool {
        guard let writeI2C = avWriteI2CFn else {
            return false
        }

        let clampedMax = max(1, maxVal)
        let rawVal = max(0, min(clampedMax, Int((Double(percent) / 100.0 * Double(clampedMax)).rounded())))
        let hi = UInt8((rawVal >> 8) & 0xFF)
        let lo = UInt8(rawVal & 0xFF)
        let chk: UInt8 = 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ hi ^ lo
        let setPacket: [UInt8] = [0x84, 0x03, 0x10, hi, lo, chk]

        var wroteAny = false
        for av in externalAVServices() {
            for _ in 0..<2 {
                var send = setPacket
                let wrc = send.withUnsafeMutableBytes { buf -> IOReturn in
                    guard let ptr = buf.baseAddress else { return kIOReturnBadArgument }
                    return writeI2C(av, 0x37, 0x51, ptr, UInt32(buf.count))
                }
                if wrc == kIOReturnSuccess {
                    wroteAny = true
                    usleep(10_000)
                    break
                }
                usleep(15_000)
            }
        }
        return wroteAny
    }

    // MARK: - Media, Touchpad & Keyboard (CGEvent)

    func mediaAction(_ action: String) {
        switch action {
        case "play-pause": postMediaKey(16) // NX_KEYTYPE_PLAY
        case "next": postMediaKey(17)       // NX_KEYTYPE_NEXT
        case "prev": postMediaKey(18)       // NX_KEYTYPE_PREVIOUS
        case "fullscreen": pressKey("f", mods: ["ctrl", "cmd"])
        default: break
        }
    }

    private func postMediaKey(_ keyType: Int32) {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xa00 : 0xb00)
            let data1 = Int((keyType << 16) | (isDown ? 0xa00 : 0xb00))
            if let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    func mouseMove(dx: Int, dy: Int) {
        let cur = CGEvent(source: nil)?.location ?? .zero
        let target = CGPoint(x: cur.x + CGFloat(dx), y: cur.y + CGFloat(dy))
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func mouseScroll(dx: Int, dy: Int) {
        CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy * 4),
            wheel2: Int32(dx * 4),
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    func mouseClick(button: String, count: Int) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let isRight = button == "right"
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let btn: CGMouseButton = isRight ? .right : .left
        for clickIndex in 1...max(1, min(count, 3)) {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: loc, mouseButton: btn)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: loc, mouseButton: btn)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up?.post(tap: .cghidEventTap)
        }
    }

    func mouseDrag(state: String) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let evType: CGEventType = state == "down" ? .leftMouseDown : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: evType, mouseCursorPosition: loc, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func typeText(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    func pressKey(_ key: String, mods: [String]) {
        guard let code = Self.keyCode(for: key.lowercased()) else {
            if key.count == 1 { typeText(key) }
            return
        }
        var flags: CGEventFlags = []
        for m in mods.map({ $0.lowercased() }) {
            switch m {
            case "cmd", "meta", "win": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Screenshot, Apps, Clipboard, URL

    /// Captures the main screen using `/usr/sbin/screencapture` and downscales/compresses it for fast LAN/Relay transfer.
    func captureScreenshotJPEG() -> (data: Data, width: Int, height: Int)? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakepc_shot_\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let exitCode = runProcess("/usr/sbin/screencapture", ["-x", "-t", "jpg", tmp.path])
        guard exitCode == 0,
              let rawData = try? Data(contentsOf: tmp),
              !rawData.isEmpty,
              let sourceRep = NSBitmapImageRep(data: rawData)
        else { return nil }

        let srcW = sourceRep.pixelsWide
        let srcH = sourceRep.pixelsHigh
        guard srcW > 0, srcH > 0 else { return nil }

        let maxWidth = 1280
        let targetW: Int
        let targetH: Int
        if srcW > maxWidth {
            targetW = maxWidth
            targetH = max(1, Int((Double(srcH) * Double(maxWidth) / Double(srcW)).rounded()))
        } else {
            targetW = srcW
            targetH = srcH
        }

        if let scaledRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            scaledRep.size = NSSize(width: targetW, height: targetH)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: scaledRep) {
                NSGraphicsContext.current = ctx
                ctx.imageInterpolation = .high
                sourceRep.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH))
            }
            NSGraphicsContext.restoreGraphicsState()
            if let compressed = scaledRep.representation(using: .jpeg, properties: [.compressionFactor: 0.62]),
               !compressed.isEmpty {
                return (compressed, targetW, targetH)
            }
        }

        if let fallback = sourceRep.representation(using: .jpeg, properties: [.compressionFactor: 0.62]),
           !fallback.isEmpty {
            return (fallback, srcW, srcH)
        }
        return (rawData, srcW, srcH)
    }

    func listRunningApps() -> [AppEntry] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { app in
                AppEntry(
                    id: String(app.processIdentifier),
                    name: app.localizedName ?? app.bundleIdentifier ?? "App",
                    icon: "app",
                    iconImage: nil
                )
            }
    }

    func closeApp(pidString: String, force: Bool) -> (Bool, String) {
        guard let pid = pid_t(pidString),
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return (false, "Application not found")
        }
        let ok = force ? app.forceTerminate() : app.terminate()
        return ok ? (true, "Application closed") : (false, "Application did not close")
    }

    func openURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return NSWorkspace.shared.open(url)
    }

    func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func getClipboard(maxChars: Int = 65536) -> (String, Bool) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if text.count > maxChars {
            return (String(text.prefix(maxChars)), true)
        }
        return (text, false)
    }

    // MARK: - Helpers

    @discardableResult
    func runProcess(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func runProcessOutput(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func keyCode(for name: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "escape": 53, "esc": 53, "tab": 48, "enter": 36, "return": 36,
            "space": 49, "backspace": 51, "delete": 117,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        ]
        return map[name]
    }
}

/// On-demand ScreenCaptureKit video (GPU-scaled JPEG) + 24 kHz mono PCM system audio streamer.
/// Automatically stops capture after 5s of inactivity so idle CPU/GPU usage stays at 0%.
final class ScreenStreamManager: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = ScreenStreamManager()

    struct StreamFrame {
        let imageData: Data
        let width: Int
        let height: Int
        let audioData: Data
        let audioSeq: Int64
        let sampleRate: Int
        let channels: Int
    }

    private let lock = NSLock()
    private let videoQueue = DispatchQueue(label: "com.wakepc.stream.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.wakepc.stream.audio", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var stream: SCStream?
    private var isStarting = false
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestFrameSeq: Int = 0
    private var cachedJPEGSeq: Int = -1
    private var cachedJPEGData = Data()
    private var cachedRelaySeq: Int = -1
    private var cachedRelayData = Data()
    private var targetWidth = 1280
    private var targetHeight = 720
    private var lastRequestAt = Date.distantPast
    private var watchdogTimer: DispatchSourceTimer?

    private let sampleRate = 24000
    private let audioCapacity = 36000
    private var audioRing = [Int16](repeating: 0, count: 36000)
    private var audioSeq: Int64 = 0

    private func hasPixelBuffer() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestPixelBuffer != nil
    }

    private func snapshotState(includeAudio: Bool, sinceSeq: Int64, viaRelay: Bool) -> (
        pb: CVPixelBuffer?, seq: Int, cachedSeq: Int, cachedImg: Data,
        w: Int, h: Int, audioBytes: Data, curAudioSeq: Int64
    ) {
        lock.lock()
        defer { lock.unlock() }
        var audioBytes = Data()
        let curAudioSeq = audioSeq
        if includeAudio && !viaRelay && curAudioSeq > 0 {
            let window: Int64
            if sinceSeq <= 0 || sinceSeq > curAudioSeq {
                window = min(curAudioSeq, 2400)
            } else {
                window = min(curAudioSeq - sinceSeq, Int64(audioCapacity / 2))
            }
            if window > 0 {
                let startSample = curAudioSeq - window
                var chunk = [Int16](repeating: 0, count: Int(window))
                for idx in 0..<Int(window) {
                    chunk[idx] = audioRing[Int((startSample + Int64(idx)) % Int64(audioCapacity))]
                }
                audioBytes = chunk.withUnsafeBytes { Data($0) }
            }
        }
        let cSeq = viaRelay ? cachedRelaySeq : cachedJPEGSeq
        let cImg = viaRelay ? cachedRelayData : cachedJPEGData
        return (latestPixelBuffer, latestFrameSeq, cSeq, cImg, targetWidth, targetHeight, audioBytes, curAudioSeq)
    }

    private func updateCachedJPEG(seq: Int, data: Data, viaRelay: Bool) {
        lock.lock()
        if viaRelay {
            cachedRelaySeq = seq
            cachedRelayData = data
        } else {
            cachedJPEGSeq = seq
            cachedJPEGData = data
        }
        lock.unlock()
    }

    private func markStartingOrRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastRequestAt = Date()
        let alreadyRunning = stream != nil || isStarting
        if !alreadyRunning {
            isStarting = true
        }
        startWatchdogLocked()
        return alreadyRunning
    }

    private func finishStart(stream newStream: SCStream?, width: Int, height: Int) {
        lock.lock()
        if let newStream {
            stream = newStream
            targetWidth = width
            targetHeight = height
        }
        isStarting = false
        lock.unlock()
    }

    func requestFrame(includeAudio: Bool, sinceSeq: Int64, viaRelay: Bool = false) async -> StreamFrame? {
        await ensureStarted()

        for _ in 0..<8 {
            if hasPixelBuffer() { break }
            try? await Task.sleep(nanoseconds: 45_000_000)
        }

        let snap = snapshotState(includeAudio: includeAudio, sinceSeq: sinceSeq, viaRelay: viaRelay)
        let jpegData: Data
        var outW = snap.w
        var outH = snap.h
        if let pb = snap.pb {
            var ciImg = CIImage(cvPixelBuffer: pb)
            var quality: CGFloat = 0.55
            if viaRelay {
                quality = 0.42
                if snap.w > 960 {
                    let scale = 960.0 / CGFloat(snap.w)
                    ciImg = ciImg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    if ciImg.extent.origin != .zero {
                        ciImg = ciImg.transformed(by: CGAffineTransform(translationX: -ciImg.extent.origin.x, y: -ciImg.extent.origin.y))
                    }
                    outW = 960
                    outH = max(1, Int((Double(snap.h) * Double(scale)).rounded()))
                }
            }
            if snap.cachedSeq == snap.seq && !snap.cachedImg.isEmpty {
                jpegData = snap.cachedImg
            } else if let encoded = ciContext.jpegRepresentation(
                of: ciImg,
                colorSpace: srgbSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            ), !encoded.isEmpty {
                jpegData = encoded
                updateCachedJPEG(seq: snap.seq, data: encoded, viaRelay: viaRelay)
            } else if let fallback = await MainActor.run(body: { MacSystemController.shared.captureScreenshotJPEG() }) {
                return StreamFrame(
                    imageData: fallback.data,
                    width: fallback.width,
                    height: fallback.height,
                    audioData: snap.audioBytes,
                    audioSeq: snap.curAudioSeq,
                    sampleRate: sampleRate,
                    channels: 1
                )
            } else {
                return nil
            }
        } else if let fallback = await MainActor.run(body: { MacSystemController.shared.captureScreenshotJPEG() }) {
            jpegData = fallback.data
            outW = fallback.width
            outH = fallback.height
        } else {
            return nil
        }

        return StreamFrame(
            imageData: jpegData,
            width: outW,
            height: outH,
            audioData: snap.audioBytes,
            audioSeq: snap.curAudioSeq,
            sampleRate: sampleRate,
            channels: 1
        )
    }

    func stop() {
        lock.lock()
        let active = stream
        stream = nil
        isStarting = false
        latestPixelBuffer = nil
        cachedJPEGSeq = -1
        cachedJPEGData = Data()
        cachedRelaySeq = -1
        cachedRelayData = Data()
        watchdogTimer?.cancel()
        watchdogTimer = nil
        lock.unlock()

        if let active {
            Task.detached {
                try? await active.stopCapture()
            }
        }
    }

    private func ensureStarted() async {
        if markStartingOrRunning() { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                finishStart(stream: nil, width: 0, height: 0)
                return
            }

            let aspect = Double(display.height) / max(1.0, Double(display.width))
            let w = min(1280, max(640, display.width))
            let h = max(360, Int((Double(w) * aspect).rounded()) & ~1)

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = w
            cfg.height = h
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 20)
            cfg.queueDepth = 3
            cfg.showsCursor = true
            cfg.capturesAudio = true
            cfg.sampleRate = sampleRate
            cfg.channelCount = 1
            cfg.excludesCurrentProcessAudio = true

            let newStream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()

            finishStart(stream: newStream, width: w, height: h)
        } catch {
            finishStart(stream: nil, width: 0, height: 0)
        }
    }

    private func startWatchdogLocked() {
        if watchdogTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = Date().timeIntervalSince(self.lastRequestAt)
            let hasStream = self.stream != nil
            self.lock.unlock()
            if hasStream && idle > 5.0 {
                self.stop()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lock.lock()
            latestPixelBuffer = pb
            latestFrameSeq += 1
            lock.unlock()

        case .audio:
            guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee
            else { return }

            var neededSize = 0
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &neededSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: nil
            )
            let listSize = max(neededSize, MemoryLayout<AudioBufferList>.size)
            let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { ablRaw.deallocate() }
            let ablPtr = ablRaw.assumingMemoryBound(to: AudioBufferList.self)

            var blockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPtr,
                bufferListSize: listSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr, ablPtr.pointee.mNumberBuffers > 0 else { return }
            let buf = ablPtr.pointee.mBuffers
            guard let dataPtr = buf.mData, buf.mDataByteSize > 0 else { return }

            let byteCount = Int(buf.mDataByteSize)
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let step = isNonInterleaved ? 1 : channels

            var samples: [Int16] = []
            if isFloat {
                let totalFloats = byteCount / MemoryLayout<Float>.size
                let floatPtr = dataPtr.assumingMemoryBound(to: Float.self)
                samples.reserveCapacity(totalFloats / step)
                var i = 0
                while i < totalFloats {
                    let clamped = max(-1.0 as Float, min(1.0 as Float, floatPtr[i]))
                    samples.append(Int16(clamped * 32767.0))
                    i += step
                }
            } else if asbd.mBitsPerChannel == 16 {
                let totalInt16 = byteCount / MemoryLayout<Int16>.size
                let intPtr = dataPtr.assumingMemoryBound(to: Int16.self)
                samples.reserveCapacity(totalInt16 / step)
                var i = 0
                while i < totalInt16 {
                    samples.append(intPtr[i])
                    i += step
                }
            }
            guard !samples.isEmpty else { return }

            lock.lock()
            for s in samples {
                audioRing[Int(audioSeq % Int64(audioCapacity))] = s
                audioSeq += 1
            }
            lock.unlock()

        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stop()
    }
}
