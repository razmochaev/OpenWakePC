import Darwin
import SwiftUI

public enum ButtonDecor: String, CaseIterable, Codable, Sendable {
    case palms
    case money
    case sun
    case wanted
    case police
    case birds
}

/// Complete catalog of all 21 OpenWakePC themes — 100% free, zero paywall.
public struct AppTheme: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let emoji: String
    public let colors: [Color]
    public let accentColor: Color
    public let backgroundColor: Color
    public let backgroundEndColor: Color
    public let backgroundIsLight: Bool
    public let isAnimated: Bool
    public let buttonDecor: ButtonDecor?

    public var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    public static let all: [AppTheme] = [
        AppTheme(
            id: "aura", name: "Aura", emoji: "✨",
            colors: [Color(hex: 0x6366F1), Color(hex: 0xA855F7)],
            accentColor: Color(hex: 0x8B5CF6),
            backgroundColor: Color(hex: 0x0F1021), backgroundEndColor: Color(hex: 0x1E1B4B),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "aurora", name: "Aurora", emoji: "🌌",
            colors: [Color(hex: 0x06B6D4), Color(hex: 0x10B981), Color(hex: 0x6366F1)],
            accentColor: Color(hex: 0x14B8A6),
            backgroundColor: Color(hex: 0x061622), backgroundEndColor: Color(hex: 0x0B2E2E),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "black", name: "Obsidian", emoji: "🖤",
            colors: [Color(hex: 0x27272A), Color(hex: 0x09090B)],
            accentColor: Color(hex: 0xE4E4E7),
            backgroundColor: Color(hex: 0x000000), backgroundEndColor: Color(hex: 0x111113),
            backgroundIsLight: false, isAnimated: false, buttonDecor: nil
        ),
        AppTheme(
            id: "dark", name: "Midnight", emoji: "🌙",
            colors: [Color(hex: 0x1E293B), Color(hex: 0x0F172A)],
            accentColor: Color(hex: 0x38BDF8),
            backgroundColor: Color(hex: 0x0B1120), backgroundEndColor: Color(hex: 0x1E293B),
            backgroundIsLight: false, isAnimated: false, buttonDecor: nil
        ),
        AppTheme(
            id: "diamond", name: "Diamond", emoji: "💎",
            colors: [Color(hex: 0xBAE6FD), Color(hex: 0xE0F2FE), Color(hex: 0xC7D2FE)],
            accentColor: Color(hex: 0x0284C7),
            backgroundColor: Color(hex: 0xF0F9FF), backgroundEndColor: Color(hex: 0xE0E7FF),
            backgroundIsLight: true, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "fire", name: "Ember", emoji: "🔥",
            colors: [Color(hex: 0xEF4444), Color(hex: 0xF97316)],
            accentColor: Color(hex: 0xF97316),
            backgroundColor: Color(hex: 0x1C0A09), backgroundEndColor: Color(hex: 0x3B100A),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "forest", name: "Forest", emoji: "🌲",
            colors: [Color(hex: 0x15803D), Color(hex: 0x059669)],
            accentColor: Color(hex: 0x22C55E),
            backgroundColor: Color(hex: 0x071A10), backgroundEndColor: Color(hex: 0x103320),
            backgroundIsLight: false, isAnimated: false, buttonDecor: nil
        ),
        AppTheme(
            id: "galaxy", name: "Galaxy", emoji: "🪐",
            colors: [Color(hex: 0x4C1D95), Color(hex: 0x9333EA), Color(hex: 0xEC4899)],
            accentColor: Color(hex: 0xC084FC),
            backgroundColor: Color(hex: 0x090418), backgroundEndColor: Color(hex: 0x240C42),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "golden", name: "Golden", emoji: "🏆",
            colors: [Color(hex: 0xD97706), Color(hex: 0xF59E0B), Color(hex: 0xFDE047)],
            accentColor: Color(hex: 0xF59E0B),
            backgroundColor: Color(hex: 0x1A1305), backgroundEndColor: Color(hex: 0x332408),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "grape", name: "Grape", emoji: "🍇",
            colors: [Color(hex: 0x7E22CE), Color(hex: 0xA21CAF)],
            accentColor: Color(hex: 0xD946EF),
            backgroundColor: Color(hex: 0x160722), backgroundEndColor: Color(hex: 0x2D0D45),
            backgroundIsLight: false, isAnimated: false, buttonDecor: nil
        ),
        AppTheme(
            id: "miami", name: "VI Miami", emoji: "🌴",
            colors: [Color(hex: 0xFF4D94), Color(hex: 0xFF8C42), Color(hex: 0x5B21B6)],
            accentColor: Color(hex: 0xFF4D94),
            backgroundColor: Color(hex: 0x1B082B), backgroundEndColor: Color(hex: 0x4C1347),
            backgroundIsLight: false, isAnimated: true, buttonDecor: .palms
        ),
        AppTheme(
            id: "mint", name: "Mint", emoji: "🌿",
            colors: [Color(hex: 0x34D399), Color(hex: 0x2DD4BF)],
            accentColor: Color(hex: 0x0D9488),
            backgroundColor: Color(hex: 0xECFDF5), backgroundEndColor: Color(hex: 0xCCFBF1),
            backgroundIsLight: true, isAnimated: false, buttonDecor: nil
        ),
        AppTheme(
            id: "neon", name: "Cyberpunk", emoji: "⚡",
            colors: [Color(hex: 0x00F5D4), Color(hex: 0xF15BB5), Color(hex: 0xFEE440)],
            accentColor: Color(hex: 0x00F5D4),
            backgroundColor: Color(hex: 0x090814), backgroundEndColor: Color(hex: 0x1A0B2E),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "ocean", name: "Ocean", emoji: "🌊",
            colors: [Color(hex: 0x0284C7), Color(hex: 0x06B6D4)],
            accentColor: Color(hex: 0x38BDF8),
            backgroundColor: Color(hex: 0x061A2B), backgroundEndColor: Color(hex: 0x0C3554),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "peachy", name: "Peachy", emoji: "🍑",
            colors: [Color(hex: 0xFB923C), Color(hex: 0xFDA4AF)],
            accentColor: Color(hex: 0xEA580C),
            backgroundColor: Color(hex: 0xFFF7ED), backgroundEndColor: Color(hex: 0xFFE4E6),
            backgroundIsLight: true, isAnimated: false, buttonDecor: nil
        ),
        AppTheme(
            id: "rainbow", name: "Prism", emoji: "🌈",
            colors: [Color(hex: 0xEF4444), Color(hex: 0xF59E0B), Color(hex: 0x10B981), Color(hex: 0x3B82F6), Color(hex: 0x8B5CF6)],
            accentColor: Color(hex: 0xEC4899),
            backgroundColor: Color(hex: 0x120F24), backgroundEndColor: Color(hex: 0x1F183B),
            backgroundIsLight: false, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "sakura", name: "Sakura", emoji: "🌸",
            colors: [Color(hex: 0xF472B6), Color(hex: 0xFBCFE8)],
            accentColor: Color(hex: 0xDB2777),
            backgroundColor: Color(hex: 0xFDF2F8), backgroundEndColor: Color(hex: 0xFCE7F3),
            backgroundIsLight: true, isAnimated: true, buttonDecor: nil
        ),
        AppTheme(
            id: "sapphire", name: "Sapphire", emoji: "🔷",
            colors: [Color(hex: 0x1D4ED8), Color(hex: 0x3B82F6)],
            accentColor: Color(hex: 0x60A5FA),
            backgroundColor: Color(hex: 0x071330), backgroundEndColor: Color(hex: 0x10275C),
            backgroundIsLight: false, isAnimated: false, buttonDecor: nil
        ),
        AppTheme(
            id: "sunset", name: "Sunset", emoji: "🌅",
            colors: [Color(hex: 0xF43F5E), Color(hex: 0xFB923C), Color(hex: 0xFACC15)],
            accentColor: Color(hex: 0xFB7185),
            backgroundColor: Color(hex: 0x1F0C19), backgroundEndColor: Color(hex: 0x3D1528),
            backgroundIsLight: false, isAnimated: true, buttonDecor: .sun
        ),
        AppTheme(
            id: "tropical", name: "Tropical", emoji: "🌺",
            colors: [Color(hex: 0x10B981), Color(hex: 0x06B6D4), Color(hex: 0xF59E0B)],
            accentColor: Color(hex: 0x2DD4BF),
            backgroundColor: Color(hex: 0x072124), backgroundEndColor: Color(hex: 0x103B3D),
            backgroundIsLight: false, isAnimated: true, buttonDecor: .birds
        ),
        AppTheme(
            id: "whiskey", name: "Whiskey", emoji: "🥃",
            colors: [Color(hex: 0x92400E), Color(hex: 0xD97706)],
            accentColor: Color(hex: 0xF59E0B),
            backgroundColor: Color(hex: 0x170E08), backgroundEndColor: Color(hex: 0x2E1C10),
            backgroundIsLight: false, isAnimated: false, buttonDecor: nil
        ),
    ]

    public static func theme(for id: String) -> AppTheme {
        all.first(where: { $0.id == id }) ?? all[0]
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Decorative Shapes & Theme Views

public struct PalmShape: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let trunkBase = CGPoint(x: rect.midX, y: rect.maxY)
        let crown = CGPoint(x: rect.midX + rect.width * 0.08, y: rect.minY + rect.height * 0.35)
        path.move(to: trunkBase)
        path.addQuadCurve(to: crown, control: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.midY))
        for angle in stride(from: -150.0, through: 30.0, by: 36.0) {
            let rad: Double = angle * Double.pi / 180.0
            let tip = CGPoint(
                x: crown.x + CGFloat(Darwin.cos(rad)) * rect.width * 0.42,
                y: crown.y + CGFloat(Darwin.sin(rad)) * rect.height * 0.32
            )
            path.move(to: crown)
            path.addQuadCurve(to: tip, control: CGPoint(x: (crown.x + tip.x) / 2, y: min(crown.y, tip.y) - 8))
        }
        return path
    }
}

