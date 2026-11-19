import AVFoundation
import ObjectiveC
import SwiftUI
import UIKit

// MARK: - Live Audio Player for Remote Screen Stream (24 kHz Int16 Mono PCM)

private final class LiveAudioStreamPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var configuredRate: Double = 0
    private var format: AVAudioFormat?
    private var pendingBuffers = 0

    func enqueue(pcmData: Data, sampleRate: Int, channels: Int) {
        guard !pcmData.isEmpty else { return }
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        lock.lock()
        let tooManyPending = pendingBuffers >= 8
        lock.unlock()
        if tooManyPending { return }

        let targetRate = Double(max(8000, sampleRate))
        let ch = AVAudioChannelCount(max(1, min(2, channels)))
        if configuredRate != targetRate || format == nil || !engine.isRunning {
            configure(sampleRate: targetRate, channels: ch)
        }
        guard let fmt = format,
              let pcmBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sampleCount)),
              let outPtr = pcmBuf.floatChannelData?[0]
        else { return }

        pcmBuf.frameLength = AVAudioFrameCount(sampleCount)
        pcmData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let s = Int16(littleEndian: src[i])
                outPtr[i] = Float(s) / 32768.0
            }
        }

        lock.lock()
        pendingBuffers += 1
        lock.unlock()

        player.scheduleBuffer(pcmBuf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pendingBuffers = max(0, self.pendingBuffers - 1)
            self.lock.unlock()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    func stop() {
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        lock.lock()
        pendingBuffers = 0
        lock.unlock()
    }

    private func configure(sampleRate: Double, channels: AVAudioChannelCount) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        if engine.isRunning {
            player.stop()
            engine.stop()
        }
        if let newFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false) {
            if !engine.attachedNodes.contains(player) {
                engine.attach(player)
            }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: newFmt)
            format = newFmt
            configuredRate = sampleRate
            try? engine.start()
            player.play()
        }
    }
}

// MARK: - PC Screen Viewer (Live LAN Video + System Audio + Relay Fallback)

struct PCScreenshotSheet: View {
    let profile: PCProfile
    let theme: AppTheme
    var onProfileHealed: ((PCProfile) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var network = NetworkService.shared
    @State private var currentProfile: PCProfile
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var chunkProgress: Double = 0
    @State private var errorMessage: String?
    @State private var savedToast = false
    @State private var isFullscreen = false
    @State private var isStreaming = true
    @State private var isAudioMuted = false
    @State private var streamAvailable = true
    @State private var currentFPS: Int = 0
    @State private var audioSeq: Int64 = 0
    @State private var audioPlayer = LiveAudioStreamPlayer()

    init(profile: PCProfile, theme: AppTheme, onProfileHealed: ((PCProfile) -> Void)? = nil) {
        self.profile = profile
        self.theme = theme
        self.onProfileHealed = onProfileHealed
        self._currentProfile = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImageView(image: image) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isFullscreen.toggle()
                        }
                    }
                    .ignoresSafeArea()

