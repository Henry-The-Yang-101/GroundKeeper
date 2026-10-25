import SwiftUI
@preconcurrency import AVFoundation
import GroundKeeperCore

struct ReceiptCameraView: View {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (Data) -> Void
    @State private var camera = ReceiptCamera()
    @State private var ready = false
    @State private var capturing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeading(title: "Take receipt photo", subtitle: "Hold the receipt steady and keep all the text in frame.")
            ZStack {
                CameraPreview(session: camera.session)
                if !ready && error == nil { ProgressView("Starting camera…").padding().background(.regularMaterial) }
                if let error { ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text(error)) }
            }.frame(height: 360).clipped()
            SheetFooter {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if capturing { ProgressView().controlSize(.small) }
                Button("Take photo", systemImage: "camera") {
                    capturing = true
                    camera.capture { result in
                        Task { @MainActor in
                            capturing = false
                            switch result {
                            case .success(let data): onCapture(data); dismiss()
                            case .failure(let failure): error = failure.localizedDescription
                            }
                        }
                    }
                }.buttonStyle(.brass).disabled(!ready || capturing).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 650)
        .task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            guard allowed else { error = "Allow GroundKeeper in System Settings → Privacy & Security → Camera, then try again."; return }
            camera.start { result in
                Task { @MainActor in
                    switch result {
                    case .success: ready = true
                    case .failure(let failure): error = failure.localizedDescription
                    }
                }
            }
        }
        .onDisappear { camera.stop() }
    }
}

/// All capture configuration and delegate state belongs to this serial queue.
/// The preview layer only observes the session on the main thread.
private final class ReceiptCamera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "GroundKeeper.receipt-camera")
    private let output = AVCapturePhotoOutput()
    private var completion: (@Sendable (Result<Data, Error>) -> Void)?

    func start(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                guard let device = AVCaptureDevice.default(for: .video) else { throw LedgerError.unavailable("Connect a camera, or choose a receipt from Photos or Files.") }
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    throw LedgerError.unavailable("This camera cannot capture photos. Choose a receipt from Photos or Files.")
                }
                self.session.addInput(input); self.session.addOutput(self.output)
                self.session.commitConfiguration()
                self.session.startRunning()
                guard self.session.isRunning else { throw LedgerError.unavailable("The camera could not start. It may be in use by another app.") }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }
    func stop() { queue.async { self.session.stopRunning(); self.completion = nil } }
    func capture(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        queue.async {
            guard self.session.isRunning else { completion(.failure(LedgerError.unavailable("The camera is disconnected. Reopen Take photo to try again."))); return }
            self.completion = completion
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        queue.async {
            if let error { self.completion?(.failure(error)) }
            else if let data { self.completion?(.success(data)) }
            else { self.completion?(.failure(LedgerError.invalid("The camera returned no image. Try taking another photo."))) }
            self.completion = nil
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> Preview {
        let view = Preview()
        view.preview.session = session
        return view
    }
    func updateNSView(_ nsView: Preview, context: Context) { }
    final class Preview: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            preview.videoGravity = .resizeAspect
            layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func layout() { super.layout(); preview.frame = bounds }
    }
}
