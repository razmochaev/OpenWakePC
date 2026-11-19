import AVFoundation
import SwiftUI

struct QRScannerSheet: View {
    let onScanned: (PCQRCode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                QRCameraControllerView { codeString in
                    if let parsed = PCQRCode.parse(from: codeString) {
                        HapticService.shared.success()
                        onScanned(parsed)
                        dismiss()
                    } else {
                        errorMessage = L10n.tr("qr_invalid_code")
                    }
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white, lineWidth: 3)
                        .frame(width: 240, height: 240)
                        .shadow(color: .black.opacity(0.4), radius: 12)
                    Spacer()
                    Text(errorMessage ?? L10n.tr("qr_hint"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 36)
                }
            }
            .navigationTitle(L10n.tr("action_scan_qr"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("action_cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct QRCameraControllerView: UIViewControllerRepresentable {
    let onCodeFound: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let ctrl = QRCameraController()
        ctrl.onCodeFound = onCodeFound
        return ctrl
    }

    func updateUIViewController(_ uiViewController: QRCameraController, context: Context) {}
}

final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeFound: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDelivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCaptureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasDelivered = false
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func configureCaptureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDelivered,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue
        else { return }
        hasDelivered = true
        session.stopRunning()
        onCodeFound?(value)
    }
}