                    if !isFullscreen {
                        VStack {
                            HStack {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isStreaming && streamAvailable ? Color.red : Color.gray)
                                        .frame(width: 7, height: 7)
                                    Text(isStreaming && streamAvailable ? L10n.tr("stream_live_badge") : L10n.tr("stream_paused_badge"))
                                        .font(.caption2.weight(.bold))
                                    Text("• \(network.lastUsedRoute == .lan ? "LAN" : "Relay")")
                                        .font(.caption2.weight(.medium))
                                        .opacity(0.85)
                                    if isStreaming && streamAvailable && currentFPS > 0 {
                                        Text("\(currentFPS) FPS")
                                            .font(.caption2.monospacedDigit())
                                            .opacity(0.75)
                                    }
                                    if isStreaming && streamAvailable && network.lastUsedRoute == .lan && !isAudioMuted {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.caption2)
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.65), in: Capsule())
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView(value: chunkProgress > 0 ? chunkProgress : nil)
                            .tint(theme.accentColor)
                            .frame(width: 180)
                        Text(L10n.tr("screenshot_loading"))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle(L10n.tr("tool_screenshot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(isFullscreen)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isStreaming.toggle()
                        if !isStreaming {
                            currentFPS = 0
                            audioPlayer.stop()
                            Task { await NetworkService.shared.stopStream(profile: currentProfile) }
                        }
                    } label: {
                        Image(systemName: isStreaming ? "pause.fill" : "play.fill")
                    }

                    Button {
                        isAudioMuted.toggle()
                        if isAudioMuted {
                            audioPlayer.stop()
                        }
                    } label: {
                        Image(systemName: isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }

                    if let image {
                        Button {
                            SaveToPhotosHelper.save(image) { ok in
                                if ok {
                                    HapticService.shared.success()
                                    savedToast = true
                                }
                            }
                        } label: {
                            Image(systemName: savedToast ? "checkmark.circle.fill" : "square.and.arrow.down")
                        }
                    }

                    Button {
                        if !isStreaming {
                            isStreaming = true
                        } else {
                            Task { await loadScreenshot() }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task(id: isStreaming) {
                if isStreaming {
                    await runLiveStreamLoop()
                } else if image == nil {
                    await loadScreenshot()
                }
            }
            .onDisappear {
                isStreaming = false
                audioPlayer.stop()
                Task { await NetworkService.shared.stopStream(profile: currentProfile) }
            }
        }
    }

    private func runLiveStreamLoop() async {
        isLoading = (image == nil)
        errorMessage = nil
        var failures = 0
        var lastStreamHealAt: Date = .distantPast
        var fpsCount = 0
        var fpsWindowStart = Date()

        while !Task.isCancelled && isStreaming {
            do {
                let wantAudio = !isAudioMuted && network.lastUsedRoute == .lan
                let frame = try await NetworkService.shared.fetchStreamFrame(
                    profile: currentProfile,
                    includeAudio: wantAudio,
                    sinceSeq: audioSeq
                )
                failures = 0
                streamAvailable = true
                isLoading = false
                errorMessage = nil
                image = frame.image
                audioSeq = frame.audioSeq

                fpsCount += 1
                let elapsed = Date().timeIntervalSince(fpsWindowStart)
                if elapsed >= 1.0 {
                    currentFPS = Int((Double(fpsCount) / elapsed).rounded())
                    fpsCount = 0
                    fpsWindowStart = Date()
                }

                if wantAudio, frame.isLAN, let pcm = frame.audioData, !pcm.isEmpty {
                    audioPlayer.enqueue(pcmData: pcm, sampleRate: frame.audioRate, channels: frame.audioChannels)
                }
                let delayNs: UInt64 = frame.isLAN ? 30_000_000 : 900_000_000
                try? await Task.sleep(nanoseconds: delayNs)
            } catch {
                failures += 1
                currentFPS = 0
                if failures >= 3,
                   network.interfaces.wifi,
                   Date().timeIntervalSince(lastStreamHealAt) >= 15.0 {
                    lastStreamHealAt = Date()
                    if let healed = await LANAddressHealer.heal(profile: currentProfile) {
                        var updated = currentProfile
                        updated.ip = healed.ip
                        updated.apiPort = healed.port
                        updated.broadcast = healed.broadcast
                        if let healedMAC = healed.mac, PCQRCode.isValidMAC(healedMAC) {
                            updated.mac = healedMAC.uppercased()
                        }
                        if let healedToken = healed.token, !healedToken.isEmpty {
                            updated.token = healedToken
                        }
                        if (updated.deviceId ?? "").isEmpty, let healedDeviceId = healed.deviceId, !healedDeviceId.isEmpty {
                            updated.deviceId = healedDeviceId
                        }
                        if updated.ip != currentProfile.ip || updated.token != currentProfile.token {
                            currentProfile = updated
                            NetworkService.shared.invalidateRouteCache(for: updated.id)
                            onProfileHealed?(updated)
                            failures = 0
                            continue
                        }
                    }
                }
                if failures == 1 || image == nil {
                    if let shot = try? await NetworkService.shared.fetchScreenshot(profile: currentProfile) {
                        image = shot
                        isLoading = false
                        streamAvailable = true
                        errorMessage = nil
                    } else if image == nil && failures >= 2 {
                        isLoading = false
                        errorMessage = error.localizedDescription
                    }
                }
                let backoffNs: UInt64 = failures >= 3 ? 1_500_000_000 : 600_000_000
                try? await Task.sleep(nanoseconds: backoffNs)
            }
        }
    }

    private func loadScreenshot() async {
        isLoading = true
        errorMessage = nil
        chunkProgress = 0
        savedToast = false
        defer { isLoading = false }
        do {
            image = try await NetworkService.shared.fetchScreenshot(profile: currentProfile) { progress in
                chunkProgress = progress
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap)
    }

    func makeUIView(context: Context) -> ZoomableScrollView {
        let scroll = ZoomableScrollView()
        scroll.delegate = context.coordinator
        scroll.backgroundColor = .black
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 5.0
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.setImage(image)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateUIView(_ uiView: ZoomableScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        uiView.setImage(image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: ZoomableScrollView?
        var onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomableScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomableScrollView)?.centerImageView()
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.05 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: scrollView.imageView)
                let size = CGSize(
                    width: scrollView.bounds.width / 2.5,
                    height: scrollView.bounds.height / 2.5
                )
                let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
                scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
            }
        }
    }
}

private final class ZoomableScrollView: UIScrollView {
    let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ newImage: UIImage) {
        guard imageView.image !== newImage else { return }
        let prevSize = imageView.image?.size
        imageView.image = newImage
        if lastBoundsSize != .zero,
           imageView.frame.size.width > 1,
           imageView.frame.size.height > 1,
           let prevSize,
           prevSize == newImage.size {
            return
        }
        zoomScale = 1.0
        lastBoundsSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size.width > 0, bounds.size.height > 0 else { return }
        if abs(bounds.size.width - lastBoundsSize.width) > 0.5 || abs(bounds.size.height - lastBoundsSize.height) > 0.5 {
            lastBoundsSize = bounds.size
            fitImageToBounds()
        }
    }

