import SwiftUI
import UIKit

struct TouchpadSheet: View {
    let profile: PCProfile
    let theme: AppTheme

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TouchpadModel
    @State private var showKeyboard = false

    struct Hotkey: Identifiable {
        let id = UUID()
        let title: String
        let key: String
        let mods: [String]
    }

    init(profile: PCProfile, theme: AppTheme) {
        self.profile = profile
        self.theme = theme
        _model = StateObject(wrappedValue: TouchpadModel(profile: profile))
    }

    private var hotkeys: [Hotkey] {
        let isMac = profile.deviceType == .mac
        return [
            Hotkey(title: "Esc", key: "escape", mods: []),
            Hotkey(title: "Tab", key: "tab", mods: []),
            Hotkey(title: isMac ? "⌘Tab" : "Alt+Tab", key: "tab", mods: isMac ? ["cmd"] : ["alt"]),
            Hotkey(title: isMac ? "⌘C" : "Ctrl+C", key: "c", mods: isMac ? ["cmd"] : ["ctrl"]),
            Hotkey(title: isMac ? "⌘V" : "Ctrl+V", key: "v", mods: isMac ? ["cmd"] : ["ctrl"]),
            Hotkey(title: isMac ? "⌘W" : "Ctrl+W", key: "w", mods: isMac ? ["cmd"] : ["ctrl"]),
            Hotkey(title: "←", key: "left", mods: []),
            Hotkey(title: "↑", key: "up", mods: []),
            Hotkey(title: "↓", key: "down", mods: []),
            Hotkey(title: "→", key: "right", mods: []),
            Hotkey(title: "Enter", key: "enter", mods: []),
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if model.lanUnavailable {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(L10n.tr("touchpad_lan_only_banner"))
                            .font(.caption)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                // Hotkeys strip (works over LAN & Relay)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(hotkeys) { hk in
                            Button(hk.title) {
                                model.pressKey(hk.key, mods: hk.mods)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.horizontal)
                }

                // Interactive multi-touch surface + UIKeyInput bridge
                TouchpadSurfaceRepresentable(
                    model: model,
                    keyboardActive: $showKeyboard
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(theme.accentColor.opacity(0.35), lineWidth: 1.5)
                )
                .overlay {
                    if !showKeyboard {
                        VStack(spacing: 12) {
                            Image(systemName: "hand.point.up.left.fill")
                                .font(.title2)
                                .foregroundStyle(theme.accentColor.opacity(0.75))

                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                                gesturePill(icon: "hand.point.up", title: L10n.tr("touchpad_g1_title"), sub: L10n.tr("touchpad_g1_sub"))
                                gesturePill(icon: "scroll", title: L10n.tr("touchpad_g2_title"), sub: L10n.tr("touchpad_g2_sub"))
                                gesturePill(icon: "hand.tap", title: L10n.tr("touchpad_g3_title"), sub: L10n.tr("touchpad_g3_sub"))
                                gesturePill(icon: "hand.draw", title: L10n.tr("touchpad_g4_title"), sub: L10n.tr("touchpad_g4_sub"))
                            }
                            .padding(.horizontal, 18)
                        }
                        .opacity(0.55)
                        .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal)

                // Explicit Left / Keyboard / Right buttons
                HStack(spacing: 12) {
                    Button {
                        model.click(button: "left", count: 1)
                    } label: {
                        Text(L10n.tr("touchpad_left_click"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(model.lanUnavailable)

                    Button {
                        showKeyboard.toggle()
                    } label: {
                        Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                            .font(.title3)
                            .frame(width: 56, height: 48)
                            .background(theme.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        model.click(button: "right", count: 1)
                    } label: {
                        Text(L10n.tr("touchpad_right_click"))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(model.lanUnavailable)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .navigationTitle(L10n.tr("tool_touchpad"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) {
                        model.stop()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                model.stop()
            }
        }
    }

    private func gesturePill(icon: String, title: String, sub: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(theme.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TouchpadSurfaceRepresentable: UIViewRepresentable {
    let model: TouchpadModel
    @Binding var keyboardActive: Bool

    func makeUIView(context: Context) -> TouchpadSurfaceView {
        let view = TouchpadSurfaceView()
        view.model = model
        view.onKeyboardDismissed = {
            DispatchQueue.main.async { keyboardActive = false }
        }
        return view
    }

    func updateUIView(_ uiView: TouchpadSurfaceView, context: Context) {
        if keyboardActive && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !keyboardActive && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

final class TouchpadSurfaceView: UIView, UIKeyInput {
    weak var model: TouchpadModel?
    var onKeyboardDismissed: (() -> Void)?

    private var lastPanPoint: CGPoint = .zero
    private var lastScrollPoint: CGPoint = .zero
    private var isDragging = false

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTouchesRequired = 1
        singleTap.numberOfTapsRequired = 1
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        addGestureRecognizer(twoFingerTap)

        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        addGestureRecognizer(oneFingerPan)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerScroll(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingerPan)

        let dragGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        dragGesture.numberOfTapsRequired = 1
        dragGesture.minimumPressDuration = 0.25
        addGestureRecognizer(dragGesture)
    }

    @objc private func handleSingleTap() {
        model?.click(button: "left", count: 1)
    }

    @objc private func handleTwoFingerTap() {
        model?.click(button: "right", count: 1)
    }

    @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        let loc = gesture.location(in: self)
        switch gesture.state {
        case .began:
            lastPanPoint = loc
        case .changed:
            let dx = loc.x - lastPanPoint.x
            let dy = loc.y - lastPanPoint.y
            lastPanPoint = loc
            model?.move(dx: dx, dy: dy)
        default:
            break
        }
    }

    @objc private func handleTwoFingerScroll(_ gesture: UIPanGestureRecognizer) {
        let loc = gesture.location(in: self)
        switch gesture.state {
        case .began:
            lastScrollPoint = loc
        case .changed:
            let dx = (loc.x - lastScrollPoint.x) / 6.0
            let dy = (loc.y - lastScrollPoint.y) / 6.0
            lastScrollPoint = loc
            model?.scroll(dx: dx, dy: dy)
        default:
            break
        }
    }

    @objc private func handleDrag(_ gesture: UILongPressGestureRecognizer) {
        let loc = gesture.location(in: self)
        switch gesture.state {
        case .began:
            isDragging = true
            lastPanPoint = loc
            model?.drag(down: true)
        case .changed:
            let dx = loc.x - lastPanPoint.x
            let dy = loc.y - lastPanPoint.y
            lastPanPoint = loc
            model?.move(dx: dx, dy: dy)
        case .ended, .cancelled, .failed:
            if isDragging {
                isDragging = false
                model?.drag(down: false)
            }
        default:
            break
        }
    }

    // MARK: - UIKeyInput

    func insertText(_ text: String) {
        if text == "\n" {
            model?.pressKey("enter")
        } else {
            model?.sendText(text)
        }
    }

    func deleteBackward() {
        model?.pressKey("backspace")
    }
}
