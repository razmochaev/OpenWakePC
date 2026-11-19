import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SendToPCSheet: View {
    let profile: PCProfile
    let theme: AppTheme

    @Environment(\.dismiss) private var dismiss

    struct UploadItem: Identifiable {
        let id = UUID()
        let filename: String
        var progress: Double = 0
        var isDone: Bool = false
        var error: String?
    }

    @State private var inputText = ""
    @State private var statusMessage: String?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var uploads: [UploadItem] = []

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("send_text_section")) {
                    TextField(L10n.tr("send_text_placeholder"), text: $inputText, axis: .vertical)
                        .lineLimit(2...5)

                    HStack {
                        Button {
                            sendTextOrURL()
                        } label: {
                            Label(
                                looksLikeURL(inputText) ? L10n.tr("action_open_in_browser") : L10n.tr("action_send_clipboard"),
                                systemImage: looksLikeURL(inputText) ? "safari" : "doc.on.clipboard"
                            )
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer()

                        Button {
                            pullPCClipboard()
                        } label: {
                            Label(L10n.tr("action_get_clipboard"), systemImage: "arrow.down.doc")
                        }
                    }
                }

                Section {
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 10,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label(L10n.tr("action_pick_photos"), systemImage: "photo.on.rectangle.angled")
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label(L10n.tr("action_pick_files"), systemImage: "folder")
                    }
                } header: {
                    Text(L10n.tr("send_files_section"))
                } footer: {
                    Text(L10n.tr("send_files_footer"))
                }

                if !uploads.isEmpty {
                    Section(L10n.tr("section_uploads")) {
                        ForEach(uploads) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.filename)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Spacer()
                                    if item.isDone {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else if let err = item.error {
                                        Text(err).font(.caption).foregroundStyle(.red)
                                    } else {
                                        Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit())
                                    }
                                }
                                if !item.isDone && item.error == nil {
                                    ProgressView(value: item.progress)
                                        .tint(theme.accentColor)
                                }
                            }
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.tr("tool_send_to_pc"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("action_done")) { dismiss() }
                }
            }
            .onChange(of: selectedPhotoItems) { items in
                guard !items.isEmpty else { return }
                let copy = items
                selectedPhotoItems = []
                Task { await handlePickedPhotos(copy) }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls {
                        Task { await uploadLocalFile(url, securityScoped: true) }
                    }
                }
            }
        }
    }

    private func looksLikeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    private func sendTextOrURL() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                if looksLikeURL(trimmed) {
                    _ = try await NetworkService.shared.openURL(trimmed, on: profile)
                    statusMessage = L10n.tr("toast_url_opened")
                } else {
                    _ = try await NetworkService.shared.sendClipboard(trimmed, on: profile)
                    statusMessage = L10n.tr("toast_clipboard_sent")
                }
                HapticService.shared.success()
                inputText = ""
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func pullPCClipboard() {
        Task {
            do {
                let res = try await NetworkService.shared.getClipboard(from: profile)
                UIPasteboard.general.string = res.text
                HapticService.shared.success()
                statusMessage = res.truncated ? L10n.tr("clipboard_get_truncated") : L10n.tr("toast_clipboard_copied")
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) async {
        for (idx, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "bin"
            let filename = "media_\(Int(Date().timeIntervalSince1970))_\(idx).\(ext)"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? data.write(to: tempURL)
            await uploadLocalFile(tempURL, securityScoped: false, cleanupAfter: true)
        }
    }

    private func uploadLocalFile(_ url: URL, securityScoped: Bool, cleanupAfter: Bool = false) async {
        let accessed = securityScoped ? url.startAccessingSecurityScopedResource() : false
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            if cleanupAfter { try? FileManager.default.removeItem(at: url) }
        }

        let item = UploadItem(filename: url.lastPathComponent)
        uploads.insert(item, at: 0)
        let itemId = item.id

        do {
            _ = try await NetworkService.shared.uploadFile(
                fileURL: url,
                filename: url.lastPathComponent,
                to: profile
            ) { progress in
                Task { @MainActor in
                    if let idx = uploads.firstIndex(where: { $0.id == itemId }) {
                        uploads[idx].progress = progress
                    }
                }
            }
            if let idx = uploads.firstIndex(where: { $0.id == itemId }) {
                uploads[idx].progress = 1.0
                uploads[idx].isDone = true
            }
            HapticService.shared.success()
        } catch {
            if let idx = uploads.firstIndex(where: { $0.id == itemId }) {
                uploads[idx].error = error.localizedDescription
            }
        }
    }
}
