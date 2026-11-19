import SwiftUI
import WidgetKit

// MARK: - iOS 18 Control Center Controls (100% Free)

@available(iOS 18.0, *)
struct WakePCControl: ControlWidget {
    static let kind = "org.openwakepc.control.wake"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: WakeControlIntent()) {
                Label("OpenWakePC", systemImage: "power")
            }
        }
        .displayName("OpenWakePC")
        .description("Send Wake-on-LAN to your active computer.")
    }
}

@available(iOS 18.0, *)
struct SleepPCControl: ControlWidget {
    static let kind = "org.openwakepc.control.sleep"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SleepControlIntent()) {
                Label("Sleep PC", systemImage: "moon.zzz.fill")
            }
        }
        .displayName("Sleep PC")
        .description("Put your active computer to sleep.")
    }
}

@available(iOS 18.0, *)
struct ShutdownPCControl: ControlWidget {
    static let kind = "org.openwakepc.control.shutdown"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ShutdownControlIntent()) {
                Label("Shut Down PC", systemImage: "power.circle.fill")
            }
        }
        .displayName("Shut Down PC")
        .description("Shut down your active computer.")
    }
}

@available(iOS 18.0, *)
struct MutePCControl: ControlWidget {
    static let kind = "org.openwakepc.control.mute"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: MuteControlIntent()) {
                Label("Mute PC", systemImage: "speaker.slash.fill")
            }
        }
        .displayName("Mute PC")
        .description("Toggle mute on your active computer.")
    }
}
