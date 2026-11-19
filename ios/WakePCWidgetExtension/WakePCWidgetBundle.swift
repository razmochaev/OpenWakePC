import SwiftUI
import WidgetKit

@main
struct WakePCWidgetBundle: WidgetBundle {
    var body: some Widget {
        WakePCWidget()
        WakePCLockScreenWidget()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        WakePCWakeLiveActivity()
        WakePCWidgetLiveActivity()
        #endif
        if #available(iOS 18.0, *) {
            WakePCControl()
            SleepPCControl()
            ShutdownPCControl()
            MutePCControl()
        }
    }
}
