import SwiftUI
import GroundKeeperCore

struct OllamaSetupView: View {
    @Environment(AppWorkspace.self) private var workspace
    @State private var models: [OllamaModel] = []
    @State private var selectedName = ""
    @State private var refreshing = false
    @State private var status = ""
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ollama", systemImage: "desktopcomputer").font(VaultTypography.section)
            Text("Use a model you already have in Ollama. No GroundKeeper model download is needed. Open Ollama on this Mac, then refresh the list. Only local text-generation models are supported.")
                .foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Ollama models") { refreshTask = Task { await refresh() } }
                    .disabled(refreshing)
                if refreshing { ProgressView().controlSize(.small) }
                Link("Get Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
            }
            if !models.isEmpty {
                Picker("Installed model", selection: $selectedName) {
                    ForEach(models) { model in
                        Text("\(model.name) · \(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file))").tag(model.name)
                    }
                }
                .disabled(workspace.saving || workspace.processing || refreshing)
                Button("Use Ollama model") {
                    if let selected = models.first(where: { $0.name == selectedName }) { workspace.useOllama(selected) }
                }
                .disabled(workspace.saving || workspace.processing || !workspace.ready || refreshing || !models.contains(where: { $0.name == selectedName }))
            }
            if !status.isEmpty { Text(status).font(.callout).foregroundStyle(AppStyle.muted) }
            if workspace.classifierProvider == "ollama" {
                Label("Selected: \(workspace.ollamaModelName)", systemImage: "checkmark.circle").font(.callout)
            }
            Text("Transaction text and any attached classification evidence go to Ollama on this Mac. Suggestions always need review. Ollama must stay running; model quality and speed vary.")
                .font(.callout).foregroundStyle(AppStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        .task { await refresh() }
        .onDisappear { refreshTask?.cancel() }
    }
    @MainActor private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let available = try await workspace.ollama.models()
            try Task.checkCancellation()
            models = available
            if !models.contains(where: { $0.name == selectedName }) {
                selectedName = models.first(where: { $0.name == workspace.ollamaModelName })?.name ?? models.first?.name ?? ""
            }
            status = models.isEmpty ? "No local text-generation models found. Install a chat or instruction model in Ollama, then refresh." : "Found \(models.count) installed local models."
        } catch is CancellationError {} catch {
            models = []; status = error.localizedDescription
        }
    }
}