    private func fitImageToBounds() {
        guard let img = imageView.image, img.size.width > 0, img.size.height > 0,
              bounds.width > 0, bounds.height > 0
        else { return }

        zoomScale = 1.0
        let widthRatio = bounds.width / img.size.width
        let heightRatio = bounds.height / img.size.height
        let scale = min(widthRatio, heightRatio)
        let fittedSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)

        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        centerImageView()
    }

    func centerImageView() {
        let offsetX = max((bounds.width - contentSize.width) * 0.5, 0)
        let offsetY = max((bounds.height - contentSize.height) * 0.5, 0)
        if abs(contentInset.top - offsetY) > 0.5
            || abs(contentInset.left - offsetX) > 0.5
            || abs(contentInset.bottom - offsetY) > 0.5
            || abs(contentInset.right - offsetX) > 0.5 {
            contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        }
    }
}

final class SaveToPhotosHelper: NSObject {
    private var completion: ((Bool) -> Void)?

    static func save(_ image: UIImage, completion: @escaping (Bool) -> Void) {
        let helper = SaveToPhotosHelper()
        helper.completion = completion
        UIImageWriteToSavedPhotosAlbum(image, helper, #selector(didFinish(_:didFinishSavingWithError:contextInfo:)), nil)
        // Retain briefly until callback fires
        objc_setAssociatedObject(image, "SaveToPhotosHelper", helper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc private func didFinish(
        _ image: UIImage,
        didFinishSavingWithError error: Error?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        completion?(error == nil)
        objc_setAssociatedObject(image, "SaveToPhotosHelper", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - Running Apps Sheet (Soft & Force Close)

struct RunningAppsSheet: View {
    let profile: PCProfile

    @Environment(\.dismiss) private var dismiss
    @State private var apps: [RunningAppInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var forceCloseTarget: RunningAppInfo?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(apps) { app in
                    HStack {
                        Image(systemName: app.icon ?? "app")
                            .frame(width: 26)
                        Text(app.name)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await closeApp(app, force: false) }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                    }
                }
            }
            .overlay {
                if isLoading && apps.isEmpty { ProgressView() }
            }
            .navigationTitle(L10n.tr("tool_running_apps"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await load() }
            .alert(L10n.tr("apps_force_close_title"), isPresented: Binding(
                get: { forceCloseTarget != nil },
                set: { if !$0 { forceCloseTarget = nil } }
            )) {
                Button(L10n.tr("action_cancel"), role: .cancel) { forceCloseTarget = nil }
                Button(L10n.tr("apps_force_close_btn"), role: .destructive) {
                    if let target = forceCloseTarget {
                        Task { await closeApp(target, force: true) }
                    }
                }
            } message: {
                Text(L10n.tr("apps_force_close_msg", forceCloseTarget?.name ?? ""))
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            apps = try await NetworkService.shared.fetchRunningApps(profile: profile)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeApp(_ app: RunningAppInfo, force: Bool) async {
        do {
            let resp = try await NetworkService.shared.closeApp(id: app.id, force: force, on: profile)
            if resp.success {
                apps.removeAll { $0.id == app.id }
                HapticService.shared.success()
            } else if !force {
                forceCloseTarget = app
            } else {
                errorMessage = resp.message
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Audio Outputs Sheet

struct AudioOutputSheet: View {
    let profile: PCProfile
    @Environment(\.dismiss) private var dismiss
    @State private var outputs: [AudioOutputInfo] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List(outputs) { output in
                Button {
                    Task {
                        if let resp = try? await NetworkService.shared.setAudioOutput(id: output.id, on: profile),
                           let updated = resp.data?.outputs {
                            outputs = updated
                            HapticService.shared.success()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                        Text(output.name)
                        Spacer()
                        if output.isDefault {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
            }
            .overlay { if isLoading && outputs.isEmpty { ProgressView() } }
            .navigationTitle(L10n.tr("audio_outputs_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
            }
            .task {
                isLoading = true
                outputs = (try? await NetworkService.shared.fetchAudioOutputs(profile: profile)) ?? []
                isLoading = false
            }
        }
    }
}

// MARK: - Audio Inputs Sheet (Microphone Device Picker)

struct AudioInputSheet: View {
    let profile: PCProfile
    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [AudioOutputInfo] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List(inputs) { input in
                Button {
                    Task {
                        if let resp = try? await NetworkService.shared.setAudioInput(id: input.id, on: profile),
                           let updated = resp.data?.inputs {
                            inputs = updated
                            HapticService.shared.success()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "mic.fill")
                        Text(input.name)
                        Spacer()
                        if input.isDefault {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        }
                    }
                }
            }
            .overlay { if isLoading && inputs.isEmpty { ProgressView() } }
            .navigationTitle(L10n.tr("audio_inputs_title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
            }
            .task {
                isLoading = true
                inputs = (try? await NetworkService.shared.fetchAudioInputs(profile: profile)) ?? []
                isLoading = false
            }
        }
    }
}

// MARK: - Power Confirmation & Schedule Sheets

struct PowerConfirmSheet: View {
    let command: PowerCommand
    let pcName: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: command == .shutdown ? "power" : "arrow.clockwise")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.red)
                .padding(.top, 24)

            Text(command == .shutdown ? L10n.tr("confirm_shutdown_title") : L10n.tr("confirm_restart_title"))
                .font(.title3.bold())

            Text(L10n.tr("confirm_power_body", pcName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button(L10n.tr("action_cancel")) { dismiss() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                Button(role: .destructive) {
                    dismiss()
                    onConfirm()
                } label: {
                    Text(L10n.tr("action_confirm"))
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .presentationDetents([.height(280)])
    }
}

struct ScheduleActionSheet: View {
    let action: ScheduleAction
    let supportsIdleAction: Bool
    let onScheduleMinutes: (Int) -> Void
    let onIdleFinish: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hours: Int = 0
    @State private var minutes: Int = 30
    @State private var idleMinutes: Int = 10

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("schedule_timer_section")) {
                    Stepper("\(L10n.tr("unit_hours")): \(hours)", value: $hours, in: 0...23)
                    Stepper("\(L10n.tr("unit_minutes")): \(minutes)", value: $minutes, in: 0...59, step: 5)

                    Button {
                        let total = max(1, hours * 60 + minutes)
                        onScheduleMinutes(total)
                        dismiss()
                    } label: {
                        Label(L10n.tr("schedule_start_btn"), systemImage: "timer")
                    }
                }

                if supportsIdleAction {
                    Section {
                        Stepper("\(L10n.tr("idle_minutes_label")): \(idleMinutes)", value: $idleMinutes, in: 5...120, step: 5)
                        Button {
                            onIdleFinish(idleMinutes)
                            dismiss()
                        } label: {
                            Label(L10n.tr("idle_finish_btn"), systemImage: "hourglass")
                        }
                    } header: {
                        Text(L10n.tr("idle_section_title"))
                    } footer: {
                        Text(L10n.tr("idle_section_footer"))
                    }
                }
            }
            .navigationTitle("\(L10n.tr("schedule_title")) (\(action.rawValue.capitalized))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("action_cancel")) { dismiss() }
                }
            }
        }
    }
}
