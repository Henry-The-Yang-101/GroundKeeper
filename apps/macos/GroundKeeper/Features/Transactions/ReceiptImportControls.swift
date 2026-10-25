import SwiftUI
import PhotosUI
import GroundKeeperCore

/// Every source arrives at the same crop sheet and bounded JPEG encoder.
struct ReceiptImportControls: View {
    let onImport: (Data) -> Void
    @State private var photo: PhotosPickerItem?
    @State private var showFile = false
    @State private var showCamera = false
    @State private var cameraData: Data?
    @State private var cropSource: ReceiptCropSource?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                Button("Files…", systemImage: "folder") { showFile = true }
                Button("Take photo…", systemImage: "camera") { showCamera = true }
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            Text("Crop before adding. Images are saved as JPEG, up to 8 MiB each.")
                .font(.caption).foregroundStyle(AppStyle.muted)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                busy = true; error = nil
                Task {
                    do {
                        let data = try await Task.detached(priority: .userInitiated) {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let file = try FileHandle(forReadingFrom: url)
                            defer { try? file.close() }
                            let data = try file.read(upToCount: ReceiptImageProcessor.maximumInputBytes + 1) ?? Data()
                            return try ReceiptImageProcessor.jpeg(data)
                        }.value
                        cropSource = ReceiptCropSource(data: data)
                    } catch { self.error = error.localizedDescription }
                    busy = false
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .task(id: photo) {
            guard let photo else { return }
            busy = true; error = nil
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw LedgerError.invalid("Photos could not load that image. Choose another photo or export it to Files.") }
                try Task.checkCancellation()
                await prepare(data)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            busy = false
            self.photo = nil
        }
        .sheet(isPresented: $showCamera, onDismiss: {
            if let data = cameraData {
                cameraData = nil
                Task { await prepare(data) }
            }
        }) {
            ReceiptCameraView { cameraData = $0 }.vaultSheet()
        }
        .sheet(item: $cropSource) { source in
            ReceiptCropView(source: source, onUse: onImport).vaultSheet()
        }
    }

    private func prepare(_ data: Data) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let jpeg = try await Task.detached(priority: .userInitiated) { try ReceiptImageProcessor.jpeg(data) }.value
            try Task.checkCancellation()
            cropSource = ReceiptCropSource(data: jpeg)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
