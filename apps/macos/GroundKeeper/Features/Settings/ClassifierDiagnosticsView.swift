import SwiftUI
import AppKit

/// Exercises the real bridge with explicitly entered fictional text. It never
/// classifies or changes the disposable transaction workspace automatically.
struct ClassifierDiagnosticsView: View {
    @State private var client = ClassifierClient()
    @State private var status = "Not started"
    @State private var packageURL: URL?
    @State private var sample = "EXAMPLE CAFE"
    @State private var running: Task<Void, Never>?
    @State private var busy = false

    var body: some View {
        Section {
            LabeledContent("Service", value: status)
            if let packageURL { LabeledContent("Selected package", value: packageURL.lastPathComponent) }
            HStack {
                Button("Check Metal GPU") {
                    run {
                        _ = try await client.handshake()
                        let result = try await client.probeGPU()
                        guard result.mlx?.value == 32, result.laya?.value == 32 else { throw ClassifierBridgeError.invalidResponse }
                        status = "MLX GPU and PyTorch MPS verified"
                    }
                }
                Button("Choose model package…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                    panel.message = "Choose a GroundKeeper data-only model package containing classifier.json."
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    packageURL = url; status = "Selected · loads when classifying"
                }
                if packageURL != nil {
                    Button("Clear selection") { packageURL = nil }
                }
            }.disabled(busy)
            TextField("Fictional transaction description", text: $sample)
            HStack {
                Button("Classify sample") {
                    guard let packageURL else { return }
                    run {
                        let access = packageURL.startAccessingSecurityScopedResource()
                        defer { if access { packageURL.stopAccessingSecurityScopedResource() } }
                        let model = try await client.prepareModel(at: packageURL)
                        let result = try await client.classify(ClassifierInput(description: sample, direction: "debit", currency: "CAD"),
                            model: model, partID: UUID().uuidString, revision: 1)
                        status = "\(result.decision?.type ?? "unknown") · \(result.decision?.category ?? "none") · review required"
                    }
                }.disabled(busy || packageURL == nil || sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { Button("Cancel") { running?.cancel() } }
            }
        } header: {
            Text("Local classifier diagnostics")
        } footer: {
            Text("Runs locally in the bundled XPC service. Models require Metal GPU support. Results are suggestions; this tool does not save or edit transactions.")
        }
        .task {
            for await event in await client.events where busy { status = event.stage.replacingOccurrences(of: "_", with: " ") }
        }
        .onDisappear { running?.cancel() }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        running = Task { @MainActor in
            defer { busy = false; running = nil }
            do { try await operation() }
            catch is CancellationError { status = "Cancelled" }
            catch { status = error.localizedDescription }
            await client.shutdown()
        }
    }
}
