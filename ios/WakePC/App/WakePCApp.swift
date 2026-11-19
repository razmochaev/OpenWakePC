import SwiftUI

@main
struct WakePCApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @AppStorage("appearanceOverride") private var appearanceOverride: String = "system"
    @AppStorage("selectedTheme") private var selectedThemeId: String = "aura"

    @State private var showSplash = true
    @State private var incomingQRCode: PCQRCode?

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(incomingQRCode: $incomingQRCode)
                    .preferredColorScheme(resolvedColorScheme)
                    .onOpenURL { url in
                        if let qr = PCQRCode.parse(from: url.absoluteString) {
                            incomingQRCode = qr
                        }
                    }

                if showSplash {
                    SplashScreenView(theme: AppTheme.theme(for: selectedThemeId))
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                WatchSyncService.shared.activate()
                try? await Task.sleep(nanoseconds: 550_000_000)
                withAnimation(.easeOut(duration: 0.35)) {
                    showSplash = false
                }
            }
        }
    }

    private var resolvedColorScheme: ColorScheme? {
        switch appearanceOverride {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct SplashScreenView: View {
    let theme: AppTheme
    @State private var scale: CGFloat = 0.88

    var body: some View {
        ZStack {
            ThemeBackdrop(theme: theme)
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(theme.gradient)
                        .frame(width: 96, height: 96)
                        .shadow(color: theme.accentColor.opacity(0.45), radius: 22, y: 8)
                    Image(systemName: "power")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(scale)

                Text("OpenWakePC")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.backgroundIsLight ? .black : .white)

                Text(L10n.tr("splash_subtitle_free"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle((theme.backgroundIsLight ? Color.black : Color.white).opacity(0.68))
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                scale = 1.0
            }
        }
    }
}