public struct BirdShape: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY * 0.75),
            control: CGPoint(x: rect.width * 0.25, y: rect.minY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.width * 0.75, y: rect.minY)
        )
        return path
    }
}

public struct ThemeBackdrop: View {
    public let theme: AppTheme
    @State private var pulse = false

    public init(theme: AppTheme) {
        self.theme = theme
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.backgroundColor, theme.backgroundEndColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(theme.accentColor.opacity(theme.backgroundIsLight ? 0.16 : 0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: pulse ? -60 : 60, y: pulse ? -160 : -110)

            Circle()
                .fill((theme.colors.last ?? theme.accentColor).opacity(theme.backgroundIsLight ? 0.12 : 0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 85)
                .offset(x: pulse ? 70 : -50, y: pulse ? 210 : 160)
        }
        .ignoresSafeArea()
        .onAppear {
            guard theme.isAnimated else { return }
            withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }
}

public struct ThemeButtonArt: View {
    public let decor: ButtonDecor

    public init(decor: ButtonDecor) {
        self.decor = decor
    }

    public var body: some View {
        ZStack {
            switch decor {
            case .palms:
                PalmShape()
                    .stroke(.white.opacity(0.22), lineWidth: 2)
                    .frame(width: 72, height: 72)
                    .offset(x: 42, y: 24)
            case .birds:
                BirdShape()
                    .stroke(.white.opacity(0.28), lineWidth: 2)
                    .frame(width: 32, height: 14)
                    .offset(x: -36, y: -28)
            case .sun:
                Circle()
                    .fill(.yellow.opacity(0.2))
                    .frame(width: 56, height: 56)
                    .offset(x: 34, y: -30)
            case .money, .wanted, .police:
                Image(systemName: decor == .wanted ? "star.fill" : (decor == .money ? "dollarsign.circle" : "shield.fill"))
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.16))
                    .offset(x: 36, y: 28)
            }
        }
    }
}

public struct GlassPressButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
